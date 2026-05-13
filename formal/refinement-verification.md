# Abstraction-mapping refinement verification (issue #13)

The drift check (`scripts/verify-formal.sh` step 6) confirms
every Quint action has a row in `abstraction-mapping.md`. It
does NOT confirm that the Go function actually implements the
abstract action's semantics. This doc is the methodology for
closing that gap and the current coverage status.

## The two phases

The issue scopes two distinct attacks:

  * **Phase 1 (pragmatic).** Per-action Go property tests. For
    each abstract action, write a test that drives the Go
    function from a pre-state matching the abstract
    precondition, runs the function, and asserts the post-state
    matches the abstract postcondition. This is what landed in
    `internal/refinement/`.
  * **Phase 2 (research).** A Go-to-Lean translator analogous
    to Aeneas's MIR-to-Lean pipeline, but for Go's SSA. The
    translator emits Lean encodings of the relevant Go
    functions; the refinement obligations become Lean
    theorems. This is research-grade and out of scope for
    the formality branch.

## Phase 1 framework (`internal/refinement/`)

The framework is deliberately thin — refinement testing
doesn't fit a single shape, so it offers a `Case` struct, a
`Suite`, and a runner:

```go
suite := refinement.NewSuite().
    Add(refinement.Case{
        Action: "AddLearner",
        GoRef:  "internal/trace.JSONLinesRecorder.Record",
        Setup:  func(t *testing.T) any { ... },
        Pre:    func(state any) bool { ... },
        Run:    func(t *testing.T, state any) any { ... },
        Post:   func(state any) error { ... },
    })
verdicts := suite.Run(t)
```

A Case captures four bits of the abstraction-mapping contract:

  * **Action** — Quint action name (matches a row in
    abstraction-mapping.md).
  * **GoRef** — canonical Go entry point as
    `import/path.Func`, grep-friendly.
  * **Pre** — abstract precondition over a setup state. Returns
    false → SKIP.
  * **Run** + **Post** — drive the Go function; assert the
    abstract effect.

Verdicts are emitted as `OK`/`SKIP`/`FAIL` lines for easy
grep against test output.

## Running

```sh
# Phase 1: run every refinement Case + report coverage.
make verify-refinement

# Plus race-detection over the same suite:
make test-race

# Or just the suite:
go test -count=1 ./internal/refinement/...
```

The `verify-refinement` target prints a coverage line of the
form `==> Refinement coverage: M / N actions covered (P%)`
against `formal/abstraction-mapping.md`. The target is
informational — failing the coverage bar does NOT fail the
target. (Promoting to fail is a follow-up once coverage
crosses the issue's 50% bar.)

## Coverage status (commit 905f7b179, 2026-05-09)

13 / 189 actions covered (~7%).

Covered actions:

  * EtcdMembership: Bootstrap, AddLearner, RemoveMember,
    PromoteLearner, ObserveLearnerProgress, ElectLeader (6 of
    9 actions in the spec).
  * KubeadmJoin: BeginJoin, PreflightPass, KubeletStarted,
    EtcdAddLearnerSucceeded, JoinComplete (5 of 11 actions in
    the spec).
  * Plus 2 negative cases (PromoteLearner without Eligible →
    PromotionEligibility violation; ElectLeader of a learner →
    LearnerCannotVote violation) that exercise the checker's
    reject path. Negative cases are interesting because they
    refine the spec's *forbidden* transitions, not just the
    permitted ones.

The 50% acceptance bar is 95+ cases. The shortfall is
deliberate: each of the 195 abstract actions in
`abstraction-mapping.md` requires its own thoughtful test
with a representative pre-state, and most actions (FM-1's
join-phase machinery, FM-9's recurrence, KCP's full
reconcile loop) need a controller-runtime test environment
to drive the actual Go function — not just a recorder
record. That work is genuine per-action investment that
exceeds a single commit's scope.

The framework itself is complete: future contributors can add
cases incrementally without touching the runner. Each new
Case is a one-PR loop:

  1. Pick an action from `formal/abstraction-mapping.md`.
  2. Identify the Go entry point.
  3. Write Setup / Pre / Run / Post.
  4. `make verify-refinement` confirms the Case passes and the
     coverage line ticks up.

## Phase 2: a Go-to-Lean translator (research)

The pragmatic path above asserts refinement at runtime — a
test that, on the inputs it tries, the Go function obeys the
abstract postcondition. This is sufficient to catch egregious
divergence but doesn't verify refinement statically: a state
the test didn't think to try might still violate the contract.

Static refinement verification would map each Go function to a
Lean term and prove the term refines the corresponding Quint
action. The closest existing precedent:

  * **Aeneas** (Inria) — translates Rust MIR to Lean / F* /
    Coq. Handles Rust's borrow-checker semantics through a
    pure-functional encoding. Mature; used to verify libraries
    like `crelf` and parts of `secp256k1`.
  * **Hax** (also Inria) — F*-targeted Rust verifier; broader
    coverage at lower fidelity.

Both target Rust. Go has no direct equivalent. The closest
candidates:

  * **gocfg / SSA toolchain** — `golang.org/x/tools/go/ssa`
    produces an SSA representation that an Aeneas-style
    pipeline could consume. Goroutines and channels are the
    main extra complexity; for CAPI controllers the relevant
    code is mostly sequential reconcile-loop logic that
    avoids the trickiest concurrency patterns.
  * **Hand-written Lean encodings** — the existing
    `formal/proofs/ControlPlane/Ordering.lean` pattern
    extended: each Go function gets a Lean term that
    transparently mirrors its control flow. No translator;
    the encoding is a deliberate human-authored faithful
    rewrite. Verified by inspection rather than mechanically.

Phase 2 is parked as a research direction in this doc. If the
formality branch goes upstream and a follow-up KEP is filed,
Phase 2 is the natural first item on its work-stream.

## Layout

```
internal/refinement/
├── refinement.go                       # Case / Suite / Verdict
├── recorder_refinement_test.go         # 8 EtcdMembership cases
└── multi_spec_refinement_test.go       # 5 KubeadmJoin cases + loader identities
internal/trace/checkers/etcdscheduler/
├── checker.go                          # Remediation admission↔commit checker
└── checker_test.go                     # synthetic stale-voter / learner-promotion cases
internal/trace/testdata/
├── remediation_orphan_etcd_learner.jsonl
└── remediation_concurrent_cp_remediation.jsonl
formal/
└── refinement-verification.md          # (this file)
```

## Remediation trace-refinement corpus (issue #107)

`formal-refinement` is the CI-style entrypoint for the remediation trace
checker added under `internal/trace/checkers/etcdscheduler/`. The checker
validates two paired admission↔commit refinement properties over
`trace.SpecRemediation` records:

- `GateAndCommitObserveConsistentState`
- `EveryRemoveMemberHasMatchingValidCommitAdmission`

Current corpus members:

- `internal/trace/testdata/remediation_orphan_etcd_learner.jsonl`
  - orphan-learner path where the commit is correctly aborted while the
    etcd member is still joining / unnamed
- `internal/trace/testdata/remediation_concurrent_cp_remediation.jsonl`
  - two-machine remediation trace where the second commit is correctly
    aborted after the first removal is already in flight
- `internal/trace/testdata/remediation_cas_stale_voter_count_aborted_pass.jsonl`
  - admission saw `admissionVoterCount=3`; before commit a concurrent
    removal landed (`freshVoterSet.size()=2`); CAS aborts and the trace is
    accepted (issue #110)
- `internal/trace/testdata/remediation_cas_learner_promoted_aborted_pass.jsonl`
  - admission saw `targetIsLearner=true`; the learner was promoted before
    commit (`freshTargetIsLearner=false`); CAS aborts and the trace is
    accepted (issue #110)

Negative corpus (kept under `internal/trace/testdata/` but expected to fail
validation — exercised through `make verify-remediation-cas-traces`):

- `remediation_cas_stale_voter_count_fail.jsonl` — commit + RPC proceeded
  after `freshVoterSet.size() < admissionVoterCount`; checker MUST fail
  with `GateAndCommitObserveConsistentState`.
- `remediation_cas_learner_promoted_fail.jsonl` — commit + RPC proceeded
  after the learner was promoted mid-flight; checker MUST fail with
  `GateAndCommitObserveConsistentState`.
- `remediation_cas_concurrent_cp_remediation_fail.jsonl` — two-machine
  trace where the second commit proceeded after the first removal already
  dropped the voter count below the admission snapshot; checker MUST fail
  with `GateAndCommitObserveConsistentState`.

## RemediationCAS.tla (issue #110)

`formal/specs/RemediationCAS.tla` is the TLA+ companion to the trace
checker. It explicitly models the per-Machine handshake
`ReadGate → CommitAdmission → RemoveMemberRPC` (or `ReadGate →
CommitAdmissionAborted`) interleaved with concurrent live-state
perturbations (`VoterRemoved`, `LearnerPromoted`, `LearnerAdded`). TLC
enumerates the reachable state space and confirms two refinement
invariants:

- `GateAndCommitObserveConsistentState` — every successful commit was
  CAS-consistent with its admission.
- `EveryRemoveMemberHasMatchingValidCommitAdmission` — every RPC was
  preceded by a non-aborted commit for the same Machine.

Run with `make verify-remediation-cas-tla`. The model uses
`Machines={m1, m2}, MaxVoters=3` — the smallest configuration that
distinguishes both the concurrent-removal abort path and the
learner-promotion abort path. State count: ~5.6k distinct states,
sub-second on a modern laptop.

How to add a new remediation trace:

1. Record JSONL `trace.SpecRemediation` events using the recorder helpers in
   `test/e2e/internal/tracerecord/recorder.go`:
   - `ReadGate`
   - `CommitAdmission`
   - `CommitAdmissionAborted`
   - `RemoveMemberRPC`
2. Save the fixture under `internal/trace/testdata/`.
3. Add the fixture path to `TestLoadRecordsRemediationFixtures`.
4. Add the fixture path to the `formal-refinement` Make target if it is a
   PASS corpus member.
5. For a FAIL-only synthetic trace (e.g. stale voter count or learner
   promotion at commit-time), keep it in the checker unit tests instead of
   the passing corpus.
