# Property-based trace replay (issue #11)

Random Quint traces, replayed through the Go-side checkers in
`internal/trace/checkers/`. Each trace is a witness; pipeline
errors are CI-failing, checker findings are logged for review.

## What this is

The Quint specs in `formal/specs/` describe transition relations.
`quint run --mbt --out-itf=...` walks the model randomly and
emits one ITF JSON file per trace. Each ITF state carries the
action the model chose, the non-deterministic parameters it
picked, and the post-state of every variable.

Real CAPD controller-manager logs can be lifted into the same
`TraceRecord` JSONL shape with `hack/tools/capd-log-to-trace/`, or
 fed straight into `trace-validator -format capdlog`. The same
 checker set therefore covers both synthetic Quint traces and real
 controller traces.

`internal/trace/itf.go::LoadITF` parses these ITF files into
`TraceRecord` slices the per-spec checkers consume. The
`hack/tools/trace-validator/` binary runs every checker against
a single trace; the `hack/tools/trace-replay-sweep.sh` script
runs the validator across N random traces per spec and reports
a per-spec summary.

## Running

```sh
# Default: 50 traces per spec, 15-step traces, ~10 s wall.
make verify-trace-replay

# Issue #11 acceptance criterion: 10k traces/spec.
make verify-trace-replay-large

# Treat every checker finding as a CI failure (default mode logs
# findings; only pipeline failures fail CI):
make verify-trace-replay-strict

# Or invoke the script directly with custom flags:
hack/tools/trace-replay-sweep.sh \
  --total-traces 200 \
  --max-steps 20 \
  --specs EtcdMembership,KubeadmJoin \
  --out-dir /tmp/replay-2026-05-08
```

## Two error categories

The sweep distinguishes two failure modes:

  * **Pipeline failures** — `MalformedRecord` verdicts or JSON
    decode errors. These mean the trace-replay plumbing is
    broken: the loader is missing a parameter alias, a checker
    can't read a record it should, etc. Pipeline failures
    always fail CI.

  * **Checker findings** — proper invariant violations. These
    are interesting but may reflect checker incompleteness
    (the checker reconstructs less state than the spec
    enforces) rather than a real Go-vs-spec deviation. The
    sweep logs findings to `<out-dir>/findings.txt` and exits
    0 unless `--strict` is set.

## Why findings are logged-only by default

The current per-spec checkers in `internal/trace/checkers/`
were authored against hand-curated traces (the FM-1
IncidentWitness, FM-2 quorum-loss). Their internal state
machines mirror enough of the spec to catch the specific
counterexamples those scenarios produce. Random traces exercise
state combinations the checkers don't fully reconstruct — so a
random `EtcdMembership` trace that legitimately reaches an
all-learners state will trip `VoterSetNonEmpty` even though the
spec itself permits the state.

The right long-term fix is to make every checker a faithful
replay of the spec's transition relation (this is essentially
what Apalache/TLC do internally). That's a larger investment
than this issue's scope. For now: pipeline plumbing is
hardened; findings are filed in the counterexample log as a
known checker-incompleteness category.

## What the sweep has found

50 traces × 4 specs at default settings (issue #11 close):

  * EtcdMembership.qnt: ~10–15% of random traces trip
    `VoterSetNonEmpty`. The model permits `RemoveMember` to
    fire any time the resulting member set is non-empty
    (including all-learners); the checker assumes voters > 0.
    Filed in `formal/counterexample-log.md` as
    `EtcdMembership.RandomReplayCheckerIncomplete`.
  * KCPReconcile.qnt: ~50–60% of random traces trip
    `RemediationOnlyWhenSafe`. Cause: the checker recomputes
    `safe := matchableEqMachines() && quorumPreservedAfterDelete(mid)`
    using its own state, but the spec's safety verdict
    persists in `decision[m]` across multiple
    `EvaluateCanSafelyRemediate` calls. Filed as
    `KCPReconcile.RandomReplayCheckerStateDivergence`.
  * KubeadmJoin.qnt: clean.
  * MachineHealthCheck.qnt: clean.

10k-trace runs are the natural follow-up; the script handles
that scale (see `make verify-trace-replay-large`).

## Layout

```
internal/trace/
├── capdlog.go                # CAPD structured-log -> TraceRecord translator
├── capdlog_test.go           # fixture-based translator tests
├── itf.go                    # MBT-aware ITF loader + spec/param dispatch
├── itf_test.go               # round-trip + unwrap unit tests
├── testdata/
│   ├── capd_*.jsonl          # canonical CAPD log fixtures
│   └── etcd_membership.mbt.itf.json
hack/tools/
├── capd-log-to-trace/        # standalone CAPD log -> JSONL translator
├── trace-validator/          # one-trace CLI (also used by FM-2 e2e)
└── trace-replay-sweep.sh     # N-trace × M-spec sweep
formal/
└── trace-replay.md           # (this file)
```

## Adding a new spec to the sweep

Three steps:

1. Make sure the spec's actions are listed in
   `InferSpecFromAction` (`internal/trace/itf.go`).
2. Make sure each action's parameter names are in
   `actionParamAliases` (same file). Map each Quint parameter
   to the canonical name the checker expects.
3. Add the spec name to the `--specs` flag default in
   `trace-replay-sweep.sh` (or pass it explicitly).

Run `make verify-trace-replay` to confirm the new spec produces
no pipeline errors.
