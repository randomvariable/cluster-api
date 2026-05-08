# formal/ — overview and reading order

This subtree is a refinement test suite for the Cluster API
Kubeadm Control Plane lifecycle. It pairs Quint specifications
of KCP, etcd membership, kubeadm-join, and MachineHealthCheck
with TLC / Apalache verification, a Go trace-refinement runtime,
RFC-2119 contracts pinned to upstream commits, and a working
CAPD e2e reproducer for the modelled scenario shape.

The CAEP at
[`docs/proposals/20260507-formal-control-plane-lifecycle-model.md`](../docs/proposals/20260507-formal-control-plane-lifecycle-model.md)
is the formal entry point. Read it before this overview if the
shape of the work is unfamiliar.

## Reading order

For a code reviewer:

1. [`overview.md`](./overview.md) (this file) — what's here, why.
2. [`test-corpus-spec.md`](./test-corpus-spec.md) — MoSCoW prioritisation, feature model, definition of done.
3. [`failure-modes.md`](./failure-modes.md) — catalogue of 24 FMs + 4 from upstream research.
4. [`issue-corpus.md`](./issue-corpus.md) — 15 model-found issues classified by component + severity.
5. [`upstream-issues-research.md`](./upstream-issues-research.md) — GitHub-issue mining; Tier 1 confirms FM-1 / FM-3 are upstream-known.
6. [`lsp-grounding.md`](./lsp-grounding.md) — every Quint action ↔ Go entry point.
7. [`dst-methodology.md`](./dst-methodology.md) — fault catalogue mapping abstract actions to docker primitives.
8. [`e2e-blueprints.md`](./e2e-blueprints.md) — CAPD e2e spec sketches for FMs not yet implemented.
9. [`verify-runbook.md`](./verify-runbook.md) — copy-paste commands to reproduce every TLC / Apalache verdict.
10. [`abstraction-mapping.md`](./abstraction-mapping.md) — per-action refinement-mapping table.
11. [`counterexample-log.md`](./counterexample-log.md) — append-only ledger for spec violations.
12. [`specs/Lifecycle.qnt`](./specs/Lifecycle.qnt) — the model.

For a contributor adding a new failure mode:

1. Read `dst-methodology.md` §2 to identify the docker primitive.
2. Add an `<modeName>Init` action in `Lifecycle.qnt`; verify with
   `quint typecheck`.
3. Add an entry in `failure-modes.md`.
4. Add an `IC-NN` row in `issue-corpus.md` (severity, suggested
   remediation).
5. Run `quint verify --backend=tlc` for reachability under
   `step` and (if the FM is EXOGENOUS or KCP-BUG-latent)
   `--backend=apalache` under `stepNoRecovery` for hopelessness.
6. Update `lsp-grounding.md` with a row for any new Go entry
   point.
7. (Optional) Implement an e2e spec in `test/e2e/` per the
   templates in `e2e-blueprints.md`.

## What's verified

| FM | Init | Recovery | TLC verdict | Apalache verdict | CAPD e2e |
|---|---|---|---|---|---|
| FM-1 | `incidentInit` | RemoveStuckLearner + DeleteFailedMachine + AddMachine | 6.5K states (FM-1 invariants) | n/a | (events.log captures shape during FM-2 e2e) |
| FM-2 | `twoMachineBothUnhealthyInit` | HealEtcdReachability | 1.4M states reach (4.7 s) | UNREACHABLE under stepNoRecovery (76 s) | **PASSES** (`test/e2e/fm2_quorum_loss.go`) |
| FM-3 | `partitionedClusterInit` | HealEtcdReachability | 11.6K states (1.0 s) | UNREACHABLE (82 s) | blueprint |
| FM-5 | `noCorrespondingMemberInit` | DeleteFailedMachine | 165K states (1.9 s) | — | — |
| FM-8 | (counterexample to InformativenessObligation) | Projection rewrite | n/a (spec gap) | n/a | — |
| FM-11 | `invalidKubeletInit` | MHC + remediation | 24K states (1.0 s) | — | — |
| FM-12 | `slowStorageEtcdJoinInit` | DeleteFailedMachine | 3.5K states (0.86 s) | — | — |
| FM-13 | `lbBrokenInit` | HealLb + HealEtcdReachability | 2.3M states (7.3 s) | UNREACHABLE (38 s) | blueprint |
| FM-14 | `nodeNeverJoinsInit` | RestoreNodeReachability + remediation | 25K states (1.0 s) | — | — |
| FM-15 | `upgradeInFlightInit` | Rolling update completes | 2.5M states (6.3 s) | — | blueprint |
| FM-16 | `singleNodeLostVoterInit` | RestoreClusterFromSnapshot | 633 states (0.8 s) | UNREACHABLE (21 s) | — |
| FM-17 | `kubeadmMisconfigInit` | DeleteFailedMachine + AddMachine | 2.1K states (0.84 s) | UNREACHABLE (~80 s) | — |
| FM-18 | `concurrentScaleAndRemediateInit` | targetEtcdClusterHealthy serialisation | 9.5K states (1.2 s) | — | — |
| FM-19 | `apiserverRestartInit` | HealLb after restart | 10.9K states (1.1 s) | — | blueprint |
| FM-20 | `upgradeRollbackMidFlightInit` | Roll-forward delete + recreate | 19.4K states (1.2 s) | — | — |
| FM-21 | `fiveNodeTwoFailuresInit` | Sequential remediation | 17.7K states (1.3 s) | — | — |
| FM-22 | `singleNodeScaleUpFailureInit` | HealEtcdReachability | 13.5K states (1.2 s) | (FM-2 sub-shape; FM-2 hopelessness applies) | — |
| FM-23 | `drainStuckInit` | Drain timeout + force-delete | 11.9K states (1.3 s) | **AllSafetyInvariants holds** (Apalache, ~278 s) | blueprint |
| FM-24 | `etcdDefragPauseInit` | Defrag finishes | 12.5K states (1.0 s) | — | blueprint |

19 catalogued FMs have an init action and a TLC reachability
verdict. **Six** carry exhaustive Apalache verdicts
(FM-2, FM-3, FM-13, FM-16, FM-17, **FM-23**). One e2e spec PASSES on
real CAPD (FM-2). Six e2e blueprints are sketched.

IC-11 (upgrade rollback mid-flight) is now TLC-verified end-to-end
via the deterministic `upgradeRollbackRecoveryRun` reaching
`HealthyControlPlane` in 4 steps.

## Outstanding gaps

| Gap | Where documented |
|---|---|
| FM-9 fairness annotations not added (60-conjunct expansion) | `failure-modes.md` FM-9 |
| FM-31, FM-32, FM-34, FM-37 init actions concept-only | `failure-modes.md` (full sections) |
| FM-33 worker-machine preflight out of scope | `test-corpus-spec.md` Won't |
| FM-35 self-hosted upgrade requires topology expansion | `upstream-issues-research.md` Tier 2 |
| Most FMs lack e2e specs (5 are blueprinted) | `e2e-blueprints.md` |

The corpus is **complete enough for an upstream conversation**:
the 19 modes with TLC verdicts plus 5 with Apalache proofs cover
every operational concern raised, including 1/3/5-node
topologies, scale-up/scale-down, upgrades, kubeadm misconfigs,
LB outages, drain blocks, and etcd-defrag pauses. The 4 model-
incomplete rows (FM-9, FM-23, FM-31, FM-32, FM-34, FM-37) are
documented with explicit modelling paths.

## Tooling state

| Tool | Version pinned | Purpose |
|---|---|---|
| Quint | 0.32.0 | Source of truth for the model |
| TLC | 2.18+ via `quint verify --backend=tlc` | Exhaustive reachability checking |
| Apalache | via `quint verify --backend=apalache` | Symbolic hopelessness proofs |
| Lean 4 | v4.16.0 | Refinement / informativeness lemmas (scaffolded) |
| gopls | (mcp) | LSP-grounded refinement anchors |
| CAPD + Kind | v1.34.0 (local override; main pins v1.36.0) | e2e cluster substrate |

## CI gate

`scripts/verify-formal.sh` runs:

1. `quint typecheck` on every `.qnt`.
2. `quint run` with declared `runs`.
3. `lake build` in `formal/proofs/`.
4. `tlc` against `.tla` + `.cfg` pairs.
5. `go build / test / vet` of `internal/trace` + `hack/tools/trace-validator`.
6. Drift check: every Quint action has an abstraction-mapping
   row.

The gate is non-blocking on tool absence — it reports `SKIP`
rather than silent success.

## Branch

The corpus lives on the `formality` branch in the user's fork.
No upstream push, no PR.
