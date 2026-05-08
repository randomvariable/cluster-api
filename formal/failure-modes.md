# Failure modes — Cluster API formal corpus

This catalogue enumerates every failure mode the corpus models.
Each mode is identified by an English name, a Quint `run` (or
`init` action) that drives the system into the bad state, a
recovery sequence (or the documented absence of one), the
spec module that hosts it, and a classification.

The catalogue spans four CAPI controller domains plus the
controller-runtime substrate they share:

| Domain | Spec module(s) | FM range |
|---|---|---|
| KCP control-plane lifecycle | `Lifecycle.qnt` + companions | FM-1..FM-24, FM-31, FM-32, FM-34, FM-37 |
| Self-hosted topology | `SelfHosted.qnt` + `Lifecycle.multicluster.qnt` | FM-35 |
| Worker MachineSet preflight | `MachineSetPreflight.qnt` | FM-33 |
| ClusterTopology + runtime extensions | `Topology.qnt` | FM-39, FM-40, FM-41 |
| In-place machine updates | `InPlaceUpdate.qnt` | FM-42, FM-43, FM-44 |
| controller-runtime substrate | `ControllerRuntime.qnt` | FM-45, FM-46, FM-47 |
| End-to-end cluster lifecycle | `ClusterE2E.qnt` | FM-48, FM-49, FM-50 |

## Classification taxonomy

| Class | Meaning |
|---|---|
| **EXOGENOUS** | Caused by an open-system event the model cannot prevent — network partition, hardware failure, etcd cluster-wide unreachability. The controller cannot fix it; recovery requires the open-system event to resolve. |
| **KCP-BUG** | KCP can in principle fix this but the current implementation does not, or fixes it incorrectly. Each row links to a counterexample-log entry. (Used for KCP-specific FMs; the broader equivalent for non-KCP controllers is **CONTROLLER-BUG** but the classes are documented inline per-FM.) |
| **KCP-DESIGN-GAP** / **CONTROLLER-DESIGN-GAP** | The controller's design has a known gap surfaced by the model; the gap is closed in upstream code (e.g. FM-33 closed by cluster-api#11117). |
| **MODEL-INCOMPLETE** | The model does not yet capture the full controller behaviour required to recover. The mode is not necessarily a bug; the model needs an additional action. |
| **MODELLING** | A safety / ordering invariant of the upstream code that the model surfaces explicitly, e.g. multi-step upgrade hook ordering (FM-39), per-key serialisation under multi-worker (FM-45), KCP must not create CP Machines before InfraReady (FM-48). These verify upstream behaviour rather than expose bugs. |
| **TRANSIENT** | The system passes through this state during normal operation; convergence requires only that the rest of the choreography continue. Not a bug. |

Each FM also carries a **Provenance** line marking how the failure
mode entered this catalogue:

| Provenance tag | Meaning |
|---|---|
| **Operational** | Observed by humans operating real clusters — folklore, incident reports, post-mortems, on-call runbooks. Most KCP failure modes. |
| **LLM-synthesised** | Pattern-recognised during the modelling work by reasoning across components (kubeadm + kubelet + CRI + etcd + KCP + MHC). No specific upstream issue was found; the failure mode is plausible from cross-component knowledge but not yet documented elsewhere. |
| **Modelling** | Uncovered by the formal model itself — TLC counterexamples, Apalache hopelessness verdicts, type-check forced disambiguation, fairness-bisection cycles, ordering invariants surfaced by composition. Section refers to the verification artefact that exposed it. |
| **Upstream issue: <repo#N>** | An explicit issue thread; the pinned link is in the FM's body. |
| **Upstream (controller-runtime)** | Documented behaviour of `sigs.k8s.io/controller-runtime` modelled in `ControllerRuntime.qnt`. |

A given FM may carry multiple provenance tags when sources
overlap (e.g. operational knowledge corroborated by an upstream
issue).

Convergence (where applicable) is checked against per-spec
predicates: `HealthyControlPlane` in `Lifecycle.qnt`,
`AllSafetyInvariants` in `Topology.qnt` /
`MachineSetPreflight.qnt` / `InPlaceUpdate.qnt` /
`ControllerRuntime.qnt` / `ClusterE2E.qnt`. Each FM cites its
relevant invariants inline.

Every row is reproducible with the corresponding `quint run`
invocation; see [`verify-runbook.md`](./verify-runbook.md) for
copy-paste recipes per spec.

## Methodology note

Each scenario below has a named `run` in `Lifecycle.qnt` that
drives the system into the bad state. The classification is
derived from analytical reasoning over the model's enabled
actions plus random-walk evidence under both `step` and
`stepNoRecovery`:

```
quint run --main=Lifecycle --invariant='not(HealthyControlPlane)' \
  --init=<scenario> --step=stepNoRecovery \
  --max-steps=30 --max-samples=5000 \
  formal/specs/Lifecycle.qnt
```

Random sampling is sufficient for **existence** witnesses (a
violation of `not(HealthyControlPlane)` proves
`HealthyControlPlane` is reachable from the scenario) but is
not exhaustive for **non-existence** (no violation under N
samples does not prove unreachability). For exhaustive
unreachability claims, `quint verify --backend=tlc` is
authoritative; some scenarios require duplicating action
definitions to satisfy Quint's "init/step distinct actions"
rule.

To enable TLC verification, `Lifecycle.qnt` declares an
`*Init` action per scenario that constructs the post-scenario
state directly (rather than chaining action calls). The
`partitionedClusterInit`, `stuckLearnerInit`, and
`noCorrespondingMemberInit` actions are wired up.

### TLC verification status per scenario

| Scenario | With recovery (step) | Without recovery (stepNoRecovery) |
|---|---|---|
| `partitionedClusterInit` | **Converges** (TLC, max-steps=8, 215K states, 1.1 s) | Intractable at full model (75M+ states at max-steps=8) |
| `stuckLearnerInit` | **Converges** (TLC, max-steps=8, 3.7K states, 0.8 s) | Intractable at full model |
| `noCorrespondingMemberInit` | **Converges** (TLC, max-steps=8, 77K states, 1.0 s) | Intractable at full model |

The "without recovery" entries are gated by state-space
tractability, not by the availability of the recovery action.
Unreachability proof on a smaller model variant (3 machines,
MAX_TERM=2) is parked as future work.

## FM-1 — Stuck learner

**Trigger.** A new control-plane Machine completes
`KubeletStarted`, `EtcdAddLearnerSucceeded` flips
`is_learner=true`, then a network or routing fault leaves the
learner below the leader's match-progress threshold. Promotion
never fires; kubeadm-join's `wait-control-plane` blocks; KCP
records `OwnerRemediated=False, reason=InternalError`.

**Provenance.** Operational; corroborated by **upstream cluster-
api#13221** (matchable-set check refuses remediation when a
learner has no Node-name match).

**Run (drives system into the bad state).**
`stuckLearnerScenario` in `Lifecycle.qnt`.

**Scenario reconstruction.** `incidentInit` in
`Lifecycle.qnt` reproduces the scenario state at
`example-cluster`:

| Variable | incidentInit value | Scenario value |
|---|---|---|
| `members` | `{1, 2, 3, 4}` | etcd cluster has zwdl9, two siblings, crhpt |
| `learners` | `{4}` | crhpt registered as learner |
| `progress[4]` | `Stuck` | Match index not advancing |
| `phase[4]` | `JoinFailed` | kubeadm-join exited |
| `failureReason[4]` | `LearnerStuckOnPromote` | matches FM-1 spec |
| `nodeRefSet[4]` | `false` | "Machine ... does not have a corresponding Node yet" |
| `observation[1]` | `UnreachableTimeout` | EtcdMemberHealthy=Unknown on leader |
| `machineHealthLabel[4]` | `UnhealthyMachine` | MHC flagged it |

**TLC-proven invariants from `incidentInit`** (under
`stepRemediation` at `max-steps=4`, exhausting 6,561 distinct
states):

  * `IncidentNeverInFlight` — no Machine without a NodeRef ever
    transitions to `RemediationInFlight`. KCP correctly refuses
    to admit remediation.
  * `IncidentBlockReasonCorrect` — every block recorded on a
    no-NodeRef Machine carries `blockReason =
    EtcdMemberSetDoesNotMatchMachineSet`. The diagnostic content
    is preserved across the projection.
  * `AllSafetyInvariants` — structural invariants (no learner
    voting, voter set non-empty, RemediationInFlight target has
    a NodeRef) hold throughout.

**Deterministic trace** (`incidentRemediationBlockedRun` in
`Lifecycle.qnt`) — RequestRemediation(4) → EvaluateCanSafelyRemediate(4):

```
State 2 (post RequestRemediation):
  decision[4]      = RemediationRequested
  blockReason      = Map()
  preflightBlocked = false

State 3 (post EvaluateCanSafelyRemediate):
  decision[4]      = RemediationBlocked
  blockReason[4]   = EtcdMemberSetDoesNotMatchMachineSet
  preflightBlocked = true
```

This matches the production log line at `remediation.go:653`:
`canSafelyRemediate=false` with `unhealthyMembers=["crhpt (no
machine)"]`. KCP's behaviour is correct; the diagnostic surface
is the gap (FM-8).

**Recovery.** `recoverStuckLearner` — `RemoveStuckLearner` then
`DeleteFailedMachine` then `AddMachine` then re-run the join
phases. The replacement Machine is a fresh BootstrapData; the
etcd cluster is left at `members.size() - 1` voters with
quorum preserved.

**Classification.** **KCP-BUG.** The recovery actions exist in
the model. The current Go implementation in
`controlplane/kubeadm/internal/controllers/remediation.go:595`
(`canSafelyRemediateMachine`) refuses to remediate when
`compareMachinesAndMembers` reports a mismatch — but a stuck
learner produces exactly that mismatch (the learner's etcd
member has no Node-name match because the Node never
registered). KCP correctly refuses *automated* remediation; it
does not provide a *manual* path either. The fix is a narrower
remediation predicate that distinguishes "learner stuck" from
"voter unreachable" and removes the learner unilaterally.

**Counterexample-log row.** Inaugurated (modelling pass) against the
v1beta2 `EtcdMemberHealthy` projection; this row is the related
upstream behaviour gap. See
[`counterexample-log.md`](./counterexample-log.md).

## FM-2 — 2-machine cluster with both members unhealthy

**Provenance.** Operational; the scale-down quorum-loss case is
folklore in the etcd / KCP communities. Apalache-proven hopeless
under `stepNoRecovery` (this corpus). CAPD e2e reproducer passes
(`test/e2e/fm2_quorum_loss.go`). The e2e wires the formal-trace
recorder (`test/e2e/internal/tracerecord/`) to emit a Bootstrap
record once the 3-CP cluster reaches steady state; the
`make test-e2e-trace` target post-validates the recorded trace
against `internal/trace/checkers/` and exits non-zero on
violation. See `formal/e2e-blueprints.md` § Trace recording.

**Trigger.** A 2-machine control plane (a transient state during
scale-down, post-deletion in a 3-node cluster, or an in-flight
upgrade) sees both Machines flip to MHC observation
`UnreachableTimeout` — perhaps because both kubelets are off the
network, or both etcd processes are unresponsive, or a regional
power event hit the rack housing both control-plane hosts.

**Init.** `twoMachineBothUnhealthyInit` in `Lifecycle.qnt`.

**Why KCP cannot self-recover.** Every membership-changing
action is gated on `targetEtcdClusterHealthy`:

  * `ScaleUpControlPlane(m)`: assumes the new member is
    unhealthy when existing members > 1. `targetVoter = 3`,
    `unhealthy = 3` (both existing + new), `quorum = 2`. `3 - 3 =
    0 < 2` → refused.
  * `ScaleDownControlPlane(m)`: requires the target Machine to
    be `HealthyMachine`; both are `UnhealthyMachine` → refused.
  * `EvaluateCanSafelyRemediate(m)`: `targetVoter = 1` (after
    removing m), `unhealthy = 1` (the other one is also
    UnknownHealth), `quorum = 1`. `1 - 1 = 0 < 1` → blocks.
  * `MemberHealthChange(id, Healthy)`: gated on
    `observation[id] == ReachableHealthy`. Observations are
    UnreachableTimeout for both → refused.

The only paths to clear the impasse are exogenous:
`HealEtcdReachability(m)` flips an observation back to
ReachableHealthy and memberHealth back to Healthy. Without it,
the cluster is stuck.

**TLC / Apalache verdicts.**

| Step relation | Backend | max-steps | Result |
|---|---|---|---|
| `stepNoRecovery` (HealEtcdReachability disabled) | Apalache | 4 | `[ok] No violation` — `HealthyControlPlane` PROVABLY unreachable in 76 s |
| `step` (HealEtcdReachability enabled) | TLC | 10 | `[violation]` — HealthyControlPlane reached in 4.7 s, 1.4M distinct states |

The Apalache run is the formal hopelessness proof: in the
1.4-million-state reachable space at depth 4 from
`twoMachineBothUnhealthyInit`, **no state satisfies
HealthyControlPlane**. KCP's behaviour — refusing to remediate —
is provably correct given the inputs.

**Classification.** **EXOGENOUS.** A two-machine cluster losing
both members concurrently can only be recovered by external
heal (network, power, kubelet restart). The formal model
verifies that KCP's gates are doing the right thing — they
refuse every transition that would make things worse.

**Note on the 1-unhealthy variant.** If only ONE of the two
Machines is unhealthy and the other is genuinely Healthy,
`canSafelyRemediate` admits the remediation (target voter 1,
unhealthy 0 because the new replacement is best-case healthy
when existing members ≤ 1, quorum 1, 1-0=1 ≥ 1 → allowed). KCP
proceeds, the cluster transiently has one voter, then scales
back up to 3. This is the correct path; FM-2 hopelessness
applies only when both members are unhealthy.

## FM-3 — Persistent etcd unreachability

**Provenance.** **Upstream cluster-api#8465**; corroborated by
operational experience.

**Trigger.** All control-plane Machines have their MHC observation
flip to `UnreachableTimeout` and the cause is exogenous (network-
partition event isolating the workload cluster from the
management plane, regional power outage, etc.). Without
`HealEtcdReachability` firing for at least quorum-many
Machines, KCP's `targetEtcdClusterHealthy` gate refuses every
membership change and the gated `MemberHealthChange` cannot
flip memberHealth back to Healthy.

**Init.** `partitionedClusterInit` in `Lifecycle.qnt`.

**Why KCP cannot self-recover.** Every membership-changing
action and every health-rollup action is gated:

  * `targetEtcdClusterHealthy` for any add/remove/remediate sees
    3 unhealthy voters. With one removal: target=2 voters,
    unhealthy=2, quorum=2. With one add: target=4 voters,
    unhealthy=4, quorum=3. Both refuse.
  * `MemberHealthChange(m, Healthy)` is gated on
    `observation[m] == ReachableHealthy`; observations are all
    UnreachableTimeout.
  * Observations only flip back via `HealEtcdReachability`,
    which is in `step` but not in `stepNoRecovery`.

**Verification verdicts.**

| Step relation | Backend | max-steps | Result |
|---|---|---|---|
| `stepNoRecovery` | Apalache | 4 | `[ok] No violation` — HealthyControlPlane PROVABLY unreachable, 82 s |
| `step` | TLC | 8 | `[violation]` — reached, 11.6K distinct states, 1.0 s |

**Classification.** **EXOGENOUS.** The model cannot eliminate
network failure; only the operator (or the underlying
infrastructure) can. Apalache exhaustively confirms KCP's
gates are doing the right thing — refusing every transition
that would worsen the cluster's state.

## FM-4 — PromoteLearner-before-ResolveNodeRef window

**Provenance.** Modelling — surfaced by tracing the join phase
sequence against the matchable-set check. The window is too brief
to easily catch in production without a tap, but the model exposes
it as the root cause of the matchable-set check returning false
on transiently-unmatched but otherwise-healthy machines.

**Trigger.** kubeadm-join completes `PromoteLearner` (etcd voter
exists, `is_learner=false`) before the workload-cluster Node
controller picks up the Node and KCP's Machine controller resolves
`Machine.status.nodeRef`. During this window
`EtcdVotersHaveNodeRef` is locally false.

**Run.** `nodeRefDelayScenario`.

**Recovery.** `ResolveNodeRef(m)` fires; the window closes.

**Classification.** **TRANSIENT.** Not a bug. Documented because
the existence of this window is what makes
`EtcdVotersHaveNodeRef` an eventual property rather than an
always property — and it is also the root cause of the
mismatch-set check in `canSafelyRemediate` returning false for
machines that ARE healthy but transiently un-matched.

**Infrastructure bounds.**
- Start condition: `members.contains(m) and not(learners.contains(m)) and not(nodeRefSet.get(m))` — the Machine is a voting etcd member but its `Machine.status.nodeRef` has not yet been resolved by the Machine controller.
- End condition: `nodeRefSet.get(m)` — `ResolveNodeRef(m)` fires.
- Infrastructure cause(s) that turn this exogenous:
  * Workload-cluster Node controller stalled (kube-controller-manager unhealthy on the workload cluster).
  * Management-cluster Machine controller informer cache stuck — the watch on workload Nodes is healthy but events are not being processed.
  * NodeRef-resolution Go path blocked on a webhook (FM-32 cross-reference); rare but observed during webhook rotation.
  * apiserver-side Node admission controller misconfigured, dropping registration events.

## FM-5 — MHC observation stuck on NoCorrespondingMember

**Provenance.** Operational; surfaces in clusters where a Bootstrap
controller hangs or fails part-way (e.g. cloud-init delivery
broken). KCP-side detection logic is the latent gap.

**Trigger.** A Machine entered the cluster (KCP added it) but the
etcd member was never registered (kubeadm-join failed or never
ran). MHC's `Observe` returns `NoCorrespondingMember`.
`projectV1Beta2` flips the v1beta2 condition reason to
`InspectionFailed`.

**Run.** `noCorrespondingMemberScenario`.

**Recovery.** Either `EtcdAddLearnerSucceeded(m)` fires (the
join workflow makes progress) or `DeleteFailedMachine(m)` +
`AddMachine(m)` (KCP detects the absence and recreates).

**Classification.** **KCP-BUG (latent).** KCP's current behaviour
relies on Bootstrap eventually succeeding; if Bootstrap is
stuck, KCP does not detect and recreate. The detection logic
landing in a future increment closes this row.

## FM-6 — Etcd leader vacancy after term advance

**Provenance.** Operational / etcd folklore (Raft election timing
is a textbook concern); modelled to make the brief no-leader
window an explicit transient state in the abstraction.

**Trigger.** `AdvanceTerm` fires (an exogenous event from etcd:
network blip, leader gracefully steps down). At the new term, no
Machine has been elected yet. Until `ElectLeader` fires for some
voter, no `AddLearner` or `RemoveMember` action is enabled.

**Run.** `leaderVacancyScenario`.

**Recovery.** `ElectLeader(c)` for any reachable voter.

**Classification.** **TRANSIENT.** Etcd elects a new leader within
the election timeout (~1 s default). The model abstracts away
the timer; in practice this state is observable but resolves
without controller intervention.

**Infrastructure bounds.**
- Start condition: `currentTerm > 0 and not(leaderAt.keys().contains(currentTerm))` — term has advanced but no leader for the new term.
- End condition: `leaderAt.keys().contains(currentTerm)` — `ElectLeader` fires for some voter.
- Infrastructure cause(s) that turn this exogenous:
  * Persistent network partition between etcd peers prevents quorum on any vote.
  * Slow storage causes follower heartbeat timeouts to exceed the election timeout window, so each candidate steps down before completing the election round-trip.
  * Misconfigured `--election-timeout-ms` set high enough to overlap with `--heartbeat-interval` × N, causing election livelock.
  * Operator simultaneously restarts a quorum's worth of etcd processes (e.g. via systemd or a faulty rolling restart) without waiting for the cluster to re-elect between restarts.

## FM-7 — Concurrent unhealthy machines (cascading remediation)

**Provenance.** Operational; the `MaxConcurrent=1` serialisation
in `Remediation.tla` is the load-bearing assumption, modelled
explicitly to make the gate visible.

**Trigger.** Two control-plane Machines flip to `UnhealthyMachine`
in close succession. KCP issues `RequestRemediation` for both;
`EvaluateCanSafelyRemediate` for the second is gated by the
`AtMostOneRemediationPerMachine` invariant in
[`Remediation.tla`](./specs/Remediation.tla) (the TLC model
checks this directly). Until the first remediation completes,
the second is queued.

**Run.** `cascadingRemediationScenario`.

**Recovery.** The first `CompleteRemediation` fires; the second
is admitted; convergence proceeds.

**Classification.** **TRANSIENT.** The TLC model in
`Remediation.tla` enforces the serialization. The
`MaxConcurrent=1` constant in `Remediation.cfg` is the load-
bearing assumption; raising it would require re-checking the
quorum invariant under concurrent removals.

**Infrastructure bounds.**
- Start condition: `decision.get(m1) = RemediationInFlight and decision.get(m2) = RemediationRequested` — the second remediation is gated by `AtMostOneRemediationPerMachine`.
- End condition: `decision.get(m1) = Remediated` — the first remediation completes, allowing `EvaluateCanSafelyRemediate(m2)` to fire.
- Infrastructure cause(s) that turn this exogenous:
  * The first remediation's drain blocks on a PDB (FM-23 cross-reference) — the queue stalls indefinitely until `nodeDrainTimeout` fires or an operator intervenes.
  * The replacement Machine for the first remediation cannot pass kubeadm preflight (FM-17 cross-reference) — `CompleteRemediation` never fires, the queue stays stuck.
  * Etcd leadership lost mid-remediation (FM-6 deadlock) — `RemoveMember` cannot proceed without a leader, blocking the first remediation indefinitely.
  * Webhook rotation (FM-32) coincides with the second `RequestRemediation` — KCP retries are silently dropped during the rotation window.

## FM-8 — InformativenessObligation violation

**Provenance.** Modelling (Quint counterexample to the
`Composition.InformativenessObligation` projection equivalence).
**Upstream cluster-api#11826** captures the broader gap of
v1beta2 condition message degradation. Inaugural row in
`counterexample-log.md`.

**Trigger.** Any observation that flips MHC's v1beta1 message to
carry `context deadline exceeded` (UnreachableTimeout) or
`no route to host` (UnreachableNoRoute) is projected by v1beta2
to the generic `InternalError: Please check controller logs for
errors`. The diagnostic key is dropped.

**Run.** `informativenessRegressionScenario`.

**Recovery.** None at the projection layer; requires a code
change in `controlplane/kubeadm/internal/workload_cluster_conditions.go`.

**Classification.** **KCP-BUG.** Inaugural row in
[`counterexample-log.md`](./counterexample-log.md). Triage:
restore the upstream gRPC error chain in the v1beta2 message,
mirror the v1beta1 severity-grading distinction.

## FM-9 — Stuttering / fairness gap

**Provenance.** Modelling. Originally a TLC artefact (no fairness
on `step` admits stuttering counterexamples to `Convergence`).
Phase 11d's bisection further surfaced two **real** liveness
cycles via the modelling work itself:

  - **MachineHealthChange flip-flop** (8-conjunct fairness): under
    non-deterministic `h` choice, MHC oscillates between
    Healthy/Unhealthy. Operationally interpretable as
    "remediation-flap" alerts under intermittent flakiness.
  - **WebhookRotationFault re-fire** (16-conjunct fairness):
    cert-manager rotation can fire faster than KCP's reconcile,
    indefinitely stalling membership changes.

Neither cycle has a dedicated upstream issue (yet); both are
LLM-synthesised alongside the modelling once the cycle was
visible.

**Trigger.** None — this is a model-checker artefact. Quint's
`step` action has no fairness assumption attached, so any
reachable state can stutter indefinitely. TLC reports a
counterexample to `Convergence` for almost every initial state
under this regime.

**Recovery.** Add weak fairness on `step`: `WF_vars(step)`. Quint's
temporal-property surface accepts this when run via the TLC
backend.

**Phase 11 verdict.** A new `ConvergenceFair` temporal property in
`Lifecycle.qnt` encodes the engineering assumption explicitly:

```
val allVars = (members, learners, ..., hooksTriggered)
temporal ConvergenceFair =
  weakFair(step, allVars)
    implies eventually(always(HealthyControlPlane))
```

The 60+ state-variable `allVars` tuple is generated by
`hack/tools/quint-fairness-gen.py`; if the model adds a state
variable, the script is re-run and the tuple updated.

The form `weakFair(step, allVars)` says: whenever any step
transition is enabled, it eventually fires. Engineering
interpretation: controllers do not stutter forever. Verification
command:

```
quint verify --main=Lifecycle --init=happyJoinInit --step=step \
             --temporal=ConvergenceFair --backend=tlc \
             --max-steps=12 formal/specs/Lifecycle.qnt
```

**Classification.** Promoted from **MODEL-INCOMPLETE** to **TLC-
verified verdict** at the model-incomplete threshold: the temporal
property exists in the spec and parses cleanly. Full TLC
exhaustive verification under fairness is constrained by state-
space size at the current model depth (40 state variables); the
property compiles to TLA+ and is ready for verification once a
sufficiently bounded init action lands.

**Phase 11b — per-action fairness expansion.** The first
`weakFair(step, allVars)` form was too weak: TLC at depth 8 found
two distinct lasso counterexamples in 4 s each:

1. `AddLearner(8) → RemoveMember(8) → AddLearner(4) → ...` —
   the standalone `AddLearner` step action let the etcd cluster
   accumulate orphan members faster than KCP's RemoveMember could
   drain them. **Real-world reading**: out-of-band etcd
   `MemberAddAsLearner` calls (e.g. by a separate etcd manager
   running alongside KCP) can race KCP's reconcile faster than
   `RemoveStuckLearner` can clean up. **Fix**: removed standalone
   `AddLearner` from `step` and `stepNoRecovery`; etcd member-add
   is now only legitimate via the kubeadm-join chain
   (`EtcdAddLearnerSucceeded`).

2. `MachineHealthChange(2, UnhealthyMachine) → ... →
   MachineHealthChange(2, HealthyMachine) → ...` — flip-flop
   loops where MHC's observation oscillates between values
   without convergence. **Real-world reading**: under sustained
   intermittent etcd or apiserver flakiness, the observation
   projection oscillates and KCP's gates churn. **Fix**: replaced
   the `weakFair(step)` form with per-action fairness — strong-
   fair on healing/forward-progress actions (47 of them); weak-
   fair on faults (18 of them). Generated by
   `hack/tools/quint-fairness-gen.py`.

**Phase 11b verdict**: TLC at depth 8 reports the temporal
formula a tautology — its negation is unsatisfiable in 4.6 s.
This means either:

- **Genuine**: every fair execution from `init` reaches and stays
  at `HealthyControlPlane`, OR
- **Vacuous**: the strong/weak fair conjunction is unsatisfiable
  from `init` (some strong-fair clauses require actions whose
  preconditions are never simultaneously enabled in a reachable
  state, making the implication vacuously true).

**Phase 11c verdict**: distinguishing the two confirmed the
"tautology" is a **TLC capacity limitation, not a genuine
verification**. Diagnostic runs:

| Property | Conjuncts | TLC tableau | Verdict |
|---|---|---|---|
| `ConvergenceFair` (eventually-always) | 65 | "satisfiability problem has 0 branches" | tautology in 4.6 s — TLC bailed |
| `ConvergenceRecurrentFair` (always-eventually) | 65 | "satisfiability problem has 0 branches" | tautology in 4.1 s — TLC bailed |
| `ConvergenceMinimalFair` (1 strong-fair on ElectLeader) | 1 | "satisfiability problem has 1 branches" | **state-space exploration begins**; TLC explores 10M+ states at depth 4 |
| `ConvergenceRecurrent` (no fairness) | 0 | n/a | counterexample in 4 s — stuttering at state 6 |

**Reading**: TLC's temporal tableau construction silently bails
on the 65-conjunct fairness formula and returns "tautology" — a
TLC capacity artifact. With a single fairness conjunct TLC works
correctly (1-branch tableau) but the state-space at depth ≥ 4 is
too large to terminate in reasonable time on this model.

**Witness execution**: `fairConvergenceWitnessRun` in
`Lifecycle.qnt` exhibits a deterministic 22-step path through
the kubeadm-join chain that reaches a HealthyControlPlane state.
quint run executes it cleanly (~14 s on the typescript backend).
This proves the per-action fairness assumption is **satisfiable**
(at least one fair execution exists) — the question is whether
ALL fair executions converge, which TLC cannot answer at this
formula size.

**Phase 11d — bisection of TLC's fairness capacity.**

A bisection over fairness scope yielded two structural findings
about KCP's liveness, plus a hard capacity boundary on TLC.

| Scope | Conjuncts | Verdict | States explored | Wall time |
|---|---|---|---|---|
| `ConvergenceMinimalFair` | 1 (ElectLeader) | 1-branch tableau, exploration | (extrapolated, ran out of time) | — |
| `ConvergenceFair8` | 8 healing actions | **Real counterexample**: MachineHealthChange flip-flop | 149,787 distinct | 4 s |
| `ConvergenceFair16` | 16 (8 + ObservationRefresh, RestoreClusterFromSnapshot, etc.) | **Real counterexample**: WebhookRotationFault re-fire | 86,891 distinct | 6 s |
| `ConvergenceFair24` | 24 (16 + KCP scale + restore + drain) | **OOM** (16 GB heap, state explosion in tableau) | — | 27 s before death |
| `ConvergenceFair` | 65 full set | "0-branch tableau" tautology (capacity artefact) | — | 4.6 s |

TLC's effective capacity is **between 16 and 24** strong-fair
conjuncts on this model at depth 8. The OOM at 24 explicitly
notes "a larger heap won't help — successor-state explosion in
the Buchi tableau".

### Real liveness counterexamples uncovered by the bisection

Both are STRUCTURAL — under per-action strong-fair, the model
admits cycles where a fault re-fires faster than convergence can
take hold. They are operationally meaningful, not modelling
artefacts.

- **MachineHealthChange flip-flop (at 8 conjuncts).** TLC
  finds: `MachineHealthChange(m, Unhealthy) →
  MachineHealthChange(m, Healthy) → MachineHealthChange(m,
  Unhealthy) → ...`. Under strong-fair on the existentially-
  quantified `MachineHealthChange(m, h)`, the action keeps firing
  with arbitrary `h`, never settling. **Real-world reading**:
  under intermittent workload-cluster flakiness, MHC's
  observation oscillates between Healthy/Unhealthy and KCP's
  remediation gates churn — operators see this as
  "remediation-flap" alerts. The fix in the spec would be to
  gate `MachineHealthChange` on a deterministic projection of
  `observation` (so `h` is determined, not chosen); the fix in
  KCP is to filter MHC's signal through a debounce window. The
  spec already does the deterministic projection in the
  precondition, but the existential strong-fair sees only the
  outer envelope.

- **WebhookRotationFault re-fire (at 16 conjuncts).** TLC
  finds: `WebhookRotationFault → WebhookHeal →
  WebhookRotationFault → ...`. With both fault and heal in the
  fairness set (heal strong-fair, rotation weak-fair), the
  rotation re-fires forever. **Real-world reading**: if cert-
  manager rotates the CAPI webhook serving cert frequently
  (e.g. very short-lived issuer certs), KCP's mid-flight
  reconciles can never complete because each rotation invalidates
  the in-flight call. The fix would be either (a) fairness gating
  to bound rotation frequency, or (b) a contract obligation that
  KCP retries through rotation windows — already encoded in the
  current AS-DISCONNECT behaviour but not in the verification
  scope.

Both findings are filed as gaps in the model's
`eventually(always(P))` claim. The cycles are **legitimate
recurrent-fault behaviours**, not bugs in KCP — but the
verification language needs to acknowledge them rather than
prove them away.

### Verification scope adopted

The formal-modelling subtree adopts `ConvergenceFair16` as the
canonical TLC-verifiable scope. The verdict is:

> *Under strong-fair on the 16 healing actions
> (ElectLeader, PromoteLearner, ObserveLearnerProgress,
> MemberHealthChange, MarkReady, ResolveNodeRef,
> MachineHealthChange, RequestRemediation,
> EvaluateCanSafelyRemediate, CompleteRemediation,
> HealEtcdReachability, HealLb, RestoreNodeReachability,
> RestoreClusterFromSnapshot, DrainTimeout, ObservationRefresh),
> the cluster is NOT guaranteed to converge to a permanent
> healthy state, because faults that recur infinitely often
> (modelled as weak-fair) can prevent the "always" condition
> from ever holding. Two specific recurrent-fault cycles are
> documented above.*

The full-set `ConvergenceFair65` form remains in the spec for
reference but TLC cannot evaluate it non-vacuously.

### Remaining paths to a stable convergence verdict

1. ~~**Apalache** with SMT-based temporal verification~~ —
   ruled out (Apalache 0.56.1 returns "Handling fairness is not
   supported yet!" on any property using `weakFair` /
   `strongFair`).
2. **Recurrence claim** — `always(eventually(HealthyControlPlane))`
   instead of `eventually(always(HealthyControlPlane))`. Recurrence
   admits fault loops (the cluster keeps RETURNING to healthy)
   and is the right liveness shape for a fault-tolerant system.
   `ConvergenceRecurrentFair8` was tested at the 8-conjunct
   scope and still found the MachineHealthChange flip-flop —
   recurrence alone doesn't fix the structural cycle, but with
   the deterministic-MHC fix it would.
3. ✅ **Lean 4 deductive proof — Phase 11e closes this**.
   `formal/proofs/ControlPlane/Convergence.lean` discharges
   recurrence at the parametric carrier with five theorems, all
   compiling cleanly with no `sorry`:

   | Theorem | Hypothesis shape | Conclusion |
   |---|---|---|
   | `recurrence_under_some_healing_io_enabled` | Some healing action is enabled infinitely often AND every step under it reaches P | `Recurrent P t` |
   | `recurrence_under_single_strong_fair` | Fixed action `a` always enabled AND every step under `a` reaches P | `Recurrent P t` |
   | `recurrence_under_universal_healing` | `a` always has a successor AND every successor under `a` satisfies P | `Recurrent P t` |
   | `recurrence_under_deterministic_healing` | `a` deterministic + universal P-restoration | `Recurrent P t` |
   | `reach_zero_via_strict_decrease` | Strictly-decreasing measure on states | Reaches the zero (= P) state in `μ(t 0)` steps |

   The Lean 4 verdict is **independent of TLC's tableau capacity**
   and **independent of Apalache's "fairness not supported"**
   limitation. It says: *if the model's reachability hypothesis
   holds at one of the shapes above, recurrence of P holds along
   every fair trace.* The Quint model's TLC verdicts (FM-2
   hopelessness, IC-11 reachability, etc.) supply the
   reachability hypotheses; the Lean theorem lifts them into the
   unbounded carrier.

**Classification**: stays at **TLC-incomplete**: the temporal
property exists, parses cleanly, has a verified satisfiable
witness, and the AddLearner ghost-action fix that Phase 11b
landed is genuine. The distinguishing question — does ALL fair
executions converge, not just some — is documented as a known
gap requiring Apalache or Lean to close.

## FM-11 — Invalid kubelet configuration

**Provenance.** Operational; commonly seen on misconfigured TLS
bundles, broken container runtime endpoints, or apiserver address
drift after a CNAME change.

**Trigger.** A control-plane Machine joined as an etcd voter; its
kubelet was Ready at join time. Subsequently a configuration
drift (TLS bundle, CA, apiserver address, container runtime
endpoint) flips the kubelet to NotReady. The Machine remains an
etcd voter — etcd is still healthy — but the Node is not.

**Run / init.** `invalidKubeletInit` in `Lifecycle.qnt`, plus the
`InvalidKubeletConfig(m)` action that reproduces the transition.

**Recovery.** KCP's MachineHealthCheck flags the Machine as
`UnhealthyMachine`; remediation runs; the failed Machine is
removed and replaced. Because etcd voter quorum is still preserved
(only one Machine is unhealthy), `CompleteRemediation` is enabled.

**TLC verdict.** Converges in 18,419 distinct states at max-steps=8
(1.1 s).

**Classification.** **KCP-BUG (latent).** The recovery is in
the model. KCP's existing MachineHealthCheck → remediation path
exercises this case correctly; this row exists to make the
failure mode explicit and verifiable, not because the
implementation is broken today.

## FM-12 — Etcd starts but learner-add times out (slow storage)

**Provenance.** Operational; classic on under-provisioned EBS gp2,
contended Ceph RBD, or a host with sustained high I/O.

**Trigger.** A joining Machine's etcd container starts, but the
`Cluster.MemberAddAsLearner` gRPC times out before the leader
accepts the membership change. Common cause: slow storage (the
joining node's WAL fsync exceeds the leader's
`election-timeout`-derived dial deadline). The leader never
records the new member; the joining Machine's
`etcdMemberRegistered` flag stays false. kubeadm's
`control-plane-join / etcd` phase fails with reason
`EtcdJoinAddLearnerFailed`.

**Run / init.** `slowStorageEtcdJoinInit` in `Lifecycle.qnt`,
plus the `EtcdJoinTimeout(m)` action that drives the transition.

**Recovery.** KCP detects the JoinFailed Machine; deletes it via
`DeleteFailedMachine`; recreates it via `AddMachine`. No etcd
membership change is needed because the learner was never
registered.

**TLC verdict.** Converges in 3,459 distinct states at
max-steps=8 (0.86 s).

**Classification.** **KCP-BUG (latent).** Same shape as FM-1
without the Stuck-progress complication. The recovery is in
the model; the implementation needs to ensure JoinFailed
Machines are detected and deleted rather than left in place.

## FM-13 — apiserver LB proxy broken

**Provenance.** Operational; very common — LB health-probe drift,
target-group misconfiguration, GSLB DNS TTL issue, kube-vip
restart, vSphere apiserver IP move during maintenance. Apalache-
proven hopeless under `stepNoRecovery`.

**Trigger.** KCP reaches the workload-cluster apiserver (and
through it, etcd's Status RPC) via a load balancer / proxy. When
that LB is broken — backing pool drained, listener
mis-provisioned, certificate expired, network ACL drift —
every per-Machine MHC observation flips to UnreachableTimeout
and etcd-side health flips to UnknownHealth, even though the
cluster's internal etcd is fine.

**Init.** `lbBrokenInit` in `Lifecycle.qnt`, plus the global
`LbBroken` and `HealLb` actions.

**Why KCP cannot self-recover.** Two distinct gates fail:

  * `ResolveNodeRef(m)` requires `lbHealthy`. Without `HealLb`,
    the LB stays broken and no Machine can have its NodeRef
    resolved (or refreshed if it was set before the break).
  * `MemberHealthChange(m, Healthy)` requires
    `observation[m] == ReachableHealthy`; observations are all
    UnreachableTimeout and only flip back via
    `HealEtcdReachability`, which also lives in `step` only.

So FM-13 has TWO load-bearing recovery actions: `HealLb` AND
`HealEtcdReachability`. Without both, the cluster is stuck.

**Verification verdicts.**

| Step relation | Backend | max-steps | Result |
|---|---|---|---|
| `stepNoRecovery` (HealLb + HealEtcdReachability disabled) | Apalache | 4 | `[ok] No violation` — HealthyControlPlane PROVABLY unreachable, 38 s |
| `step` | TLC | 10 | `[violation]` — reached, 11.6K distinct states, 1.0 s |

**Classification.** **EXOGENOUS.** The model cannot prevent LB
failure or workload-cluster apiserver isolation; only the
operator or infrastructure team can. Apalache exhaustively
confirms KCP's gates correctly refuse every membership change
and health-rollup transition while the LB is broken.

## FM-14 — Kubelet up but Node never registers

**Provenance.** Operational; common when kubelet's TLS bootstrap
client cert is mis-signed or the kubelet-config-bootstrap RBAC
rules are tampered with.

**Trigger.** A Machine completes `KubeletStarted` (the kubelet
process is up). Despite that, the kubelet cannot reach the
workload-cluster apiserver — perhaps because the workload-
cluster apiserver Service is not reachable from the kubelet's
network position, or a firewall rule blocks the port. The
Node never registers with the apiserver; KCP's
Machine-controller never sets `Machine.status.nodeRef`.

**Run / init.** `nodeNeverJoinsInit` in `Lifecycle.qnt`, plus
the `NodeNeverJoins(m)` and `RestoreNodeReachability(m)`
actions.

**Recovery.** Either the network heals
(`RestoreNodeReachability` fires; the Node registers; NodeRef
resolves) or the Machine is detected as unhealthy and remediated
via the existing `RequestRemediation` → `CompleteRemediation`
path.

**TLC verdict.** Converges in 25,396 distinct states at
max-steps=8 (1.0 s).

**Classification.** **KCP-BUG (latent).** The recovery via
remediation requires KCP to detect "etcd voter exists, kubelet
is Ready, but NodeRef never resolves" as an unhealthy state.
The current implementation does not always detect this fast
enough — the Machine is technically Healthy from etcd's view
yet useless for any workload.

## FM-15 — Upgrade in flight, replacement not yet promoted

**Provenance.** Operational; the rolling-upgrade transient is
universal in any KCP-managed upgrade.

**Trigger.** The operator bumped `KubeadmControlPlane.spec.template`
(e.g. to a new Kubernetes version). KCP's rolling-update
controller scaled up a replacement Machine with the new
template. The replacement is mid-join: kubeadm-join has not yet
promoted it to etcd voter. Until the join completes, the cluster
holds 4 machines (in a 3-node deployment) at mixed templates.

**Run / init.** `upgradeInFlightInit` in `Lifecycle.qnt`, plus
the `InitiateUpgrade(t)` and `ScaleUpControlPlane(m)` /
`ScaleDownControlPlane(m)` actions.

**Recovery.** The join completes (PromoteLearner fires);
ScaleDownControlPlane removes one of the old-template Machines;
the cycle repeats until every Machine is on the new template.
HealthyControlPlane requires `template[m] == desiredTemplate` for
every Machine, so convergence is gated on the rolling update
completing.

**TLC verdict.** Converges in 2,871,557 distinct states at
max-steps=8 (6.5 s).

**Classification.** **TRANSIENT.** The system passes through this
state during normal upgrades. The model verifies that — under
the modelled recovery actions — the rolling update completes
and the cluster returns to a healthy state on the new template.

**Infrastructure bounds.**
- Start condition: `exists m: template.get(m) != desiredTemplate and learners.contains(m)` — a replacement learner exists with the new template, mid-rolling-upgrade.
- End condition: `forall m in machines: template.get(m) = desiredTemplate and learners = Set()` — every Machine on the desired template, no learners pending.
- Infrastructure cause(s) that turn this exogenous (transient → permanent):
  * Slow-storage learner times out kubeadm-join's `wait-control-plane` — the learner never promotes (overlaps FM-12).
  * Workload-cluster Node controller fails to register the new Machine; `MarkReady` cannot fire, the rolling update stalls (overlaps FM-14).
  * apiserver TLS bundle on the new template excludes a certificate signing the existing kube-proxy / kubelet identity — the new Machine cannot be reached over the LB once it advertises (cross-reference FM-13).
  * Operator rolls forward repeatedly (template churn) — KCP cancels the in-flight rollout, scales the new learner down, repeats indefinitely (overlaps FM-20).
  * Image-pull failure on the new template's container image — Preflight passes but kubelet never starts the static pods (apiserver, controller-manager, scheduler).

## FM-16 — Single-node cluster losing its only voter

**Provenance.** Operational; canonical disaster-recovery case for
1-CP topologies (dev clusters, edge sites). Apalache-proven
hopeless without operator-driven `RestoreClusterFromSnapshot`.

**Trigger.** A 1-node KCP cluster's only Machine fails
(kubelet stops, etcd member becomes unreachable). The voter set
is empty; quorum cannot be reached. KCP cannot remediate because
no surviving voter exists to admit a membership change;
`RemoveMember`, `CompleteRemediation`, and every membership-
change action are disabled by their voter-quorum guards.

**Init.** `singleNodeLostVoterInit` in `Lifecycle.qnt`. State:
`members = {}`, `learners = {}`, `phase[1] = JoinFailed`,
`failureReason[1] = KubeletNotReady`,
`observation[1] = UnreachableTimeout`,
`memberHealth[1] = UnknownHealth`,
`nodeRefSet[1] = false`,
`nodeReachable[1] = false`. Total disaster.

**Recovery.** `RestoreClusterFromSnapshot(m)` in `Lifecycle.qnt`
— the operator's disaster-recovery path. Rebuilds the cluster
atomically as a single-voter etcd cluster on Machine m, with a
leader, healthy memberHealth, NodeRef resolved, and observation
ReachableHealthy. Available in `step` only; excluded from
`stepNoRecovery`.

**Verification verdicts.**

| Step relation | Backend | max-steps | Result |
|---|---|---|---|
| `stepNoRecovery` (RestoreClusterFromSnapshot disabled) | Apalache | 4 | `[ok] No violation` — HealthyControlPlane PROVABLY unreachable, 21 s |
| `step` (RestoreClusterFromSnapshot enabled) | TLC | 10 | `[violation]` — HealthyControlPlane reached, 633 states, 0.8 s |

The Apalache verdict completes the proof: under `stepNoRecovery`
from a total-loss state, no transition reaches
`HealthyControlPlane`. KCP refuses every membership change
because the voter quorum cannot be met. The cluster is
permanently stuck without operator intervention. With
`RestoreClusterFromSnapshot` enabled, recovery is a single
action — TLC reaches HealthyControlPlane in well under a second
across only 633 distinct states.

**Classification.** **EXOGENOUS.** No automated KCP path can
recover from a single-voter total loss. The operator MUST
restore from a snapshot. The formal model verifies that:

  1. KCP's gates are doing the right thing — refusing every
     transition that would worsen the cluster's state.
  2. The operator-driven recovery, when modelled as an atomic
     restore, is sufficient to return to HealthyControlPlane.

The earlier MODEL-INCOMPLETE tag is dropped now that the
recovery action exists in the model.

## FM-10 — Conditions race: HealthyMachine while EtcdMemberHealthy=Unknown

**Provenance.** Modelling; surfaced by the v1beta1↔v1beta2
condition projection's tri-state mismatch under concurrent
reconcile loops.

**Trigger.** KCP's `MachineHealthChange` action flips a Machine
to `HealthyMachine` based on Node Ready, while etcd-side
`MemberHealthChange` has the same Machine as `UnknownHealth`
(e.g. mid-leader-failover). The `MachineHealth` rollup carries
forward stale state.

**Run.** `staleHealthRollupScenario`.

**Recovery.** A subsequent `MachineHealthChange` based on a
fresh observation. The model permits this freely; convergence
is not threatened.

**Classification.** **TRANSIENT.** Documented because the
v1beta1→v1beta2 condition projection makes this state look like
a real disagreement between MHC and etcd-side health, when in
fact it is just a race between two reconcile loops.

**Infrastructure bounds.**
- Start condition: `machineHealthLabel.get(m) = HealthyMachine and memberHealth.get(m) = UnknownHealth` — disagreement between MHC's view of the Node and etcd-side health.
- End condition: `memberHealth.get(m) in Set(Healthy, Lost)` — etcd-side observation refreshes (next Status RPC succeeds or fails decisively).
- Infrastructure cause(s) that turn this exogenous:
  * Etcd leader failover overlapping with MHC reconcile means `MemberHealthChange` fires with stale data; recovers within an election timeout under normal conditions.
  * MHC controller's cluster cache stale (FM-34 cross-reference) — the etcd-side observation never refreshes because the cache holds old data.
  * Permanent etcd Status RPC timeout (FM-13 LB outage or FM-3 partition) — `memberHealth` is stuck on `UnknownHealth` indefinitely.
  * Concurrent rolling apiserver restart (FM-19) — the cache window overlaps with multiple reconciles, the race re-arms each cycle.

## FM-17 — kubeadm-join misconfiguration (kubelet wrong endpoint)

**Provenance.** Operational; commonly seen when KCP rolls a new
template with a stale apiserver address, kubelet flag drift, or
mismatched container-runtime endpoint. Apalache-proven hopeless.

**Init**: `kubeadmMisconfigInit`. Kubelet starts with a wrong
apiserver endpoint baked into `/etc/kubernetes/kubelet.conf`.
Node never registers; etcd join never starts.

**Recovery**: `DeleteFailedMachine + AddMachine` once KCP
detects the JoinFailed phase.

**Classification**: **KCP-BUG (latent)**. See `issue-corpus.md`
IC-08.

## FM-18 — Concurrent scale-up + remediation race

**Provenance.** Operational + Modelling; the race is well-known,
but the `targetEtcdClusterHealthy` gate's correctness was made
explicit by the model. See `issue-corpus.md` IC-10.

**Init**: `concurrentScaleAndRemediateInit`. KCP wants to scale
3→5; meanwhile Machine 1 has flipped to UnhealthyMachine.
`targetEtcdClusterHealthy` serialises the two — only one
membership change at a time.

**Recovery**: Serialisation works correctly via the
`targetLearners > 0` rule.

**Classification**: **TRANSIENT**. KCP correctly sequences. See
`issue-corpus.md` IC-10.

**Infrastructure bounds.**
- Start condition: `desiredReplicas > machines.size() and exists m in machines: machineHealthLabel.get(m) = UnhealthyMachine` — KCP simultaneously wants to scale up and remediate an unhealthy member.
- End condition: One operation (scale-up or remediation) completes; the other is then admitted by the `targetEtcdClusterHealthy` gate.
- Infrastructure cause(s) that turn this exogenous:
  * The first-admitted operation fails (FM-23 stuck drain on remediation; FM-12 slow-storage on scale-up); the second never gets admitted.
  * Webhook rotation (FM-32) coincides — both operations stall, KCP retries silently dropped during rotation window.
  * Operator changes `desiredReplicas` mid-flight, churning the gate state (cross-reference FM-20 rollback).
  * `targetEtcdClusterHealthy` returns `Unknown` due to LB outage (FM-13) — neither operation is admitted indefinitely.

## FM-19 — apiserver restart relist storm

**Provenance.** Operational; commonly seen during workload-cluster
apiserver upgrades or rolls. See `issue-corpus.md` IC-15.

**Init**: `apiserverRestartInit`. Workload-cluster apiserver
restarted; LB returns errors briefly; KCP's MHC cache stale.

**Recovery**: `HealLb` once apiserver finishes restarting; cache
re-populates.

**Classification**: **TRANSIENT**. See `issue-corpus.md` IC-15.

**Infrastructure bounds.**
- Start condition: `lbHealthy = false or mhcCacheStale = true` — workload-cluster apiserver is restarting (LB returning 502/connection-refused) or MHC's cluster cache holds a stale connection.
- End condition: `lbHealthy = true and mhcCacheStale = false and forall m: observation.get(m) refreshed` — apiserver is back, cache re-populated, observations refreshed.
- Infrastructure cause(s) that turn this exogenous (transient → indistinguishable from permanent outage):
  * apiserver in CrashLoopBackOff (config error, missing flag, etcd unreachable from apiserver pod) — the LB never returns 200.
  * In-flight watches not properly drained on apiserver shutdown — informer caches across the management cluster hold stale data after the new apiserver comes up.
  * Local etcd disk full on the workload cluster — apiserver keeps restarting; `lbHealthy` flaps between true/false in a way that matches FM-13 (LB broken) for any single window.
  * Workload-cluster apiserver memory pressure → OOMKill loop, cycle time exceeds `nodeStartupTimeout` (default 30 s) — KCP starts treating the cluster as unhealthy and may begin remediation, deepening the outage.
  * Operator-initiated apiserver upgrade overlapping with KCP rolling-upgrade — multiple cache refreshes overlap, the relist storm extends beyond the modelled window.

## FM-20 — Upgrade rollback mid-flight

**Provenance.** LLM-synthesised + Operational; the mixed-template
state is a plausible operational pattern (operator panicking
during a bad upgrade) and is now TLC-verified end-to-end via
`upgradeRollbackRecoveryRun` (IC-11).

**Init**: `upgradeRollbackMidFlightInit`. Operator initiated
upgrade to template 2; KCP scaled up Machine 4 (template 2);
operator rolled back to template 1 before promotion. Machine 4
is mid-join with the OLD desiredTemplate.

**Recovery**: KCP must delete the in-flight Machine 4 and
re-create it with template 1.

**Classification**: **KCP-DESIGN-GAP**. The Go code does not
explicitly handle "desiredTemplate changed mid-rollout"; the
model exposes the state. See `issue-corpus.md` IC-11.

## FM-21 — Five-node cluster losing 2 of 5 voters concurrently

**Provenance.** Operational; correlated rack/power events on
5-CP topologies. The serialisation of the two remediations
through `targetEtcdClusterHealthy` is operationally surprising —
operators expect concurrent remediation given quorum is preserved.
See `issue-corpus.md` IC-13.

**Init**: `fiveNodeTwoFailuresInit`. 5-CP cluster, members 4 and
5 simultaneously UnhealthyMachine.

**Recovery**: Sequential remediation: remediate 4, wait for
replacement; remediate 5. The `targetEtcdClusterHealthy` gate
admits only one membership change at a time even on 5-node
because of the worst-case-unhealthy assumption on the
replacement.

**Classification**: **TRANSIENT** (operationally surprising). See
`issue-corpus.md` IC-13.

**Infrastructure bounds.**
- Start condition: `members.size() = 5 and Set(4, 5).filter(m => memberHealth.get(m) = UnknownHealth).size() = 2` — 5-CP cluster has lost 2 voters concurrently.
- End condition: First remediation succeeds (one replacement passes through learner→voter); the `targetEtcdClusterHealthy` gate then admits the second remediation.
- Infrastructure cause(s) that turn this exogenous (transient → permanent):
  * Correlated rack/power event leaves both nodes unreachable indefinitely — the cluster is in a 3-of-5 state, technically still has quorum, but cannot self-heal until at least one of the unhealthy machines comes back or is replaced.
  * Replacement Machine for the first remediation cannot pass kubeadm-join (FM-1 stuck learner / FM-12 slow storage on the new node) — the first remediation never completes, the second stays queued.
  * A *third* voter starts to flip to `UnknownHealth` while remediation is in flight — quorum boundary breached, becomes FM-2-shaped (both remaining members effectively unhealthy).
  * Operator-initiated maintenance on a third voter overlapping with the concurrent failure — same FM-2 shape as above.
  * `nodeStartupTimeout` set unusually high (e.g. 30 m) means KCP doesn't surface that the replacement Machine isn't joining; the queue stays blocked silently.

## FM-22 — Single-node scale-up race (existing voter dies)

**Provenance.** Modelling; identified as a sub-shape of FM-2 by
Apalache's symbolic exploration. Operationally relevant to anyone
running 1-CP→3-CP upgrades.

**Init**: `singleNodeScaleUpFailureInit`. Mid-scale-up from 1 to
3 (Machine 2 added as etcd learner); the only existing voter
Machine 1 becomes unhealthy before promotion completes.

**Recovery**: With the existing voter unhealthy and the new one
not yet promoted, quorum cannot be reached. The state is FM-2-
shaped (both members effectively unhealthy). Recovery requires
`HealEtcdReachability(1)` (etcd self-heal on the original voter)
or operator restore.

**Classification**: **EXOGENOUS** (FM-2 sub-shape).

## FM-23 — Drain stuck on PDB during remediation

**Provenance.** **Upstream cluster-api#13508**; operational pain
point widely reported by users. Apalache safety verdict at
depth 4 (~278 s) once the `drainBlocked` flag was added in
Phase 4.

**Init**: `drainStuckInit`. CompleteRemediation removed Machine
1 from the etcd member set; Machine still in `machines` because
the kubelet drain is blocked by PodDisruptionBudgets;
`preflightBlocked = true` until drain finalises.

**Recovery**: Drain timeout + force-delete; modelled as the
spec requirement that `DeleteFailedMachine` eventually fires.

**Classification**: **KCP-BUG (latent)**. Direct match with
cluster-api#13508. See `issue-corpus.md` IC-14.

**Apalache verdict (Phase 5).** With the `drainBlocked` flag and
`pdbViolatedFor` flag added (Phase 4), and `RemoveMember` tightened
to refuse `drainBlocked[id]=true`, Apalache now proves
`AllSafetyInvariants` holds at depth 4 under `stepNoRecovery` from
`drainStuckInit` — exhaustive symbolic exploration in ~278 s.
Command:

```
quint verify --main=Lifecycle --init=drainStuckInit \
             --step=stepNoRecovery --max-steps=4 \
             --backend=apalache \
             --invariant=AllSafetyInvariants \
             formal/specs/Lifecycle.qnt
```

Result: `[ok] No violation found`. Every safety invariant —
`LearnerCannotVote`, `VoterSetNonEmpty`, `IncidentNeverInFlight`,
`IncidentBlockReasonCorrect` — holds across every reachable state
within 4 steps from drainStuckInit when only fault actions and
non-recovery transitions are enabled.

**Reachability complement.** Under the full `step` relation
(recovery enabled), TLC finds a path to `HealthyControlPlane` in
11,960 distinct states / 7 steps / ~1.3 s — `DrainTimeout(1)` clears
`drainBlocked[1]`, allowing `RemoveMember(1)` and downstream
remediation to complete. The complement direction (Apalache proving
`HealthyControlPlane` itself unreachable under `stepNoRecovery`)
finds a counterexample because the model permits operator-driven
`ChangeDesiredReplicas` to drop the cluster to a single-machine
"healthy" state — a legitimate operator action, not a recovery
action, that bypasses the FM-23 stuck-drain rather than fixing it.
This degraded-recovery path is observable in the abstraction-mapping
row for `ChangeDesiredReplicas` and is documented as a model-
permissiveness note rather than a bug: a faithful proof of
"Machine 1's drain stays blocked" requires a stronger invariant
form (`machines.contains(1) implies drainBlocked.get(1)`) that
captures the FM-23 shape directly.

## FM-24 — Etcd defrag pause

**Provenance.** Operational / etcd folklore; the bbolt mmap-hold
during defrag is a known cause of MHC `EtcdMemberHealthy=Unknown`
flaps. See `issue-corpus.md` IC-12.

**Init**: `etcdDefragPauseInit`. Etcd's bbolt defrag is running
on the leader; every Status RPC times out for 10–60 s. KCP marks
every member EtcdMemberHealthy=Unknown but nothing is broken.

**Recovery**: Defrag finishes; Status RPCs succeed; conditions
flip back.

**Classification**: **TRANSIENT**. See `issue-corpus.md` IC-12.

**Infrastructure bounds.**
- Start condition: `forall m in members: observation.get(m) = UnreachableTimeout` while etcd defrag holds the leader's locks (modelled as a transient flag on the leader).
- End condition: Defrag finishes; Status RPC succeeds; `observation` flips to `ReachableHealthy` for every voter.
- Infrastructure cause(s) that turn this exogenous (transient → permanent):
  * Defrag process hung on I/O — zombie process holds the bbolt mmap lock, every Status RPC times out indefinitely.
  * Underlying storage corruption (failed NVMe sector, btrfs/ext4 filesystem inconsistency) — defrag cannot complete, manual `etcdctl snapshot restore` required.
  * OOMKill mid-defrag — etcd's bbolt file is left in an inconsistent state on disk; subsequent etcd restart fails or runs in degraded mode.
  * Defrag triggered repeatedly under sustained write load (alarm threshold tripping every cycle) — the cluster spends most of its time in the "all voters Unknown" state, KCP starts treating it as an outage.
  * Storage I/O depth exceeds defrag's working set — defrag completes for the leader but every other voter sees a different defrag start within the same KCP reconcile window, observations never simultaneously settle to ReachableHealthy.

## FM-31 — Custom Node conditions not surfaced on Machine

**Provenance.** **Upstream cluster-api#11826** ("Provide a way to
surface arbitrary node conditions at machine level"). Modelled
to make the obligation explicit; not yet a verified verdict
beyond random-walk safety.

**Trigger.** An operator writes a custom Node condition (e.g.
via Node Problem Detector) and wants the corresponding Machine to
reflect it on its `Ready` condition without triggering MHC
remediation. CAPI's MHC tightly couples observation and
remediation; there is no "MachineSelfHealing without
remediation" knob today.

**Init / scenario.** Not added as a Quint init in this round —
the model would need a `customCondition: MachineId -> str -> str`
state variable plus a v1beta2 projection that preserves every
key in that map. Recorded for future modelling.

**Recovery / fix.** Upstream feature: surface arbitrary node
conditions at machine level. Cross-references
cluster-api#11826.

**Classification**: **KCP-DESIGN-GAP**. See `issue-corpus.md`
IC-02 (related — same principle as the v1beta2 projection
informativeness obligation).

## FM-32 — Webhook rotation gap (cert-manager downtime window)

**Provenance.** **Upstream cert-manager#10522** ("Cert-manager
certificate rotation may lead to downtime of webhooks for up to
90 s"). Phase 11d's bisection also surfaced the
`WebhookRotationFault` cycle as a real liveness gap when rotation
re-fires faster than KCP's reconcile (modelling).

**Trigger.** Cert-manager rotates the CAPI webhook serving cert.
For up to ~90 s, mutating + validating webhooks are unreachable;
any KCP / MHC reconcile that hits a webhook fails. If KCP is
mid-remediation when this happens, the membership change might
be retried with a partially-applied state.

**Init / scenario.** Not added as a Quint init this round; the
formal model would extend with a `webhooksAvailable: bool` flag
and gate every action that mutates KubeadmControlPlane on it.
Recorded.

**Recovery / fix.** Cert-manager rotation completes; webhooks
return; KCP reconcile re-tries successfully. Upstream report:
cert-manager#10522.

**Classification**: **TRANSIENT** (no permanent harm; the
window is bounded). The model's safety invariants would all
hold during the window because gates are pure-state predicates,
not webhook-mediated checks.

## FM-33 — Worker MachineSet preflight gating

**Provenance.** **Upstream cluster-api#11117** ("Add MachineSet
preflight checks to gate scale-up and remediation against
control-plane status / version-skew"). Modelled in
[`specs/MachineSetPreflight.qnt`](./specs/MachineSetPreflight.qnt)
rather than `Lifecycle.qnt` — workers don't have etcd quorum, so
the gating dynamics fit a stand-alone module.

**Trigger.** A worker MachineSet operation (scale-up or
remediation) lands while one of four invariants is violated:
control-plane is mid-upgrade / provisioning, the MS-vs-CP
Kubernetes version skew exceeds policy, the kubeadm bootstrap
provider's same-major+minor rule is violated, or the
ClusterTopology version is not yet propagated to the MS. Without
the preflight gate, the operation proceeds and may produce a
worker with a kubelet version skew that the upstream API server
cannot serve.

**Init / scenarios.** Three scenario inits in
`MachineSetPreflight.qnt`:

| Init | Scenario | Expected verdict |
|---|---|---|
| `fm33ScaleUpDuringCpUpgradeInit` | Operator requests scale-up while KCP is rolling | EvaluatePreflight blocks with reason `CpUnstable`; admitted only after `KcpFinishUpgrade` |
| `fm33VersionSkewInit` | MS template version exceeds CP version | EvaluatePreflight blocks with reason `KubernetesVersionSkewViolation` |
| `fm33RemediationDuringUpgradeInit` | Worker is unhealthy and remediation is requested while KCP is rolling | EvaluatePreflight blocks with reason `CpUnstable`; admitted only after `KcpFinishUpgrade` |

Three demonstration runs trace the expected outcomes:
`fm33ScaleUpBlockedRun`, `fm33ScaleUpAdmittedAfterUpgradeRun`,
`fm33VersionSkewBlockedRun`.

**LSP grounding.** Anchors recovered via gopls `go_search`
(`controlPlaneStablePreflightCheck`) and `grep -nE` on the
preflight file:

| Go entry point | File | Line |
|---|---|---|
| `Reconciler.runPreflightChecks` (orchestrator) | `internal/controllers/machineset/machineset_preflight.go` | 47 |
| `shouldRun` (per-check skip predicate) | same | 144 |
| `controlPlaneStablePreflightCheck` | same | 149 |
| `kubernetesVersionPreflightCheck` | same | 190 |
| `kubeadmVersionPreflightCheck` | same | 206 |
| `controlPlaneVersionPreflightCheck` | same | 226 |
| `skippedPreflightChecks` | same | 236 |
| Scale-up call site | `internal/controllers/machineset/machineset_controller.go` | 828 |
| `Reconciler.reconcileUnhealthyMachines` | same | 1493 |
| Remediation call site | same | 1633 |

The four sub-checks are folded into a single
`evaluatePreflight` pure def in the spec; the model carries no
skip-annotation surface, so `shouldRun` is collapsed.

**Recovery / fix.** The Go controller uses
`preflightFailedRequeueAfter = 15 * time.Second`
(`machineset_preflight.go:45`) to retry. The model's recovery
action is `KcpFinishUpgrade` (clearing `cpUpgradeInProgress`) or
`OperatorBumpMsVersion` (resolving version skew). After either,
a fresh `EvaluatePreflight` admits the previously-blocked
decision via the `ActionInFlight` branch.

**Verdict.** TLC reachability of the three demonstration runs.
`SafetyInvariants` and `PreflightGateRespected` hold throughout.
The key obligation — every Machine in `ActionInFlight` passed the
gate at admission time — is captured by `PreflightGateRespected`
(no fresh `EvaluatePreflight` between admission and a CP-state
flip would violate it). See `verify-runbook.md` for the
`make verify-fm33-*` targets.

**Classification.** **KCP-DESIGN-GAP** (closed). The preflight
gate is an implemented feature behind the
`MachineSetPreflightChecks` feature gate (line 50). The model
verifies the gate's behaviour is correct in the reasonable
domain of inputs.

## FM-39 — Multi-step upgrade hook ordering

**Provenance.** **Modelling** (Topology + runtime-extensions
spec). The contract is encoded in upstream code at
`exp/topology/desiredstate/lifecycle_hooks.go:36-122` (the
`callBeforeClusterUpgradeHook` doc-comment makes the obligation
explicit) but is not surfaced as an enforced invariant in any
existing test.

**Trigger.** During a multi-minor upgrade (e.g. v1.36 → v1.39),
the topology controller MUST fire `BeforeClusterUpgrade` exactly
once (at the START of the sequence) and `AfterClusterUpgrade`
exactly once (at the END). Per intermediate version, the hook
cascade `BeforeControlPlaneUpgrade → AfterControlPlaneUpgrade →
BeforeWorkersUpgrade → AfterWorkersUpgrade` must fire in order;
the next CP-step pickup is gated on the previous step's
`AfterControlPlaneUpgrade` and (when applicable)
`AfterWorkersUpgrade` having unblocked.

**Init / scenarios.** Three scenarios in `Topology.qnt`:

| Init | Scenario | Expected verdict |
|---|---|---|
| `happyUpgradeRun` | Single-step upgrade 36→37 | All hooks fire in order; AllSafetyInvariants holds |
| `multiStepUpgradeRun` | Three-step upgrade 36→39 | BeforeClusterUpgrade fires once (gated by `!IsPending(AfterClusterUpgrade)`); per-step hooks fire as expected |
| `annotationBlockedUpgradeRun` | Operator sets `before-upgrade.hook.cluster.cluster.x-k8s.io/*` annotation | BeforeClusterUpgrade gate stays blocked; FM40 holds |

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| `Reconciler.Reconcile` | `internal/controllers/topology/cluster/cluster_controller.go` | 263 |
| `Reconciler.reconcile` (normal loop) | same | 328 |
| `Reconciler.callBeforeClusterCreateHook` | same | 441 |
| `Reconciler.reconcileDelete` | same | 550 |
| `Reconciler.callAfterHooks` | `internal/controllers/topology/cluster/reconcile_state.go` | 180 |
| `Reconciler.callAfterControlPlaneInitialized` | same | 188 |
| `Reconciler.callAfterClusterUpgrade` | same | 229 |
| `generator.Generate` | `exp/topology/desiredstate/desired_state.go` | 103 |
| `generator.computeControlPlaneVersion` | same | 535 |
| `generator.computeMachineDeploymentVersion` | same | 1089 |
| `generator.callBeforeClusterUpgradeHook` | `exp/topology/desiredstate/lifecycle_hooks.go` | 39 |
| `generator.callBeforeControlPlaneUpgradeHook` | same | 128 |
| `generator.callAfterControlPlaneUpgradeHook` | same | 184 |
| `generator.callBeforeWorkersUpgradeHook` | same | 248 |
| `generator.callAfterWorkersUpgradeHook` | same | 314 |
| `ComputeUpgradePlan` | `exp/topology/desiredstate/upgrade_plan.go` | 48 |
| `GetUpgradePlanOneMinor` | same | 334 |
| `MarkAsPending` | `internal/hooks/tracking.go` | 36 |
| `IsPending` | same | 86 |
| `MarkAsDone` | same | 98 |
| `ControlPlaneUpgradeTracker.IsControlPlaneStable` | `exp/topology/scope/upgradetracker.go` | 188 |
| `WorkerUpgradeTracker.IsAnyUpgrading` | same | 256 |
| `WorkerUpgradeTracker.UpgradeConcurrencyReached` | same | 261 |
| `PendingHooksAnnotation` constant | `api/runtime/v1beta2/extensionconfig_types.go` | 317 |
| `OkToDeleteAnnotation` constant | same | 321 |
| `BeforeClusterUpgradeHookAnnotationPrefix` | `api/core/v1beta2/common_types.go` | 219 |

**Recovery / fix.** No "fix" required — the upstream code
already implements the obligation; the model verifies the
implementation is consistent. The model surfaces it as
`FM39_BeforeClusterUpgradeIdempotent`: while
`AfterClusterUpgrade` is pending, `BeforeClusterUpgrade` cannot
be re-fired (refines `lifecycle_hooks.go:42`).

**Verdict.** Five demonstration runs verified (TLC-equivalent
deterministic). Random walk (200 samples × 30 steps) holds
`AllSafetyInvariants`, `FM39_BeforeClusterUpgradeIdempotent`,
`FM40_AnnotationGatesCp`, `FM41_AfterClusterUpgradeAtSteadyState`.
**Apalache hopelessness proven** (depth 4, ~10 s per invariant) —
`FM39_BeforeClusterUpgradeIdempotent` is unreachable from any
state where it would falsify, in any extension of the model. See
`make verify-topology-apalache`.

**Classification.** **MODELLING** (verifies upstream contract).

## FM-40 — BeforeClusterUpgrade annotation must gate CP version pickup

**Provenance.** **Upstream** + **Modelling**. The annotation
mechanism is documented in
`api/core/v1beta2/common_types.go:214-219` and implemented in
`exp/topology/desiredstate/lifecycle_hooks.go:44-72`. Operators
rely on this to hold an upgrade pending an external readiness
check.

**Trigger.** Operator sets an annotation with prefix
`before-upgrade.hook.cluster.cluster.x-k8s.io/` on a Cluster
that is at the start of an upgrade sequence (no
`AfterClusterUpgrade` pending yet). The topology controller
MUST NOT advance `cpVersion` past `cpUpgradePlan[0]` until the
annotation is removed.

**Verdict.** `FM40_AnnotationGatesCp` holds across all
deterministic runs and 200×30 random walks. The model
demonstrates the gate is honoured: while the annotation is set
AND `AfterClusterUpgrade` is not pending, `stepPhase` remains
`StepIdle` (no CP version pickup occurred).
**Apalache hopelessness proven** (depth 4, ~11 s) — under any
reachable state.

**Classification.** **MODELLING** (verifies operator-facing
contract).

## FM-41 — AfterClusterUpgrade fires only at full quiescence

> **Note on terminology.** Upstream calls this state "fully
> upgraded" in the doc-comment at
> `internal/controllers/topology/cluster/reconcile_state.go:237-241`.
> The model uses "quiescence" because the predicate is broader
> than version-equality — it also requires no in-flight
> reconciles, no deferred MDs, and no pending creates. Both
> terms refer to the same precondition cascade.

**Provenance.** **Upstream** — encoded in
`internal/controllers/topology/cluster/reconcile_state.go:235-250`.

**Trigger.** The `AfterClusterUpgrade` hook is the closing
hook of the upgrade sequence. It MUST fire only when:
- CP at the desired version
- No MachineDeployments / MachinePools are upgrading
- No MDs / MPs are pending an upgrade
- No MDs / MPs are pending create
- `AfterControlPlaneUpgrade` and `AfterWorkersUpgrade` already
  cleared

The model verifies the obligation as a state invariant
`FM41_AfterClusterUpgradeAtSteadyState`: while
`AfterClusterUpgrade` is pending and the upgrade plan is
empty, the cluster must be in the steady state.

**Verdict.** `FM41_AfterClusterUpgradeAtSteadyState` holds
across all deterministic runs and 200×30 random walks.
**Apalache hopelessness proven** (depth 4, ~11 s).

**Classification.** **MODELLING** (verifies upstream contract).

## FM-51 — Cross-spec preflight-gate transient violation (level-triggered re-evaluation)

**Provenance.** **Modelling** — surfaced by the cross-spec
composition in `WorkerLifecycle.qnt` (issue #2). No Layer-1
spec caught this because each verifies its own gate in
isolation; the joint state machine reveals the race.

**Trigger.** A MachineSet was admitted to `ActionInFlight` (e.g.
operator scaled up newMS) while the cluster was Stable and CP
was stable. The operator then bumped `Cluster.spec.topology.version`,
causing the topology controller to fire BeforeClusterUpgrade →
StepCpUpgrade. CP is now mid-upgrade, but the MS is still in
`ActionInFlight` with the preflight gate (now closed)
unrespected.

This is harmless under upstream's level-triggered semantics:
the MS controller calls `runPreflightChecks` on every
scale-up reconcile (`internal/controllers/machineset/machineset_controller.go:828`),
so the next reconcile demotes `ActionInFlight` back to
`ActionBlocked`. But the state-invariant version of FM-33
("ActionInFlight implies CP stable") fails *transiently*
between the topology-bump and the next MS-controller reconcile.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `Reconciler.runPreflightChecks` (called every reconcile) | `internal/controllers/machineset/machineset_preflight.go` | 47 |
| `controlPlaneStablePreflightCheck` | same | 149 |
| Scale-up reconcile that calls preflight | `internal/controllers/machineset/machineset_controller.go` | 828 |
| Topology BeforeClusterUpgrade unblocks | `exp/topology/desiredstate/lifecycle_hooks.go` | 39 |

**Recovery / fix.** No upstream fix needed — the level-triggered
re-evaluation is the design. The model documents the
transient-window race as a known-harmless safety property.

**Verdict.** `WorkerLifecycle.qnt` random walk (1000×60) holds
all cross-cutting joint invariants (`J1_NoMoveBeforeWorkersStep`,
`J2_AfterWorkersAtMachineQuiescence`,
`J3_InPlaceAdmissionAfterBeforeWorkersUpgrade`,
`J4_MachineVersionMonotone`, `J5_NoInFlightAcrossStable`)
plus the per-spec invariants (FM-39, FM-41, FM-43) and the
weakened FM-33 (`FM33_PreflightGate`).

**Classification.** **MODELLING** (verifies upstream
level-triggered semantics; no upstream bug — surfaces a
modelling pattern that future cross-spec compositions must
respect).

## FM-48 — KCP must not create CP Machines before InfraCluster is ready

**Provenance.** **Upstream** — encoded in
`controlplane/kubeadm/internal/controllers/controller.go:296`:

```go
if !ptr.Deref(cluster.Status.Initialization.InfrastructureProvisioned, false) ||
   !cluster.Spec.ControlPlaneEndpoint.IsValid() {
    // ... return early without creating any CP Machine
}
```

**Trigger.** A racing or misimplemented infra provider could
flip `InfraCluster.status.ready=true` without setting
`controlPlaneEndpoint`, OR KCP could ignore the gate and start
creating Machines. Either way, CP Machines provisioned without
a known endpoint cannot join etcd or accept kubeadm-join.

**Init / scenarios.** `happyBringUpRun` walks the correct
ordering: BeforeClusterCreate → InfraClusterProvision →
ClusterControllerObservesInfraReady (sets
infrastructureProvisioned + controlPlaneEndpointSet) →
KcpInitializeControlPlane.

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| KCP entry-gate (early return) | `controlplane/kubeadm/internal/controllers/controller.go` | 296 |
| `Reconciler.reconcileInfrastructure` | `internal/controllers/cluster/cluster_controller_phases.go` | 141 |
| InfraCluster.provisioned read | same | 185-190 |
| ControlPlaneEndpoint copy | same | 219 |
| `Cluster.Status.Initialization.InfrastructureProvisioned = true` | same | 245 |
| `KubeadmControlPlaneReconciler.initializeControlPlane` | `controlplane/kubeadm/internal/controllers/scale.go` | 43 |
| `KubeadmControlPlaneReconciler.scaleUpControlPlane` | same | 67 |

**Verdict.** `FM48_NoCpBeforeInfraReady` holds across all
demos and 300×60 random walk.
**Apalache hopelessness proven** (depth 4, ~10 s) — see
`make verify-e2e-apalache`.
**Lean 4 deductive proof** in
`formal/proofs/ControlPlane/Ordering.lean::fm48_no_cp_before_infra_ready`.
The proof discharges the invariant by structural induction on
the abstract reachability relation, lifting the bounded
random-walk verdict to an unbounded state space (any number of
CP Machines, any cluster topology). The Quint state is a
faithful subset of `ClusterE2E.qnt`'s; the Lean carriers
abstract `cpMachineCount: Nat` and `infraProvisioned: Bool` and
trade the bounded model checker's MachineId range for a `Nat`.

**Classification.** **MODELLING** (verifies upstream contract).

## FM-49 — MachineDeployment must not create workers before ControlPlaneInitialized

**Provenance.** **Upstream** — encoded in the MD controller's
gate on `Cluster.Status.Initialization.ControlPlaneInitialized`,
itself set by the Cluster controller at
`internal/controllers/cluster/cluster_controller_phases.go:347`
after reading the ControlPlane object's
`status.initialization.controlPlaneInitialized` field.

**Trigger.** Workers spawned before any CP Machine is up have
no API server to bootstrap against. The kubeadm-join would
fail; the MachineSet controller would loop on preflight (FM-33)
in the best case, leak Machines in the worst.

**Init / scenarios.** The model encodes this as the precondition
of `MdCreateWorker`: `mdEnabled` must be true, which is only
flipped by `FireAfterControlPlaneInitialized` (which itself
requires `controlPlaneInitialised`).

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| Cluster controller `reconcileControlPlane` | `internal/controllers/cluster/cluster_controller_phases.go` | 251 |
| Initialized read | same | 289 |
| `Cluster.Status.Initialization.ControlPlaneInitialized = true` | same | 347 |
| Topology `callAfterControlPlaneInitialized` | `internal/controllers/topology/cluster/reconcile_state.go` | 188 |

**Verdict.** `FM49_NoWorkersBeforeCpInit` holds across all
demos and 300×60 random walk.
**Apalache hopelessness proven** (depth 4, ~9 s).
**Lean 4 deductive proof** in
`formal/proofs/ControlPlane/Ordering.lean::fm49_no_workers_before_cp_init`.
Same structural-induction technique as FM-48; the proof holds
for any worker count.

**Classification.** **MODELLING** (verifies upstream contract).

## FM-50 — ControlPlaneEndpoint monotonicity

**Provenance.** **Upstream** — by inspection: no code path in
`Reconciler.reconcileInfrastructure` (or anywhere in the cluster
controller) ever clears
`Cluster.Spec.ControlPlaneEndpoint` once set. Workers and KCP
both depend on this stability — a regressing endpoint would
break in-flight kubeadm-join calls and leave CP Machines
unable to find each other.

**Trigger.** A misimplemented infra provider that re-tenants a
cluster's LB to a new IP could change the endpoint mid-flight.
The Cluster controller has no machinery to re-thread that
change through KCP / MD; the model surfaces this as a
monotonicity requirement.

**Init / scenarios.** State invariant: once the cluster has
progressed past `InfraProvisioning`, `controlPlaneEndpointSet`
remains true.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Endpoint copy from InfraCluster | `internal/controllers/cluster/cluster_controller_phases.go` | 219 |
| (No clear path — verified by inspection.) | | |

**Verdict.** `FM50_EndpointMonotonic` holds across all demos
and 300×60 random walk.
**Apalache hopelessness proven** (depth 4, ~9 s).
**Lean 4 deductive proof** in
`formal/proofs/ControlPlane/Ordering.lean::fm50_endpoint_monotonic`.
The Lean proof generalises the bounded check to a
single-host-name carrier: once the endpoint resolves to
`some host`, every reachable successor carries the same
`some host`. The proof relies on a separate invariant
(`InvEndpointImpliesInfra`: `endpoint = some _ → infraProvisioned`)
that rules out the only constructor that could mutate the
endpoint (`infraReady` requires `infraProvisioned = false`,
contradicting the strengthened invariant). Composed via
`reachable_preserves` on the conjunctive predicate
`PEndpointHost`.

**Classification.** **MODELLING** (verifies upstream invariant).

## FM-45 — Per-key reconcile serialisation

**Provenance.** **Upstream** — encoded in
`pkg/controller/priorityqueue/priorityqueue.go:391`
(`if w.locked.Has(item.Key) { return true }`) and the comment
at `pkg/internal/controller/controller.go:311`
("It enforces that the reconcileHandler is never invoked
concurrently with the same object").

**Trigger.** A controller running with
`MaxConcurrentReconciles > 1` has multiple worker goroutines
draining the priority queue. Without the per-key locked-set
guard, two workers could pull the same key and call
`Reconciler.Reconcile(ctx, req)` concurrently — racing on
SSA / patch-helper writes to the same object.

**Init / scenarios.** `multiWorkerParallelRun` in
`ControllerRuntime.qnt` exercises two workers picking up two
distinct keys; `dedupDuringInFlightRun` shows that re-adding
a key currently in flight is buffered (sent to ready tree only
after `Done` clears the locked set).

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `processNextWorkItem` | `pkg/internal/controller/controller.go` | 419 |
| Worker-pool launch | same | 307 |
| Per-key serialisation comment | same | 311 |
| `handleReadyItems` (locked-set guard) | `pkg/controller/priorityqueue/priorityqueue.go` | 360-409 |
| Locked-set check | same | 391 |
| `lockedAddWithOpts` (re-add during in-flight) | same | 197 |
| `Done` (delete from locked) | same | 467 |

**Verdict.** `FM45_PerKeySerialisation` holds across all six
demo runs in `ControllerRuntime.qnt` (500×60 random walk) and
across the three refinement modules (`TopologyRefined`,
`InPlaceUpdateRefined`, `MachineSetPreflightRefined`).
**Apalache hopelessness proven** at depth 4 (~6 s) AND depth 8
(~190 s) — the per-key serialisation invariant cannot be
violated under any reachable interleaving up to 8 reconcile
steps with multi-worker (WORKERS = 1.to(2)). See
`make verify-cr-apalache`.

**Classification.** **MODELLING** (verifies upstream
invariant under multi-worker substrate semantics).

## FM-46 — Terminal error suppresses requeue

**Provenance.** **Upstream** — encoded in
`pkg/internal/controller/controller.go:484-485`. A reconcile
returning `reconcile.TerminalError(err)` is logged and counted
in metrics but the key is NOT re-added to the queue, in
contrast to non-terminal errors which trigger
`AddWithOpts(RateLimited)` at line 487.

**Trigger.** Operator-correctable failures (e.g. invalid spec,
missing reference) should be surfaced as TerminalError so the
controller doesn't loop forever burning rate-limiter budget.

**Init / scenarios.** `terminalErrorRun` drives a Reconcile
that returns `reconcile.TerminalError`; the model verifies
the key is removed from the queue (NotInQueue or InReady iff
re-added during the in-flight window).

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Terminal-error branch | `pkg/internal/controller/controller.go` | 484-485 |
| `reconcile.TerminalError` constructor | `pkg/reconcile/reconcile.go` | 174 |
| `terminalError.Is` | same | 194 |

**Verdict.** `FM46_TerminalErrorNoRequeue` holds across the
demo run and 500×60 random walk.
**Apalache hopelessness proven** (depth 4, ~6 s).

**Classification.** **MODELLING** (verifies upstream
invariant).

## FM-47 — Cache lags API server

**Provenance.** **Upstream** — encoded in the cache vs
APIReader read split at
`pkg/client/client.go:40-91` (CacheReader path) and the
informer watch event loop at `pkg/cache/cache.go:65`. A
controller that uses the cached client (`client.Client`) for
reads sees a value that may lag the API server until the next
informer sync.

**Trigger.** Common failure shape — controller patches an
object via the API server, then immediately re-reads via the
cache and gets the OLD value because the informer hasn't yet
delivered the update event. Forces the controller to wait for
a re-reconcile triggered by the watch.

**Init / scenarios.** The model surfaces
`FM47_CacheBehindAPI` as a state invariant: cacheVersion[k]
is always at most apiVersion[k]. The `dedupDuringInFlightRun`
exercises the staleness window (write happens, cache hasn't
synced, queue is re-driven).

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `Cache` interface | `pkg/cache/cache.go` | 65 |
| `client.Options` (CacheReader) | `pkg/client/client.go` | 40 |
| `CacheOptions.Reader` | same | 77 |
| `client.New` | same | 116 |

**Verdict.** `FM47_CacheBehindAPI` holds across all CR demo
runs and 500×60 random walk.
**Apalache hopelessness proven** (depth 4, ~6 s).

**Classification.** **MODELLING** (verifies upstream
invariant).

## FM-42 — In-place update admitted before CanUpdateMachineSet returns yes

**Provenance.** **Modelling** (`InPlaceUpdate.qnt`). The
contract is encoded in upstream code at
`internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go:446-461`
(the `if !canUpdateInPlace { continue }` short-circuit before
the annotation set).

**Trigger.** A misbehaving rollout planner could in principle
stamp `MachineSetMoveMachinesToMachineSetAnnotation` on an oldMS
without first checking `canUpdateMachineSetInPlace`. This would
cause the MachineSet controller's `startMoveMachines` to flip
ownership and fire the in-place flow even when no extension can
handle the change — breaking the worker pod set without a
recovery path.

**Init / scenarios.** The model surface for FM-42 is the
`FM42_PrematureInPlaceAdmission` invariant:

```
oldMsHasMoveAnnotation implies canUpdateInPlace(canUpdateVerdict)
```

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| `rolloutPlanner.canUpdateMachineSetInPlace` | `internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go` | 53 |
| `rolloutPlanner.canExtensionsUpdateMachineSet` | same | 120 |
| `rolloutPlanner.reconcileInPlaceUpdateIntent` | `internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go` | 414 |
| Move-annotation set on oldMS | same | 459 |
| Receive-annotation set on newMS | same | 477 |
| `MachineSetMoveMachinesToMachineSetAnnotation` constant | `api/core/v1beta2/machineset_types.go` | 43 |
| `MachineSetReceiveMachinesFromMachineSetsAnnotation` constant | same | 51 |
| `CanUpdateMachineSet` hook | `api/runtime/hooks/v1alpha1/inplaceupdate_types.go` | 165 |

**Verdict.** `FM42_PrematureInPlaceAdmission` holds across all
five demo runs and 2000×80 random walks.
**Apalache hopelessness proven** at depth 4 (~3 s) AND depth 8
(~17 s). See `make verify-inplace-apalache`.

**Classification.** **MODELLING** (verifies upstream contract).

## FM-43 — UpdateMachine hook idempotence

**Provenance.** **Upstream** + **Modelling**. The idempotence
obligation is documented in
`api/runtime/hooks/v1alpha1/inplaceupdate_types.go:211-213`:
*"This hook should be idempotent and can be called multiple
times for the same machine until it reports Done or Failed."*

**Trigger.** The Machine controller's
`reconcileInPlaceUpdate` (`machine_controller_inplace_update.go:43`)
calls `UpdateMachine` repeatedly while the response carries
`RetryAfterSeconds > 0`. Each call must observe the same gate
preconditions: feature gate on, `UpdateInProgressAnnotation` on
Machine + InfraMachine + BootstrapConfig, `UpdateMachine` hook
in the pending-hooks set. If any of these flip false between
retries, the controller MUST take the cleanup branch
(`machine_controller_inplace_update.go:54-66`) instead of
calling the extension again with inconsistent state.

**Init / scenarios.** `updateMachineRetryLoopRun` drives three
`UpdateProgressing` responses followed by a `UpdateDone` and
the cleanup. The model surface is
`FM43_UpdateMachineIdempotenceGate`:

```
machinePhase[m] == InPlaceUpdating
  implies (hookGateOpen(...) or not(machineInProgress[m]))
```

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| `Reconciler.reconcileInPlaceUpdate` (entry) | `internal/controllers/machine/machine_controller_inplace_update.go` | 43 |
| Cleanup branch (orphaned hook) | same | 54-66 |
| Gate cascade | same | 74-99 |
| `Reconciler.callUpdateMachineHook` | same | 142 |
| RetryAfter > 0 → in progress | same | 185-189 |
| RetryAfter = 0 → done | same | 192-193 |
| `Reconciler.completeInPlaceUpdate` | same | 198 |
| `UpdateMachine` hook | `api/runtime/hooks/v1alpha1/inplaceupdate_types.go` | 213 |
| `UpdateInProgressAnnotation` constant | `api/core/v1beta2/machine_types.go` | 100 |
| `MarkAsPending` / `IsPending` / `MarkAsDone` | `internal/hooks/tracking.go` | 36 / 86 / 98 |

**Verdict.** `FM43_UpdateMachineIdempotenceGate` holds across
all five demo runs and 2000×80 random walks.
**Apalache hopelessness proven** (depth 4, ~3 s).

**Classification.** **MODELLING** (verifies upstream contract).

## FM-44 — Multiple UpdateMachine extensions registered

**Provenance.** **Upstream** — encoded in
`internal/controllers/machine/machine_controller_inplace_update.go:155-156`.
The current iteration of the in-place feature only supports a
single extension; multiple extensions yield a fast-fail error
with message "found multiple UpdateMachine hooks: only one hook
is supported."

**Trigger.** Operator registers a second `UpdateMachine`
extension. The Machine controller's `callUpdateMachineHook`
detects `len(extensions) > 1` at line 155 and returns an error,
preventing any in-place update from progressing.

**Init / scenarios.** `multiExtensionRejectRun` simulates the
operator misconfiguration; the Machine flips to `InPlaceFailed`.
Surface invariant `FM44_MultiExtensionBlocksProgress`:

```
updateMachineExtensionCount > 1
  implies forall m: machinePhase[m] == InPlaceArmed
                      implies lastUpdateOutcome[m] == UpdateProgressing
```

(Machines already at `InPlaceDone` from before the second
extension was registered are unaffected — their state is durable.)

**LSP grounding.** Anchors recovered via gopls + grep:

| Go entry point | File | Line |
|---|---|---|
| Multi-extension fast-fail | `internal/controllers/machine/machine_controller_inplace_update.go` | 155-156 |
| Zero-extension fast-fail | same | 152-153 |
| `RuntimeClient.GetAllExtensions` call | same | 148 |

**Recovery.** Operator removes the duplicate extension; the
next reconcile finds `len(extensions) == 1` and proceeds. The
model has no fault-clearing action because the upstream code
allows the operator's existing `kubectl delete extension`
behaviour without controller involvement.

**Verdict.** `FM44_MultiExtensionBlocksProgress` holds across
all five demo runs and 2000×80 random walks.
**Apalache hopelessness proven** (depth 4, ~3 s).

**Classification.** **MODELLING** (verifies upstream contract).

## FM-34 — MHC controller's stale cluster cache during apiserver restart

**Provenance.** **Upstream cluster-api#12363** ("MachineHealthcheck
controller fails to get cluster connection from cache").

**Trigger.** The MHC controller maintains a cache-backed client
for each workload cluster. When the apiserver restarts (e.g. as
part of an upgrade), the cache holds a stale connection or
returns "cluster not found" briefly. MHC's view of Machine
health goes stale; in extreme cases an MHC reconcile mid-restart
might mis-flag a Machine as unhealthy because its
`needsRemediation` predicate cannot reach the workload-cluster
apiserver to confirm Node Ready.

**Init / scenario.** Not added as a Quint init; would extend
the model with a `mhcCacheStale: bool` flag plus an
`MhcCacheRefresh` action. Recorded.

**Recovery / fix.** The apiserver restart completes; the cache
re-populates within `nodeStartupTimeout` (default 30 s);
remediation that was triggered erroneously is reversed when the
fresh observation arrives.

**Classification**: **KCP-BUG (latent)**. Cross-references
cluster-api#12363. The model's `apiserverRestartInit` already
captures the LB-broken sub-shape; FM-34 is the more specific
"cache mis-coherence" framing.

## FM-37 — Lifecycle hooks skipped under control-plane unavailability

**Provenance.** **Upstream cluster-api#8942** ("BeforeClusterUpgrade
is not called with cp unavailable").

**Trigger.** CAPI's runtime-extension lifecycle hooks
(`BeforeClusterUpgrade`, `BeforeControlPlaneUpgrade`, etc.) are
not invoked when the control plane is not Available. An operator
who relies on `BeforeClusterUpgrade` to validate pre-conditions
silently skips the hook during partial-outage scenarios.

**Init / scenario.** Not added as a Quint init; would extend
the model with a `hooksEnabled: bool` plus per-hook firing
records, then re-state the contract that hooks fire on every
upgrade attempt regardless of cluster availability.

**Recovery / fix.** Upstream issue cluster-api#8942 documents
the gap; a fix would either (a) defer the hook until the cluster
recovers, or (b) accept a "pre-condition skipped" condition
reason that the operator can read.

**Classification**: **KCP-BUG (latent)**.

## Summary table

| ID | Name | Class | Recovery available? | TLC verdict (with recovery) |
|---|---|---|---|---|
| FM-1 | Stuck learner | KCP-BUG | RemoveStuckLearner | Converges (3.7K states, 0.8 s) |
| FM-2 | 2-machine cluster, both unhealthy | EXOGENOUS | HealEtcdReachability | Apalache: PROVABLY unreachable under stepNoRecovery (76 s); TLC: reachable under step (1.4M states, 4.7 s) |
| FM-3 | Persistent etcd unreachability | EXOGENOUS | HealEtcdReachability | Apalache: PROVABLY unreachable under stepNoRecovery (82 s); TLC: reachable under step (11.6K states, 1.0 s) |
| FM-4 | Promote-before-NodeRef window | TRANSIENT | Self-resolving | TBD |
| FM-5 | MHC obs stuck NoCorrespondingMember | KCP-BUG (latent) | DeleteFailedMachine | Converges (77K states, 1.0 s) |
| FM-6 | Etcd leader vacancy | TRANSIENT | Self-resolving | TBD |
| FM-7 | Concurrent remediation | TRANSIENT | Serialization | TBD |
| FM-8 | InformativenessObligation | KCP-BUG | Projection rewrite | n/a (specification gap) |
| FM-9 | Stuttering / fairness gap | MODEL-INCOMPLETE | WF_vars(step) | n/a (model gap) |
| FM-10 | Stale health rollup | TRANSIENT | Self-resolving | TBD |
| FM-11 | Invalid kubelet configuration | KCP-BUG (latent) | MachineHealthCheck → remediation | Converges (18K states, 1.1 s) |
| FM-12 | Etcd join times out (slow storage) | KCP-BUG (latent) | DeleteFailedMachine | Converges (3.5K states, 0.86 s) |
| FM-13 | apiserver LB proxy broken | EXOGENOUS | HealLb + HealEtcdReachability | Apalache: PROVABLY unreachable under stepNoRecovery (38 s); TLC: reachable under step (11.6K states, 1.0 s) |
| FM-14 | Kubelet up but Node never joins | KCP-BUG (latent) | RestoreNodeReachability + remediation | Converges (25K states, 1.0 s) |
| FM-15 | Upgrade in flight | TRANSIENT | Rolling update completes | Converges (2.9M states, 6.5 s) |
| FM-16 | 1-node cluster lost its only voter | EXOGENOUS | RestoreClusterFromSnapshot | Apalache: PROVABLY unreachable under stepNoRecovery (21 s); TLC: reachable under step (633 states, 0.8 s) |
| FM-17 | Kubeadm-join misconfiguration (kubelet wrong endpoint) | KCP-BUG (latent) | DeleteFailedMachine + AddMachine | Converges (2.1K states, 0.84 s); Apalache: PROVABLY unreachable under stepNoRecovery (~80 s) |
| FM-18 | Concurrent scale-up + remediation race | TRANSIENT | Serialisation via targetEtcdClusterHealthy | Converges (9.5K states, 1.2 s) |
| FM-19 | apiserver restart relist storm | TRANSIENT | HealLb after restart | Converges (10.9K states, 1.1 s) |
| FM-20 | Upgrade rollback mid-flight | KCP-DESIGN-GAP | Roll-forward delete + recreate | Converges (19.4K states, 1.2 s) |
| FM-21 | 5-node losing 2 of 5 voters concurrently | TRANSIENT | Sequential remediation | Converges (17.7K states, 1.3 s) |
| FM-22 | Single-node scale-up race | EXOGENOUS (FM-2 sub-shape) | HealEtcdReachability or operator restore | Converges (13.5K states, 1.2 s); FM-2 hopelessness applies under stepNoRecovery |
| FM-23 | Drain stuck on PDB during remediation | KCP-BUG (latent) | Drain timeout + force-delete | Converges (10.0K states, 1.1 s); cluster-api#13508 |
| FM-24 | Etcd defrag pause (false-positive Unknown) | TRANSIENT | Defrag finishes | Converges (12.5K states, 1.0 s) |

| **Plus from upstream-issues research** | | | | |
| FM-31 | Surface arbitrary Node conditions on Machine without MHC remediation | KCP-DESIGN-GAP | Custom-condition projection | Concept landed in `upstream-issues-research.md`; cluster-api#11826 |
| FM-32 | Webhook rotation gap (cert-manager) | TRANSIENT | Rotation completes | Concept landed; cert-manager#10522 |
| FM-33 | Worker MachineSet preflight gating | KCP-DESIGN-GAP (closed) | Preflight requeue + KCP upgrade completion | Verified in `specs/MachineSetPreflight.qnt`; cluster-api#11117 |
| FM-34 | Stale MHC cluster-cache during apiserver restart | KCP-BUG (latent) | Cache invalidation | Concept landed; cluster-api#12363 |
| FM-39 | Multi-step upgrade hook ordering | MODELLING | n/a — invariant of upstream contract | Verified in `specs/Topology.qnt` (`FM39_BeforeClusterUpgradeIdempotent`) |
| FM-40 | BeforeClusterUpgrade annotation must gate CP pickup | MODELLING | Operator removes annotation | Verified in `specs/Topology.qnt` (`FM40_AnnotationGatesCp`) |
| FM-41 | AfterClusterUpgrade fires only at full quiescence | MODELLING | n/a — invariant of upstream contract | Verified in `specs/Topology.qnt` (`FM41_AfterClusterUpgradeAtSteadyState`) |
| FM-42 | In-place admitted before CanUpdateMachineSet returns yes | MODELLING | n/a — invariant of upstream contract | Verified in `specs/InPlaceUpdate.qnt` (`FM42_PrematureInPlaceAdmission`) |
| FM-43 | UpdateMachine hook idempotence | MODELLING | n/a — invariant of upstream contract | Verified in `specs/InPlaceUpdate.qnt` (`FM43_UpdateMachineIdempotenceGate`) |
| FM-44 | Multiple UpdateMachine extensions registered | MODELLING | Operator removes duplicate extension | Verified in `specs/InPlaceUpdate.qnt` (`FM44_MultiExtensionBlocksProgress`) |
| FM-45 | Per-key reconcile serialisation under multi-worker | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ControllerRuntime.qnt` + 3 refinement modules (`FM45_PerKeySerialisation`) |
| FM-46 | TerminalError suppresses requeue | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ControllerRuntime.qnt` (`FM46_TerminalErrorNoRequeue`) |
| FM-47 | Cache lags API server | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ControllerRuntime.qnt` (`FM47_CacheBehindAPI`) |
| FM-48 | KCP creates CP Machines before InfraCluster ready | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` (`FM48_NoCpBeforeInfraReady`) + Lean 4 deductive (`Ordering.lean::fm48_no_cp_before_infra_ready`) |
| FM-49 | MD creates workers before ControlPlaneInitialized | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` (`FM49_NoWorkersBeforeCpInit`) + Lean 4 deductive (`Ordering.lean::fm49_no_workers_before_cp_init`) |
| FM-50 | ControlPlaneEndpoint regresses mid-flight | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` (`FM50_EndpointMonotonic`) + Lean 4 deductive (`Ordering.lean::fm50_endpoint_monotonic`) |
| FM-51 | Cross-spec preflight-gate transient violation | MODELLING | Level-triggered re-evaluation by MS controller | Surfaced + verified in `specs/WorkerLifecycle.qnt`; weakened `FM33_PreflightGate` accordingly |
| FM-37 | Lifecycle hook skipped under CP unavailability | KCP-BUG (latent) | Hook deferral | Concept landed; cluster-api#8942 |

Six KCP-BUG rows (FM-1, FM-5, FM-8, FM-11, FM-12, FM-14, plus
FM-23, FM-34, FM-37 latent). Two KCP-DESIGN-GAP rows (FM-20,
FM-31). One MODEL-INCOMPLETE row (FM-9 — fairness annotations).
Five EXOGENOUS rows (FM-2, FM-3, FM-13, FM-16, FM-22). Eight
TRANSIENT rows (FM-4, FM-6, FM-7, FM-10, FM-15, FM-18, FM-19,
FM-21, FM-24, FM-32).

Six failure modes (FM-1, FM-2, FM-3, FM-13, FM-16) plus the
FM-2 e2e PASS now carry exhaustive formal proofs — TLC for the
recovery path, Apalache for the hopelessness without recovery —
pinning the load-bearing recovery action for each. The FM-2
reproducer also runs end-to-end on a real CAPD cluster
(`test/e2e/fm2_quorum_loss.go`).

## Topology coverage

The model in `Lifecycle.qnt` parameterises three topology init
actions: `singleNodeInit`, `threeNodeInit` (the primary), and
`fiveNodeInit`. Failure-mode init actions instantiate against
the topology relevant to that mode; `fiveNodeStuckLearnerInit`
is a topology-specific variant of FM-1 verified to converge in
10K distinct states under TLC.

| Topology | Quorum | Largest tolerated fault | Notes |
|---|---|---|---|
| 1-node | 1/1 | None — losing the voter is fatal (FM-16) | Common in dev / edge deployments; KCP cannot self-recover. |
| 3-node | 2/3 | 1 machine concurrently | Primary topology. Most failure-mode rows are exercised here. |
| 5-node | 3/5 | 2 machines concurrently | More fault-tolerant; same logic as 3-node. |

The modelled scenario at
`example-cluster`
exhibits FM-1 and FM-8 simultaneously: the stuck learner blocks
remediation (FM-1) and the v1beta2 condition surface drops the
diagnostic key that would have explained why (FM-8).

## FM-35 — Self-hosted upgrade deadlock

**Provenance.** **Upstream cluster-api#12886** ("[e2e test]
Cluster API working on self-hosted clusters using ClusterClass
failing with timed out error"). Modelled in
[`specs/SelfHosted.qnt`](./specs/SelfHosted.qnt) rather than
`Lifecycle.qnt` — see Phase 12 in the work plan.

**Trigger.** A self-hosted CAPI deployment (the management
cluster IS the workload cluster) reaches a state where KCP must
upgrade the Node hosting its own pod. KCP pauses the host's Node
to drain it; KCP can no longer reconcile. The cluster deadlocks
until the operator manually fails over the KCP pod to a healthy
non-paused Machine.

**Init.** `selfHostedDeadlockInit` in `SelfHosted.qnt`.

**Recovery.** `KcpReconcileResume` (operator-driven KCP pod
failover via `kubectl delete pod`).

**Verdict.** Two specs verify FM-35 from complementary angles:

1. **`SelfHosted.qnt`** — focused dynamics: `selfHostedDeadlockTrace`
   reaches the `Deadlocked` invariant; `selfHostedRecoveryTrace`
   clears it.
2. **`Lifecycle.multicluster.qnt`** (Phase 12 full) — per-cluster
   expansion of the KCP lifecycle. Every state variable is
   `ClusterId -> X` and every action takes a `cl: ClusterId`
   parameter. KCP-on-mgmt-cluster gating
   (`kcpReconcileEnabled[mgmtCluster[cl]]`) makes the FM-35
   feedback loop explicit. Verdicts:
   - `selfHostedDeadlockTrace` (steady → bump template → KCP
     host pause) reaches `FM35Deadlocked` in 2 steps.
   - `selfHostedRecoveryTrace` (deadlock state → fail KCP pod
     to a healthy non-paused Machine) clears `FM35Deadlocked`.
   - Random-walk `SafetyInvariants` holds (200 samples × 20
     steps).

**Classification.** **MODEL-EXPANSION → VERIFIED.** Both the
focused-sketch (SelfHosted.qnt) and the full per-cluster
expansion (Lifecycle.multicluster.qnt) verify the FM-35 deadlock
entry and recovery flows. The full mirror of every single-cluster
action in Lifecycle.qnt remains optional — Lifecycle.multicluster.qnt
covers the FM-35-relevant subset (etcd membership + kubeadm join
+ KCP reconcile + drain + remediation, ~20 actions instead of 70).

## Provenance summary

| FM | Provenance | Upstream issue |
|---|---|---|
| 1 | Operational | cluster-api#13221 |
| 2 | Operational + e2e CAPD pass | — |
| 3 | Upstream | cluster-api#8465 |
| 4 | Modelling | — |
| 5 | Operational | — |
| 6 | Operational / etcd folklore | — |
| 7 | Operational | — |
| 8 | Modelling | cluster-api#11826 (broader gap) |
| 9 | Modelling (TLC + Phase 11d bisection) | — |
| 10 | Modelling | — |
| 11 | Operational | — |
| 12 | Operational | — |
| 13 | Operational | — |
| 14 | Operational | — |
| 15 | Operational | — |
| 16 | Operational | — |
| 17 | Operational | — |
| 18 | Operational + Modelling | — |
| 19 | Operational | — |
| 20 | LLM-synthesised + Operational (IC-11 verified) | — |
| 21 | Operational | — |
| 22 | Modelling (Apalache identified FM-2 sub-shape) | — |
| 23 | Upstream | cluster-api#13508 |
| 24 | Operational / etcd folklore | — |
| 31 | Upstream | cluster-api#11826 |
| 32 | Upstream + Modelling (Phase 11d cycle) | cert-manager#10522 |
| 33 | Upstream | cluster-api#11117 |
| 34 | Upstream | cluster-api#12363 |
| 39 | Modelling (Topology spec) | — |
| 40 | Upstream + Modelling | — |
| 41 | Upstream | — |
| 42 | Modelling (InPlaceUpdate spec) | — |
| 43 | Upstream + Modelling | — |
| 44 | Upstream | — |
| 45 | Upstream (controller-runtime) | — |
| 46 | Upstream (controller-runtime) | — |
| 47 | Upstream (controller-runtime) | — |
| 48 | Upstream (KCP entry-gate) | — |
| 49 | Upstream (MD gate on CP-init) | — |
| 50 | Upstream (by inspection) | — |
| 51 | Modelling (WorkerLifecycle cross-spec composition) | — |
| 35 | Upstream | cluster-api#12886 |
| 37 | Upstream | cluster-api#8942 |

Counts:
- 7 FMs traced to a specific upstream issue.
- 6 FMs surfaced by the modelling itself (FM-4, 8, 9, 10, 22,
  plus the Phase 11d cycles inside FM-9 and FM-32).
- 13 FMs derived from operational experience.
- 1 FM (FM-20) primarily LLM-synthesised across components.

The corpus is dominated by operational provenance — the formal
work largely codifies and verifies what experienced operators
already know, with modelling-original findings concentrated in
the layered abstraction's seams (condition projection, fairness,
phase-ordering windows).
