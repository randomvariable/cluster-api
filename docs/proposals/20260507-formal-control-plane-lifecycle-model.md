---
title: Formal model of Cluster API control-plane lifecycle
authors:
  - "@randomvariable"
reviewers:
  - TBD
creation-date: 2026-05-07
last-updated: 2026-05-07
status: provisional
see-also:
  - "/docs/proposals/20191017-kubeadm-based-control-plane.md"
  - "/docs/proposals/20191030-machine-health-checking.md"
  - "/docs/proposals/20240916-improve-status-in-CAPI-resources.md"
replaces: []
superseded-by: []
---

# Formal model of Cluster API control-plane lifecycle

## Table of Contents

- [Glossary](#glossary)
- [Summary](#summary)
- [Motivation](#motivation)
  - [Goals](#goals)
  - [Non-Goals / Future Work](#non-goals--future-work)
- [Proposal](#proposal)
  - [User stories](#user-stories)
  - [Repository layout](#repository-layout)
  - [Methodology](#methodology)
  - [Quint as the source of truth](#quint-as-the-source-of-truth)
  - [Refinement-mapping discipline](#refinement-mapping-discipline)
  - [Contracts](#contracts)
  - [Counterexample ledger](#counterexample-ledger)
  - [CI gating](#ci-gating)
- [Worked example: a stuck etcd learner](#worked-example-a-stuck-etcd-learner)
- [Implementation phases](#implementation-phases)
- [Drawbacks](#drawbacks)
- [Alternatives](#alternatives)
- [Upgrade strategy](#upgrade-strategy)
- [Glossary references](#glossary-references)

## Glossary

- **Quint** — a specification language with an executable simulator and
  Apalache/TLC backends, developed by Informal Systems and licensed
  under Apache 2.0. Models in this proposal are written in Quint
  unless noted.
- **TLA+** — Lamport's temporal logic of actions, used here for
  scheduler-shaped subsystems (priorities, preemption, queues).
- **Lean 4** — interactive theorem prover used for refinement proofs
  that exceed model-checking's scope (parametric refinement,
  informativeness ordering, parametric safety lemmas).
- **Refinement mapping** — a function from concrete states to
  abstract states such that every concrete transition is allowed by
  the abstract specification (Abadi & Lamport, *The Existence of
  Refinement Mappings*, Theoretical Computer Science 82(2):253–284,
  1991).
- **RFC 2119** — IETF normative-keyword vocabulary
  (MUST/SHOULD/MAY/...). Used for upstream-component contracts.
- **Trace** — a finite sequence of observed transitions emitted by a
  running controller, in a JSON wire format compatible with the
  Quint Informal Trace Format (ITF) where possible.
- **Counterexample** — a concrete trace, produced by a model-checker,
  fuzzer, or production telemetry, that violates a stated
  specification invariant.

## Summary

This proposal introduces a `formal/` subtree to the Cluster API
repository containing executable specifications for the
control-plane lifecycle managed by the Kubeadm Control Plane (KCP)
provider. The model covers four interacting state machines —
KCP reconciliation, MachineHealthCheck, kubeadm-join, and the
underlying etcd Raft membership — plus their composition.
Specifications are written primarily in Quint, with TLA+ for
scheduler-shaped subsystems and Lean 4 for refinement and
informativeness lemmas that exceed model-checking's reach. A
Go trace-refinement runtime under `internal/trace/` consumes
controller events and verifies each concrete trace against the
abstract specification.

The model is grounded in three RFC 2119 contracts, each pinned to
a specific upstream commit, that document what KCP relies on from
kubeadm, etcd, and the Machine API.

## Motivation

KCP, MachineHealthCheck, kubeadm, and etcd interact through a
choreography of conditions, events, and gRPC calls. The
choreography has correctness obligations that no single component
documents in full:

- KCP's `canSafelyRemediate` predicate depends on whether every
  unhealthy machine can be matched to an etcd member, which in turn
  depends on whether the machine has reported a node name, which in
  turn depends on whether kubeadm-join completed past
  `NewKubeletStartPhase` and registered the node. A break in any
  link silently disables remediation.
- The `EtcdMemberHealthy` condition surface lost diagnostic
  information when it was migrated from v1beta1 to v1beta2: the
  v1beta1 form carried the underlying gRPC error chain
  (`failed to get etcdStatus...`), the v1beta2 form replaced it with
  a generic `InternalError: Please check controller logs`. This is a
  regression that no contract today forbids.
- Operators encountering these patterns in production cannot tell
  whether the system is behaving correctly (refusing to remediate
  because remediation would be unsafe) or incorrectly (failing to
  remediate because it cannot diagnose the cause). The two look the
  same on the cluster's surface.

A formal model of the choreography turns each of these into a stated
invariant, model-checked at CI time and refined into a runtime trace
checker. When the production system enters a new shape, the
counterexample ledger names the invariant it violated, the
contributors who own it, and the path to closure.

### Goals

1. Express the KCP, MHC, kubeadm-join, and etcd-membership state
   machines as Quint modules whose actions correspond 1:1 with
   existing Go reconciliation steps.
2. State and prove (where decidable) the safety invariants the
   choreography depends on — quorum preservation, learner promotion
   ordering, remediation-only-when-safe, condition-informativeness
   monotonicity (v1beta1 ⊑ v1beta2).
3. Pin the upstream contracts the model assumes — kubeadm-etcd
   wire and CLI surface, etcd Raft membership semantics, KCP's own
   condition surface — to specific upstream commits, with
   line-anchored citations and a re-anchor script.
4. Generate, from the same modules, Go trace-refinement checkers
   that consume controller-runtime events and verify production
   traces against the model.
5. Ledger every counterexample (model-checker, fuzz, or production)
   with a documented closure path.

### Non-Goals / Future Work

- Model the entirety of CAPI. The scope is the KCP-managed
  control-plane lifecycle. Worker-machine flows, infrastructure
  provider state machines, and ClusterClass topology choreography
  are out of scope for this proposal.
- Replace upstream specifications. etcd's Raft has its own TLA+
  spec; we cite it, do not redo it.
- Prove liveness. Initial scope is safety invariants. Liveness
  obligations may be added in a later increment.
- Automate fix derivation. The model identifies invariant
  violations; fixes remain human-authored.

## Proposal

### User stories

#### Story 1 — Operator diagnoses a stuck control plane

An operator sees `KubeadmControlPlane` events reporting
`ControlPlaneUnhealthy` and `OwnerRemediated=False
reason=InternalError`. They invoke `clusterctl describe --explain`
(future work) or run the `trace-validator` CLI against the
controller log. The validator reports:
`InformativenessObligation violated at MHC/DeriveCondition_v1beta2 —
upstream gRPC error chain dropped from condition message`,
plus `IncidentWitness matched — KCP correctly refused to remediate
because the etcd member set could not be matched to the machine
set`. The operator now knows that remediation is correctly inhibited
and that the v1beta2 condition surface is the diagnostic gap.

#### Story 2 — Maintainer adds a new remediation path

A maintainer wants to add a remediation path for the stuck-learner
case (no NodeRef, etcd member exists as a learner, learner stuck).
They add a `RemediateStuckLearner` action to `KCPReconcile.qnt` and
re-run `quint test`. The model-checker either confirms the new
action preserves all stated invariants, or produces a
counterexample. The counterexample is the design feedback the
maintainer needs *before* writing Go code.

#### Story 3 — Reviewer validates a controller change

A reviewer reads a PR that touches KCP's preflight checks. The PR
must include either an updated row in `formal/abstraction-mapping.md`
linking the new Go entry point to a Quint action, or a justification
for why no abstraction-mapping row applies. CI fails if a Quint
action's abstraction-mapping row points to a Go file:line that no
longer exists.

### Repository layout

```text
docs/proposals/
└── 20260507-formal-control-plane-lifecycle-model.md   # this file

formal/
├── README.md                          # entry point
├── Makefile                           # quint / tlc / lean targets
├── specs/                             # Quint + TLA+ source of truth
│   ├── EtcdMembership.qnt
│   ├── KubeadmJoin.qnt
│   ├── KCPReconcile.qnt
│   ├── MachineHealthCheck.qnt
│   ├── Composition.qnt                # imports the four above
│   ├── Remediation.tla                # scheduler shape
│   └── Remediation.cfg
├── proofs/                            # Lean 4 lake project
│   ├── lakefile.lean
│   ├── lean-toolchain
│   └── ControlPlane/
│       ├── Refinement.lean
│       ├── Informativeness.lean
│       └── Safety.lean
├── contracts/
│   ├── kubeadm-etcd-contract.md       # RFC-2119, pinned to k/k SHA
│   ├── kcp-machine-contract.md        # RFC-2119, condition surface
│   ├── etcd-raft-contract.md          # RFC-2119, pinned to etcd SHA
│   ├── commits.yaml                   # pinned upstream SHAs
│   └── relink.py                      # SHA bump helper
├── abstraction-mapping.md             # Action ↔ Go file:line
└── counterexample-log.md              # incident ledger

internal/trace/                        # Go runtime
├── record.go
├── recorder.go
├── itf.go
├── verdict.go
└── checkers/
    ├── etcd_membership.go
    ├── kubeadm_join.go
    ├── kcp_reconcile.go
    └── mhc.go

hack/tools/trace-validator/
└── main.go                            # CLI: trace JSON Lines → verdict

scripts/
└── verify-formal.sh                   # CI gate
```

### Methodology

The choice of three formal tools is deliberate, not redundant:

- **Quint** for the core state machines. Quint compiles to TLA+ and
  also runs an executable simulator, which makes the same source
  serve both as a model-checking input and as a generator of
  example traces for review and demo. The four core modules
  (`EtcdMembership`, `KubeadmJoin`, `KCPReconcile`,
  `MachineHealthCheck`) plus their composition are written here.
- **TLA+** directly for `Remediation.tla`. This subsystem has
  scheduler shape (queues, priorities, preemption) where TLC's
  state-space exploration paired with the action-composition idiom
  in TLA+ is more economical than the Quint equivalent. The result
  remains compatible: Quint compiles to TLA+, and TLC can check
  composed specifications across both notations.
- **Lean 4** for two obligations that exceed model-checking:
  parametric refinement (every Quint trace concretises to a Go
  trace) and informativeness ordering (v1beta1 condition projection
  is at least as informative as v1beta2). These are quantified
  over an unbounded domain — model checkers cannot decide them.

The Go trace runtime is a separate, independent reimplementation in
the implementation language. This is not redundant: the runtime
encodes the *checker*, not the spec, and its job is to reject
production traces that violate the spec — exactly the abstraction-
mapping discipline of Abadi & Lamport (1991).

### Quint as the source of truth

When a Go controller's behaviour and a Quint module's behaviour
diverge, one of them is wrong. The convention this proposal
adopts is:

> The Quint module is normative for *what should happen*; the Go
> controller is normative for *what does happen*. Divergence is
> resolved by either changing the Go controller (the common case)
> or filing an ADR-style amendment to the Quint module (rare). The
> abstraction-mapping table is the contract.

This convention is borrowed from Lampson's *How to Build a Highly
Available System Using Consensus* (1996, §1) and is the same
discipline applied by formally-verified systems including
seL4, IronClad, and Project Everest.

### Refinement-mapping discipline

`formal/abstraction-mapping.md` contains one row per Quint or TLA+
*action*. Each row names:

| Spec | Action | Go reference | Purpose |

The Go reference is `path/to/file.go:LINE` pointing at the entry
point that refines the action. Maintenance rules:

1. Add a new row whenever a new action is introduced in any spec.
2. Update the row whenever the Go entry point moves. Stale rows
   are correctness bugs, not documentation debt.
3. CI gate: every Go reference MUST resolve. Removed Go entry
   points fail the gate.

This is the same discipline used by the seL4 functional-correctness
proof (Klein et al., SOSP 2009, §5).

### Contracts

The model assumes upstream behaviour from three components. Each
assumption is documented in an RFC 2119 contract, anchored to a
specific upstream commit, with line-range citations.

- `formal/contracts/kubeadm-etcd-contract.md` — what KCP and the
  generated etcd static-pod manifest assume about kubeadm.
- `formal/contracts/etcd-raft-contract.md` — what KCP assumes about
  etcd's Raft membership semantics, in particular the
  AddLearner→Promote sequence and the leader-side promote
  eligibility check.
- `formal/contracts/kcp-machine-contract.md` — what callers assume
  about KCP's own condition surface (v1beta1 and v1beta2).

Pinned commits live in `formal/contracts/commits.yaml`. The
`formal/contracts/relink.py` helper bumps a pin and rewrites the
links across `contracts/*.md`, warning if a target line range no
longer matches by content fingerprint.

### Counterexample ledger

`formal/counterexample-log.md` is a markdown ledger with the schema
below. Every model-checker counterexample, fuzz finding, or
production-traced violation gets a row.

| Date | Spec | Action | Classification | Severity | Status | Fix link | Evidence | Notes |

Status workflow: `Open → Reproduced-Test-Written →
Fixed-In-Implementation → Closed-Verified`. Rows are append-only;
closure does not delete. The discipline here matches the
[Linux kernel's regression-tracking model](https://www.kernel.org/doc/html/latest/admin-guide/reporting-regressions.html).

The inaugural row is the InformativenessObligation counterexample
produced by the user-reported stuck-learner incident.

### CI gating

`scripts/verify-formal.sh` is wired into existing CI verification.
It runs:

1. `quint typecheck` on every `formal/specs/*.qnt`.
2. `quint test` on every Quint module that defines `runs`.
3. `lake build` in `formal/proofs/` (skipped with explicit notice
   if Lean is unavailable in the environment).
4. `tlc -config <m>.cfg <m>.tla` on every TLA+ module that has a
   `.cfg` (also skipped with explicit notice if TLC is unavailable).
5. `go build ./hack/tools/trace-validator/...` and
   `go vet ./internal/trace/...`.
6. Drift check: every action declared in any Quint module has a
   row in `formal/abstraction-mapping.md`.

The gate is non-blocking on tool absence — it never silently passes;
it reports `SKIP: quint not in PATH (install: ...)` so reviewers
know what coverage they have on a given run.

## Worked example: a stuck etcd learner

The user-reported incident under
`KubeadmControlPlane=ns-vault-prod-ky8ns/kvp22096-98cda1-fpx9t`
exercises the model end-to-end:

1. `KubeadmJoin` reaches `KubeletStart` but `EtcdJoinAddLearner`
   succeeds and `WaitForEtcdQuorum` blocks: the learner never
   promotes.
2. `MachineHealthCheck` observes `EtcdMemberHealthy=Unknown` on the
   leader's machine and `NodeRef=∅` on the learner's machine.
3. `KCPReconcile` runs preflight, finds an unhealthy machine that
   cannot be matched to an etcd member (because the learner's
   node name is unknown), computes `canSafelyRemediate=false`, and
   inhibits remediation.

The model expresses this as the `IncidentWitness` invariant in
`formal/specs/Composition.qnt`:

```quint
val IncidentWitness =
  forall m1, m2 in Machine.
    SameKCP(m1, m2) and
    m1.NodeRef == None and
    EtcdMemberHealthy(m2) == Unknown and
    EtcdLearnerOf(m1) and not EtcdPromoted(m1)
    implies
      not canSafelyRemediate and KCP.preflightBlocked
```

This is a *positive* invariant — KCP's behaviour is correct given
the inputs. The corresponding *negative* finding is the
`InformativenessObligation`:

```quint
val InformativenessObligation =
  forall s in KCPState.
    informativeness(project_v1beta1(s))
      <= informativeness(project_v1beta2(s))
```

The incident produces a counterexample because v1beta2's
`reason=InternalError, message="Please check controller logs"`
loses the gRPC error chain that v1beta1's
`message="failed to get etcdStatus for workload cluster ..."`
preserved. The counterexample is filed against the model and
becomes the design input for whoever fixes the v1beta2 condition
projection.

## Implementation phases

The `formal/` subtree lands in increments. Each increment is
independently useful and reviewable.

| Phase | Deliverable | Status gate |
|---|---|---|
| **0 — proposal + scaffold** | This CAEP, `formal/` directory tree with READMEs, `Makefile`, contracts skeletons, abstraction-mapping skeleton, counterexample-log skeleton. | CAEP merged; scaffold passes drift check. |
| **1 — core specs** | The four Quint modules + Composition. `IncidentWitness` model-checks. `InformativenessObligation` produces a counterexample matching the user-reported incident. | `quint typecheck` clean; `quint test` runs; counterexample-log row inaugurated. |
| **2 — contracts** | The three RFC-2119 contracts, line-anchored to pinned commits. `relink.py` working. | Contracts review-complete; pins recorded in `commits.yaml`. |
| **3 — proofs** | Lean 4 lake project. `Refinement.lean` skeleton; `Informativeness.lean` proof of the partial-order; `Safety.lean` proof of `canSafelyRemediate ⇒ quorum-preserving`. | `lake build` clean. |
| **4 — runtime** | Go trace-refinement runtime + `trace-validator` CLI. Per-checker tests. | `go build` and `go test` clean; CI gate active. |
| **5 — TLA+ remediation** | `Remediation.tla` + `.cfg`; TLC checks all stated invariants. | TLC run clean. |
| **6 — telemetry** | Controller-runtime event tap emits `TraceRecord` JSON Lines. `clusterctl describe --explain` (future work) consumes the same trace. | Optional; see future-work issues. |

## Drawbacks

1. **Tool surface.** Three formal tools (Quint, TLA+, Lean) plus a
   Go runtime is more surface area than CAPI maintainers have
   historically maintained. The verify gate is non-blocking on tool
   absence to mitigate, but the maintenance burden is real.
2. **Drift risk.** Every controller change that touches a modelled
   action must update the abstraction-mapping row. The CI drift
   check makes this enforceable but adds review overhead.
3. **Skill ceiling.** Model-checking and Lean proofs raise the
   contributor bar for a subset of changes. The proposal mitigates
   by scoping formal artefacts narrowly: the abstraction-mapping
   table is the contract a typical contributor interacts with;
   only formal-stack changes touch the spec sources.

## Alternatives

- **Annotation-only ADRs.** Document choreography in markdown
  without an executable model. Rejected: the user-reported
  incident reveals exactly the kind of multi-component invariant
  that survives a markdown review and fails in production.
- **Property-based tests only.** Use `gopter` or similar in Go.
  Rejected: property-based tests are random; model-checking is
  exhaustive over a bounded state space, and Lean proves
  parametric obligations a Go test cannot express.
- **TLA+ only.** Drop Quint. Rejected: Quint's executable
  simulator and lower notational overhead make the spec accessible
  to reviewers who do not write TLA+ daily. The CAPI contributor
  base is the deciding factor.
- **External repository.** Maintain `formal/` as a separate repo.
  Rejected: drift between an external spec and CAPI's Go controllers
  is the failure mode this proposal exists to eliminate.

## Upgrade strategy

The `formal/` subtree is additive — no existing CAPI artefacts
change in Phase 0 or Phase 1. Phases 2–5 add CI gates that are
non-blocking on tool absence. Phase 6 introduces an opt-in event
tap; existing controllers run unchanged when the tap is disabled.

## Glossary references

- Abadi, M. and Lamport, L. *The Existence of Refinement
  Mappings.* Theoretical Computer Science, 82(2):253–284, 1991.
- Cerone, A., Bernardi, G. and Gotsman, A. *A Framework for
  Transactional Consistency Models with Atomic Visibility.*
  Journal of the ACM 65(2):11, 2018.
- IETF RFC 2119. *Key words for use in RFCs to Indicate
  Requirement Levels.* March 1997.
- Klein, G. et al. *seL4: Formal Verification of an OS Kernel.*
  SOSP 2009.
- Lamport, L. *Specifying Systems.* Addison-Wesley, 2002.
- Lampson, B. *How to Build a Highly Available System Using
  Consensus.* WDAG 1996.

<!-- markdownlint-disable-file MD013 MD024 -->
