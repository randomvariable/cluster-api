# Explanation

Why the formal subtree is shaped the way it is. For task-oriented
recipes see [`how-to.md`](./how-to.md); for the exhaustive listing
see [`reference.md`](./reference.md).

## Why a formal model at all

The Cluster API control-plane lifecycle has at least three
interdependent state machines (KCP, etcd Raft, kubeadm-join) running
on top of a fourth (the kubelet ↔ containerd ↔ static-pod runtime).
A bug in any layer's invariant — quorum preservation, phase
ordering, MHC observation projection — surfaces as cluster downtime
that operators document but rarely root-cause to a specific
contract. The formal model makes the implicit contracts between
these layers explicit and machine-checkable.

Concretely, the corpus exists to:

1. **Catch interface drift early** — every action in the Quint spec
   is anchored to a Go entry point in `abstraction-mapping.md`. If a
   future refactor moves or renames an entry point, the CI gate
   refuses the change, forcing a deliberate decision.
2. **Document operational failure modes** — the 24 catalogued FMs
   (plus 4 from upstream issue mining) capture the failure shapes
   operators see in production, with explicit start/end conditions
   and infrastructure causes.
3. **Verify hopelessness claims** — Apalache proves five FMs (FM-2,
   3, 13, 16, 17) are unrecoverable without operator intervention.
   These verdicts justify the operator-facing alerts ("you must
   restore from snapshot") that exist today as folklore.
4. **Provide a shared vocabulary** — when an upstream issue
   describes a failure, mapping it to a model FM gives reviewers a
   shared anchor and makes the overlap with already-documented FMs
   visible.

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

## Why a monolithic Lifecycle.qnt

The original plan had one module per concern (EtcdMembership,
KCPReconcile, KubeadmJoin, MachineHealthCheck) plus a Composition
module wiring them. We have those modules — they're checked by the
abstraction-mapping drift CI gate — but TLC and Apalache run against
the monolithic `Lifecycle.qnt`. Why:

- **Cross-module composition in Quint hits TLA+ level errors.**
  `import M.*` plus `init`/`step` collisions cause `Level error in
  applying operator $SetOfAll` from TLC. Worked around for the
  modular specs but the composition is sketchy.
- **Single-spec verification is faster.** Apalache's symbolic engine
  prefers one spec; cross-module verification compounds variable
  resolution.
- **Counterexamples are easier to read.** A monolithic spec means
  a single trace; modular specs require synthesis.

The trade-off: Lifecycle.qnt is large (~5000 lines, 70 actions). The
modular specs are kept as documentation and for the abstraction-
mapping drift check.

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

Two paths forward:
1. ~~**Apalache** — SMT-based, handles larger formulas.~~
   **Ruled out**: Apalache 0.56.1's experimental temporal-property
   pass returns `error: Handling fairness is not supported yet!`
   for any property using `weakFair` / `strongFair`. We can use
   Apalache for non-fair temporal properties (`eventually(P)`,
   `always(P)`) but those inherit the stuttering counterexample
   TLC already finds without fairness.
2. **Reduced fairness scope** — TLC's tableau handles small
   fairness sets (the 1-conjunct `ConvergenceMinimalFair` produced
   a 1-branch tableau and started state-space exploration). The
   approach: identify a minimal sufficient set of strong-fair
   actions (probably `ElectLeader`, `PromoteLearner`, `MarkReady`,
   `ResolveNodeRef`, `MachineHealthChange`, `CompleteRemediation`,
   `HealEtcdReachability`, `HealLb`) and prove convergence under
   just those. This is the actionable next step.
3. **Lean 4** — manual proof against the parametric carrier in
   `formal/proofs/ControlPlane/`. Produces a deductive verdict
   independent of model-checker capacity. Scaffolded; not yet
   discharged.

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
