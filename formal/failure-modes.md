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
| End-to-end cluster lifecycle | `ClusterE2E.qnt`, `ClusterE2ERefined.qnt` | FM-48, FM-49, FM-50 |
| Finalizer chain ordering | `Finalizers.qnt` | FM-57, FM-58 |
| Runtime SDK replay / cache lifecycle | `RuntimeSDK.qnt` | FM-59, FM-60 |
| Conversion-webhook round-trip / outage fallback | `ConversionWebhook.qnt` | FM-63, FM-64, FM-65 |
| Kubelet PKI / kubeconfig rotation | `KubeletPKI.qnt` | FM-66, FM-67, FM-68 |

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

**CAPD e2e reproducer.** `test/e2e/fm3_etcd_unreachable.go` —
disconnects one CP node container from the kind network via
`docker network disconnect`, asserts the Machine set stays
stable through partition + reconnect. Trace recording wired
via `tracerecord.E2ERecorder`. Implementation landed; CAPD
verification is operator-driven (see `make test-e2e-trace`).

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

**CAPD e2e reproducer.** `test/e2e/fm13_apiserver_lb_broken.go`
— pauses the `<cluster>-lb` haproxy container via `docker
pause`; asserts the Machine set stays stable while the LB is
unreachable; recovers via `docker unpause`. Trace recording
wired. Implementation landed; CAPD verification is
operator-driven.

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

**CAPD e2e reproducer.** `test/e2e/fm15_upgrade_in_flight.go` —
3-CP cluster at `KubernetesVersionUpgradeFrom`, drives a rolling
control-plane upgrade to `KubernetesVersionUpgradeTo` via
`framework.UpgradeControlPlaneAndWaitForUpgrade`, asserts the
3-Machine set is fully replaced (initial ∩ upgraded = ∅) on the
target version. Trace recording wired. Implementation landed;
CAPD verification is operator-driven.

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

**CAPD e2e reproducer.** `test/e2e/fm19_apiserver_restart.go` —
kills one CP node's `kube-apiserver` static pod via `crictl rm
-f` from inside the node container; asserts the Machine set
stays stable while kubelet relaunches the static pod. Trace
recording wired. Implementation landed; CAPD verification is
operator-driven.

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

**CAPD e2e reproducer.** `test/e2e/fm23_drain_blocked_pdb.go` —
deploys a sticky pod (toleration for CP NoSchedule taint, pinned
to a chosen CP Node) and a `policy/v1` `PodDisruptionBudget` with
`maxUnavailable: 0`; labels the host Machine `mhc-test=fail` to
trigger remediation; asserts the Machine deletion stalls while
the PDB is in place; deletes the PDB and asserts deletion
completes. Trace recording wired. Implementation landed; CAPD
verification is operator-driven.

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

## FM-110 — Cluster delete during an in-flight edit allows a stale write to land

**Provenance.** **Modelling** — issue #68 standalone edit/delete race
slice (`ClusterEditDeleteRace.qnt`). The model is grounded in the normal
patch/write helpers and the existing delete/missing-object handling
surfaces that already appear in the stale-enqueue corpus.

**Trigger.** A `Cluster.spec` edit has already incremented desired state
but its final persisted write has not landed yet. `kubectl delete`
arrives, the object is deleted, but a stale in-flight write still lands
after delete was already observed.

**Init / scenarios.** `editThenDeleteRun` shows the intended regime: the
edit persists first, then delete wins, and any later write observes the
object is gone (`DeleteCancelsFurtherWrites`). `deleteMidEditRun` drives
the bad path: desired generation increments, delete is observed, and a
stale write still lands, violating `NoWriteAfterDeleteObserved`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Patch/write helper | `util/patch/patch.go` | 186 |
| Deprecated patch helper | `util/deprecated/v1beta1/patch/patch.go` | 181 |
| Related delete/missing-object behaviour | `formal/specs/StaleEnqueueShutdown.qnt` | 1-162 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-write-after-delete path via `deleteMidEditRun`, and
Apalache reaches the same `NoWriteAfterDeleteObserved` violation from
`deleteDuringEditInit` within depth 4 (`make verify-cluster-delete-race-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-114 — SSA field-manager ownership transfer is silently reverted by a stale manager

**Provenance.** **Modelling** — issue #66 standalone SSA field-manager
conflict slice (`SsaFieldManagerConflict.qnt`). The model is grounded in
the topology structured-merge dry-run / server-side patch helper and the
repo's managed-fields ownership manipulation helpers.

**Trigger.** Manager `kubectl` currently owns a field with value `3`.
Manager `capi-cli` attempts `5` without force and correctly hits a
conflict. `capi-cli` then retries with force and takes ownership, but
`kubectl` still believes `3` is current and re-applies its stale value,
silently reverting the forced handoff.

**Init / scenarios.** `forceHandoffRun` shows the intended regime:
conflict is surfaced, `capi-cli` force-applies `5`, ownership transfers,
and `ForcedApplyTransfersOwnership` holds. `staleManagerRevertRun`
continues with `kubectl` reapplying `3`, violating
`NoSilentRevertAfterConflict`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Structured-merge dry-run cleanup / ownership shaping | `internal/controllers/topology/cluster/structuredmerge/dryrun.go` | 220-281 |
| Structured-merge server-side patch helper call sites | `internal/controllers/topology/cluster/reconcile_state.go` | 450-505 |
| Managed-fields ownership helpers | `internal/util/ssa/managedfields.go` | 49-197 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-manager revert path via `staleManagerRevertRun`, and
Apalache reaches the same `NoSilentRevertAfterConflict` violation from
`staleRevertInit` within depth 4 (`make verify-ssa-conflict-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-122 — Third-party ClusterRole drift leaves CAPI controllers failing 403

**Provenance.** **Modelling** — issue #74 standalone ClusterRole drift
slice (`ClusterRoleDrift.qnt`). The model is grounded in the generated
manager ClusterRole manifests and the same SSA/managed-fields ownership
helpers already used for the spec-field conflict models.

**Trigger.** A foreign chart applies a ClusterRole with the same name as
one of CAPI’s manager roles and overwrites its rule set. Before CAPI
reasserts ownership, controller operations that previously had
permission begin failing with 403.

**Init / scenarios.** `reassertAfterDriftRun` shows the intended regime:
the foreign drift is observed, `capi` re-applies the correct role rules,
and `CapiRoleStableUnderForeignApplier` holds. `drifted403Run` keeps the
role drifted and executes a controller operation, violating
`NoSilentPermissionLossAfterDrift`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Generated manager ClusterRole | `bootstrap/kubeadm/config/rbac/role.yaml` | 1-70 |
| Kubebuilder RBAC marker surface | `bootstrap/kubeadm/main.go` | 176-182 |
| Structured-merge / SSA ownership helper | `internal/controllers/topology/cluster/structuredmerge/dryrun.go` | 220-281 |
| Managed-fields ownership helpers | `internal/util/ssa/managedfields.go` | 49-197 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the foreign-overwrite permission-loss path via
`drifted403Run`, and Apalache reaches the same
`NoSilentPermissionLossAfterDrift` violation from `drifted403Init`
within depth 4 (`make verify-clusterrole-drift-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-111 — Backup/apply partial rollback silently drops fields and controllers re-default them

**Provenance.** **Modelling** — issue #67 standalone backup/apply
rollback-default loop (`PartialRollbackDrop.qnt`). The model is grounded
in the managed-fields / apply surfaces and the controller/webhook
re-defaulting paths already used elsewhere in the topology corpus.

**Trigger.** An operator creates a backup with `kubectl get -o yaml`, the
backup omits server-defaulted fields, and a later `kubectl apply` of the
backup nulls those fields. Controllers/webhooks re-default the fields,
leaving the object drifting away from the operator’s backup expectation.

**Init / scenarios.** `singleRedefaultRun` shows the intended regime:
backup omits the field, apply drops it, controller re-defaults it once,
and `OperatorActionRecoverable` holds. `rollbackLoopRun` adds the
operator-observed loop marker after re-default, violating
`RedefaultConverges`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Managed-fields / apply cleanup | `internal/util/ssa/managedfields.go` | 49-197 |
| Topology dry-run managed-fields cleanup | `internal/controllers/topology/cluster/structuredmerge/dryrun.go` | 220-281 |
| Cluster managed-fields stripping before reconcile/runtime use | `internal/controllers/topology/cluster/cluster_controller.go` | 607-608 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the backup/apply redefine loop via `rollbackLoopRun`, and
Apalache reaches the same `RedefaultConverges` violation from
`rollbackLoopInit` within depth 4 (`make verify-partial-revert-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

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
demos and 300×60 random walk in `ClusterE2E.qnt`, and again across the
substrate-aware `ClusterE2ERefined.qnt` demos plus 500×60 random walk.
**Apalache hopelessness proven** (depth 4, ~10 s) in `ClusterE2E.qnt`
and re-recorded at depth 4 in `ClusterE2ERefined.qnt` — see
`make verify-e2e-apalache` and `make verify-clustere2e-refined`.
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
demos and 300×60 random walk in `ClusterE2E.qnt`, and across the
substrate-aware `ClusterE2ERefined.qnt` demos plus 500×60 random walk.
**Apalache hopelessness proven** (depth 4, ~9 s) and re-recorded in the
refined model at depth 4.
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
and 300×60 random walk in `ClusterE2E.qnt`, and across the
substrate-aware `ClusterE2ERefined.qnt` demos plus 500×60 random walk.
**Apalache hopelessness proven** (depth 4, ~9 s) and re-recorded in the
refined model at depth 4.
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

## FM-52 — MachineDeployment rollout / MHC conflicting delete pressure

**Provenance.** **Modelling** — surfaced by the dedicated
MachineDeployment rollout model for issue #14. The race is
between rollout-owned old-Machine scale-down and
MachineHealthCheck-owned remediation for the same worker fleet.

**Trigger.** A rollout is already running, replacement capacity
exists, and MHC independently marks an old Machine unhealthy.
If ownership bookkeeping is stale, both the rollout planner and
the remediation path may attempt to claim the same delete slot.

**Init / scenarios.** `conflictingDeleteRaceRun` demonstrates the
safe sequence where MHC and rollout delete different Machines.
`MachineDeletionRaceWithMHC` is kept as a synthetic bug action to
show the conflicting-delete shape explicitly.

**Verdict.** Stable invariant `MhcCannotDeleteScaleDownVictim`
holds in `specs/MachineDeploymentRollout.qnt` (1000×60 random
walk) and the controller-runtime refinement preserves the same
ownership split under single-key reconcile serialisation.

**Classification.** **MODELLING** (ownership invariant over
upstream choreography).

## FM-53 — Rollout availability snapshot invariant is too strong

**Provenance.** **Modelling** — issue #14 intentionally asks for
counterexample-driven refinement of MD rollout invariants.

**Trigger.** While a rollout is running, the operator changes
`MachineDeployment.spec.replicas` upward while an MHC-owned drain
is already in flight. The stronger snapshot-style obligation
`AvailabilityBound` fails transiently before the replacement
Machine becomes Healthy.

**Init / scenarios.** Captured in
`counterexample-log.md` as a deliberate open counterexample on
`MachineDeploymentRollout.AvailabilityBound`.

**Verdict.** The invariant is retained as a documented
counterexample candidate and is NOT part of the passing stable
safety battery. This is an accepted modelling outcome, not an
upstream implementation bug.

**Classification.** **MODELLING** (counterexample candidate).

## FM-95 — ClusterTopology reads a torn ClusterClass view mid-update

**Provenance.** **Modelling** — issue #84 standalone ClusterClass /
topology torn-read slice (`ClusterClassTopologyRace.qnt`). The concrete
read surface is the topology reconciler invoking
`DefaultAndValidateVariables` against a `ClusterClass`, while the
definition-conflict signal is grounded in the topology variable
validation helpers.

**Trigger.** `ClusterClass` begins updating its variable definitions,
but the topology reconciler reads a mixed old/new view before the update
finishes. Variable resolution then sees an inconsistent definition set
and produces an invalid merged template.

**Init / scenarios.** `versionPinnedReadRun` shows the intended regime:
update the ClusterClass, finish the update, then let topology pin and
resolve the new version cleanly. `tornReadRun` begins the update,
performs a mid-update read, and resolves variables from that torn view,
violating `ConsistentCCViewPerReconcile`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Topology reconciler variable default/validate read | `internal/controllers/topology/cluster/cluster_controller.go` | 354 |
| Cluster webhook variable validation surface | `internal/webhooks/cluster.go` | 754-756 |
| Variable-definition conflict surfacing | `internal/topology/variables/utils.go` | 78 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the torn-read path via `tornReadRun`, and Apalache reaches the
same `ConsistentCCViewPerReconcile` violation from `tornReadInit`
within depth 4 (`make verify-cc-topology-race-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-96 — ClusterResourceSet ApplyOnce runs before kubelets join

**Provenance.** **Modelling** — issue #85 standalone ClusterResourceSet
timing slice (`ClusterResourceSetTiming.qnt`). The concrete strategy
surface is the CRS controller's `ApplyOnce` vs `Reconcile` split; the
readiness race is grounded in the same control-plane-init milestone the
topology/formal corpus already uses.

**Trigger.** `Cluster.Status.ControlPlaneInitialized` becomes true, the
ClusterResourceSet `ApplyOnce` strategy fires, but worker kubelets have
not yet joined. The payload is consumed exactly once, fails to take
effect, and is never retried.

**Init / scenarios.** `joinsBeforeApplyRun` shows the intended regime:
control plane initialises, kubelets join, then CRS applies and the
payload becomes effective. `applyBeforeJoinRun` races the apply ahead of
kubelet join, violating `ApplyOnceEventuallyTakesEffect`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| CRS apply / binding update path | `internal/controllers/clusterresourceset/clusterresourceset_controller.go` | 292-447 |
| CRS strategy selection | `internal/controllers/clusterresourceset/clusterresourceset_scope.go` | 81-87 |
| Control-plane-init milestone grounding | `internal/controllers/topology/cluster/cluster_controller.go` | 354 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the ApplyOnce timing race via `applyBeforeJoinRun`, and
Apalache reaches the same `ApplyOnceEventuallyTakesEffect` violation
from `applyBeforeJoinInit` within depth 4
(`make verify-crs-timing-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-118 — CRD schema bump adds required fields and invalidates stored objects

**Provenance.** **Modelling** — issue #77 standalone CRD schema-upgrade
slice (`CrdSchemaBump.qnt`). The model is grounded in the real CRD
migration/storage-version machinery and the conversion utility surface
used when reading or rewriting stored objects.

**Trigger.** A CRD upgrade bumps the served/storage schema and adds a new
required field. Existing stored objects still reflect the older schema,
no migration has rewritten them, and the next controller read fails
validation instead of succeeding through conversion or migration.

**Init / scenarios.** `migratedObjectRun` shows the intended regime:
schema bumps, a migration rewrites the stored object to include the new
required field, and reads succeed, satisfying
`MigrationPathExistsForBumpedSchema`. `validationFailureRun` drives the
bad path: schema bumps, no migration occurs, and the next read fails,
violating `NoOrphanedStoredObjects`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| clusterctl CRD migration checks | `cmd/clusterctl/client/cluster/crd_migration.go` | 66-228 |
| controller CRD migrator rewrite path | `controllers/crdmigrator/crd_migrator.go` | 262-435 |
| conversion utility annotation/migration surface | `util/conversion/conversion.go` | 43-123 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the validation-failure path via `validationFailureRun`, and
Apalache reaches the same `NoOrphanedStoredObjects` violation from
`validationFailureInit` within depth 4 (`make verify-crd-schema-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-97 — KCP and MHC concurrently delete the same Machine

**Provenance.** **Modelling** — issue #83 standalone delete-race slice
(`KcpMhcDeleteRace.qnt`). The KCP replacement path is grounded in the
control-plane scale/helpers code, while the MHC-side selection/remediation
path is grounded in the machine-healthcheck controller.

**Trigger.** KCP has already selected an unhealthy old machine for
replacement and may have created the replacement, while MHC independently
marks the same old machine unhealthy and also decides it should be
deleted. Depending on timing, both controllers can believe they own
deletion, and the replacement can even be selected for remediation before
it has stabilized.

**Init / scenarios.** `authoritativeDeleteRun` shows the intended regime:
KCP creates the replacement and is the sole deleter of the old machine.
`concurrentDeleteRun` sets both KCP and MHC as deleters of the old
machine, violating `NoDoubleDelete`. `replacementCannibalisedRun` creates
the replacement, lands it on the same node/failure domain, and has MHC
select it immediately, violating `NoReplacementCannibalisation`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| KCP replacement selection / creation grounding | `controlplane/kubeadm/internal/controllers/scale.go` | 1-260 |
| KCP helper creation path | `controlplane/kubeadm/internal/controllers/helpers.go` | 149-305 |
| MHC remediation request / existence checks | `internal/controllers/machinehealthcheck/machinehealthcheck_controller.go` | 421-521, 795-813 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the concurrent double-delete path via `concurrentDeleteRun`,
and Apalache reaches the same `NoDoubleDelete` violation from
`doubleDeleteInit` within depth 4 (`make verify-kcp-mhc-delete-apalache`).
The replacement-cannibalisation variant is separately captured via
`NoReplacementCannibalisation` on `replacementCannibalisedRun`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-98 — Machine readiness gets stuck because bootstrap and infra ready edges are observed separately

**Provenance.** **Modelling** — issue #86 standalone Machine readiness
race slice (`BootstrapInfraReadyRace.qnt`). The model is grounded in the
two independent readiness mirrors the Machine controller already maintains
for bootstrap and infrastructure providers.

**Trigger.** Bootstrap readiness becomes true and is observed first.
Infrastructure readiness later becomes true in reality, but the follow-up
event is lost or never reaches the next Machine reconcile. The Machine
controller remains stuck with `lastObserved = bootstrap` and never flips
Machine ready even though both children are ready in truth.

**Init / scenarios.** `bothReadyObservedRun` shows the intended regime:
both child-ready edges are observed and `MachineReadyEventuallyReflectsBoth`
holds. `missingInfraEventRun` drives the bad path: bootstrap is observed,
infra flips ready, the event is dropped, and
`NoStuckUnreadyDespiteBothChildrenReady` is violated.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Bootstrap-ready mirror | `internal/controllers/machine/machine_controller_status.go` | 78-164 |
| Bootstrap-ready phase integration | `internal/controllers/machine/machine_controller_phases.go` | 180-205 |
| Infra-ready mirror | `internal/controllers/machine/machine_controller_status.go` | 167-255 |
| Infra-ready phase integration | `internal/controllers/machine/machine_controller_phases.go` | 305-373 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the missing-event stuck-unready path via
`missingInfraEventRun`, and Apalache reaches the same
`NoStuckUnreadyDespiteBothChildrenReady` violation from
`missingEventInit` within depth 4 (`make verify-bootstrap-infra-race-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-99 — Two operators' concurrent `Cluster.spec` edits lose intent or violate surge assumptions

**Provenance.** **Modelling** — issue #65 standalone concurrent-edit
slice (`ConcurrentClusterSpecEdits.qnt`). The spec is grounded in the
existing SSA/co-authorship topology helper and the KCP scale path that
turns the desired version/replica spec into actual control-plane size.

**Trigger.** Operator A updates `spec.topology.version`, while operator B
concurrently updates `spec.topology.controlPlane.replicas`. In the safe
case both intents converge. In the bad cases, a stale full-object apply
drops the version edit or rollout surge and replica scale-up together
push actual replicas beyond the intended surge bound.

**Init / scenarios.** `serialEditsRun` shows the intended regime: the
version edit is applied, rollout progresses, then the replica edit is
applied and the final state converges to version `1.30` and replicas `5`.
`lostEditRun` models a stale full-object overwrite and violates
`NoLostEdit`. `surgeRaceRun` models rollout surge and scale-up both
growing the population, violating `NoSurgeBoundViolation`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| SSA/co-authorship helper | `internal/controllers/topology/cluster/structuredmerge/serversidepathhelper.go` | 1-262 |
| SSA co-authoring tests | `internal/controllers/topology/cluster/structuredmerge/serversidepathhelper_test.go` | 50-51, 637-638 |
| KCP scale path grounding | `controlplane/kubeadm/internal/controllers/scale.go` | 1-260 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-overwrite path via `lostEditRun`, and Apalache
reaches the same `NoLostEdit` violation from `lostEditInit` within depth
4 (`make verify-concurrent-spec-edits-apalache`). The surge-race variant
is separately captured via `NoSurgeBoundViolation` on `surgeRaceRun`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-100 — Autoscaler scale-up and KCP rollout surge overproduce replicas

**Provenance.** **Modelling** — issue #87 standalone autoscaler + rollout
surge slice (`AutoscalerKcpSurgeRace.qnt`). The spec is grounded in the
existing MachineDeployment surge arithmetic and the API contract that an
external autoscaler may manage replica count.

**Trigger.** Cluster-autoscaler raises desired worker replicas while a
rollout path still computes surge from a stale desired count. Before the
two intents are arbitrated into one source of truth, both the autoscaler
and the rollout logic independently grow the worker pool.

**Init / scenarios.** `serializedScaleRollRun` shows the intended regime:
autoscaler scale-up is applied first, then rollout surge is computed from
the updated desired count and `AutoscalerKcpArbitrated` holds.
`concurrentScaleRollRun` keeps the stale autoscaler intent alive while
applying rollout surge on top of the scaled-up pool, violating
`SurgeBoundUnderConcurrentScale`.

**LSP grounding.**

| Go / API entry point | File | Line |
|---|---|---|
| External autoscaler ownership hint | `api/core/v1beta1/cluster_types.go` | 733, 921 |
| MD surge arithmetic | `internal/controllers/machinedeployment/mdutil/util.go` | 295-302, 336, 663-684 |
| Rollout planner / surge usage | `internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go` | 481-515 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the concurrent autoscale+rollout path via
`concurrentScaleRollRun`, and Apalache reaches the same
`SurgeBoundUnderConcurrentScale` violation from `concurrentScaleInit`
within depth 4 (`make verify-autoscaler-kcp-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-105 — Mid-rollout etcd tag bump traps the control-plane upgrade

**Provenance.** **Modelling** — issue #81 standalone version-coupling
slice (`EtcdKubernetesVersionSkew.qnt`). The model is grounded in the
fact that the real upgrade helpers expose Kubernetes version and
`etcdImageTag` as separate knobs, while the Kubernetes-side preflight
logic enforces skew/order constraints.

**Trigger.** A control-plane Kubernetes upgrade is already mid-rollout
when `etcdImageTag` is bumped. The new etcd image is now coupled to a
Kubernetes/kubeadm state that has not fully converged, so preflight
blocks the next step and the rollout becomes trapped until versions are
realigned.

**Init / scenarios.** `orderedUpgradeRun` shows the intended regime:
Kubernetes rollout completes first, then the etcd tag changes, and
`EtcdUpgradeAfterControlPlaneGate` holds. `midRolloutEtcdBumpRun` bumps
the etcd tag while `midRollout=true`, triggering `dependencyTrap=true`
and violating `NoMidRolloutDependencyTrap`.

**LSP grounding.**

| Go / test entry point | File | Line |
|---|---|---|
| Control-plane helper etcd tag override | `test/framework/controlplane_helpers.go` | 340-341 |
| Topology helper etcd tag variable injection | `test/framework/cluster_topology_helpers.go` | 98-100 |
| E2E etcd upgrade knob | `test/e2e/cluster_upgrade.go` | 184, 221 |
| Kubernetes-side skew / preflight gate | `internal/controllers/machineset/machineset_preflight.go` | 100-122, 191-220 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the mid-rollout dependency trap via `midRolloutEtcdBumpRun`,
and Apalache reaches the same `NoMidRolloutDependencyTrap` violation from
`dependencyTrapInit` within depth 4 (`make verify-etcd-k8s-skew-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-113 — AZ-wide failure leaves KCP stuck targeting a failed or exhausted AZ

**Provenance.** **Modelling** — issue #59 standalone AZ failover / capacity
slice (`AzFailoverCapacity.qnt`). The model is grounded in the real
failure-domain scale-up picker and desired-machine creation path used by
KCP.

**Trigger.** One AZ fails, KCP needs to relaunch the lost control-plane
replica, but the first surviving AZ it targets is either still the failed
AZ or an exhausted surviving AZ. If KCP never retargets to another
surviving AZ that still has capacity, replacement remains pending
indefinitely.

**Init / scenarios.** `alternativeAzSuccessRun` shows the intended safe
regime: AZ `a` fails, `b` is exhausted, KCP first hits the failed/exhausted
path, then retargets to `c` and successfully creates the replacement,
satisfying `KcpAttemptsAlternativeAzs`. `stuckOnFailedAzRun` keeps the
replacement pending against the failed AZ, violating
`NoIndefiniteScaleAttempt`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Scale-up failure-domain picker | `controlplane/kubeadm/internal/control_plane.go` | 238-247 |
| KCP scale-up calls into picker | `controlplane/kubeadm/internal/controllers/scale.go` | 46, 85 |
| Desired-machine creation in failure domain | `controlplane/kubeadm/internal/controllers/helpers.go` | 160-163 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the failover-stall path via `stuckOnFailedAzRun`, and
Apalache reaches the same `NoIndefiniteScaleAttempt` violation from
`stuckFailoverInit` within depth 4 (`make verify-az-failure-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-104 — Rollback during partial cycling temporarily exceeds surge bound

**Provenance.** **Modelling** — issue #82 standalone rollback-during-
partial-cycle surge slice (`RollbackSurgeRace.qnt`). The model is
grounded in the same MachineDeployment surge arithmetic as the autoscaler
race, but with the second actor replaced by an operator rollback intent.

**Trigger.** A rollout already has surge replicas in flight when an
operator rollback is requested. Instead of waiting until the old-version
drain point is reached, rollback restores old replicas immediately,
temporarily pushing total replicas beyond `desiredReplicas + maxSurge`.

**Init / scenarios.** `serializedRollbackRun` shows the intended regime:
surge starts, an old replica drains, rollback is requested, and the old
replica is only restored at the safe point. `rollbackMidCycleRun`
requests rollback while surge is still present and immediately restores
an old replica, violating `NoTransientSurgeBeyondBound`.

**LSP grounding.**

| Go / test entry point | File | Line |
|---|---|---|
| MD surge arithmetic | `internal/controllers/machinedeployment/mdutil/util.go` | 295-302, 336, 663-684 |
| Rollout planner / surge usage | `internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go` | 481-515 |
| Rollback partial-changes test hint | `internal/controllers/machineset/machineset_controller_test.go` | 2724 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the rollback-mid-cycle surge path via `rollbackMidCycleRun`,
and Apalache reaches the same `NoTransientSurgeBeyondBound` violation
from `rollbackMidCycleInit` within depth 4
(`make verify-rollback-surge-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-101 — Controller-manager replay re-applies an effect after leader failover

**Provenance.** **Modelling** — issue #90 standalone controller-manager
OOM / replay slice (`ControllerManagerReplay.qnt`). The leader-election
and replay substrate is grounded in the existing `ControllerRuntime.qnt`
formal model and the test-framework note that failed leader election /
restarts extend retries.

**Trigger.** The leader controller-manager applies an effect, OOM-kills,
loses its in-memory "already did X" marker, another replica acquires the
lease with a cold cache, and replay logic re-applies the same effect
instead of reconstructing completion from durable state.

**Init / scenarios.** `cleanReplayRun` shows the intended regime: the
original leader applies the effect once, dies, the new leader takes over,
and `ReplayFromDurableState` restores the in-memory marker without
changing `effectCount`. `doubleEffectReplayRun` takes the bad path and
increments `effectCount` a second time, violating `NoDoubleEffect`.

**LSP grounding.**

| Go / formal entry point | File | Line |
|---|---|---|
| Existing leader/replay substrate | `formal/specs/ControllerRuntime.qnt` | 1-427 |
| Restart/retry note | `test/framework/cluster_proxy.go` | 58 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the replay double-effect path via `doubleEffectReplayRun`, and
Apalache reaches the same `NoDoubleEffect` violation from
`doubleEffectInit` within depth 4 (`make verify-controller-replay-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-103 — Management-cluster split-brain yields two active leader controllers

**Provenance.** **Modelling** — issue #94 standalone split-brain slice
(`ControllerLeaderSplitBrain.qnt`). The model is grounded in the same
leader-election surface as `ControllerManagerReplay.qnt`, but explores the
more adversarial case where lease ownership temporarily diverges and two
leaders both believe they are active.

**Trigger.** The management-cluster apiserver or lease view splits such
that controller-manager replica A and replica B both believe they own the
lease. Before convergence, both apply the same controller effect.

**Init / scenarios.** `leaseConvergesRun` shows the intended regime:
single leader applies the effect and lease convergence preserves that
single-writer history. `splitBrainRun` first enters `LeaseSplit`, then
lets both leaders apply the effect, violating
`NoDuplicateEffectAcrossLeaders`.

**LSP grounding.**

| Go / formal entry point | File | Line |
|---|---|---|
| Main manager leader-election flags | `main.go` | 364-369 |
| KCP manager leader-election flags | `controlplane/kubeadm/main.go` | 287-292 |
| Existing single-leader replay substrate | `formal/specs/ControllerManagerReplay.qnt` | 1-67 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the split-brain duplicate-effect path via `splitBrainRun`, and
Apalache reaches the same `NoDuplicateEffectAcrossLeaders` violation from
`splitBrainInit` within depth 4 (`make verify-controller-splitbrain-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-102 — MachinePool spec replicas and provider actual scale oscillate

**Provenance.** **Modelling** — issue #89 standalone MachinePool
scale-conflict slice (`MachinePoolScaleConflict.qnt`). The CAPI side is
grounded in the desired-state generator that computes
`MachinePool.spec.replicas`, while the provider side is grounded in the
API contract that an external autoscaler/provider may own scale.

**Trigger.** CAPI keeps forcing `MachinePool.spec.replicas` to one value
while the provider/autoscaler keeps rebalancing actual instances to
another. Without explicit ownership arbitration, the system alternates
between the two intents and never converges.

**Init / scenarios.** `arbitratedScaleRun` shows the intended regime:
provider scale ownership is marked, provider actual is rebalanced, and
CAPI adopts provider actual as the new desired replica count so
`EventualConvergence` holds. `oscillationRun` takes the bad path:
CAPI sets replicas to `5`, the provider rebalances to `8`, and the model
records the oscillation, violating `NoOscillation`.

**LSP grounding.**

| Go / API entry point | File | Line |
|---|---|---|
| Desired MachinePool replicas | `exp/topology/desiredstate/desired_state.go` | 1337-1415 |
| External autoscaler ownership hint | `api/core/v1beta1/cluster_types.go` | 733, 921 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the spec-vs-provider oscillation via `oscillationRun`, and
Apalache reaches the same `NoOscillation` violation from
`oscillationInit` within depth 4 (`make verify-machinepool-scale-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-66 — User-provided kubeconfig secret is rotated as if KCP owned it

**Provenance.** **Modelling** — first issue-20 counterexample
candidate.

**Trigger.** A kubeconfig Secret that is user-provided or otherwise not
owned by KCP is still regenerated when its client certificate ages past
the renewal window.

**Init / scenarios.** Logged in `counterexample-log.md` as
`KubeletPKI.ownedSecretOnlyRotates`, reproduced via
`userSecretRotationRun` with `--invariant=ownedSecretOnlyRotates`.

**Verdict.** Logged as a deliberate ownership-guard counterexample.
The stable invariant set follows the controller helper, which only
rotates owned Secrets.

**Classification.** **MODELLING** (counterexample candidate).

## FM-67 — Cluster CA is regenerated after KCP initialization

**Provenance.** **Modelling** — second issue-20 counterexample
candidate.

**Trigger.** KCP has already initialized at least one control-plane
machine, cluster CA material later goes missing, and reconcile mints a
fresh CA instead of surfacing the unsupported state as an error.

**Init / scenarios.** Logged in `counterexample-log.md` as
`KubeletPKI.caNotRecreatedAfterInit`, reproduced via
`postInitCARegenRun` with `--invariant=caNotRecreatedAfterInit`.

**Verdict.** Logged as the post-init CA-regeneration counterexample.
The stable model follows `reconcileClusterCertificates`: generation is
allowed only before initialization; after that, missing CA is an error.

**Classification.** **MODELLING** (counterexample candidate).

## FM-68 — Kubeconfig rotation rewrites the control-plane endpoint

**Provenance.** **Modelling** — third issue-20 counterexample
candidate.

**Trigger.** A kubeconfig rotation path replaces or rewrites the server
endpoint instead of preserving the address parsed from the existing
Secret.

**Init / scenarios.** Logged in `counterexample-log.md` as
`KubeletPKI.rotationPreservesEndpoint`, reproduced via
`endpointRewriteRun` with `--invariant=rotationPreservesEndpoint`.

**Verdict.** Logged as the endpoint-rewrite counterexample. The stable
invariant follows `RegenerateSecret`, which reuses the endpoint parsed
from the existing kubeconfig before re-signing client credentials.

**Classification.** **MODELLING** (counterexample candidate).

## FM-54 — Old-MS starvation snapshot invariant is too strong

**Provenance.** **Modelling** — second issue-14 counterexample
candidate.

**Trigger.** The rollout planner selected an old Machine only
after replacement capacity existed, but a later operator template
change aborts the rollout generation. The derived state can still
show `scaleDownSelected=true` after the earlier replacement-ready
fact has been invalidated, so a timeless `NoStarveOldMS`
obligation is too strong.

**Init / scenarios.** Logged in `counterexample-log.md` on
`MachineDeploymentRollout.NoStarveOldMS`.

**Verdict.** Like FM-53, this remains a documented
counterexample candidate rather than a member of the stable
passing invariant battery.

**Classification.** **MODELLING** (counterexample candidate).

## FM-55 — ClusterClass patch order is non-confluent on overlapping fields

**Provenance.** **Modelling** — issue #15 adds an explicit model for
the ordered patch accumulation loop in the topology patch engine.

**Trigger.** Two ClusterClass patches write the same JSON pointer
(`ImageTag` in the abstraction). Enabling the conflicting patch and
then flipping `ClusterClassPatchOrderChange` changes the final merged
template even though the enabled patch set is unchanged.

**Init / scenarios.** Captured in `counterexample-log.md` as
`ClusterClassPatches.mergeDeterministicAllOrders`. The stable invariant
`mergeDeterministic` is intentionally scoped to independent-field patch
sets only.

**Verdict.** Deliberate counterexample candidate. Not treated as an
upstream implementation bug; it documents the non-confluent merge shape
that an explicit ordered patch pipeline necessarily admits.

**Classification.** **MODELLING** (counterexample candidate).

## FM-56 — Immutable-field snapshot taken before validation is too strong

**Provenance.** **Modelling** — second issue-15 counterexample
candidate.

**Trigger.** `ClusterClassImmutableFieldChanges` updates the variable
feeding an immutable field. The raw merged template flips the field, but
the webhook verdict becomes `ValidationReject` and `MergedTemplateApplied`
never commits the change to the applied template.

**Init / scenarios.** Logged in `counterexample-log.md` as
`ClusterClassPatches.immutableMergedCandidate`.

**Verdict.** The stronger pre-validation snapshot claim is rejected on
purpose. The stable invariant is `immutablePreserved`, which ranges over
the applied template that survives webhook validation.

**Classification.** **MODELLING** (counterexample candidate).

## FM-57 — Parent object disappears before child finalizers clear

**Provenance.** **Modelling** — issue #18 adds an explicit finalizer
chain model and a synthetic `OwnerDeletedMachineSet` action to exercise
the ordering bug the stable safety invariants intentionally exclude.

**Trigger.** A parent object (`MachineSetObj` in the reproduced trace)
has already cleared its own finalizer and disappears while a child
(`MachineObj`) is still alive with provider-side leaves
(`InfraMachineObj`, `BootstrapConfigObj`) pending.

**Init / scenarios.** Logged in `counterexample-log.md` as
`Finalizers.ownerDeletionWaitsForChildrenCandidate`, reproduced via
`orphanedChildOrderingRun` followed by `OwnerDeletedMachineSet`.

**Verdict.** Deliberate counterexample candidate. Not treated as an
upstream implementation bug by itself; it documents the stronger
ordering obligation that the current stable battery does not claim.

**Classification.** **MODELLING** (counterexample candidate).

## FM-58 — Progress-from-any-state is too strong under deletion stalls

**Provenance.** **Modelling** — second issue-18 counterexample
candidate.

**Trigger.** Deletion is in flight, but no controller has yet
acknowledged the parent/child handoff and the external block flags are
also asserted (`infraQuotaExceeded`, `nodeDrainBlocked`). In that state
the stronger obligation that *some* `RemoveFinalizer` action is enabled
from every deleting state fails immediately.

**Init / scenarios.** Logged in `counterexample-log.md` as
`Finalizers.progressFromAnyStateCandidate`, reproduced via
`blockedDeletionRun`.

**Verdict.** Accepted as an over-strong liveness candidate rather than a
passing invariant. The stable battery verifies safety properties of the
chain and leaves eventual progress to the Lean companion theorem under a
well-founded clearing measure.

**Classification.** **MODELLING** (counterexample candidate).

## FM-59 — Restart invalidates in-memory hook cache, causing replay

**Provenance.** **Modelling** — issue #16 adds an explicit Runtime SDK
discovery / cache lifecycle model.

**Trigger.** A hook response has already been applied once for the
current generation, then a controller restart invalidates the in-memory
response cache. The next retry replays the transport call even though the
effect-level application remains idempotent.

**Init / scenarios.** Logged in `counterexample-log.md` as
`RuntimeSDK.restartCacheReuseCandidate`, reproduced via
`restartCacheReplayRun` followed by `InvokeHook`.

**Verdict.** Deliberate counterexample candidate. The stable invariant is
`cacheInvalidatedOnRestart`; the stronger claim that there is no replayed
transport call across restart is intentionally rejected.

**Classification.** **MODELLING** (counterexample candidate).

## FM-60 — Partial failure may require transport replay of the same hook generation

**Provenance.** **Modelling** — second issue-16 counterexample
candidate.

**Trigger.** One extension in an N-extension hook chain fails after a
prefix of handlers has already completed. Recovery keeps the
already-applied prefix intact, but a retry replays the transport-level
hook call for the same generation.

**Init / scenarios.** Logged in `counterexample-log.md` as
`RuntimeSDK.partialFailureSingleTransportCandidate`, reproduced via
`partialFailureRetryRun` followed by `InvokeHook`.

**Verdict.** Accepted as a replay-style counterexample rather than a
stable invariant failure. The passing property is
`partialFailureRecoverable`, which protects prefix integrity instead of
forbidding replay.

**Classification.** **MODELLING** (counterexample candidate).

## FM-61 — Pivot crash leaves dual-live object without pause fence

**Provenance.** **Modelling** — issue #17 adds an explicit clusterctl
move / pivot model for source pause, destination restore, and source
teardown.

**Trigger.** A controller crash lands after the destination has already
restored part of the owner graph, but before the move is fenced by the
intended pause / teardown window. The same object can then be live on
both clusters while neither side is safely fenced.

**Init / scenarios.** Logged in `counterexample-log.md` as
`Pivot.crashMutualExclusionCandidate`, reproduced via
`crashDualReconcileRun`.

**Verdict.** Deliberate counterexample candidate. The stable invariant
`mutualExclusion` only ranges over reachable states that keep the
transfer fenced while duplication is tolerated; the stronger crash-state
claim is documented separately.

**Classification.** **MODELLING** (counterexample candidate).

## FM-62 — Partial pivot restores leaf before owner chain

**Provenance.** **Modelling** — second issue-17 counterexample
candidate.

**Trigger.** A partial restore places a leaf object on the destination
cluster while its owner chain is still present only on the source. The
result is a destination-side orphan that the stable owner-closure
invariant intentionally excludes from the passing battery.

**Init / scenarios.** Logged in `counterexample-log.md` as
`Pivot.partialPivotOrphanCandidate`, reproduced via `partialOrphanRun`.

**Verdict.** Accepted as a stronger pivot-snapshot obligation rather
than a passing invariant. The stable property `noOrphan` allows
source+destination duplication during transfer, but not destination-only
children whose owner chain is missing there.

**Classification.** **MODELLING** (counterexample candidate).

## FM-63 — v1beta2 projection drops a legacy diagnostic key

**Provenance.** **Modelling** — issue #19 adds an explicit
conversion-webhook model plus a Lean witness for the FM-16
informativeness gap.

**Trigger.** A v1beta1 status projection carries a legacy diagnostic
tag (`context deadline exceeded`) while the v1beta2 status surface only
keeps a generic wrapper tag. The newer projection is therefore not at
least as informative as the older one.

**Init / scenarios.** Logged in `counterexample-log.md` as
`ConversionWebhook.roundTripStatusInformative`, reproduced via
`statusProjectionLossRun` with `--invariant=roundTripStatusInformative`.

**Verdict.** Deliberate counterexample candidate and the concrete
witness used to replace the previous `trivial` proof in
`formal/proofs/ControlPlane/Informativeness.lean`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-64 — One-version-only status field is dropped without documentation

**Provenance.** **Modelling** — second issue-19 counterexample
candidate.

**Trigger.** A field that exists only in one version is absent from the
other version's surface, and the drop is not explicitly documented in
the conversion corpus.

**Init / scenarios.** Logged in `counterexample-log.md` as
`ConversionWebhook.informationLossDocumented`, reproduced via
`undocumentedFieldLossRun` with `--invariant=informationLossDocumented`.

**Verdict.** Accepted as a documentation-gap counterexample rather than
a stable invariant failure in the supported conversion path.

**Classification.** **MODELLING** (counterexample candidate).

## FM-65 — NoneConverter fallback serves a cross-version read

**Provenance.** **Modelling** — third issue-19 counterexample
candidate.

**Trigger.** The conversion webhook is unavailable, `noneConverter`
fallback is enabled, and the caller still requests a different API
version than the stored one. That is exactly the silent-cross-version
path the model treats as unsafe.

**Init / scenarios.** Logged in `counterexample-log.md` as
`ConversionWebhook.noneConverterCrossVersionCandidate`, reproduced via
`outageFallbackRun` with
`--invariant=noneConverterCrossVersionCandidate`.

**Verdict.** Logged as the expected outage-fallback counterexample.
The stable invariant `webhookFailureSafe` requires this situation to
surface as a clean error while leaving stored data untouched.

**Classification.** **MODELLING** (counterexample candidate).

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

## FM-69 — Bounded fault storm still permits legitimate reconcile completion

**Provenance.** **Modelling** — issue #30 fault-storm slice layered on
top of `ControllerRuntime.qnt`.

**Trigger.** Several non-legitimate keys flap simultaneously, but the
aggregate fault rate stays within the abstract refill budget captured by
`MAX_BURST` and `REFILL_RATE`.

**Init / scenarios.** `boundedFaultStormRun` drives two faulting keys
plus a distinguished legitimate key (`LEGIT_KEY`). The scenario checks
`FM69_BoundedFaultProgress`, requiring the legitimate key to still
finish with `OutcomeSuccess`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `processNextWorkItem` | `pkg/internal/controller/controller.go` | 419 |
| Non-terminal error requeue (`AddRateLimited`) | same | 487-489 |
| `handleWaitingItems` | `pkg/controller/priorityqueue/priorityqueue.go` | 309-356 |
| `NumRequeues` / `Forget` | same | 497-521 |

**Verdict.** `FM69_BoundedFaultProgress` holds on the dedicated
bounded-fault demo run. This is not claimed as a global controller-runtime
invariant; it is an issue-specific scenario check layered on top of the
stable FM-45/46/47 battery.

**Classification.** **MODELLING** (bounded-fault scenario holds).

## FM-70 — Fault-storm overload starves a legitimate reconcile

**Provenance.** **Modelling** — issue #30 overload counterexample.

**Trigger.** Repeated fault-induced retries on other keys consume the
abstract dispatch budget quickly enough that a legitimate key remains in
the ready queue without being served.

**Init / scenarios.** `faultStormOverloadRun` drives two consecutive
error / requeue cycles for a flapping peer key before enqueuing the
distinguished legitimate key. The stronger property
`FM70_NoLegitReadyBacklog` then fails because the legitimate key is left
in `InReady` rather than being reconciled immediately.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `processNextWorkItem` | `pkg/internal/controller/controller.go` | 419 |
| Non-terminal error requeue (`AddRateLimited`) | same | 487-489 |
| `handleWaitingItems` | `pkg/controller/priorityqueue/priorityqueue.go` | 309-356 |
| `NumRequeues` / `Forget` | same | 497-521 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the overload shape directly via `faultStormOverloadRun`, and Apalache
finds a violation of `FM70_NoLegitReadyBacklog` from `init` within depth
4 (`make verify-cr-faultstorm-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-71 — Cross-controller cyclic enqueue livelock

**Provenance.** **Modelling** — issue #31 two-controller queue / cache
cycle (`CrossControllerCycle.qnt`). The concrete watch edges come from
the MachineDeployment controller watching MachineSets and the MachineSet
controller watching MachineDeployments / Machines.

**Trigger.** Reconciler `Md` is in flight, cross-enqueues work that makes
`Ms` reconcile, and then waits for its cache to observe the resulting
MachineSet-side update. `Ms` starts, cross-enqueues back toward the
Deployment-side object, and also waits for its own cache to observe the
peer-side update. With both caches still stale, both controllers are in
flight and blocked on each other.

**Init / scenarios.** `livelockCycleRun` reaches the blocked cycle in four
steps and violates `NoCyclicLivelock`. `stabilisedCycleRun` follows the
same enqueue pattern but then executes `CacheSyncMdOnMs` /
`CacheSyncMsOnMd`, after which `CompleteMd` / `CompleteMs` are enabled and
the cycle drains.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| `MachineSetToDeployments` watch enqueue | `internal/controllers/machinedeployment/machinedeployment_controller.go` | 106-113 |
| `MachineToMachineSets` / `mdToMachineSets` watch enqueue | `internal/controllers/machineset/machineset_controller.go` | 131-141 |
| Cache reader split | `pkg/client/client.go` | 40-91 |
| Queue drain | `pkg/internal/controller/controller.go` | 419 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the livelock via `livelockCycleRun`, and Apalache reaches the same
blocked shape from `init` within depth 4 (`make verify-cross-controller-cycle-apalache`).
The stabilised companion scenario demonstrates the recovery regime once
the peer cache views catch up.

**Classification.** **MODELLING** (counterexample candidate).

## FM-72 — Reflector relist storm duplicates a Machine create

**Provenance.** **Modelling** — issue #32 bookmark-gap / RV-too-old / relist
storm abstraction (`ReflectorRelistStorm.qnt`). The concrete watch
semantics are anchored to the in-memory runtime watch implementation,
while the create surface is anchored to the KCP machine-generation helper.

**Trigger.** A reflector misses a bookmark, the apiserver compacts, the
watch session relists, and the current create-intent state is replayed.
If reconcile is not idempotent, both the relist replay and the later
watch replay can trigger the same Machine create path.

**Init / scenarios.** `idempotentRelistStormRun` shows the safe regime:
the duplicate delivery is ignored and `NoDuplicateMachineLeak` still
holds. `duplicateCreateRelistStormRun` takes the adversarial branch
`CreateDuplicateMachineBug` and violates `NoDuplicateMachineLeak` by
driving `machineCount` from `1` to `2`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Bookmark event emission | `test/infrastructure/inmemory/pkg/server/api/watch.go` | 173-185 |
| Bookmark RV retrieval | `test/infrastructure/inmemory/pkg/runtime/cache/cache.go` | 51 |
| Bookmark RV client impl | `test/infrastructure/inmemory/pkg/runtime/cache/client.go` | 84-95 |
| KCP desired-machine generation | `controlplane/kubeadm/internal/controllers/helpers.go` | 149-193 |
| KCP Machine create + cache wait | `controlplane/kubeadm/internal/controllers/helpers.go` | 298-305 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the duplicate-create bug via `duplicateCreateRelistStormRun`, and
Apalache reaches the same `NoDuplicateMachineLeak` violation from `init`
within depth 4 (`make verify-reliststorm-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-73 — Deleted object stays enqueued into a nil-read / shutdown-drain race

**Provenance.** **Modelling** — issue #33 queue/object lifecycle slice
(`StaleEnqueueShutdown.qnt`). The delete-after-enqueue path is grounded to
KCP/helper `IsNotFound` handling, while the shutdown side reuses the same
queue-drain intuition already present in the controller-runtime substrate.

**Trigger.** A key is enqueued, the object disappears from etcd before
reconcile reads it, and reconcile either handles NotFound correctly or
incorrectly proceeds as if a live object were still present. In the sister
scenario, manager shutdown stops accepting new work while one reconcile is
already in flight.

**Init / scenarios.** `deletedObjectHandledRun` demonstrates the safe
NotFound path via `HandleNotFound`. `shutdownDrainRun` shows an in-flight
reconcile draining after `ManagerShutdown`. `nilReadAfterDeleteRun`
reproduces the panic-class bug via `NilReadBug`, and `orphanedFinalizerRun`
reproduces the stronger finalizer-leak candidate.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| KCP reconcile NotFound handling | `controlplane/kubeadm/internal/controllers/controller.go` | 182, 451 |
| KCP helper NotFound handling | `controlplane/kubeadm/internal/controllers/helpers.go` | 59 |
| Queue work-item processing | `pkg/internal/controller/controller.go` | 419 |
| Finalizer patch NotFound guard | `util/patch/patch.go` | 186 |
| Deprecated patch NotFound guard | `util/deprecated/v1beta1/patch/patch.go` | 181 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the nil-read bug via `nilReadAfterDeleteRun`, and Apalache reaches the
same `NoNilReadAfterDelete` violation from `init` within depth 4
(`make verify-stale-shutdown-apalache`). The shutdown-drain companion run
still satisfies `ShutdownDrainCompletes`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-74 — Validator reads stale field before mutator default/replay converges

**Provenance.** **Modelling** — issue #34 admission-chain ordering slice
(`WebhookOrdering.qnt`). The concrete default/validate anchor is the
Cluster topology variable webhook path; reinvocation is modelled as
platform admission behaviour layered on top of that path.

**Trigger.** A validating webhook observes a field, then a mutating step
defaults or normalises that field later in the same admission chain. If
the validating verdict is not replayed against the new value, the final
admitted object no longer matches what the validator actually checked.

**Init / scenarios.** `convergingReinvocationRun` models the safe regime:
validator reads `Invalid`, mutator moves the value through `Defaulted`
into `Valid`, reinvocation is triggered, and the second validator pass
converges (`ReinvocationConverges`). `staleValidatorReadRun` models the
counterexample where mutation/defaulting happens after the original read,
but the chain still declares itself converged with the stale observation.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Cluster variable default + validate | `internal/webhooks/cluster.go` | 754-900 |
| Cluster topology path invoking `DefaultAndValidateVariables` | `internal/controllers/topology/cluster/cluster_controller.go` | 354 |
| ClusterClass variable validation | `internal/topology/variables/clusterclass_variable_validation.go` | 55-120 |
| ClusterClass webhook validation hook | `internal/webhooks/clusterclass.go` | 125 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the stale-validator-read bug via `staleValidatorReadRun`, and Apalache
reaches the same `ObservedValueIsFinal` violation from `init` within
depth 4 (`make verify-webhook-ordering-apalache`). The converging
companion run shows the intended replay regime.

**Classification.** **MODELLING** (counterexample candidate).

## FM-75 — Self-hosted webhook outage deadlocks upgrade or opens unsafe ignore window

**Provenance.** **Modelling** — issue #35 self-referential webhook outage
slice (`WebhookSelfReference.qnt`). The concrete anchor is the webhook
manifests’ `failurePolicy: Fail` plus the fact that upgrade-relevant
control-plane reconciliation depends on admission succeeding while the
same cluster is hosting the webhook pod.

**Trigger.** The webhook pod restarts or goes unavailable during an
upgrade of the same cluster. With fail-closed admission, progress stalls
waiting for a webhook that is itself affected by the upgrade. With a broad
temporary switch to `Ignore`, progress resumes but invalid mutations can
slip through during the outage window.

**Init / scenarios.** `safeFallbackRun` models the intended safe regime:
admission is still unavailable, but an explicit `safeFallbackActive` path
lets the upgrade continue without admitting an invalid mutation.
`failClosedDeadlockRun` models the pure fail-closed deadlock and violates
`UpgradeProgressDespiteWebhookGap`. `ignoreWindowInvalidMutationRun`
models the unsafe branch where `failurePolicy == Ignore` admits a pending
invalid mutation, violating `NoInvalidMutationDuringIgnoreWindow`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Core webhook manifests (`failurePolicy: Fail`) | `config/webhook/manifests.yaml` | n/a |
| Bootstrap kubeadm webhook manifests | `bootstrap/kubeadm/config/webhook/manifests.yaml` | n/a |
| KCP webhook manifests | `controlplane/kubeadm/config/webhook/manifests.yaml` | n/a |
| KCP upgrade / reconcile surface | `controlplane/kubeadm/internal/controllers/controller.go` | upgrade-relevant reconcile path |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the fail-closed deadlock via `failClosedDeadlockRun`, and Apalache reaches
the same `UpgradeProgressDespiteWebhookGap` violation from `init` within
depth 4 using the narrowed `stepApalache` relation
(`make verify-webhook-selfref-apalache`). The ignore-window unsafe branch
is documented as a second explicit counterexample.

**Classification.** **MODELLING** (counterexample candidate).

## FM-76 — Serving cert rotates before apiserver trust cache refreshes CABundle

**Provenance.** **Modelling** — issue #36 CABundle staleness slice
(`WebhookCABundleStaleness.qnt`). The concrete anchors are the webhook
cert-manager certificate resources, CABundle injection kustomizations,
and the webhook manifest consumption path.

**Trigger.** cert-manager rotates the webhook serving cert and the new CA
is injected into the webhook configuration, but the kube-apiserver still
holds the old CA in its internal cache for a short window. Admission then
fails with x509 trust errors even though the webhook configuration already
contains the new bundle.

**Init / scenarios.** `refreshRecoveryRun` models the intended recovery
path: serving cert rotates, CABundle is injected, one admission fails
while trust is stale, then `ApiserverRefreshCache` aligns the trust bundle
and admission succeeds again. `staleTrustOutageRun` models the minimal
counterexample where the serving cert rotates and admission is attempted
before cache refresh, violating `CurrentlyTrusted`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Core webhook cert-manager cert | `config/certmanager/certificate.yaml` | n/a |
| Bootstrap webhook cert-manager cert | `bootstrap/kubeadm/config/certmanager/certificate.yaml` | n/a |
| KCP webhook cert-manager cert | `controlplane/kubeadm/config/certmanager/certificate.yaml` | n/a |
| Core CA injection kustomization | `config/default/kustomization.yaml` | n/a |
| Bootstrap CA injection kustomization | `bootstrap/kubeadm/config/default/kustomization.yaml` | n/a |
| KCP CA injection kustomization | `controlplane/kubeadm/config/default/kustomization.yaml` | n/a |
| Webhook manifest consumption | `config/webhook/manifests.yaml` | n/a |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the stale-trust x509 window via `staleTrustOutageRun`, and Apalache
reaches the same `CurrentlyTrusted` violation from `init` within depth 4
(`make verify-webhook-cabundle-apalache`). The companion recovery run
demonstrates that an eventual cache refresh clears the outage.

**Classification.** **MODELLING** (counterexample candidate).

## FM-78 — Dry-run admission probe triggers real side effects despite NoneOnDryRun

**Provenance.** **Modelling** — issue #38 dry-run side-effects contract
slice (`DryRunSideEffects.qnt`). The concrete anchors are the webhook
manifests’ `sideEffects: None` declarations and the repo’s real
controller-side SSA dry-run probes.

**Trigger.** A controller performs a dry-run request (for example, an SSA
probe while preparing an in-place update diff), the webhook declares that
it has no side effects on dry-run, but the implementation still triggers
an external call.

**Init / scenarios.** `compliantDryRunProbeRun` models the intended safe
regime: the dry-run request is queued, the webhook executes, and no real
side effect is triggered. `violatingDryRunProbeRun` takes the explicit
bug branch `WebhookFiresExternalCall`, violating `DryRunHasNoSideEffects`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Core webhook manifests (`sideEffects: None`) | `config/webhook/manifests.yaml` | 27, 48, 69, ... |
| Bootstrap webhook manifests (`sideEffects: None`) | `bootstrap/kubeadm/config/webhook/manifests.yaml` | 26, 53, 74 |
| KCP webhook manifests (`sideEffects: None`) | `controlplane/kubeadm/config/webhook/manifests.yaml` | 27, 53, 74, 94 |
| Dry-run SSA option | `internal/util/ssa/patch.go` | 38-43, 119 |
| In-place update dry-run probes | `controlplane/kubeadm/internal/controllers/inplace_canupdatemachine.go` | 160, 169, 178 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the violating dry-run probe via `violatingDryRunProbeRun`, and Apalache
reaches the same `DryRunHasNoSideEffects` violation from the dedicated
`violatingProbeInit` within depth 4
(`make verify-dryrun-sideeffects-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-79 — Asymmetric partition creates a dual-leader window

**Provenance.** **Modelling** — issue #39 directed-network-partition
slice (`AsymmetricPartition.qnt`). The concrete symmetric grounding is
the `Partition(m)` fault in `Lifecycle.qnt`; this standalone model makes
the reachability loss directional instead of all-or-nothing.

**Trigger.** Heartbeats or acknowledgements are blocked only in one
direction. The follower side stops receiving the evidence it needs to
keep following, starts an election, and advances term, while the
original leader still has enough connectivity to keep accepting writes.

**Init / scenarios.** `dualLeaderWindowRun` blocks only the `B -> A`
direction, starts a follower-side election, and then takes
`MinorityLeaderStillAcceptsWrites`, violating `NoSimultaneousLeaders`.
`recoveredDirectionalPartitionRun` follows the same prefix but then
heals the block and applies `RecoverToSingleLeader`, satisfying the
recovered end-state `RecoveredToSingleLeader`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Symmetric partition grounding | `formal/specs/Lifecycle.qnt` | 2023-2042 |
| Leader election grounding | `formal/specs/Lifecycle.qnt` | 613-628 |
| Leader step-down grounding | `formal/specs/Lifecycle.qnt` | 858-875 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the dual-leader window via `dualLeaderWindowRun`, and Apalache reaches
the same `NoSimultaneousLeaders` violation from the dedicated
`dualLeaderInit` within depth 4
(`make verify-asymmetric-partition-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-80 — Snapshot restore races concurrent compaction and KCP membership reconcile

**Provenance.** **Modelling** — issue #40 restore/compaction race slice
(`SnapshotRestoreCompaction.qnt`). The concrete operator restore surface
is grounded in `Lifecycle.qnt`'s existing `RestoreClusterFromSnapshot`
action; compaction is grounded in the same spec's `EtcdCompactionStart`
and `EtcdCompactionDone` actions.

**Trigger.** The operator begins restoring an older etcd snapshot while
KCP still mutates the live member set, and compaction advances during the
same window. The member set can then be rolled back to the snapshot while
the log basis the restore expected has already been compacted away.

**Init / scenarios.** `cleanRestoreRun` captures the intended regime
where restore completes without overlap and
`MemberSetMatchesSnapshotPostRestore` holds. `compactionRaceRun` begins a
restore, lets KCP reconcile add a live member, then advances compaction
before completing restore; `NoLogInconsistency` fails in that path.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Restore grounding | `formal/specs/Lifecycle.qnt` | 2522-2581 |
| Compaction start grounding | `formal/specs/Lifecycle.qnt` | 3000-3077 |
| Compaction done grounding | `formal/specs/Lifecycle.qnt` | 3623-3660 |

**Verdict.** Deliberate counterexample candidate. `quint run` reproduces
the restore/compaction race via `compactionRaceRun`, and Apalache reaches
the same `NoLogInconsistency` violation from the dedicated `raceInit`
within depth 4 (`make verify-snapshot-restore-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-81 — Defrag overlaps a second maintenance fault and drops quorum

**Provenance.** **Modelling** — issue #41 standalone defrag-maintenance
slice (`DefragQuorumLoss.qnt`). The concrete quorum arithmetic is
grounded in the existing etcd-member health logic in `Lifecycle.qnt`,
with the single-defrag pause provenance anchored by FM-24.

**Trigger.** One etcd member is paused for defrag, which is safe on a
3-member cluster by itself. A second member then glitches during the same
window, leaving only one active voter and dropping the cluster below
quorum.

**Init / scenarios.** `serialDefragRun` captures the intended regime:
begin defrag on one member and end it without overlap, preserving
`NoQuorumLossUnderSingleMaintenanceFault`. `overlapLossRun` takes the
adversarial branch `BeginDefrag(1) -> MemberGlitchDuringDefrag(2)`,
violating the same property.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Quorum arithmetic grounding | `formal/specs/Lifecycle.qnt` | 525-606 |
| Maintenance glitch provenance | `formal/specs/Lifecycle.qnt` | 2913 |
| Existing defrag pause provenance | `formal/failure-modes.md` | FM-24 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the defrag-overlap quorum-loss path via `overlapLossRun`, and
Apalache reaches the same `NoQuorumLossUnderSingleMaintenanceFault`
violation from `overlapInit` within depth 4
(`make verify-defrag-quorum-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-82 — WAL corruption / disk-full fault silently removes an etcd member

**Provenance.** **Modelling** — issue #42 standalone WAL-member-state
slice (`EtcdWalFaults.qnt`). The detection/remediation vocabulary is
grounded in the existing `RequestRemediation` surface in `Lifecycle.qnt`.

**Trigger.** A member accumulates latent WAL corruption or a disk-full
condition, then crashes or becomes opaque without an externally observed
detection signal. The cluster can lose effective quorum participation
without KCP immediately requesting remediation.

**Init / scenarios.** `detectedFaultRun` captures the intended regime:
the member enters a bad WAL state, crashes, is observed through the
opaque-loss path, and KCP requests remediation, satisfying
`KcpDetectsAndRemediates`. `silentCorruptionRun` takes the adversarial
branch where corruption is followed by crash but no detection step,
violating `NoSilentMemberLoss`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Request remediation grounding | `formal/specs/Lifecycle.qnt` | 1845-1889 |
| Crash / glitch provenance | `formal/specs/Lifecycle.qnt` | 2913 |
| Disk-pressure / custom-condition provenance | `formal/specs/Lifecycle.qnt` | 3522-3764 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the silent-member-loss path via `silentCorruptionRun`, and
Apalache reaches the same `NoSilentMemberLoss` violation from
`silentInit` within depth 4 (`make verify-wal-faults-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-83 — Etcd membership reconcile batches add and remove together

**Provenance.** **Modelling** — issue #43 standalone membership-batch
slice (`EtcdMembershipBatch.qnt`). The learner-add side is grounded in
the existing `EtcdMembership.qnt` / `Lifecycle.qnt` add/promote actions,
while the remove side is grounded in the real workload-cluster
`RemoveMember` helper.

**Trigger.** A single reconcile batch both adds/promotes a new member and
removes an existing voter, rather than waiting for a clean post-join
quorum checkpoint. This is the same family of churn the larger
`Lifecycle.qnt` corpus already flags as unrealistic flip-flop behaviour.

**Init / scenarios.** `serialMembershipRun` shows the intended regime:
join/promote the new member, finish that batch, then remove the old
member in a later batch. `sameBatchChurnRun` keeps the batch open and
applies both sides together, violating `NoSameBatchAddRemove`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Learner add / promote grounding | `formal/specs/EtcdMembership.qnt` | 143-177 |
| Kubeadm join -> add learner grounding | `formal/specs/Lifecycle.qnt` | 1415-1465 |
| Remove member call | `controlplane/kubeadm/internal/workload_cluster_etcd.go` | 88-108 |
| Etcd client remove primitive | `controlplane/kubeadm/internal/etcd/etcd.go` | 229-245 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the same-batch churn path via `sameBatchChurnRun`, and
Apalache reaches the same `NoSameBatchAddRemove` violation from
`sameBatchInit` within depth 4 (`make verify-etcd-batch-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-84 — 5-node / 3-failure recovery promotes too many learners in one window

**Provenance.** **Modelling** — issue #44 standalone 5-node recovery
slice (`EtcdFiveNodeFailure.qnt`). This avoids the blocked replica
parameterisation work in issue #27 by fixing the carrier set to a 5-voter
cluster plus two learner candidates.

**Trigger.** A 5-node control plane loses three members. Instead of
sequentially promoting one learner and stabilising, the recovery window
requests or applies multiple learner promotions before the first recovery
checkpoint has completed.

**Init / scenarios.** `sequentialRecoveryRun` shows the intended regime:
lose three voters, request remediation, promote one learner, recover one
voter, and end the recovery window. `leaderFollowersLossRun` keeps the
same incident open and applies two learner promotions, violating
`NoDoublePromotionDuringRecovery`. `symmetricTripleLossRun` additionally
checks the bounded-remediation surface via `RemediationBoundedPerScenario`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Existing 5-node carrier grounding | `formal/specs/Lifecycle.qnt` | 466-512 |
| Existing 5-node alternative init grounding | `formal/specs/Lifecycle.qnt` | 5388-5429 |
| Request remediation grounding | `formal/specs/Lifecycle.qnt` | 1845-1889 |
| Learner promotion grounding | `formal/specs/EtcdMembership.qnt` | 168-186 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the leader+followers 3-failure path via
`leaderFollowersLossRun`, and Apalache reaches the same
`NoDoublePromotionDuringRecovery` violation from `leaderFollowersInit`
within depth 4 (`make verify-etcd-5node-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-85 — Slow CRI / PLEG hang triggers over-eager remediation

**Provenance.** **Modelling** — issue #45 standalone node-health /
remediation slice (`KubeletPlegHang.qnt`). The repo does not contain
PLEG-specific controller logic, so the abstraction is grounded to the
existing `NodeReady` derivation surfaces plus the remediation vocabulary
already used in the formal corpus.

**Trigger.** Container runtime latency rises, PLEG stops observing pod
state updates long enough to cross its threshold, kubelet derives
`NodeReady = NotReady`, MHC observes the transient state, and remediation
is requested before the CRI recovers.

**Init / scenarios.** `transientSlowdownRun` shows the intended regime:
slow CRI causes a short PLEG lag but the runtime recovers before any
remediation is requested. `overeagerRemediationRun` crosses the PLEG
threshold, fires MHC, requests remediation, and only then recovers the
CRI, violating `RemediationAfterStableNotReady`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| NodeReady derivation helper | `controllers/noderefutil/util.go` | 62-82 |
| Machine NodeReady condition synthesis | `internal/controllers/machine/machine_controller_status.go` | 323-360 |
| Request remediation grounding | `formal/specs/Lifecycle.qnt` | 1845-1889 |
| Alternative remediation grounding | `formal/specs/KCPReconcile.qnt` | 164-178 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the over-eager remediation path via
`overeagerRemediationRun`, and Apalache reaches the same
`RemediationAfterStableNotReady` violation from `slowCriInit`
within depth 4 (`make verify-pleg-hang-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-86 — Registry throttle cascades into bootstrap stall

**Provenance.** **Modelling** — issue #46 standalone bootstrap-timing
slice (`RegistryPullBackoff.qnt`). The user-visible symptom grounding is
the KCP condition surface that explicitly cites `ImagePullBackOff`, while
the success latch is grounded in the existing control-plane-initialised
status flow.

**Trigger.** Registry throttling delays pulling the kube-apiserver image
long enough that the bootstrap timeout fires before the transient backoff
window clears, even though the image would eventually become available.

**Init / scenarios.** `boundedThrottleRun` shows the intended regime:
throttle once, back off, clear the throttle, pull successfully, and mark
the control plane initialised before timeout. `timeoutBeforePullClearsRun`
keeps the throttle in place long enough that `BootstrapTimeout` fires
first, violating `NoFalseBootstrapFailure`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| KCP condition symptom surface (`ImagePullBackOff`) | `api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go` | 378 |
| Legacy condition symptom surface | `api/controlplane/kubeadm/v1beta1/condition_consts.go` | 106 |
| ControlPlaneInitialized latch | `controlplane/kubeadm/internal/controllers/status.go` | 173-188 |
| Existing bootstrap progression grounding | `formal/specs/ClusterE2ERefined.qnt` | 214-247 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the timeout-before-pull-clears path via
`timeoutBeforePullClearsRun`, and Apalache reaches the same
`NoFalseBootstrapFailure` violation from `timeoutInit`
within depth 4 (`make verify-registry-pull-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-87 — MemPressure evicts a mis-priority critical static pod

**Provenance.** **Modelling** — issue #47 standalone eviction-under-
memory-pressure slice (`StaticPodMemPressure.qnt`). The concrete
customization surface is the kubeadm static-pod patch target set, while
the concrete rendered outputs in `_artifacts/.../resources/...` show the
intended `priorityClassName: system-node-critical` on the generated
control-plane pods.

**Trigger.** Node memory pressure builds an eviction candidate set and the
kube-apiserver static pod is not priority-protected because its
`priorityClassName` drifted from the intended critical value. Kubelet can
then evict the static pod mid-reconcile, taking the apiserver down.

**Init / scenarios.** `correctPriorityRun` shows the intended regime:
the control-plane static pods keep critical priority and the workload pod
is chosen for eviction instead. `misPriorityEvictionRun` first demotes
the kube-apiserver pod to `normal`, then enters memory pressure and
evicts it, violating `CriticalStaticPodsImmuneFromEviction`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Kubeadm static-pod patch target surface | `bootstrap/kubeadm/types/upstreamv1beta3/types.go` | 456-457 |
| Static-pod health surfacing on machines | `controlplane/kubeadm/internal/workload_cluster_conditions.go` | 668-670, 758-966 |
| CAPI drain path explicitly skipping static pods (contrast) | `internal/controllers/machine/drain/filters.go` | 237 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the mis-priority eviction path via `misPriorityEvictionRun`,
and Apalache reaches the same
`CriticalStaticPodsImmuneFromEviction` violation from `misPriorityInit`
within depth 4 (`make verify-static-pod-eviction-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-88 — Static-pod hash collision or stale kubelet reload preserves the wrong intent

**Provenance.** **Modelling** — issue #48 standalone manifest-identity /
kubelet-reload slice (`StaticPodHashReloadRace.qnt`). The concrete
surfaces are the rendered static-pod manifests, the kubeadm/kubelet
ConfigMap update path, and the existing static-pod health surfacing in
KCP conditions.

**Trigger.** Two distinct intended static-pod identities render to the
same manifest hash, or kubeadm rotates the desired kubelet config while
the kubelet is still running the old generation. Reconcile then reasons
from stale kubelet state and the wrong static-pod identity survives.

**Init / scenarios.** `eventualReloadRun` shows the intended regime:
kubeadm rotates, kubelet reloads, and observed intent converges to the
desired manifest set. `hashCollisionRun` writes a second distinct intent
with the same manifest hash and then observes only one identity,
violating `NoHashCollisionAcrossDistinctIntents`. `staleReloadRun`
rotates kubelet config but never reloads, violating
`ReloadEventuallyConverges`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Rendered static-pod outputs with concrete identities | `_artifacts/.../resources/kube-system/Pod/*.yaml` | n/a |
| Kubelet config ConfigMap grounding | `bootstrap/kubeadm/types/upstreamv1beta3/types.go` | 219 |
| Workload-cluster config-map update path | `controlplane/kubeadm/internal/workload_cluster.go` | 171-211 |
| Static-pod health surfacing on machines | `controlplane/kubeadm/internal/workload_cluster_conditions.go` | 668-670, 758-966 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the manifest-hash collision path via `hashCollisionRun`, and
Apalache reaches the same
`NoHashCollisionAcrossDistinctIntents` violation from `collisionInit`
within depth 4 (`make verify-static-pod-hash-apalache`). The stale
reload path is separately logged via `ReloadEventuallyConverges` on
`staleReloadRun`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-89 — CSR approval lag strands kubelet until bootstrap timeout fires

**Provenance.** **Modelling** — issue #49 standalone CSR queue / approval-lag
slice (`BootstrapCsrLag.qnt`). The repo does not contain a dedicated CSR
approval controller implementation, so the abstraction is grounded to the
archived kubelet-authentication proposal's client CSR flow plus the
existing bootstrap-failure symptom surface in the Docker test provider.

**Trigger.** Kubelet submits a bootstrap CSR, the approval controller is
slow or backlogged, kubelet retries, and bootstrap times out before the
approval is processed even though approval would eventually have
succeeded.

**Init / scenarios.** `eventualApprovalRun` shows the intended regime:
the first CSR is submitted, time advances, and approval is processed
before bootstrap fails. `approvalTimeoutRun` reaches the timeout first,
violating `BootstrapTimeoutCoversCsrLatency`. `strandedKubeletRun`
demonstrates the second target by reaching a state where bootstrap has
failed without kubelet holding a client cert, violating
`NoStrandedKubelet`.

**LSP grounding.**

| Go / doc entry point | File | Line |
|---|---|---|
| Kubelet client CSR flow | `docs/proposals/archived/20210222-kubelet-authentication.md` | 412-422 |
| Approval / signer policy surface | same document | 219-255 |
| Bootstrap failure symptom surface | `test/infrastructure/docker/api/v1beta1/condition_consts.go` | 67-70 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the approval-timeout path via `approvalTimeoutRun`, and
Apalache reaches the same `BootstrapTimeoutCoversCsrLatency` violation
from `approvalTimeoutInit` within depth 4
(`make verify-bootstrap-csr-apalache`). The stranded-kubelet variant is
separately logged via `NoStrandedKubelet` on `strandedKubeletRun`.

**Classification.** **MODELLING** (counterexample candidate).

## FM-107 — Projected ServiceAccount token rotates mid-reconcile and the controller fails on 401

**Provenance.** **Modelling** — issue #73 standalone token-rotation
slice (`ServiceAccountTokenRotation.qnt`). The model is grounded in the
real `TokenRequest` issuance surfaces used in tests and the cached/remote
cluster client surfaces used by long-running controllers.

**Trigger.** A reconcile captures a client using token version 1, the
projected ServiceAccount token rotates to version 2 while the reconcile
continues, and the next API call returns 401 because the stale token is
still attached to the cached client. The controller fails instead of
refreshing and retrying.

**Init / scenarios.** `refreshAfter401Run` shows the intended regime:
token rotates, the call gets 401, and the controller refreshes before
retrying, satisfying `RetryOn401WithRefreshedToken`. `staleTokenFailureRun`
takes the adversarial branch where the 401 is observed but reconcile ends
in failure, violating `NoSilentReconcileFailure`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| TokenRequest helper | `test/framework/autoscaler_helpers.go` | 596-604 |
| TokenRequest helper | `test/e2e/kcp_remediations.go` | 709-717 |
| Cached client construction | `controllers/clustercache/cluster_accessor_client.go` | 210-268 |
| Long-running cached client usage | `controlplane/kubeadm/internal/controllers/remediation.go` | 656 |
| Long-running cached client usage | `controlplane/kubeadm/internal/cluster.go` | 136 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-token failure path via `staleTokenFailureRun`, and
Apalache reaches the same `NoSilentReconcileFailure` violation from
`expiredTokenInit` within depth 4 (`make verify-sa-token-rotation-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-112 — IAM policy revocation strands partially provisioned machines

**Provenance.** **Modelling** — issue #60 standalone IAM revocation /
partial cloud-call 403 slice (`CloudIamPermissionLoss.qnt`). The model is
grounded in the real `controllers/clustercache` unauthorized-health-probe
surface and the fact that long-running provisioning can already have
partially succeeded before credentials drift.

**Trigger.** A machine is mid-provisioning when the controller's IAM
policy is revoked. Some earlier calls may already have succeeded, but
subsequent cloud calls start returning 403. If the controller does not
surface the failure and abort cleanly, a zombie not-ready machine can be
left behind.

**Init / scenarios.** `abortAfterPersistent403Run` shows the intended
regime: provisioning starts, IAM policy is revoked, repeated 403s are
observed, and the controller aborts before leaving a zombie machine,
satisfying `InFlightProvisioningEventuallyAborts`. `zombieMachineRun`
takes the adversarial branch where partial provisioning succeeds, the IAM
policy is revoked, a 403 is observed, and the machine is left in the
zombie state, violating `NoZombieMachine`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Unauthorized-health-probe handling | `controllers/clustercache/cluster_accessor.go` | 345-371 |
| Unauthorized disconnect behaviour | `controllers/clustercache/cluster_cache.go` | 531-545 |
| Runtime client credentials surface | `internal/runtime/client/client_test.go` | 933 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the zombie-machine path via `zombieMachineRun`, and Apalache
reaches the same `NoZombieMachine` violation from `zombieMachineInit`
within depth 4 (`make verify-cloud-iam-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-120 — PVC-using bootstrap work starts before StorageClass / CSI installation

**Provenance.** **Modelling** — issue #55 standalone PVC/bootstrap
dependency slice (`PvcBootstrapPending.qnt`). The model is grounded in
the real ClusterResourceSet ordering surface and the fact that
`StorageClass` is a concrete resource kind already handled by the repo.

**Trigger.** A bootstrap-critical Pod (or equivalent dependency) creates
its PVC before the CSI driver and/or StorageClass are available on the
fresh workload cluster. The PVC remains pending, the bootstrap Pod never
starts, and higher-level readiness stays blocked.

**Init / scenarios.** `storageReadyFirstRun` shows the intended regime:
install StorageClass and CSI first, create the PVC, bind it, then start
the bootstrap Pod, satisfying `BootstrapDependencyOrdering`.
`missingStorageClassRun` creates the PVC first and only retries pending,
violating the same property because bootstrap remains blocked forever.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Resource ordering / apply surface | `internal/controllers/clusterresourceset/clusterresourceset_controller.go` | 292-447 |
| CRS strategy split | `internal/controllers/clusterresourceset/clusterresourceset_scope.go` | 81-87 |
| Concrete `StorageClass` resource kind | `util/resource/resource.go` | 35-39 |
| Downstream infra readiness mirror | `internal/controllers/machine/machine_controller_status.go` | 167-255 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the missing-StorageClass bootstrap hang via
`missingStorageClassRun`, and Apalache reaches the same
`BootstrapDependencyOrdering` violation from `missingStorageClassInit`
within depth 4 (`make verify-pvc-bootstrap-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-121 — Filesystem-full on a node causes static-pod crashloop and spurious remediation

**Provenance.** **Modelling** — issue #57 standalone disk-pressure /
static-pod crashloop slice (`StaticPodDiskFull.qnt`). The model is
grounded in the real `NodeDiskPressure` surfacing and the control-plane
static-pod health conditions that CAPI observes on Machines.

**Trigger.** Static pod logs fill the node filesystem, log rotation is
unhealthy, kubelet raises `DiskPressure`, and the control-plane static
pod crashloops or is evicted. If KCP/MHC interpret that as a node or
machine failure instead of a transient local disk issue, remediation is
requested unnecessarily.

**Init / scenarios.** `recoveredDiskRun` shows the intended regime:
logs consume disk, pressure appears, the static pod is disrupted, but the
disk is later recovered and remediation is never requested, satisfying
`KcpRecognisesDiskPressureAsTransient`. `crashloopRemediationRun` drives
the bad path: after `DiskPressure` and static-pod crashloop, remediation
is requested anyway, violating the same property.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| NodeDiskPressure surfacing | `controllers/noderefutil/util.go` | 50-82 |
| Node condition summarisation on Machine | `internal/controllers/machine/machine_controller_status.go` | 440-474 |
| Static-pod health surfacing | `controlplane/kubeadm/internal/workload_cluster_conditions.go` | 668-670, 758-966 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the disk-full crashloop/remediation path via
`crashloopRemediationRun`, and Apalache reaches the same
`KcpRecognisesDiskPressureAsTransient` violation from `crashloopInit`
within depth 4 (`make verify-static-pod-disk-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-117 — CSI volume detach hang blocks the node/machine finalizer chain

**Provenance.** **Modelling** — issue #56 standalone CSI detach /
finalizer-chain slice (`VolumeDetachFinalizer.qnt`). The model is
grounded in the real machine deletion path that waits for volume detach
and the operator/test escape hatch used to unblock stalled detaches.

**Trigger.** A Machine is deleting, node drain has already completed, but
one or more `VolumeAttachment` objects remain attached. Detach begins and
then becomes permanently stuck due to an external CSI/provider problem.
Node finalizer removal is blocked, which in turn blocks Machine finalizer
removal and the whole chain remains stuck.

**Init / scenarios.** `successfulDetachRun` shows the intended regime:
detach begins, both attachments complete, node finalizer clears, and then
machine finalizer clears, satisfying `OperatorEscapeHatch`. `stuckDetachRun`
drives the bad path: one detach enters the stuck set and no operator
force-detach occurs, so `OperatorEscapeHatch` is violated.

**LSP grounding.**

| Go / test entry point | File | Line |
|---|---|---|
| Wait-for-volume-detach delete phase | `internal/controllers/machine/machine_controller.go` | 934-1009 |
| Volume-detach status timestamps / timeouts | `api/core/v1beta2/machine_types.go` | 614, 735, 739 |
| E2E unblock / force-detach flow | `test/e2e/node_drain.go` | 97-99, 549-593 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stuck-detach path via `stuckDetachRun`, and Apalache
reaches the same `OperatorEscapeHatch` violation from `stuckDetachInit`
within depth 4 (`make verify-volume-detach-finalizer-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-115 — Subnet/IPAM exhaustion leaves scale-up pending without surfacing the cause

**Provenance.** **Modelling** — issue #58 standalone subnet/IPAM
exhaustion slice (`IpamExhaustion.qnt`). The model is grounded in the
real `IPAddressClaim` ready reasons and the fact that operators usually
observe the downstream condition through higher-level readiness/status,
not the raw IPAM object.

**Trigger.** A new machine needs an IP but the subnet/pool is already
full. Requests keep retrying, infrastructure never becomes ready, and no
higher-level exhaustion condition is surfaced, leaving the operator with
an apparently “just pending” scale-up.

**Init / scenarios.** `exhaustionSurfacedRun` shows the intended regime:
the first retry on a full subnet is followed by an explicit surfaced
condition, satisfying `IpExhaustionEventuallySurfaced`. `silentRetryRun`
keeps retrying on the full subnet without surfacing the exhaustion,
violating `NoSilentInfiniteRetry`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| IPAM exhausted ready reason | `api/ipam/v1beta2/ipaddressclaim_types.go` | 25-40 |
| Machine infra readiness mirror | `internal/controllers/machine/machine_controller_status.go` | 167-255 |
| Higher-level cluster status surface | `internal/controllers/cluster/cluster_controller_status.go` | 1-156 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the silent-retry path via `silentRetryRun`, and Apalache
reaches the same `NoSilentInfiniteRetry` violation from `silentRetryInit`
within depth 4 (`make verify-ipam-exhaustion-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-119 — Generic adversarial fault injection can keep a service permanently unavailable

**Provenance.** **Modelling** — issue #100 reusable adversary harness
slice (`Adversary.qnt` + `AdversaryHarness.qnt`). The reusable module is
grounded in the existing fault catalogue in `dst-methodology.md`, which
already standardises fault classes used across the corpus.

**Trigger.** A fault is injected and never cleared. The composed service
harness transitions to `unavailable` and remains there indefinitely,
providing a generic proof obligation that bounded-fault assumptions must
be explicit if a spec wants eventual recovery.

**Init / scenarios.** `recoveredFaultRun` shows the intended regime:
inject a crash fault, observe the impact, clear the fault, heal, and
recover, satisfying `RecoveredAfterFaultBudget`. `permanentOutageRun`
keeps the crash fault active and violates `NoPermanentUnavailability`.
The seeded fuzz harness repeatedly finds violating seeds for the same
counterexample.

**LSP grounding.**

| Go / doc entry point | File | Line |
|---|---|---|
| Fault catalogue | `formal/dst-methodology.md` | 52-178 |
| Recurrent-fault discussion | `formal/docs/explanation.md` | 212-278 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the uncleared-fault outage via `permanentOutageRun`,
Apalache reaches the same `NoPermanentUnavailability` violation from
`permanentOutageInit` within depth 4 (`make verify-adversary-apalache`),
and `hack/tools/quint-adversary-fuzzer.py` finds reproducible violating
seeds over the same invariant.

**Classification.** **MODELLING** (counterexample candidate).

## FM-116 — Endpoint swap leaves kubeconfigs pointing at an old control-plane endpoint

**Provenance.** **Modelling** — issue #61 standalone endpoint-swap /
stale-kubeconfig slice (`EndpointSwapKubeconfig.qnt`). The model is
grounded in the real control-plane endpoint publication surfaces and the
kubeconfig generation helper.

**Trigger.** The control-plane endpoint changes (LB target/EIP swap,
clusterctl move, or provider republish), but kubeconfigs continue to
reference the old endpoint because regeneration/convergence has not
happened yet.

**Init / scenarios.** `coordinatedSwapRun` shows the intended regime:
the endpoint swaps, kubeconfigs are regenerated, and
`AllKubeconfigsConvergeToCurrent` holds. `staleKubeconfigRun` takes the
bad path where the endpoint has already moved but kubeconfigs still point
to the old value, violating that invariant.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Control-plane endpoint population | `internal/controllers/cluster/cluster_controller_phases.go` | 217-356 |
| Docker provider endpoint republish | `test/infrastructure/docker/internal/controllers/backends/docker/dockercluster_backend.go` | 100-128 |
| In-memory provider endpoint republish | `test/infrastructure/docker/internal/controllers/backends/inmemory/inmemorycluster_backend.go` | 101-157 |
| Kubeconfig generation | `util/kubeconfig/kubeconfig.go` | 111 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-endpoint path via `staleKubeconfigRun`, and
Apalache reaches the same `AllKubeconfigsConvergeToCurrent` violation
from `staleEndpointInit` within depth 4 (`make verify-endpoint-swap-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-109 — Status subresource lags and another controller acts on stale phase

**Provenance.** **Modelling** — issue #70 standalone spec/status lag
slice (`StatusSubresourceLag.qnt`). The model is grounded in the real
controller status paths where phase/status are written through separate
status-subresource updates after spec/template changes.

**Trigger.** A reconciler updates `spec.template`, incrementing desired
generation. Another controller later reads `status.phase=Running` before
the status subresource catches up and makes a contradictory level-triggered
decision based on the stale phase.

**Init / scenarios.** `convergedStatusRun` shows the intended regime:
spec changes, status catches up via the status subresource, and the drift
is cleared. `staleStatusDecisionRun` drives the bad path: `specGen`
advances to `2`, `statusGen` remains `1`, and another controller takes a
decision while the stale phase still says `Running`, violating
`LevelTriggeredControllersTolerateLag`.

**LSP grounding.**

| Go entry point | File | Line |
|---|---|---|
| Cluster status phase write | `internal/controllers/cluster/cluster_controller_status.go` | 45-112 |
| Machine status phase write | `internal/controllers/machine/machine_controller_status.go` | 900-932 |
| MachineDeployment status phase write | `internal/controllers/machinedeployment/machinedeployment_status.go` | 90-110 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the stale-status decision path via `staleStatusDecisionRun`,
and Apalache reaches the same `LevelTriggeredControllersTolerateLag`
violation from `staleStatusInit` within depth 4
(`make verify-status-lag-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-108 — Condition message truncation silently drops the root-cause-bearing tail

**Provenance.** **Modelling** — issue #72 standalone truncation slice
(`ConditionMessageTruncation.qnt`). The model is grounded in the real
long condition-message builders and the concrete `MaxLength=1024`
validation surfaces on several older message-bearing fields.

**Trigger.** A long wrapped error chain exceeds the 1024-byte storage
limit, the implementation keeps only the prefix of the message, and the
root-cause-bearing tail is dropped without any companion event carrying
the full text.

**Init / scenarios.** `tailPreservedRun` shows the intended regime:
either truncation keeps the tail or another surface can still preserve
the root cause, so `RootCauseSurvivesTruncation` holds. `tailDroppedRun`
takes the bad path where the stored message is shortened to 1024 bytes,
the root cause no longer survives in the stored condition, and no
companion event exists, violating `RootCauseSurvivesTruncation`.

**LSP grounding.**

| Go / API entry point | File | Line |
|---|---|---|
| Long drain condition message tests | `internal/controllers/machine/drain/drain_test.go` | 1786-1815, 1963-1995 |
| Topology upgrade condition message builder | `internal/controllers/topology/cluster/conditions.go` | 195-276 |
| Example 1024-byte schema cap | `api/bootstrap/kubeadm/v1beta1/kubeadm_types.go` | 411, 418, 782 |
| Example 1024-byte schema cap | `api/core/v1beta2/clusterclass_types.go` | 394, 410, 706, 879, 1247, 1303 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the tail-loss branch via `tailDroppedRun`, and Apalache
reaches the same `RootCauseSurvivesTruncation` violation from
`tailDroppedInit` within depth 4 (`make verify-msg-truncation-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-90 — MTU drift silently fragments packets and stalls snapshot transfer

**Provenance.** **Modelling** — issue #50 standalone MTU / fragmentation
slice (`MtuFragmentation.qnt`). The repo does not model PMTU discovery
directly, so the abstraction is grounded to the concrete Docker dev MTU
setting (`vethMTU: 1450`) plus the operator-level etcd snapshot-transfer
workflow.

**Trigger.** An etcd snapshot transfer emits packets larger than the
effective pod-network MTU with DF set, but the sender never receives
usable ICMP fragmentation-needed feedback. The transfer keeps retrying
without ever shrinking to a deliverable payload size and times out.

**Init / scenarios.** `convergedPmtuRun` shows the intended regime:
large packet sent, PMTU mismatch observed, path MTU learned, packet size
reduced, transfer succeeds. `silentFragDropRun` takes the bad path:
large packet sent, DF+MTU mismatch occurs, ICMP feedback is lost, and
bootstrap times out before delivery, violating
`EtcdSnapshotEventuallySucceeds`.

**LSP grounding.**

| Go / doc entry point | File | Line |
|---|---|---|
| Effective pod-network MTU | `test/e2e/config/docker-dev.yaml` | 7 |
| Snapshot restore workflow grounding | `etcdadm-controller/docs/topics/etcd/howto/backup-restore.md` | 1-120 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the silent-fragmentation timeout path via
`silentFragDropRun`, and Apalache reaches the same
`EtcdSnapshotEventuallySucceeds` violation from `silentFragInit`
within depth 4 (`make verify-mtu-frag-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-91 — Pod starts before CNI creates its veth, causing probe-loop restarts

**Provenance.** **Modelling** — issue #51 standalone CNI/veth race slice
(`CniVethRace.qnt`). The repo does not contain the kubelet/CNI handshake
implementation itself, so the abstraction is grounded to Cluster API's
explicit stance that CNI is an external post-bootstrap dependency plus
the existing NodeReady / machine-status surfaces where the downstream
symptom becomes visible.

**Trigger.** Kubelet starts a workload container before the CNI plugin
has created its veth. Startup/TCP probes fail, the container restarts,
and the loop continues until CNI catches up.

**Init / scenarios.** `cniReadyBeforeProbeRun` shows the intended safe
regime: CNI is applied, the veth appears, then the container starts and
probes succeed. `probeLoopBeforeVethRun` takes the bad path: kubelet
starts the container first, probes fail twice before veth creation, and
`NoContainerStartBeforeCni` is violated.

**LSP grounding.**

| Go / doc entry point | File | Line |
|---|---|---|
| CNI explicitly deferred until after control plane instantiation | `docs/book/src/developer/providers/contracts/control-plane.md` | 17 |
| NodeReady derivation helper | `controllers/noderefutil/util.go` | 62-82 |
| Machine node-status synthesis | `internal/controllers/machine/machine_controller_status.go` | 323-360 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the probe-loop race via `probeLoopBeforeVethRun`, and
Apalache reaches the same `NoContainerStartBeforeCni` violation from
`probeLoopInit` within depth 4 (`make verify-cni-veth-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-92 — Load balancer deregisters target before drain, blackholing existing requests

**Provenance.** **Modelling** — issue #52 standalone LB drain / existing
connection slice (`LoadBalancerDrain.qnt`). The provider side is grounded
 to the CAPD load balancer configuration-update path, while the control-
 plane side is grounded to the KCP pre-terminate sequencing surface.

**Trigger.** The load balancer deregisters an apiserver target, but
existing client TCP connections are not actively reset. If KCP kills the
apiserver pod before drain completes, those clients hang on a dead target
until timeout or eventual reset.

**Init / scenarios.** `drainBeforeKillRun` shows the intended regime:
KCP waits for drain completion (`lbDrainProgress == FULL_DRAIN`) before
killing the apiserver, so `clientHung` never becomes true.
`killBeforeDrainRun` takes the bad path: target deregistered, apiserver
killed, then a client hangs, violating `KcpUpgradeAccountsForLbDrain`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Provider-side LB configuration update | `test/infrastructure/docker/internal/docker/loadbalancer.go` | 136-203 |
| CAPD control-plane node add/remove -> LB target update | `test/infrastructure/docker/internal/controllers/backends/docker/dockermachine_backend.go` | 414-464 |
| KCP pre-terminate sequencing | `controlplane/kubeadm/internal/controllers/controller.go` | 1362-1409 |
| APIServer health surfacing | `controlplane/kubeadm/internal/workload_cluster_conditions.go` | 668-670 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the blackholed-request path via `killBeforeDrainRun`, and
Apalache reaches the same `KcpUpgradeAccountsForLbDrain` violation from
`killBeforeDrainInit` within depth 4 (`make verify-lb-drain-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-93 — NetworkPolicy cuts controller traffic mid-flight and long-lived watch stalls silently

**Provenance.** **Modelling** — issue #53 standalone netpol / connection
mode slice (`NetworkPolicyMidFlight.qnt`). The repo does not contain a
concrete NetworkPolicy controller, so the abstraction is grounded to the
existing split between long-lived cached/watch clients and uncached
request/response clients in the cluster-cache layer.

**Trigger.** An operator applies a NetworkPolicy that blocks controller
egress to the apiserver after a controller already holds a long-lived
watch connection. New connections fail fast, but the existing watch may
survive silently and stall controller progress.

**Init / scenarios.** `detectedPolicyCutRun` shows the intended regime:
policy is applied, the existing connection is terminated or a reconnect
fails fast, and the controller detects the cut. `silentWatchSurvivesRun`
takes the bad path: policy is applied, the existing long-lived watch is
not terminated, and the controller stalls silently, violating
`NoSilentControllerStall`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Long-lived cached / uncached client split | `controllers/clustercache/cluster_accessor_client.go` | 75-109, 207-293 |
| Controller reconnection surface (`ErrClusterNotConnected`) | `controllers/clustercache/cluster_accessor.go` | 402 |
| Status/failure surfacing for remote conditions | `formal/specs/ControllerRuntime.qnt` and `formal/specs/CniVethRace.qnt` companion slices | n/a |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the silent-stall path via `silentWatchSurvivesRun`, and
Apalache reaches the same `NoSilentControllerStall` violation from
`silentWatchInit` within depth 4 (`make verify-netpol-stall-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-94 — Conntrack exhaustion under churn drops new kubelet→apiserver connections

**Provenance.** **Modelling** — issue #54 standalone conntrack
exhaustion slice (`ConntrackExhaustion.qnt`). The concrete configuration
surface is the CAPD test provisioning that sets
`net.netfilter.nf_conntrack_max` on nodes.

**Trigger.** Pod or endpoint churn drives conntrack occupancy to the
configured maximum, new connections are dropped, and kubelet/apiserver
requests start timing out before occupancy can converge back below the
sustainable threshold.

**Init / scenarios.** `boundedChurnRun` shows the intended regime:
churn rate stays low enough that expiry keeps occupancy below the table
limit and `EventualConvergence` holds. `tableFullRun` raises the churn
rate, fills the table, drops a new connection, and then times out the
kubelet request, violating `EventualConvergence`.

**LSP grounding.**

| Go / artifact entry point | File | Line |
|---|---|---|
| Cloud-init conntrack max setting | `test/infrastructure/docker/internal/provisioning/cloudinit/writefiles.go` | 45-46 |
| Ignition conntrack max setting | `test/infrastructure/docker/internal/provisioning/ignition/kindadapter.go` | 40-41 |
| CAPD test kind config conntrack setting | `tilt.d/capd-test/kind.yaml` | 16-17 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the saturation path via `tableFullRun`, and Apalache reaches
the same `EventualConvergence` violation from `tableFullInit`
within depth 4 (`make verify-conntrack-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

## FM-80 — Snapshot restore races compaction and concurrent membership reconcile

**Provenance.** **Modelling** — issue #40 restore/compaction-race slice
(`SnapshotRestoreCompaction.qnt`). The operator restore grounding comes
from the existing `RestoreClusterFromSnapshot` step in `Lifecycle.qnt`.

**Trigger.** The operator begins a snapshot restore, KCP continues to
mutate the live etcd member set, and compaction advances during the same
window. The member set can later be restored back to the snapshot while
the effective log basis remains inconsistent.

**Init / scenarios.** `cleanRestoreRun` shows the intended regime where
restore starts and completes without overlap, satisfying
`MemberSetMatchesSnapshotPostRestore`. `compactionRaceRun` takes the
adversarial branch `KcpReconcileDuringRestore -> CompactDuringRestore -> CompleteRestoreWithRace`,
violating `NoLogInconsistency`.

**LSP grounding.**

| Go / spec entry point | File | Line |
|---|---|---|
| Snapshot restore grounding | `formal/specs/Lifecycle.qnt` | 2522-2581 |
| Etcd compaction grounding | `formal/specs/Lifecycle.qnt` | 3000-3077 |
| Etcd compaction completion | `formal/specs/Lifecycle.qnt` | 3623-3660 |

**Verdict.** Deliberate counterexample candidate. `quint run`
reproduces the restore/compaction race via `compactionRaceRun`, and
Apalache reaches the same `NoLogInconsistency` violation from
`raceInit` within depth 4 (`make verify-snapshot-restore-apalache`).

**Classification.** **MODELLING** (counterexample candidate).

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
| FM-69 | Bounded fault storm still permits legitimate reconcile completion | MODELLING | Token refill and eventual worker service | Verified in `specs/ControllerRuntime.qnt` (`FM69_BoundedFaultProgress`) on `boundedFaultStormRun` |
| FM-70 | Fault-storm overload starves a legitimate reconcile | MODELLING | n/a — explicit counterexample threshold | Logged as deliberate counterexample candidate on `FM70_NoLegitReadyBacklog`; Apalache reaches the violation within depth 4 |
| FM-71 | Cross-controller cyclic enqueue livelock | MODELLING | Cache stabilisation on one side breaks the cycle | Logged as deliberate counterexample candidate on `NoCyclicLivelock` in `specs/CrossControllerCycle.qnt`; Apalache reaches the violation within depth 4 |
| FM-72 | Reflector relist storm duplicates a Machine create | MODELLING | Duplicate delivery is tolerated only if reconcile is idempotent | Logged as deliberate counterexample candidate on `NoDuplicateMachineLeak` in `specs/ReflectorRelistStorm.qnt`; Apalache reaches the violation within depth 4 |
| FM-73 | Deleted object stays enqueued into a nil-read / shutdown-drain race | MODELLING | NotFound handling and in-flight drain avoid panic/leak | Logged as deliberate counterexample candidate on `NoNilReadAfterDelete` in `specs/StaleEnqueueShutdown.qnt`; Apalache reaches the violation within depth 4 |
| FM-74 | Validator reads stale field before mutator default/replay converges | MODELLING | Reinvocation lets validator re-read the final value | Logged as deliberate counterexample candidate on `ObservedValueIsFinal` in `specs/WebhookOrdering.qnt`; Apalache reaches the violation within depth 4 |
| FM-75 | Self-hosted webhook outage deadlocks upgrade or opens unsafe ignore window | MODELLING | Explicit safe fallback avoids broad ignore policy | Logged as deliberate counterexample candidate on `UpgradeProgressDespiteWebhookGap` in `specs/WebhookSelfReference.qnt`; Apalache reaches the fail-closed deadlock within depth 4 |
| FM-76 | Serving cert rotates before apiserver trust cache refreshes CABundle | MODELLING | Cache refresh closes the short x509 outage window | Logged as deliberate counterexample candidate on `CurrentlyTrusted` in `specs/WebhookCABundleStaleness.qnt`; Apalache reaches the stale-trust violation within depth 4 |
| FM-78 | Dry-run admission probe triggers real side effects despite NoneOnDryRun | MODELLING | Compliant webhooks observe dry-run and suppress external calls | Logged as deliberate counterexample candidate on `DryRunHasNoSideEffects` in `specs/DryRunSideEffects.qnt`; Apalache reaches the violating probe within depth 4 |
| FM-79 | Asymmetric partition creates a dual-leader window | MODELLING | Healing the directed block collapses back to one leader | Logged as deliberate counterexample candidate on `NoSimultaneousLeaders` in `specs/AsymmetricPartition.qnt`; Apalache reaches the dual-leader window within depth 4 |
| FM-80 | Snapshot restore races concurrent compaction and KCP membership reconcile | MODELLING | Restore completes cleanly when compaction and reconcile do not overlap | Logged as deliberate counterexample candidate on `NoLogInconsistency` in `specs/SnapshotRestoreCompaction.qnt`; Apalache reaches the inconsistency within depth 4 |
| FM-81 | Defrag overlaps a second maintenance fault and drops quorum | MODELLING | Serial single-member defrag preserves quorum | Logged as deliberate counterexample candidate on `NoQuorumLossUnderSingleMaintenanceFault` in `specs/DefragQuorumLoss.qnt`; Apalache reaches the quorum-loss state within depth 4 |
| FM-82 | WAL corruption / disk-full fault silently removes an etcd member | MODELLING | Explicit detection + remediation closes the opaque-loss window | Logged as deliberate counterexample candidate on `NoSilentMemberLoss` in `specs/EtcdWalFaults.qnt`; Apalache reaches the silent-loss state within depth 4 |
| FM-83 | Etcd membership reconcile batches add and remove together | MODELLING | Join/promote completes before remove in the serial regime | Logged as deliberate counterexample candidate on `NoSameBatchAddRemove` in `specs/EtcdMembershipBatch.qnt`; Apalache reaches the churn state within depth 4 |
| FM-84 | 5-node / 3-failure recovery promotes too many learners in one window | MODELLING | Sequential recovery keeps promotion to one learner per recovery window | Logged as deliberate counterexample candidate on `NoDoublePromotionDuringRecovery` in `specs/EtcdFiveNodeFailure.qnt`; Apalache reaches the counterexample within depth 4 |
| FM-85 | Slow CRI / PLEG hang triggers over-eager remediation | MODELLING | Transient slowdown recovers before remediation in the safe regime | Logged as deliberate counterexample candidate on `RemediationAfterStableNotReady` in `specs/KubeletPlegHang.qnt`; Apalache reaches the counterexample within depth 4 |
| FM-86 | Registry throttle cascades into bootstrap stall | MODELLING | Timeout budget exceeds transient pull backoff in the safe regime | Logged as deliberate counterexample candidate on `NoFalseBootstrapFailure` in `specs/RegistryPullBackoff.qnt`; Apalache reaches the timeout-before-pull-clears state within depth 4 |
| FM-87 | MemPressure evicts a mis-priority critical static pod | MODELLING | Correct kubeadm output keeps static pods priority-protected | Logged as deliberate counterexample candidate on `CriticalStaticPodsImmuneFromEviction` in `specs/StaticPodMemPressure.qnt`; Apalache reaches the mis-priority eviction state within depth 4 |
| FM-88 | Static-pod hash collision or stale kubelet reload preserves the wrong intent | MODELLING | Distinct intents hash differently and kubelet reload catches up in the safe regime | Logged as deliberate counterexample candidate on `NoHashCollisionAcrossDistinctIntents` / `ReloadEventuallyConverges` in `specs/StaticPodHashReloadRace.qnt`; Apalache reaches the collision state within depth 4 |
| FM-89 | CSR approval lag strands kubelet until bootstrap timeout fires | MODELLING | Approval clears before timeout in the safe regime | Logged as deliberate counterexample candidate on `BootstrapTimeoutCoversCsrLatency` / `NoStrandedKubelet` in `specs/BootstrapCsrLag.qnt`; Apalache reaches the timeout state within depth 4 |
| FM-108 | Condition message truncation silently drops the root-cause-bearing tail | MODELLING | Tail-preserving truncation or a companion event keeps diagnostics in the safe regime | Logged as deliberate counterexample candidate on `RootCauseSurvivesTruncation` in `specs/ConditionMessageTruncation.qnt`; Apalache reaches the tail-loss state within depth 4 |
| FM-107 | Projected ServiceAccount token rotates mid-reconcile and the controller fails on 401 | MODELLING | Controller refreshes token and retries after 401 in the safe regime | Logged as deliberate counterexample candidate on `NoSilentReconcileFailure` in `specs/ServiceAccountTokenRotation.qnt`; Apalache reaches the stale-token auth failure within depth 4 |
| FM-112 | IAM policy revocation strands partially provisioned machines | MODELLING | Persistent 403s force abort before a zombie machine remains in the safe regime | Logged as deliberate counterexample candidate on `NoZombieMachine` in `specs/CloudIamPermissionLoss.qnt`; Apalache reaches the zombie-machine state within depth 4 |
| FM-117 | CSI volume detach hang blocks the node/machine finalizer chain | MODELLING | Operator force-detach or detach completion clears the chain in the safe regime | Logged as deliberate counterexample candidate on `OperatorEscapeHatch` in `specs/VolumeDetachFinalizer.qnt`; Apalache reaches the stuck-detach state within depth 4 |
| FM-123 | Empty-name etcd member remains orphaned after machine deletion | MODELLING | Member reaches `Joined` or is removed before the machine and infra disappear in the safe regime | Logged as deliberate counterexample candidate on `NoOrphanJoiningMemberAfterMachineGone` / `JoiningEventuallyJoinedOrRemoved` in `specs/EtcdJoiningNameDelay.qnt`; Apalache reaches the orphan state within depth 4 |
| FM-120 | PVC-using bootstrap work starts before StorageClass / CSI installation | MODELLING | Storage primitives are installed before the PVC-using pod starts in the safe regime | Logged as deliberate counterexample candidate on `BootstrapDependencyOrdering` in `specs/PvcBootstrapPending.qnt`; Apalache reaches the pending-bootstrap state within depth 4 |
| FM-121 | Filesystem-full on a node causes static-pod crashloop and spurious remediation | MODELLING | Disk pressure clears and the static pod recovers without remediation in the safe regime | Logged as deliberate counterexample candidate on `KcpRecognisesDiskPressureAsTransient` in `specs/StaticPodDiskFull.qnt`; Apalache reaches the crashloop/remediation state within depth 4 |
| FM-116 | Endpoint swap leaves kubeconfigs pointing at an old control-plane endpoint | MODELLING | Kubeconfigs are regenerated and converge to the new endpoint in the safe regime | Logged as deliberate counterexample candidate on `AllKubeconfigsConvergeToCurrent` in `specs/EndpointSwapKubeconfig.qnt`; Apalache reaches the stale-endpoint state within depth 4 |
| FM-115 | Subnet/IPAM exhaustion leaves scale-up pending without surfacing the cause | MODELLING | Exhaustion is surfaced as a higher-level condition in the safe regime | Logged as deliberate counterexample candidate on `NoSilentInfiniteRetry` in `specs/IpamExhaustion.qnt`; Apalache reaches the silent-retry state within depth 4 |
| FM-109 | Status subresource lags and another controller acts on stale phase | MODELLING | Status catches up and level-triggered readers tolerate lag in the safe regime | Logged as deliberate counterexample candidate on `LevelTriggeredControllersTolerateLag` in `specs/StatusSubresourceLag.qnt`; Apalache reaches the stale-status decision within depth 4 |
| FM-90 | MTU drift silently fragments packets and stalls snapshot transfer | MODELLING | PMTU discovery converges and transfer succeeds in the safe regime | Logged as deliberate counterexample candidate on `EtcdSnapshotEventuallySucceeds` in `specs/MtuFragmentation.qnt`; Apalache reaches the timeout state within depth 4 |
| FM-91 | Pod starts before CNI creates its veth, causing probe-loop restarts | MODELLING | CNI catches up before probes fail in the safe regime | Logged as deliberate counterexample candidate on `NoContainerStartBeforeCni` in `specs/CniVethRace.qnt`; Apalache reaches the probe-loop state within depth 4 |
| FM-92 | Load balancer deregisters target before drain, blackholing existing requests | MODELLING | KCP waits for drain completion before apiserver termination in the safe regime | Logged as deliberate counterexample candidate on `KcpUpgradeAccountsForLbDrain` in `specs/LoadBalancerDrain.qnt`; Apalache reaches the blackholed-request state within depth 4 |
| FM-93 | NetworkPolicy cuts controller traffic mid-flight and long-lived watch stalls silently | MODELLING | Controller detects the cut or fail-fast reconnects in the safe regime | Logged as deliberate counterexample candidate on `NoSilentControllerStall` in `specs/NetworkPolicyMidFlight.qnt`; Apalache reaches the silent-stall state within depth 4 |
| FM-95 | ClusterTopology reads a torn ClusterClass view mid-update | MODELLING | Reconcile pins a consistent ClusterClass version in the safe regime | Logged as deliberate counterexample candidate on `ConsistentCCViewPerReconcile` in `specs/ClusterClassTopologyRace.qnt`; Apalache reaches the torn-read state within depth 4 |
| FM-96 | ClusterResourceSet ApplyOnce runs before kubelets join | MODELLING | Apply happens after kubelets join or Reconcile retries until readiness in the safe regime | Logged as deliberate counterexample candidate on `ApplyOnceEventuallyTakesEffect` in `specs/ClusterResourceSetTiming.qnt`; Apalache reaches the timing race within depth 4 |
| FM-99 | Two operators' concurrent `Cluster.spec` edits lose intent or violate surge assumptions | MODELLING | Both edits converge to the final spec and surge stays within bound in the safe regime | Logged as deliberate counterexample candidate on `NoLostEdit` / `NoSurgeBoundViolation` in `specs/ConcurrentClusterSpecEdits.qnt`; Apalache reaches the lost-edit state within depth 4 |
| FM-110 | Cluster delete during an in-flight edit allows a stale write to land | MODELLING | Delete wins cleanly and later writes observe not-found in the safe regime | Logged as deliberate counterexample candidate on `NoWriteAfterDeleteObserved` in `specs/ClusterEditDeleteRace.qnt`; Apalache reaches the stale-write state within depth 4 |
| FM-111 | Backup/apply partial rollback silently drops fields and controllers re-default them | MODELLING | A single re-default restores the intended stable default in the safe regime | Logged as deliberate counterexample candidate on `RedefaultConverges` in `specs/PartialRollbackDrop.qnt`; Apalache reaches the redefine-loop state within depth 4 |
| FM-114 | SSA field-manager ownership transfer is silently reverted by a stale manager | MODELLING | Conflict is surfaced and force cleanly transfers ownership in the safe regime | Logged as deliberate counterexample candidate on `NoSilentRevertAfterConflict` in `specs/SsaFieldManagerConflict.qnt`; Apalache reaches the stale-revert state within depth 4 |
| FM-122 | Third-party ClusterRole drift leaves CAPI controllers failing 403 | MODELLING | CAPI reasserts or force-takes ownership of the role in the safe regime | Logged as deliberate counterexample candidate on `NoSilentPermissionLossAfterDrift` in `specs/ClusterRoleDrift.qnt`; Apalache reaches the 403-after-drift state within depth 4 |
| FM-100 | Autoscaler scale-up and KCP rollout surge overproduce replicas | MODELLING | Autoscaler intent is incorporated before rollout surge in the safe regime | Logged as deliberate counterexample candidate on `SurgeBoundUnderConcurrentScale` in `specs/AutoscalerKcpSurgeRace.qnt`; Apalache reaches the over-replica state within depth 4 |
| FM-105 | Mid-rollout etcd tag bump traps the control-plane upgrade | MODELLING | etcd upgrade waits until the control-plane rollout gate has cleared in the safe regime | Logged as deliberate counterexample candidate on `NoMidRolloutDependencyTrap` in `specs/EtcdKubernetesVersionSkew.qnt`; Apalache reaches the dependency-trap state within depth 4 |
| FM-104 | Rollback during partial cycling temporarily exceeds surge bound | MODELLING | Rollback waits for the drain point in the safe regime | Logged as deliberate counterexample candidate on `NoTransientSurgeBeyondBound` in `specs/RollbackSurgeRace.qnt`; Apalache reaches the mid-cycle rollback surge state within depth 4 |
| FM-101 | Controller-manager replay re-applies an effect after leader failover | MODELLING | New leader reconstructs completion from durable state in the safe regime | Logged as deliberate counterexample candidate on `NoDoubleEffect` in `specs/ControllerManagerReplay.qnt`; Apalache reaches the replay state within depth 4 |
| FM-103 | Management-cluster split-brain yields two active leader controllers | MODELLING | Lease converges to a single writer before duplicate effects in the safe regime | Logged as deliberate counterexample candidate on `NoDuplicateEffectAcrossLeaders` in `specs/ControllerLeaderSplitBrain.qnt`; Apalache reaches the duplicate-effect state within depth 4 |
| FM-98 | Machine readiness gets stuck because bootstrap and infra ready edges are observed separately | MODELLING | Reconcile observes both child-ready edges and eventually marks Machine ready in the safe regime | Logged as deliberate counterexample candidate on `NoStuckUnreadyDespiteBothChildrenReady` in `specs/BootstrapInfraReadyRace.qnt`; Apalache reaches the stuck-unready state within depth 4 |
| FM-102 | MachinePool spec replicas and provider actual scale oscillate | MODELLING | Scale ownership is arbitrated and converges in the safe regime | Logged as deliberate counterexample candidate on `NoOscillation` in `specs/MachinePoolScaleConflict.qnt`; Apalache reaches the oscillation state within depth 4 |
| FM-97 | KCP and MHC concurrently delete the same Machine | MODELLING | One controller owns old-machine deletion and replacements are not immediately reselected in the safe regime | Logged as deliberate counterexample candidate on `NoDoubleDelete` / `NoReplacementCannibalisation` in `specs/KcpMhcDeleteRace.qnt`; Apalache reaches the double-delete state within depth 4 |
| FM-113 | AZ-wide failure leaves KCP stuck targeting a failed or exhausted AZ | MODELLING | KCP retargets to a surviving AZ with capacity in the safe regime | Logged as deliberate counterexample candidate on `NoIndefiniteScaleAttempt` in `specs/AzFailoverCapacity.qnt`; Apalache reaches the failover-stall state within depth 4 |
| FM-48 | KCP creates CP Machines before InfraCluster ready | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` and re-recorded in `specs/ClusterE2ERefined.qnt` (`FM48_NoCpBeforeInfraReady`) + Lean 4 deductive (`Ordering.lean::fm48_no_cp_before_infra_ready`) |
| FM-49 | MD creates workers before ControlPlaneInitialized | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` and re-recorded in `specs/ClusterE2ERefined.qnt` (`FM49_NoWorkersBeforeCpInit`) + Lean 4 deductive (`Ordering.lean::fm49_no_workers_before_cp_init`) |
| FM-50 | ControlPlaneEndpoint regresses mid-flight | MODELLING | n/a — invariant of upstream contract | Verified in `specs/ClusterE2E.qnt` and re-recorded in `specs/ClusterE2ERefined.qnt` (`FM50_EndpointMonotonic`) + Lean 4 deductive (`Ordering.lean::fm50_endpoint_monotonic`) |
| FM-51 | Cross-spec preflight-gate transient violation | MODELLING | Level-triggered re-evaluation by MS controller | Surfaced + verified in `specs/WorkerLifecycle.qnt`; weakened `FM33_PreflightGate` accordingly |
| FM-52 | MD rollout / MHC conflicting delete pressure | MODELLING | Concurrent rollout-owned and MHC-owned delete intent | Verified in `specs/MachineDeploymentRollout.qnt` (`MhcCannotDeleteScaleDownVictim`) + refinement |
| FM-53 | Rollout availability snapshot invariant too strong | MODELLING | Replica increase while remediation drain is already in flight | Logged as deliberate counterexample candidate on `AvailabilityBound` |
| FM-54 | Old-MS starvation snapshot invariant too strong | MODELLING | Template abort after earlier scale-down admission | Logged as deliberate counterexample candidate on `NoStarveOldMS` |
| FM-55 | ClusterClass patch order non-confluence on overlapping fields | MODELLING | Two patches write the same JSON pointer and order flips final merge | Logged as deliberate counterexample candidate on `mergeDeterministicAllOrders` |
| FM-56 | Immutable-field pre-validation snapshot too strong | MODELLING | Rejected immutable flip appears in merged candidate but never applies | Logged as deliberate counterexample candidate on `immutableMergedCandidate` |
| FM-57 | Parent object disappears before child finalizers clear | MODELLING | Synthetic owner-deleted step removes a parent while descendant finalizers still block | Logged as deliberate counterexample candidate on `ownerDeletionWaitsForChildrenCandidate` |
| FM-58 | Progress-from-any-state is too strong under deletion stalls | MODELLING | Deletion in flight but no `RemoveFinalizer` is enabled under acknowledgement / external blocks | Logged as deliberate counterexample candidate on `progressFromAnyStateCandidate` |
| FM-59 | Restart invalidates in-memory hook cache, causing replay | MODELLING | Retry after restart replays transport call for same hook generation | Logged as deliberate counterexample candidate on `restartCacheReuseCandidate` |
| FM-61 | Pivot crash leaves dual-live object without pause fence | MODELLING | Crash after destination restore begins but before pause / teardown completes | Logged as deliberate counterexample candidate on `crashMutualExclusionCandidate` |
| FM-62 | Partial pivot restores leaf before owner chain | MODELLING | Destination sees a child object while its owner chain is still only on source | Logged as deliberate counterexample candidate on `partialPivotOrphanCandidate` |
| FM-60 | Partial failure may require replay of the same hook generation | MODELLING | Retry after prefix-success partial failure replays transport call | Logged as deliberate counterexample candidate on `partialFailureSingleTransportCandidate` |
| FM-63 | v1beta2 projection drops a legacy diagnostic key | MODELLING | Newer status surface omits a diagnostic tag still present in the legacy surface | Logged as deliberate counterexample candidate on `roundTripStatusInformative` via `statusProjectionLossRun` |
| FM-64 | One-version-only status field is dropped without documentation | MODELLING | Conversion loses a one-version-only field and the drop is not recorded | Logged as deliberate counterexample candidate on `informationLossDocumented` via `undocumentedFieldLossRun` |
| FM-65 | NoneConverter fallback serves a cross-version read | MODELLING | Conversion webhook is down but a different-version read is still served through NoneConverter fallback | Logged as deliberate counterexample candidate on `noneConverterCrossVersionCandidate` |
| FM-66 | User-provided kubeconfig secret rotates without KCP ownership | MODELLING | Rotation path ignores the ownership guard and regenerates a user-managed Secret | Logged as deliberate counterexample candidate on `ownedSecretOnlyRotates` via `userSecretRotationRun` |
| FM-67 | Cluster CA regenerates after KCP initialization | MODELLING | Missing post-init CA is silently re-minted instead of surfaced as unsupported | Logged as deliberate counterexample candidate on `caNotRecreatedAfterInit` via `postInitCARegenRun` |
| FM-68 | Kubeconfig rotation rewrites the control-plane endpoint | MODELLING | Regeneration path changes the server address instead of preserving it from the existing Secret | Logged as deliberate counterexample candidate on `rotationPreservesEndpoint` via `endpointRewriteRun` |
| FM-119 | Generic adversarial fault injection can keep a service permanently unavailable | MODELLING | Bounded fault budgets plus explicit clear/heal recover in the safe regime | Logged as deliberate counterexample candidate on `NoPermanentUnavailability` in `specs/AdversaryHarness.qnt`; seeded fuzzing and Apalache both reach the outage state |
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

**Issue #96 deepening.** `SelfHosted.qnt` now also models the more
concrete etcd-roll trap shape: `EnterEtcdRoll` moves the self-hosted
upgrade into the etcd rollout sub-step, `EtcdRollRequiresEtcdWrite`
captures the chicken-and-egg dependency on the hosted etcd write path,
and `EnableEscapeHatch` / `ResumeEtcdRollWithEscapeHatch` capture the
operator workaround (external/staged etcd write path, read-only window,
or equivalent escape hatch).

**Verdict.** Two specs verify FM-35 from complementary angles:

1. **`SelfHosted.qnt`** — focused dynamics: `selfHostedDeadlockTrace`
   reaches the `Deadlocked` invariant; `selfHostedRecoveryTrace`
   clears it. Issue #96 further adds:
   - `selfHostedEtcdTrapTrace` (mid-flight upgrade → `EnterEtcdRoll`
     → `EtcdRollRequiresEtcdWrite`) reaches the same deadlock class via
     the explicit etcd-write trap.
   - `selfHostedEtcdEscapeTrace` (mid-flight upgrade → etcd roll →
     `EnableEscapeHatch` → `ResumeEtcdRollWithEscapeHatch`) keeps
     `EscapeHatchExists` true and clears the trap without relying on the
     hosted etcd write path.
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
