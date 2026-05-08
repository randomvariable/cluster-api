# LSP-grounded refinement anchors

Each abstract action in `formal/specs/Lifecycle.qnt` (and the
related per-module specs) is grounded in a real Go entry point in
this repository. The references below were resolved with the
gopls language server (`mcp__gopls__go_search` /
`go_symbol_references`) at the SHA recorded in
`formal/contracts/commits.yaml` under `repos.cluster-api.sha`
(`HEAD`). Treat any reference that no longer resolves as a stale
row — file a counterexample-log entry with `Spec=lsp-grounding`,
`Action=<row id>`, and patch.

The point of this file is methodological: every abstraction-
mapping row in `formal/abstraction-mapping.md` should be backed
by a gopls-resolvable symbol, not a free-text path. When a Go
function moves or is renamed, the LSP-resolved entry point is
where reviewers should look first to confirm the mapping is
still sound.

## Refinement anchors — KCP reconcile path

| Quint action / predicate | Go entry point | Notes |
|---|---|---|
| `KCPReconcile.RequestRemediation`, `EvaluateCanSafelyRemediate` | [`KubeadmControlPlaneReconciler.reconcileUnhealthyMachines`](../controlplane/kubeadm/internal/controllers/remediation.go#L54) | Driver for the whole remediation flow; the `EvaluateCanSafelyRemediate` action is the synchronisation point on `canSafelyRemediateMachine`. |
| `Lifecycle.targetEtcdClusterHealthy` | [`KubeadmControlPlaneReconciler.targetEtcdClusterHealthy`](../controlplane/kubeadm/internal/controllers/remediation.go#L692) | Direct port of the Go helper. The pure-def matches the algorithm: `targetVoters = voters - to_delete + (1 if add_member else 0)`, `targetQuorum = targetVoters/2 + 1`, refuse when `targetLearners > 0`. |
| `Lifecycle.canSafelyRemediate` (folded into `EvaluateCanSafelyRemediate`) | [`KubeadmControlPlaneReconciler.canSafelyRemediateMachine`](../controlplane/kubeadm/internal/controllers/remediation.go#L595) | Wraps `targetEtcdClusterHealthy` plus the matchable-set check (`compareMachinesAndMembers` via `tryGetEtcdMemberName`). |
| `KCPReconcile.tryGetEtcdMemberName` | [`KubeadmControlPlaneReconciler.tryGetEtcdMemberName`](../controlplane/kubeadm/internal/controllers/remediation.go#L640) | The matchable-set lookup. Returns empty string when no Machine matches the etcd member by node name — exactly the FM-1 state. |
| `KCPReconcile.ScaleUpControlPlane` | [`KubeadmControlPlaneReconciler.scaleUpControlPlane`](../controlplane/kubeadm/internal/controllers/scale.go#L67) | The Go function gates on `targetEtcdClusterHealthy(addEtcdMember=true)` indirectly via preflight; the model gates explicitly. |
| `KCPReconcile.ScaleDownControlPlane` | [`KubeadmControlPlaneReconciler.scaleDownControlPlane`](../controlplane/kubeadm/internal/controllers/scale.go#L106) | Same gate as scale-up but with `addEtcdMember=false, etcdMemberToBeDeleted=m`. |
| `KCPReconcile.ReconcileEtcdMembers` (cleanup of orphan etcd members) | [`KubeadmControlPlaneReconciler.reconcileEtcdMembers`](../controlplane/kubeadm/internal/controllers/controller.go#L1233) | Reaper for etcd members without a matching Machine. Not modelled directly; relevant for FM-5. |

## Refinement anchors — etcd membership

| Quint action | Go entry point | Notes |
|---|---|---|
| `EtcdMembership.RemoveMember` (and `Lifecycle.RemoveStuckLearner`) | [`Workload.RemoveEtcdMember`](../controlplane/kubeadm/internal/workload_cluster_etcd.go#L56) | The Go function calls `Cluster.MemberRemove` via etcd v3 gRPC. Refinement: the model's `RemoveMember` has the post-state quorum guard; the Go function delegates to etcd's runtime check. |
| `EtcdMembership.TransferLeadership` (and `Lifecycle.TransferLeadership`) | [`Workload.ForwardEtcdLeadership`](../controlplane/kubeadm/internal/workload_cluster_etcd.go#L96) | Refines the etcd `MoveLeader` RPC. KCP calls this from `scaleDownControlPlane` before `RemoveEtcdMember` whenever the target is the current leader. The model's `RemoveMember` precondition (`leaderAt[currentTerm] != id`) gates removal of the current leader, forcing the controller to call this first. Contract: R-LEAD-STEP-DOWN. |
| `EtcdMembership.LeaderStepDown` (and `Lifecycle.LeaderStepDown`) | (no direct entry point — passive lease-lapse semantics inside etcd) | Refines etcd's lease-lapse: when the leader's `memberHealth` flips to `Unhealthy` / `UnknownHealth` or the leader is removed out-of-band, the term advances with no leader at the new term. Observable from KCP's side via `Status.leader` returning a different id, or via the absence of any leader after a partition heal. Contract: R-LEAD-STEP-DOWN. |
| `EtcdMembership.UpdateClusterConfiguration` (kubeadm config bump on upgrade) | [`Workload.UpdateClusterConfiguration`](../controlplane/kubeadm/internal/workload_cluster.go#L175) | Used by `InitiateUpgrade`. The model abstracts to a single template-version flip; the Go path is a multi-step config-mutation pipeline. |

## Refinement anchors — condition projection (the v1beta2 surface)

| Quint action | Go entry point | Notes |
|---|---|---|
| `MachineHealthCheck.Observe` | [`Workload.UpdateEtcdConditions`](../controlplane/kubeadm/internal/workload_cluster_conditions.go#L48) | Driver. Calls into managed/external branches based on etcd-mode. |
| `MachineHealthCheck.DeriveCondition` (managed branch) | [`Workload.updateManagedEtcdConditions`](../controlplane/kubeadm/internal/workload_cluster_conditions.go#L66) | The function that produces the v1beta2 `EtcdMemberHealthy` condition. **This is the FM-8 surface — the v1beta2 reason `InternalError` with the generic "Please check controller logs" message is set here.** Issue corpus #IC-08 gives the exact lines. |
| `MachineHealthCheck.DeriveCondition` (matchable-set check) | [`compareMachinesAndMembers`](../controlplane/kubeadm/internal/workload_cluster_conditions.go#L375) | The function that produces the `EtcdMemberSetDoesNotMatchMachineSet` block reason. |
| `KCPReconcile.UpdateStaticPodConditions` (apiserver/scheduler/controller-manager pod health) | [`Workload.UpdateStaticPodConditions`](../controlplane/kubeadm/internal/workload_cluster_conditions.go#L464) | Future modelling: surface for FM-11 (kubelet-misconfig flow surfaces here as the static-pod conditions go non-Ready). |

## Refinement anchors — Machine controller (NodeRef resolution)

| Quint action | Go entry point | Notes |
|---|---|---|
| `KCPReconcile.ResolveNodeRef` | [`Reconciler.reconcileNode`](../internal/controllers/machine/machine_controller_noderef.go#L59) | The function that sets `Machine.status.nodeRef`. Gated on the workload-cluster apiserver being reachable; in the model this is `lbHealthy && nodeReachable[m]`. |
| `MachineHealthCheck` driver | [`machinehealthcheck.Reconciler.Reconcile`](../internal/controllers/machinehealthcheck/machinehealthcheck_controller.go#L175) | Top of the MHC reconcile loop. |
| MHC `needsRemediation` predicate | [`healthCheckTarget.needsRemediation`](../internal/controllers/machinehealthcheck/machinehealthcheck_targets.go#L80) | The function that decides whether MHC should label a Machine as unhealthy. The model abstracts this to `MachineHealthChange(m, UnhealthyMachine)`. |

## Refinement anchors — Machine controller (drain & deletion)

| Quint action | Go entry point | Notes |
|---|---|---|
| `Lifecycle.BeginDrain` | [`Reconciler.drainNode`](../internal/controllers/machine/machine_controller.go#L841); [`drain.Helper.CordonNode`](../internal/controllers/machine/drain/drain.go); [`drain.Helper.GetPodsForEviction`](../internal/controllers/machine/drain/drain.go); [`drain.Helper.EvictPods`](../internal/controllers/machine/drain/drain.go) | The CAPI Machine controller's drain step. Cordons the Node, picks Pods to evict (filters honour `MachineDrainRule` exclusions), evicts them. PDB-violating evictions surface as `evictionResult.PodsFailedEviction` and gate `drainBlocked = true` in the model. |
| `Lifecycle.DrainTimeout` | [`Reconciler.nodeDrainTimeoutExceeded`](../internal/controllers/machine/machine_controller.go#L712); [`MachineSpecDeletion.NodeDrainTimeoutSeconds`](../api/core/v1beta2/machine_types.go) | Force-delete after `nodeDrainTimeout` elapses. Refers to `Machine.Status.Deletion.NodeDrainStartTime` for elapsed-time computation. |
| `Lifecycle.RestoreNodeReachability` (NodeReachable transition) | [`noderefutil.IsNodeUnreachable`](../internal/util/noderefutil/util.go) (referenced by `drainNode` line ~870–890 to set `SkipWaitForDeleteTimeoutSeconds=1`). | When the Node is unreachable, drain uses a 1s grace period and ignores stalled Pods. The model abstracts this to `nodeReachable[m]` flipping false. |

## Refinement anchors — kube-apiserver ↔ etcd

The kube-apiserver is the point of contact between the management
cluster (KCP) and the workload cluster's etcd via the LB. The model
captures three facts about this layer.

| Quint action | Go entry point | Notes |
|---|---|---|
| `Lifecycle.ApiserverEtcdConnect` | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/preflight/checks.go:56` (`EtcdConnection.CheckEtcdServers`); `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go` (etcd v3 client used by Get:238, Create:274, Delete:342, Watch:968, GetList:736, GetCurrentResourceVersion:704, RequestWatchProgress:102). | Apiserver-on-this-Machine connects to its configured etcd backend (`--etcd-servers`). Pre-condition for apiserver readiness. |
| `Lifecycle.ApiserverEtcdDisconnect` | The etcd v3 client returning `rpctypes.ErrGRPCNoLeader` / `ErrGRPCConnectFailed` from any storage op; the apiserver's readyz endpoint then fails. | Fault — apiserver loses its etcd connection (local etcd pod crashed, network glitch, cert rotation). |
| `Lifecycle.ApiserverReadinessOk` | `staging/src/k8s.io/apiserver/pkg/server/healthz/healthz.go` (the readyz endpoint and registered checks). | apiserver `readyz` returns 200; the LB will route traffic to it. |
| `Lifecycle.EtcdCompactionStart` / `Lifecycle.EtcdCompactionDone` | `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go:52` (`StartCompactorPerEndpoint`); `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go::compactor.compactIfNeeded`. | Apiserver-driven etcd auto-compaction. Holds the bbolt mmap; gRPC reads spike to 10–60s. The FM-24 mechanism. |

## Status-rollup anchors (conditions ↔ KCP scaling decisions)

| Quint side | Go entry point | Notes |
|---|---|---|
| `Lifecycle.preflightBlocked` | [`controllers.setScalingUpCondition`](../controlplane/kubeadm/internal/controllers/status.go#L299), [`setScalingDownCondition`](../controlplane/kubeadm/internal/controllers/status.go#L351), [`getPreflightMessages`](../controlplane/kubeadm/internal/controllers/status.go#L870) | KCP's preflight messages flow through these helpers. The "Waiting for control plane to pass preflight checks" event line we observed in the e2e (and in the modelled scenario) is emitted from `getPreflightMessages`. |

## Test fixtures (signal completeness of the refinement)

A refinement is only as good as the test fixtures that exercise
it. The following Go tests verify the gates the model relies on:

| Test | Function | What it pins |
|---|---|---|
| Etcd quorum gate | [`TestTargetEtcdClusterHealthy`](../controlplane/kubeadm/internal/controllers/remediation_test.go) (function-level — `mcp__gopls__go_search` resolves the symbol) | Every adversarial branch of `targetEtcdClusterHealthy` covered with table-driven cases. |
| Remediation gate | [`TestCanSafelyRemediateMachine`](../controlplane/kubeadm/internal/controllers/remediation_test.go) | Covers matchable-set + quorum cross product. |
| Scale-up gate | [`TestKubeadmControlPlaneReconciler_scaleUpControlPlane`](../controlplane/kubeadm/internal/controllers/scale_test.go#L115) | Confirms scale-up refused under quorum stress. |
| Scale-down gate | [`TestKubeadmControlPlaneReconciler_scaleDownControlPlane_NoError`](../controlplane/kubeadm/internal/controllers/scale_test.go#L261) | Confirms scale-down respects health and quorum. |
| Etcd member removal | [`TestRemoveEtcdMember`](../controlplane/kubeadm/internal/workload_cluster_etcd_test.go#L229) | Pins `Cluster.MemberRemove` semantics on the wire. |
| Etcd leadership forward | [`TestForwardEtcdLeadership`](../controlplane/kubeadm/internal/workload_cluster_etcd_test.go#L352) | Pins the leader-transfer flow that precedes safe member removal. |
| Etcd condition derivation | [`TestUpdateEtcdConditions`](../controlplane/kubeadm/internal/workload_cluster_conditions_test.go#L47) | Covers the projection `MachineHealthCheck.DeriveCondition` refines. |
| Static-pod condition derivation | [`TestUpdateStaticPodConditions`](../controlplane/kubeadm/internal/workload_cluster_conditions_test.go#L689) | Covers the FM-11 surface for kubelet/static-pod faults. |

## Maintenance protocol

1. When adding a new Quint action to `Lifecycle.qnt`, run
   `mcp__gopls__go_search` for the most plausible Go function and
   add a row above. If no Go function exists, mark the new
   action as MODEL-INCOMPLETE in `failure-modes.md`.
2. When refactoring a Go entry point listed above, update the
   `#L<n>` anchor in the same commit. Stale anchors are
   correctness bugs, not documentation debt.
3. The CI gate in `scripts/verify-formal.sh` does not currently
   resolve LSP anchors automatically (would require gopls in CI);
   reviewers verify by clicking a sample of links during PR
   review.
