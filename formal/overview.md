# formal/ — overview and reading order

This subtree is a layered formal-modelling corpus for Cluster API.
It pairs Quint specifications of controller-runtime, KCP, etcd
membership, kubeadm-join, ClusterTopology + runtime extensions,
MachineSet preflight, in-place machine updates, MachineHealthCheck,
and an end-to-end cluster lifecycle, with TLC / Apalache
verification, a Go trace-refinement runtime, RFC-2119 contracts
pinned to upstream commits, Lean 4 deductive proofs, and a
working CAPD e2e reproducer.

The CAEP at
[`docs/proposals/20260507-formal-control-plane-lifecycle-model.md`](../docs/proposals/20260507-formal-control-plane-lifecycle-model.md)
is the original entry point (written when the corpus was KCP-only).
The corpus has since grown to cover the full Cluster API surface;
[`README.md`](./README.md) sketches the present layered scope.

## Layered architecture

The specs split into four layers; reading them in this order
mirrors the dependency graph.

```text
Layer 3 (E2E):           ClusterE2E.qnt
                                ▲
                                │ uses
Layer 2 (refinements):   TopologyRefined.qnt
                         InPlaceUpdateRefined.qnt
                         MachineSetPreflightRefined.qnt
                                ▲
                                │ refines onto
Layer 0 (substrate):     ControllerRuntime.qnt
                                ▲
                                │ underpins
Layer 1 (per-component abstract specs):
   Lifecycle.qnt + EtcdMembership / KubeadmJoin / KCPReconcile / MachineHealthCheck / Composition
   Topology.qnt
   MachineSetPreflight.qnt
   InPlaceUpdate.qnt
   SelfHosted.qnt + Lifecycle.multicluster.qnt   (FM-35 self-hosted topology)
```

## Reading order

For a code reviewer:

1. [`overview.md`](./overview.md) (this file) — what's here, why.
2. [`test-corpus-spec.md`](./test-corpus-spec.md) — MoSCoW prioritisation, feature model, definition of done.
3. [`failure-modes.md`](./failure-modes.md) — catalogue of FM-1..FM-50 covering all four CAPI controller domains.
4. [`issue-corpus.md`](./issue-corpus.md) — model-found issues classified by component + severity.
5. [`upstream-issues-research.md`](./upstream-issues-research.md) — GitHub-issue mining; informs the FM corpus.
6. [`lsp-grounding.md`](./lsp-grounding.md) — methodology for LSP-grounded refinement anchors.
7. [`abstraction-mapping.md`](./abstraction-mapping.md) — per-action refinement-mapping table (the canonical reference).
8. [`dst-methodology.md`](./dst-methodology.md) — fault catalogue mapping abstract actions to docker primitives.
9. [`e2e-blueprints.md`](./e2e-blueprints.md) — CAPD e2e spec sketches.
10. [`verify-runbook.md`](./verify-runbook.md) — copy-paste commands to reproduce every TLC / Apalache / random-walk verdict.
11. [`counterexample-log.md`](./counterexample-log.md) — append-only ledger for spec violations.
12. **Layer 0 substrate**: [`specs/ControllerRuntime.qnt`](./specs/ControllerRuntime.qnt) — controller-runtime worker pool + workqueue + leader election + cache.
13. **Layer 1 per-component**:
    - [`specs/Lifecycle.qnt`](./specs/Lifecycle.qnt) — KCP/etcd/kubeadm-join lifecycle (the original spec).
    - [`specs/Topology.qnt`](./specs/Topology.qnt) — ClusterTopology reconciler + runtime-extension lifecycle hooks.
    - [`specs/MachineSetPreflight.qnt`](./specs/MachineSetPreflight.qnt) — worker MachineSet preflight gating.
    - [`specs/InPlaceUpdate.qnt`](./specs/InPlaceUpdate.qnt) — in-place machine update choreography.
    - [`specs/SelfHosted.qnt`](./specs/SelfHosted.qnt) + [`Lifecycle.multicluster.qnt`](./specs/Lifecycle.multicluster.qnt) — FM-35 self-hosted topology.
14. **Layer 2 refinements**: [`TopologyRefined.qnt`](./specs/TopologyRefined.qnt), [`InPlaceUpdateRefined.qnt`](./specs/InPlaceUpdateRefined.qnt), [`MachineSetPreflightRefined.qnt`](./specs/MachineSetPreflightRefined.qnt) — abstract specs composed onto the controller-runtime substrate.
15. **Layer 3 E2E**: [`specs/ClusterE2E.qnt`](./specs/ClusterE2E.qnt) — end-to-end bring-up + topology hooks + rolling/in-place upgrades.

For a contributor adding a new failure mode:

1. Identify the controller domain (KCP / Topology / MachineSet /
   InPlace / cross-cutting) and pick the right spec module.
2. Read `dst-methodology.md` §2 to identify the docker primitive
   if the FM is exogenous.
3. Add the init action / fault action in that module; verify
   with `quint typecheck`.
4. Add an entry in `failure-modes.md` (the next free FM-N).
5. Add an `IC-NN` row in `issue-corpus.md` if there's a
   corresponding upstream gap.
6. Run `quint verify --backend=tlc` for reachability under
   `step` and `--backend=apalache` under `stepNoRecovery` (when
   applicable) for hopelessness.
7. Add abstraction-mapping rows in `abstraction-mapping.md` for
   any new actions.
8. Add a `make verify-fmN` (or `verify-<scenario>`) target in
   the Makefile.

## What's verified

| FM range | Spec module | Verdicts |
|---|---|---|
| FM-1..FM-24 | `specs/Lifecycle.qnt` + companions | 19 with TLC reachability; 6 with Apalache hopelessness (FM-2/3/13/16/17/23); 1 CAPD e2e PASS (FM-2) |
| FM-31/32/34/37 | `specs/Lifecycle.qnt` (custom Node conditions, webhook rotation, MHC cache, lifecycle hooks) | TLC reachability via dedicated init actions |
| FM-9 | `proofs/ControlPlane/Convergence.lean` | Lean 4 deductive recurrence proof (5 theorems, no `sorry`) |
| FM-33 | `specs/MachineSetPreflight.qnt` | 3 demo runs verify CP-stable + version-skew gating |
| FM-35 | `specs/SelfHosted.qnt` + `Lifecycle.multicluster.qnt` | Per-cluster deadlock + recovery traces |
| FM-39/40/41 | `specs/Topology.qnt` | Multi-step hook ordering, annotation gating, AfterClusterUpgrade quiescence |
| FM-42/43/44 | `specs/InPlaceUpdate.qnt` | Premature admission, hook idempotence, multi-extension fast-fail |
| FM-45/46/47 | `specs/ControllerRuntime.qnt` | Per-key serialisation under multi-worker, TerminalError no-requeue, cache lag |
| FM-48/49/50 | `specs/ClusterE2E.qnt` | No CP before InfraReady, no workers before CPInit, endpoint monotonicity |

50 failure modes total. Per-spec verdicts:

| Spec module | Demo runs | Random-walk sweep | Apalache | CAPD e2e |
|---|---|---|---|---|
| Lifecycle.qnt | 19 inits | 5000×30 across SafetyInvariants | 6 hopelessness verdicts (FM-2/3/13/16/17/23) | 1 PASS |
| Topology.qnt | 5 | 200×30 | **10/10 invariants** at depth 4 | — |
| MachineSetPreflight.qnt | 3 | (deterministic) | — | — |
| InPlaceUpdate.qnt | 5 | 2000×80 | **9/9 invariants** at depth 4 (FM-42 also at depth 8) | — |
| ControllerRuntime.qnt | 6 | 500×60 | **7/7 invariants** at depth 4 (FM-45 also at depth 8) | — |
| 3 refined modules | 6 | 300×40 each | — | — |
| ClusterE2E.qnt | 3 | 300×60 | **11/11 invariants** at depth 4 | — |

Total: ~50 demo runs, ~3000 actions covered by random walks, 178
abstraction-mapping rows under the drift check.

## Closed gaps

The corpus has progressed through several phases of expansion:

| Phase | Closure |
|---|---|
| 1 | Transient bounds (start/end/infra causes) for FM-4, 6, 7, 10, 15, 18, 19, 21, 24 |
| 2 | Etcd leader-following: `LeaderStepDown`, `TransferLeadership`, `RemoveMember` gated on leader ≠ id |
| 3 | Kubeadm join phases expanded from 7 to 16; kubelet local Node registration; CRI-bound flags |
| 4 | `drainBlocked` + `pdbViolatedFor` flags; `BeginDrain` / `DrainTimeout`; LSP-grounded in CAPI Machine controller drain |
| 4b | `criRuntimeReady`, `criImagesPulled`, `criPodSandboxRunning`, `criContainersRunning`; ContainerdReady/Crash/PullStaticPodImages/CreatePodSandbox/StartStaticPodContainers |
| 5 | FM-23 Apalache safety verdict (`AllSafetyInvariants` holds at depth 4 under stepNoRecovery, ~278 s) |
| 6 | IC-11 deterministic recovery: `upgradeRollbackRecoveryRun` reaches `HealthyControlPlane` |
| 7 | FM-31 `customCondition` + `CustomConditionObserved` action |
| 8 | FM-32 `webhooksAvailable` + `WebhookRotationFault` / `WebhookHeal` |
| 9 | FM-34 `mhcCacheStale` + `MhcCacheStale` / `MhcCacheRefresh` |
| 10 | FM-37 `hooksTriggered` + `TriggerPreUpgradeHook` |
| 11 | FM-9 `ConvergenceFair` temporal property + Lean 4 deductive proof |
| 12 | FM-35 dual-cluster `SelfHosted.qnt` + `Lifecycle.multicluster.qnt` per-cluster expansion |
| 13 | FM-33 worker-MachineSet preflight (`MachineSetPreflight.qnt`) |
| 14 | FM-39/40/41 Topology + runtime extensions (`Topology.qnt`) |
| 15 | FM-42/43/44 in-place machine updates (`InPlaceUpdate.qnt`) |
| 16 | FM-45/46/47 controller-runtime substrate (`ControllerRuntime.qnt`) + 3 refinement modules |
| 17 | FM-48/49/50 end-to-end cluster lifecycle (`ClusterE2E.qnt`) |
| 18 | Apalache hopelessness on the four newer specs (issue #1): 37 invariants verified at depth 4. Refactor to `Topology.qnt` to replace dynamic `(cpV+1).to(tV)` with constant-bounded filter (Apalache parser limitation). Make targets `verify-{cr,topology,inplace,e2e}-apalache`. |

Plus apiserver↔etcd modelling (`apiserverEtcdReachable`,
`apiserverReady`, `etcdCompactionInProgress`, etc.) and
LSP-grounded refinement anchors across:

- `internal/controllers/cluster/cluster_controller_phases.go`
- `internal/controllers/machine/{machine_controller, drain/drain.go, machine_controller_inplace_update}.go`
- `internal/controllers/machineset/machineset_{controller,preflight}.go`
- `internal/controllers/machinedeployment/machinedeployment_{controller,canupdatemachineset,rollout_*}.go`
- `internal/controllers/topology/cluster/{cluster_controller,reconcile_state}.go`
- `controlplane/kubeadm/internal/controllers/{controller,scale,remediation}.go`
- `controlplane/kubeadm/internal/{workload_cluster,workload_cluster_etcd,workload_cluster_conditions}.go`
- `exp/topology/desiredstate/{desired_state,upgrade_plan,lifecycle_hooks}.go`
- `internal/hooks/tracking.go`
- `pkg/internal/controller/controller.go`,
  `pkg/controller/priorityqueue/priorityqueue.go`,
  `pkg/manager/internal.go`,
  `pkg/{reconcile,source,handler,predicate,cache,client}/*.go`
  (controller-runtime substrate)
- Upstream Kubernetes: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/`,
  `pkg/server/healthz`, `pkg/kubelet/{kubelet_node_status, kuberuntime}/`,
  `cmd/kubeadm/app/cmd/phases/join/`

## Remaining gaps

| Gap | Where documented |
|---|---|
| Most FMs lack e2e specs (5 are blueprinted) | `e2e-blueprints.md` |
| FM-9 fairness verdict beyond TLC's 16-conjunct cap (Lean 4 deductive proof closes this; TLC capacity gap remains) | `failure-modes.md` FM-9 §"Phase 11d" |
| End-to-end refinement onto controller-runtime substrate (ClusterE2E.qnt is abstract; a `ClusterE2ERefined.qnt` would compose with the substrate but is not yet built) | (open) |

## Tooling state

| Tool | Version pinned | Purpose |
|---|---|---|
| Quint | 0.32.0 | Source of truth for the model |
| TLC | 2.18+ via `quint verify --backend=tlc` | Exhaustive reachability checking |
| Apalache | via `quint verify --backend=apalache` | Symbolic hopelessness proofs |
| Lean 4 | v4.16.0 | Deductive proofs (FM-9 fairness, refinement scaffolding) |
| gopls | (mcp) | LSP-grounded refinement anchors |
| CAPD + Kind | v1.34.0 (local override; main pins v1.36.0) | e2e cluster substrate |

## CI gate

`scripts/verify-formal.sh` runs:

1. `quint typecheck` on every `.qnt`.
2. `quint run` with declared `runs`.
3. `lake build` in `formal/proofs/`.
4. `tlc` against `.tla` + `.cfg` pairs.
5. `go build / test / vet` of `internal/trace` + `hack/tools/trace-validator`.
6. Drift check: every Quint action has an abstraction-mapping row.

The gate is non-blocking on tool absence — it reports `SKIP`
rather than silent success. Currently 178 actions covered by
the drift check.

## Branch

The corpus lives on the `formality` branch in the user's fork.
No upstream push, no PR.
