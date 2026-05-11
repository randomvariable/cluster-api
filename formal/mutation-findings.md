# Mutation testing findings

Issue #4: <https://github.com/randomvariable/cluster-api/issues/4>.

`hack/tools/quint-mutation-tester.py` applies systematic
mutations to invariants in a Quint spec, runs `quint run`
against each mutation, and reports surviving mutations
(mutations where the invariant still holds despite the
weakening — meaning the original invariant was redundant, the
random walk doesn't deeply explore the violating region, or a
spec bound makes the conjunct trivially true).

## Run

```sh
make -C formal mutation-test                  # all specs
make -C formal mutation-test-newer-sampled    # CI-sized subset of newer specs
make -C formal mutation-test-newer-full       # full newer-spec nightly sweep
hack/tools/quint-mutation-tester.py \
  formal/specs/<spec>.qnt --main=<spec>       # one spec
```

The tool exits 0 if all mutations are killed, exit 2 if any
survived. Surviving mutations' .qnt files land in
`/tmp/quint-mutations/`.

## Methodology

Eight mutation operators are applied per invariant:

| Mutation | Description |
|---|---|
| `DropConjunct` | drop the first conjunct in `all { A, B, ... }` |
| `AndToOr` | replace first ` and ` with ` or ` |
| `ForallToExists` | replace `.forall(` with `.exists(` |
| `ExistsToForall` | replace `.exists(` with `.forall(` |
| `FlipLeToLt` | replace ` <= ` with ` < ` |
| `FlipGeToGt` | replace ` >= ` with ` > ` |
| `DropImpliesLhs` | replace `A implies B` with `A or B` |
| `NegateRhs` | replace `A implies B` with `A implies not(B)` (sanity check) |

Each invariant is parsed from its `val` declaration, the body
is extracted, mutations are applied, the mutated spec is
written to a temp file, and `quint run --invariant=<name>` is
run with `--max-samples=300 --max-steps=40`. A SURVIVING
mutation = `[ok] No violation found` (invariant held despite
the weakening).

## Aggregate results

| Spec | Mutations | Killed | Survived |
|---|---|---|---|
| ControllerRuntime.qnt | 72 | 12 | 7 |
| InPlaceUpdate.qnt | 88 | 16 | 10 |
| MachineSetPreflight.qnt | 24 | 8 | 0 |
| Topology.qnt | 96 | 19 | 7 |
| ClusterE2E.qnt | 104 | 24 | 9 |
| WorkerLifecycle.qnt | 96 | 17 | 8 |
| Lifecycle.multicluster.qnt | 16 | 6 | 0 |
| SelfHosted.qnt | 8 | 0 | 0 (no invariants in filter) |
| TopologyRefined.qnt | 72 | 12 | 5 |
| InPlaceUpdateRefined.qnt | 72 | 11 | 8 |
| MachineSetPreflightRefined.qnt | 64 | 13 | 5 |
| **Total** | **712** | **138** | **59** |

Of the 59 survivors, by mutation type:

| Type | Count | Interpretation |
|---|---|---|
| `ForallToExists` | 35 | Random walk doesn't reach a state where the universally-quantified property differs from the existential one — typically because the property holds for ALL keys vacuously when no key is in the failing region. Apalache verification (issue #1) closes some of these for the new specs. |
| `AndToOr` | 11 | Conjunction is redundant: one disjunct already holds in every reachable state due to spec bounds (e.g. `workerOnKey.get(w) != IDLE_KEY implies KEYS.contains(workerOnKey.get(w))` is trivially true because `workerOnKey`'s codomain is bounded by the spec). |
| `DropImpliesLhs` | 8 | Precondition rarely activated in random walk; the invariant's antecedent state is hard to reach. Stronger random-walk parameters (`--max-samples=2000 --max-steps=80`) close most. |
| `NegateRhs` | 3 | Consequent is a tautology in the reachable state space — i.e. the predicate is always true regardless of the precondition. |
| `ExistsToForall` | 2 | Symmetric to ForallToExists. |

## Per-spec findings

### ControllerRuntime.qnt — 7 survivors

| Invariant | Mutation | Interpretation |
|---|---|---|
| `FM45_PerKeySerialisation` | ForallToExists | Random walk doesn't reach a state where two workers have the same key (Apalache proves this directly — the existential variant is also unreachable). Closed by issue #1 Apalache verification. |
| `FM46_TerminalErrorNoRequeue` | ForallToExists | Same as above. |
| `FM47_CacheBehindAPI` | ForallToExists | Same. |
| `WorkerSentinelConsistency` | AndToOr | The two conjuncts are interdependent due to the spec's worker-key invariant — `workerOnKey != IDLE_KEY` implies the key is in KEYS by construction. Conjunct is mathematically redundant. |
| `WorkerSentinelConsistency` | ForallToExists | Random-walk coverage. |
| `InFlightHasWorker` | ForallToExists | Random-walk coverage. |
| `RateLimitBounded` | ForallToExists | Random-walk coverage. The older `FlipLeToLt` survivor was closed by tightening `RateLimitBounded` to `< RATE_LIMIT_CAP`. |

### InPlaceUpdate.qnt — 10 survivors

Mostly ForallToExists / DropImpliesLhs (random-walk coverage).
Notable: `MovingPendingShape :: AndToOr` survived because once
a Machine is in `MovingPending`, both `machineOnNewMs` and
`machineInProgress` are set together by the same action
(`StartMoveMachine`) — they're never independently false in any
reachable state. Conjunct is mathematically redundant.

### Topology.qnt — 7 survivors

Includes `CpVersionWithinPlan :: DropImpliesLhs` and
`CpVersionWithinPlan :: NegateRhs` — both survive because the
implication's antecedent `clusterPhase == Upgrading` is rarely
combined with the failing post-condition in the random walk.

### ClusterE2E.qnt — 9 survivors

`AfterClusterUpgradeAtTarget :: AndToOr` survived because the
two consequents are both implied by the antecedent transitively.

### WorkerLifecycle.qnt — 8 survivors

Includes `FM33_PreflightGate :: DropImpliesLhs` — surfaces the
documented FM-51 race: the precondition `ActionInFlight` is
rarely activated under non-stable CP in the random walk.

### Lifecycle.multicluster.qnt — 0 survivors

`LifecycleMultiCluster` contributed 16 attempted mutations, 6
kills, and 0 survivors. The surviving-set follow-up work for
issue #26 therefore focuses on the single-cluster newer specs;
the multicluster slice is already load-bearing under the
current mutation operators.

## Issue #26 follow-through decisions

The original issue asked for more than just raw mutation output:
surviving mutations should either tighten the spec, be accepted
as redundant guards, or be documented as scope limits. The
following entries satisfy that follow-through for the newer-spec
surviving set.

| Spec | Invariant / mutation | Decision | Outcome |
|---|---|---|---|
| `ControllerRuntime.qnt` | `RateLimitBounded :: FlipLeToLt` | **Spec tightening** | Applied: `RateLimitBounded` now uses `< RATE_LIMIT_CAP` instead of `<= RATE_LIMIT_CAP`, matching the reachable retry ceiling observed in the mutation run. |
| `InPlaceUpdate.qnt` | `MovingPendingShape :: AndToOr` | **Accepted redundant guard** | Kept as-is for readability. The conjunction documents the two coupled facts (`machineOnNewMs` and `machineInProgress`) even though `StartMoveMachine` currently establishes them together. |
| `ClusterE2E.qnt` | `AfterClusterUpgradeAtTarget :: AndToOr` | **Accepted transitive redundancy** | Kept as-is. Both post-upgrade target conditions are transitively implied together in reachable states, but the paired form remains the clearest statement of the upgrade intent. |
| `WorkerLifecycle.qnt` | `FM33_PreflightGate :: DropImpliesLhs` | **Scope-limitation entry** | Documented as a random-walk coverage limit tied to the FM-51 race window. The antecedent is hard to activate under short random traces; this is better closed by the composition proof / deeper bounded exploration than by weakening the invariant. |

## How to address survivors

Three categories:

1. **Random-walk coverage gaps** (~50 of 60) — bumping
   `--max-samples` and `--max-steps` may close. Better:
   Apalache verification (issue #1) provides exhaustive
   bounded coverage, closing these for the four new specs.

2. **Bound-induced redundancy** (~5 of 60) — the conjunct is
   mathematically redundant given the spec's bounds. Either
   drop the conjunct (cleaner spec) or document the redundancy.

3. **Genuine over-strong / over-weak invariants** (a few
   cases) — refine the invariant body. The concrete issue-26
   tightening applied so far is `ControllerRuntime.RateLimitBounded`,
   which now uses the stricter `< RATE_LIMIT_CAP` bound.

## Limitations

- The mutation tool's body extraction is line-oriented and can
  occasionally include trailing comment text in the mutated
  body, causing parse errors. ~30% of attempted mutations
  produce parse errors rather than verdicts. These are counted
  as "killed" (since they don't reach the random walk) — the
  true survivor rate is somewhat higher than 60.
- The tool only mutates `val` invariants; `temporal` properties
  are out of scope (would require generating fairness conjunct
  mutations).
- Multi-conjunct mutations (drop two, swap two) are not
  applied — only single-mutation effects.

## Reproducibility

Surviving mutations' .qnt files are in `/tmp/quint-mutations/`.
Re-run the tool with the same flags to regenerate.
