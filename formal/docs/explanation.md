# Explanation

Why the formal subtree is shaped the way it is. For task-oriented
recipes see [`how-to.md`](./how-to.md); for the exhaustive listing
see [`reference.md`](./reference.md).

## Why a formal corpus at all

Cluster API runs an interdependent network of controllers — KCP,
ClusterTopology, MachineDeployment, MachineSet, Machine,
MachineHealthCheck — all built on the same controller-runtime
substrate (worker pool, priority queue, leader election,
informer cache). A bug in any layer's invariant — quorum
preservation, phase ordering, hook ordering, per-key reconcile
serialisation, version-skew gating — surfaces as cluster
downtime that operators document but rarely root-cause to a
specific contract.

The formal corpus makes the implicit contracts between these
layers explicit and machine-checkable.

Concretely, the corpus exists to:

1. **Catch interface drift early** — every action in every Quint
   spec is anchored to a Go entry point in
   `abstraction-mapping.md`. If a future refactor moves or
   renames an entry point, the CI gate refuses the change,
   forcing a deliberate decision.
2. **Document operational failure modes** — 50 catalogued FMs
   (FM-1..FM-50) capture failure shapes from production
   incidents, upstream issue mining, and modelling-original
   discoveries. Each carries explicit start/end conditions and
   infrastructure causes.
3. **Verify hopelessness claims** — Apalache proves six FMs
   (FM-2, 3, 13, 16, 17, 23) are unrecoverable without operator
   intervention. These verdicts justify the operator-facing
   alerts ("you must restore from snapshot") that exist today
   as folklore.
4. **Surface cross-controller ordering invariants** — the
   end-to-end spec (`ClusterE2E.qnt`) verifies cross-cutting
   properties like "KCP must not create CP Machines before
   InfraCluster is ready" (FM-48), "MD must not create workers
   before ControlPlaneInitialized" (FM-49), and
   "ControlPlaneEndpoint is monotonic" (FM-50).
5. **Provide a shared vocabulary** — when an upstream issue
   describes a failure, mapping it to a model FM gives
   reviewers a shared anchor and makes the overlap with
   already-documented FMs visible.

## The four-layer architecture

The corpus is organised around CAPI's controller architecture:

- **Layer 0 (substrate)** — `ControllerRuntime.qnt` models the
  workqueue + worker pool + leader election + cache vs APIReader
  split that every CAPI controller is built on. Multi-worker
  concurrency is variabilised via `WORKERS = 1.to(N)`.
- **Layer 1 (per-component abstract specs)** — one spec per
  controller domain, each focused on its own state machine
  without modelling the substrate. `Lifecycle.qnt` covers KCP +
  etcd + kubeadm-join + MHC; `Topology.qnt` covers the
  ClusterTopology reconciler + runtime-extension lifecycle
  hooks; `MachineSetPreflight.qnt` covers worker MS preflight
  gating; `InPlaceUpdate.qnt` covers the in-place machine update
  choreography across MD/MS/Machine controllers.
- **Layer 2 (refinements)** — three `*Refined.qnt` modules
  compose Layer 1 specs onto the Layer 0 substrate. Each
  verifies that the abstract safety invariants survive the
  multi-worker substrate semantics (per-key serialisation,
  RequeueAfter, leader election).
- **Layer 3 (end-to-end)** — `ClusterE2E.qnt` consolidates the
  full bring-up handshake (BeforeClusterCreate → InfraCluster
  provision → KCP first CP Machine → CP scale-up →
  ControlPlaneInitialized → MD creates workers → Stable) plus
  the upgrade flow (rolling vs in-place).

Why layers? Each spec is verifiable in isolation, which keeps
TLC/Apalache state spaces tractable. Layer 2 lets us prove the
abstract specs survive substrate semantics without re-verifying
the abstract behaviour. Layer 3 surfaces ordering invariants
that no single Layer-1 spec captures.

## Why Quint, not raw TLA+

Quint compiles to TLA+; using it gets you TLC + Apalache "for free".
The benefits over hand-written TLA+:

- **Type checking** — Quint's type system catches shape mismatches
  at typecheck time. TLA+ has none.
- **Modular composition** — `import` and `module` work. TLA+'s
  `EXTENDS` is awkward for our composition.
- **Familiar syntax** — closer to a programming language than
  TLA+'s mathematical operator soup. Easier review.
- **Parameterised actions** — `action F(m: MachineId): bool = ...`
  is one definition; the TLA+ equivalent is one definition per
  literal MachineId.

The cost: Quint's TLA+ output isn't always optimal, and some
features (notably fairness, see Phase 11c below) hit translation
edge cases that you'd avoid writing TLA+ directly.

## Why a monolithic Lifecycle.qnt for the KCP domain

The original plan had one module per concern (EtcdMembership,
KCPReconcile, KubeadmJoin, MachineHealthCheck) plus a Composition
module wiring them. We have those modules — they're checked by
the abstraction-mapping drift CI gate — but TLC and Apalache run
against the monolithic `Lifecycle.qnt`. Why:

- **Cross-module composition in Quint hits TLA+ level errors.**
  `import M.*` plus `init`/`step` collisions cause `Level error
  in applying operator $SetOfAll` from TLC. Worked around for
  the modular specs but the composition is sketchy.
- **Single-spec verification is faster.** Apalache's symbolic
  engine prefers one spec; cross-module verification compounds
  variable resolution.
- **Counterexamples are easier to read.** A monolithic spec
  means a single trace; modular specs require synthesis.

The trade-off: `Lifecycle.qnt` is large (~5000 lines, 70
actions). The modular specs are kept as documentation and for
the abstraction-mapping drift check.

This pattern applies only to the KCP domain. The other Layer-1
specs (`Topology.qnt`, `MachineSetPreflight.qnt`,
`InPlaceUpdate.qnt`) are each smaller (300-700 lines) and
focused on one controller, so the modular trade-off doesn't
apply.

## Why composition without import (refinement modules)

The Layer-2 refinement modules
(`TopologyRefined.qnt`, `InPlaceUpdateRefined.qnt`,
`MachineSetPreflightRefined.qnt`) embed both the substrate state
and the abstract spec state in one self-contained module rather
than using Quint `import`. Why:

- **Quint's import semantics are limited.** Cross-file imports
  don't compose well with action-level state mutation; the
  refinement modules need both substrate state vars
  (`queuePos`, `workerOnKey`) and abstract state vars
  (`clusterPhase`, `pendingHooks`) to mutate within the same
  action.
- **Self-contained modules are easier to verify.** A reader can
  see the full state machine in one file. The duplication is
  the cost of avoiding import-time errors.
- **Refinement is verified empirically.** Each refinement
  module re-states every abstract safety invariant; running
  random walks confirms they hold under the joint substrate
  semantics. This is a sound proof of refinement modulo the
  invariants verified.

## Why TLC + Apalache

TLC explores the state space breadth-first; Apalache symbolically
proves bounded properties via SMT. They cover different territory:

- **TLC** finds counterexamples cheaply (FM-X reaches HealthyControl
  Plane in a few seconds at depth 8). Good for reachability.
- **Apalache** proves *non-existence* of counterexamples up to
  depth N (no path of length ≤ N reaches the bad state). Good for
  hopelessness claims.

We use TLC for reachability under `step`, Apalache for hopelessness
under `stepNoRecovery`. Five FMs carry Apalache verdicts; the rest
have TLC reachability only because Apalache is too slow on the
larger inits.

## Why the contract-pinned RFC-2119 documents

`formal/contracts/{etcd-raft,kcp-machine,kubeadm-etcd}-contract.md`
contain the obligations the model relies on, written in the RFC-
2119 idiom (MUST / MUST NOT / SHOULD). Each obligation cites an
upstream commit SHA in `formal/contracts/commits.yaml`. Why:

- **Refactor durability** — when a Go function moves, the SHA is
  the canonical source. The Make `lsp-list` target prints all
  cited Go anchors for cross-referencing.
- **Reviewability** — a reviewer can read just the contract
  document without the spec to understand what KCP guarantees.
- **Spec/code separation** — the contract is the interface; the
  Quint spec is one implementation; the Go controller is another.
  Both implementations refine the contract.

## Why an out-of-band-etcd assumption (Phase 11c)

Standalone `AddLearner(id)` was originally in `step` because the
modular `EtcdMembership.qnt` defines it. Phase 11b found that this
let TLC discover lasso cycles where a free `AddLearner` keeps
adding orphan etcd members faster than KCP's reaper can drain them.
Real-world reading: external etcd managers (etcd-operator, an
operator's manual `etcdctl member add`) racing KCP's reconcile.

We removed standalone `AddLearner` from `step` and documented the
exclusion in `etcd-raft-contract.md §5b`. Kubeadm's direct
`MemberAddAsLearner` call is still in scope — it's the legitimate
path encoded as `EtcdAddLearnerSucceeded`, gated on
`phase[m] == EtcdJoinAddLearner` which requires a CAPI-provisioned
Machine. External managers are a separate verification round.

## Why per-action fairness for FM-9

Phase 11 landed `temporal ConvergenceFair = weakFair(step, allVars)
implies eventually(always(HealthyControlPlane))` — the simplest
possible fairness assumption. Phase 11b showed it's too weak: TLC
found a `MachineHealthChange` flip-flop where MHC's observation
oscillates between Healthy/Unhealthy without convergence.

The fix is per-action fairness:
- **Strong-fair** on healing/forward-progress actions (47): if
  enabled, MUST eventually fire.
- **Weak-fair** on faults (18): may fire 0 or N times.

The intuition: faults can recur forever (real-world clusters do),
but healing must always win the race eventually. The 65-conjunct
expansion is mechanical and lives in `hack/tools/quint-fairness-
gen.py`.

## <a id="phase-11c-tlc-tautology"></a>Why Phase 11c can't close the fairness verdict with TLC

TLC reports the 65-conjunct `ConvergenceFair` formula a "tautology
(its negation is unsatisfiable)" with "satisfiability problem has
0 branches". Diagnostic runs proved this is a TLC capacity
limitation, not a verification:

| Property | Conjuncts | TLC tableau | Verdict |
|---|---|---|---|
| `ConvergenceFair` | 65 | 0 branches | tautology |
| `ConvergenceMinimalFair` (1 strong-fair) | 1 | 1 branch | state-space exploration begins |

TLC's temporal tableau construction silently overflows on large
fairness formulas and returns "tautology" without exploring. The
distinguishing test (`ConvergenceMinimalFair`) confirms TLC works
on small formulas but balks on the full one.

`fairConvergenceWitnessRun` (a 22-step deterministic path through
the kubeadm-join chain that reaches `HealthyControlPlane`) proves
the per-action fairness *is* satisfiable — at least one fair
execution exists. Whether *all* fair executions converge is a
question TLC can't answer at this formula size.

Three paths investigated:

1. ~~**Apalache** — SMT-based, handles larger formulas.~~
   **Ruled out**: Apalache 0.56.1's experimental temporal-property
   pass returns `error: Handling fairness is not supported yet!`
   for any property using `weakFair` / `strongFair`.

2. **Reduced fairness scope** — TLC's tableau handles small
   fairness sets but state-explodes between 16 and 24 conjuncts
   on this model. Phase 11d ran a bisection:

   | Conjuncts | Verdict | Time |
   |---|---|---|
   | 8 | real cex (MachineHealthChange flip-flop) | 4 s |
   | 16 | real cex (WebhookRotationFault re-fire) | 6 s |
   | 24 | OOM at 16 GB heap (state explosion) | 27 s |
   | 65 | tautology (tableau capacity) | 4.6 s |

   Both 8- and 16-conjunct verdicts are **real liveness
   counterexamples** — under strong-fair on healing actions and
   weak-fair on faults, faults that recur infinitely often
   prevent `eventually(always(P))` from holding. The
   counterexamples are operationally meaningful: MHC flip-flop
   under intermittent flakiness (8-conjunct) and webhook
   rotation re-firing through KCP's reconcile (16-conjunct).
   Both are recurrent-fault behaviours, not modelling artefacts.

   `ConvergenceFair16` is now the canonical TLC-verifiable
   scope. The verdict acknowledges the recurrent-fault cycles
   rather than proving them away.

3. **Lean 4 deductive proof** — against the parametric carrier
   in `formal/proofs/ControlPlane/`. Independent of model-checker
   capacity. Scaffolded but the temporal forms haven't been
   stated. This is the path to a fault-aware liveness verdict
   (e.g. "after the last fault, eventually-always healthy" with
   an explicit fault budget).

## What's deferred

Documented in `overview.md` "Remaining gaps":

- Full per-cluster Lifecycle.qnt expansion for FM-35 (current
  `SelfHosted.qnt` captures the dynamics in a focused module).
- FM-33 worker-machine preflight — out of scope for control-plane
  focus.
- Most FMs lack e2e specs; only FM-2 has a passing CAPD test.

These are conscious deferrals, not unknown gaps.

## What this corpus is NOT

- **Not a complete refinement proof.** The Quint actions refine
  named Go entry points, but the *implementation* of those Go
  functions can drift from the spec without breaking the model.
  The contract-pinned commits and CI drift check catch the most
  obvious cases.
- **Not a replacement for testing.** TLC verifies the abstraction;
  the e2e tests verify the implementation. Both are needed.
- **Not a substitute for code review.** The model exposes
  invariants; review checks the code preserves them.
- **Not bug-finding.** The corpus formalises known dynamics. It
  has flagged five model-level findings (the `AddLearner` ghost
  cycle, `MachineHealthChange` flip-flop, missing
  `RemoveMember(leader)` precondition, missing `ObservationRefresh`,
  init-action permissiveness for FM-1) but no upstream Kubernetes
  or CAPI bugs.
