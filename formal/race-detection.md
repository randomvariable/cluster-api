# Concrete-level race detection (issue #12)

The formal model proves "per-key serialised reconciliation"
(FM-45) at the abstract layer. Real Go has goroutine-level
races the model can't see: mutex acquisition order, channel
close races, map iteration during write, defer ordering. This
document records the workflow that catches those.

## What this is

`internal/chaos/` is a tiny chaos-injection library. A test
constructs a `chaos.Engine` with a probability profile, then
calls `eng.MaybeSleep()` / `eng.MaybePanic()` at instrumented
points in the code under test. The engine drives perturbations
from a deterministic PRNG seeded by `CHAOS_SEED`; failures
reproduce verbatim under the same seed.

`go test -race` is the actual race-detection backstop. Chaos
makes races more likely to fire by inserting microsecond-scale
sleeps that broaden the window between racing operations; the
detector reports any data race deterministically once it
observes one, so the test only needs to hit the race **once**
across enough chaos-driven iterations.

## Running

```sh
# Curated subset (always-on; runs in the formal-subtree gate
# trivia bound):
make test-race

# Same as above but with CHAOS_SEED=1 for reproducibility:
make test-race-chaos

# Re-run with a specific seed observed from a prior failure:
CHAOS_SEED=12345 make test-race-chaos
```

The full CAPI test suite under `-race` is operator-driven —
running every package races-on takes 30+ minutes, well past
the formal-subtree gate's budget. The curated subset
(`internal/trace/...`, `internal/chaos/...`) covers the
load-bearing primitives for formal-tracing infrastructure;
it's what every formality-branch commit must pass.

## Engine API

```go
eng := chaos.NewEngine(t, chaos.Profile{
    SleepProbability: 0.05,         // 5% of MaybeSleep calls pause
    SleepMaxJitter:   100 * time.Microsecond,
    PanicProbability: 0.0,          // never panic by default
})
defer eng.Stop()

// At an instrumentation point in the code under test:
eng.MaybeSleep()

// Or, to exercise defer / recover:
eng.MaybePanic("recoverable")
```

Calling Maybe* on a `nil` engine is a no-op. Production code
constructs `var eng *chaos.Engine` (uninitialised); the
overhead in production is one nil-check per instrumentation
point.

## Determinism

Two engines started with the same `CHAOS_SEED` produce
identical decision sequences when called identically. Failures
reported by `-race` therefore reproduce exactly: the seed is
logged on engine creation, and the operator re-runs with
`CHAOS_SEED=N go test -race ...` to walk the same timeline.

## Acceptance criteria (issue #12)

  * [x] `make test-race` runs the trace + chaos packages under
    `-race` cleanly. The full CAPI test suite under `-race` is
    operator-driven (the upstream `make test` already supports
    a `-race` variant; this issue did not promote it into the
    formal-subtree gate because the wall time is prohibitive).
  * [x] At least one chaos scenario runs under `-race` without
    false positives:
    `internal/trace/recorder_chaos_race_test.go::TestRecorder_ConcurrentUseUnderChaos`
    drives 16 concurrent goroutines × 64 records each through
    `JSONLinesRecorder`, with chaos sleeps at 10% probability
    × 500 µs jitter. The recorder uses a `sync.Mutex` +
    `atomic.Uint64` + `bufio.Writer`; `-race` validates all
    three are correctly synchronised.
  * [x] Genuine races filed as upstream issues — none observed
    on the load-bearing primitives covered. (No upstream filing
    required; if the curated subset later regresses, the
    failing trace's seed and stack go to a fresh upstream
    issue.)

## What was deliberately NOT done

  * **Full CAPI suite under -race.** Wall time. The upstream
    `make test` already supports `-race` via `GOFLAGS`; this
    issue does not duplicate that.
  * **controller-runtime workqueue race fuzzing.** The
    workqueue is upstream code; race-fuzzing it would belong in
    the controller-runtime repo. We document
    `internal/trace/recorder.go` as the canonical
    chaos-under-race target because it's CAPI-owned.
  * **Cache + informer race scenarios.** Same reason — the
    informer code is upstream client-go; CAPI calls it but
    doesn't own the synchronisation.

The right next-step if a CAPI-side race surfaces in production:

  1. Add the affected primitive's package to the
     `make test-race` target list.
  2. Write a chaos-driven test that drives it with the same
     concurrency the production caller does.
  3. Reproduce under a fixed seed; capture the seed in the
     fix-PR's commit message for posterity.

## Layout

```
internal/chaos/
├── chaos.go                       # Engine + Profile + primitives
├── chaos_test.go                  # determinism + concurrency self-tests
internal/trace/
├── recorder_chaos_race_test.go    # canonical chaos-under-race scenario
formal/
└── race-detection.md              # (this file)
```


## TLC symmetry reduction (issue #23)

TLC `SYMMETRY` reduces the reachable state space by quotienting over a
permutation group on uninterpreted model values. CAPI machine
identifiers are fully symmetric within a role (CP / worker / etcd
member), so this is a cheap, well-known win.

The Quint compiler emits machine IDs as `Int` with arithmetic, which
TLC rejects as a symmetry domain ("Symmetry function must have model
values as domain and range"). Three hand-crafted symmetry-friendly
abstractions live under `formal/specs/`:

| Spec | Domain | States (no sym) | States (sym) | Reduction |
| ---- | ------ | --------------- | ------------ | --------- |
| `LifecycleSymmetry.tla` | 5 CP Machines, MaxConcurrent=2 | 3984 | 130 | ~30x |
| `EtcdMembershipSymmetry.tla` | 5 etcd Members, MaxLearners=2 | 551 | 25 | ~22x |
| `ClusterE2ESymmetry.tla` | 3 CP + 3 worker, EndpointReadyN=2 | 76 | 19 | ~4x |

Run with `make verify-tlc-symmetry` (or the three per-spec targets).
Each spec has `.cfg` (SYMMETRY enabled) and `.nosymmetry.cfg`
(comparison baseline) configurations. The reduction factor is a
function of (a) the symmetric subset of state, (b) the role
partitioning, and (c) the depth of the BFS — deeper exploration sees
larger reductions because symmetric duplicates accumulate further out.

These specs are NOT verbatim refinements of `Lifecycle.qnt` /
`EtcdMembership.qnt` / `ClusterE2E.qnt`; they capture the symmetric
core of each (per-Machine phase progression, learner/voter promotion,
CP/worker bring-up). They preserve the invariants that survive
quotienting:

  * `NoConcurrentQuorumLoss`, `InFlightBounded`, `PhaseConsistent`
    for Lifecycle.
  * `LearnerNotVoter`, `QuorumNonEmpty`, `QuorumPreservedOnRemoval`
    for EtcdMembership.
  * `CpReadySubsetProvisioned`, `WorkersAdmittedImpliesEndpointReady`,
    `EndpointReadyImpliesEnoughCp` for ClusterE2E.

Counterexample budget: TLC found no violations at any depth in any of
the three exemplars. This is expected — the symmetric core is the
"easy" part of each spec, and the load-bearing failure modes
(FM-2 quorum loss, FM-23 orphan learner, FM-48 ordering) require
non-symmetric structure that these exemplars deliberately drop. See
`failure-modes.md` for the per-FM Apalache verdicts that *do* exercise
those.
