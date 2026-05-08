# Abstraction mapping — Quint/TLA+ actions ↔ Go entry points

This table is the contract between the formal model in
[`formal/specs/`](./specs/) and the Go controllers under
[`controlplane/kubeadm/`](../controlplane/kubeadm/) and
[`internal/controllers/machinehealthcheck/`](../internal/controllers/machinehealthcheck/).
Every action in every Quint module or TLA+ specification has a row
here naming the Go entry point that refines it.

The discipline follows
[Abadi & Lamport, *The Existence of Refinement Mappings*, Theoretical Computer Science 82(2):253–284, 1991](https://doi.org/10.1016/0304-3975(91)90224-P)
and the seL4 functional-correctness convention
([Klein et al., SOSP 2009](https://doi.org/10.1145/1629575.1629596)).

## Maintenance rules

1. Add a row when a new action appears in any spec.
2. Update a row whenever the Go entry point moves; treat a stale
   row as a correctness bug, not as documentation debt.
3. The CI gate in [`scripts/verify-formal.sh`](../scripts/verify-formal.sh)
   refuses changes where any Go reference fails to resolve.
4. When a single action is jointly refined by more than one Go
   entry point, add multiple rows.
5. Rows are ordered first by spec module, then by action name.

## Rows

### EtcdMembership.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| EtcdMembership | AddLearner | controlplane/kubeadm/internal/workload_cluster_etcd.go (TBD: function refining AddLearner; current code reaches etcd via `etcd.Client.MoveLeader` paths but the AddLearner side is exercised by kubeadm-join, not by KCP. The refinement landing site is `internal/etcd/etcd.go` once Stage 4 lands the trace tap.) | Adds an etcd member as a learner. Refined indirectly through kubeadm-join. |
| EtcdMembership | AdvanceTerm | (stub) — etcd-side, not directly invoked from CAPI; the trace checker observes AdvanceTerm via the leader change in `etcd_member_status.go`. | Term advances on leader change. |
| EtcdMembership | ElectLeader | (stub) — etcd-side, observed in the `etcd.Member.IsLearner` projection. | Leader election. |
| EtcdMembership | HealthChange | controlplane/kubeadm/internal/workload_cluster_conditions.go:66 (`updateManagedEtcdConditions`) | KCP polls each member's Status; the action records the resulting health flip. |
| EtcdMembership | LeaderStepDown | (stub) — observed through `etcd.Member.IsLeader` flipping false on the prior leader (Status RPC). The model treats lease-lapse as an exogenous-from-KCP event. | Current leader steps down; term advances with no leader assigned at the new term. Refines etcd's lease-lapse semantics. Contract: R-LEAD-STEP-DOWN. |
| EtcdMembership | LearnerStuck | (stub) — surfaced by `tryGetEtcdMemberName` returning empty when a learner is unmatched. | Learner promotion stuck — fault action used by IncidentWitness. |
| EtcdMembership | ObserveLearnerProgress | (stub) — observed through `etcd.Member.RaftAppliedIndex` (not yet wired). | Leader observes a learner's progress. |
| EtcdMembership | PromoteLearner | controlplane/kubeadm/internal/workload_cluster_etcd.go (TBD: not currently invoked from KCP — promotion is performed by kubeadm-join. The trace checker observes the side-effect through MemberList.) | Promotes a learner to voter. |
| EtcdMembership | RemoveMember | controlplane/kubeadm/internal/workload_cluster_etcd.go:56 (`RemoveEtcdMember`) | Removes an etcd member. Gated on `leaderAt[currentTerm] != id` per R-LEAD-STEP-DOWN — controllers MUST transfer leadership or wait for step-down before removing the leader. |
| EtcdMembership | TransferLeadership | controlplane/kubeadm/internal/workload_cluster_etcd.go (`Workload.ForwardEtcdLeadership` — function-level; the etcd `MoveLeader` RPC is the underlying primitive). | KCP's pre-scale-down optimisation: before removing the current etcd leader, transfer leadership to a healthy follower. Contract: R-LEAD-STEP-DOWN. |

### KubeadmJoin.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| KubeadmJoin | BeginJoin | (stub) — observed indirectly through `Machine.status.bootstrapReady` flipping true. | Bootstrap controller signals join start. |
| KubeadmJoin | CheckEtcdHealth | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/checketcd.go | kubeadm's check-etcd phase: verifies the existing etcd cluster is reachable and healthy from this Machine before joining. |
| KubeadmJoin | DownloadCertsSucceeded | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/controlplaneprepare.go (control-plane-prepare phase: download-certs, certs, kubeconfig, control-plane sub-phases). | Folds the four control-plane-prepare sub-phases into one observable transition. Sets staticPodManifestsWritten. |
| KubeadmJoin | EnterEtcdAddLearner | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/controlplanejoin.go (`runEtcdJoinPhase`). | kubeadm enters the control-plane-join/etcd phase — about to call Cluster.MemberAddAsLearner. K2 ordering: NodeRegistered MUST precede this. |
| KubeadmJoin | EnterEtcdHealthCheck | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/checketcd.go | kubeadm enters the check-etcd phase. |
| KubeadmJoin | EtcdAddLearnerSucceeded | (stub) — observed when `MemberList` first reports the new member. | kubeadm-join called Cluster.MemberAddAsLearner. |
| KubeadmJoin | EtcdQuorumReady | (stub) — observed when `is_learner` flips false on `MemberList`. | Learner promoted, quorum reached. |
| KubeadmJoin | JoinFailedAt | (stub) — observed through `Machine.status.failureMessage`. | Join failed at some phase. |
| KubeadmJoin | KubeletStarted | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/kubelet.go (`runKubeletStartJoinPhase`, ~line 217-233 — `WriteConfigToDisk`, `WriteKubeletDynamicEnvFile`, `TryStartKubelet`). | kubelet-start/start phase: kubeadm has written kubelet config and started the kubelet process. Sets kubeletReady. |
| KubeadmJoin | KubeletTLSBootstrap | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/kubelet.go (`runKubeletWaitBootstrapPhase`, ~line 241-292; `waitForTLSBootstrappedClient` line 296-309). | kubelet-start/wait-bootstrap phase: kubelet's TLS Bootstrap completes, transforming bootstrap-kubelet.conf into kubelet.conf. Sets tlsBootstrapped, kubeletManifestReady. |
| KubeadmJoin | MarkAsControlPlane | k8s.io/kubernetes/cmd/kubeadm/app/phases/markcontrolplane (`MarkControlPlane`). | control-plane-join/mark-control-plane phase: applies the node-role.kubernetes.io/control-plane label and NoSchedule taint. Sets kubeadmMarkedAsControlPlane. |
| KubeadmJoin | MarkReady | (stub) — observed via `KubeadmControlPlane.status.ready`. | Final phase: KCP marks the new control plane ready. |
| KubeadmJoin | PreflightPass | k8s.io/kubernetes/cmd/kubeadm/app/cmd/phases/join/preflight.go (`runPreflightPhase`). | kubeadm preflight checks passed. |
| KubeadmJoin | RegisterLocalNode | k8s.io/kubernetes/pkg/kubelet/kubelet_node_status.go:52 (`Kubelet.registerWithAPIServer`); :90 (`Kubelet.tryRegisterWithAPIServer` calls `Nodes().Create()`); :303 (`Kubelet.initialNode`). | Kubelet performs local Node registration: creates the workload-cluster Node object via the kubelet-config-bootstrap RBAC bundle. Sets nodeLocallyRegistered. May complete before the apiserver static pod on this Machine is fully serving — kubelet uses the LB endpoint or another existing CP. K2 contract. |
| KubeadmJoin | UploadKubeadmConfig | k8s.io/kubernetes/cmd/kubeadm/app/phases/uploadconfig (`UploadConfiguration`, `UploadKubeletConfig`). | control-plane-join/uploadconfig phase: uploads ClusterConfiguration / KubeletConfiguration to kubeadm-config and kubelet-config ConfigMaps. Sets kubeadmConfigUploaded. |

### KCPReconcile.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| KCPReconcile | AddMachine | controlplane/kubeadm/internal/controllers/scale.go (`scaleUpControlPlane` — function-level; line numbers move; refinement is logical, not textual) | KCP creates a new control-plane Machine. |
| KCPReconcile | CompleteRemediation | controlplane/kubeadm/internal/controllers/remediation.go:54 (`reconcileUnhealthyMachines` post-deletion branch) | Remediation completed, replacement Machine takes over. |
| KCPReconcile | EvaluateCanSafelyRemediate | controlplane/kubeadm/internal/controllers/remediation.go:595 (`canSafelyRemediateMachine`) | The decision predicate for whether a Machine may be remediated. |
| KCPReconcile | HealthChange | controlplane/kubeadm/internal/controllers/status.go (`updateStatus` — coarse health rollup) | KCP re-projects per-Machine health. |
| KCPReconcile | RequestRemediation | controlplane/kubeadm/internal/controllers/remediation.go:54 (`reconcileUnhealthyMachines` entry) | KCP flips a Machine into remediation-requested. |
| KCPReconcile | ResolveNodeRef | internal/controllers/machine/machine_controller_noderef.go (Machine controller; refinement is upstream of KCP) | Machine controller sets `Machine.status.nodeRef`. |

### Drain & PDB

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| Lifecycle | BeginDrain | internal/controllers/machine/machine_controller.go:841 (`Reconciler.drainNode`); internal/controllers/machine/drain/drain.go (`Helper.CordonNode`, `Helper.GetPodsForEviction`, `Helper.EvictPods`). | KCP's Machine controller initiates drain. If a PDB refuses an eviction, drainBlocked sticks. Refines the upstream `Cluster.spec.controlPlane.machineDrainTimeout`. Contract: D-DRAIN-TIMEOUT. |
| Lifecycle | DrainTimeout | internal/controllers/machine/machine_controller.go:712 (`Reconciler.nodeDrainTimeoutExceeded`). The Machine controller force-deletes once the timeout elapses. | `nodeDrainTimeout` elapsed; force-delete bypasses PDB. Clears drainBlocked + preflightBlocked. Contract: D-DRAIN-TIMEOUT. |

### Apiserver ↔ etcd

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| Lifecycle | ApiserverEtcdConnect | k8s.io/apiserver/pkg/storage/etcd3/preflight/checks.go:56 (`EtcdConnection.CheckEtcdServers`); the etcd v3 client connection state in `apiserver/pkg/storage/etcd3/store.go` (Get:238, Create:274, Delete:342, Watch:968, GetList:736, GetCurrentResourceVersion:704). | apiserver-on-this-Machine establishes its etcd client connection. Pre-condition for apiserver readiness. |
| Lifecycle | ApiserverEtcdDisconnect | etcd3 client returning `rpctypes.ErrGRPCNoLeader` / `ErrGRPCConnectFailed`; observable through apiserver readyz failure. | Fault: apiserver loses its etcd connection. Forces apiserver readiness probe to fail. |
| Lifecycle | ApiserverReadinessOk | k8s.io/apiserver/pkg/server/healthz/healthz.go (the `readyz` endpoint and registered checks). | Apiserver `readyz` returns 200; LB will route traffic. |
| Lifecycle | EtcdCompactionStart | k8s.io/apiserver/pkg/storage/etcd3/compact.go:52 (`StartCompactorPerEndpoint`); also the etcd-side auto-compaction loop (`server/etcdserver/server.go::compactor`). | Etcd auto-compaction begins. Bbolt mmap held; gRPC reads spike to 10–60s of latency. Models the FM-24 shape's underlying mechanism. |
| Lifecycle | EtcdCompactionDone | (etcd-side; compactor finishes). | Compaction completes; Status RPCs return to baseline latency. Recovery action. |

### containerd ↔ CRI lifecycle of static pods

The kubelet brings up control-plane static pods (apiserver,
controller-manager, scheduler, optionally local-etcd) through the
CRI gRPC connection to containerd. Each container goes through
three CRI lifecycle stages: image-pull → sandbox-create →
container-create+start. Failure at any stage requires manual
operator intervention.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| Lifecycle | ContainerdReady | pkg/kubelet/kuberuntime/kuberuntime_manager.go (`kubeGenericRuntimeManager.Status` — RuntimeStatus probe). | The CRI runtime (containerd) is up and responding to RuntimeStatus RPCs. Pre-condition for any pod lifecycle action. |
| Lifecycle | ContainerdCrash | (containerd binary exits, CRI socket /run/containerd/containerd.sock becomes unreachable). | Fault: containerd dies; cascades all CRI lifecycle stages back to false on this Machine, plus cascades apiserverReady=false because the apiserver container process is gone. |
| Lifecycle | PullStaticPodImages | pkg/kubelet/kuberuntime/kuberuntime_image.go:33 (`kubeGenericRuntimeManager.PullImage`); the instrumented wrapper at pkg/kubelet/kuberuntime/instrumented_services.go:311. Calls CRI's RuntimeService.PullImage gRPC. | Kubelet pulls the apiserver/controller-manager/scheduler/local-etcd images via CRI. |
| Lifecycle | ImagePullFailed | pkg/kubelet/kuberuntime/kuberuntime_image.go (PullImage returns errors). | Fault: containerd cannot pull a static-pod image (registry unreachable, image bad sha, auth failure). |
| Lifecycle | CreatePodSandbox | pkg/kubelet/kuberuntime/kuberuntime_sandbox.go:38 (`kubeGenericRuntimeManager.createPodSandbox`). Calls CRI's RuntimeService.RunPodSandbox gRPC. | Kubelet creates the pod sandbox (network namespace + cgroup) for the control-plane pod. |
| Lifecycle | StartStaticPodContainers | pkg/kubelet/kuberuntime/kuberuntime_container.go:199 (`kubeGenericRuntimeManager.startContainer`). Calls CRI's RuntimeService.CreateContainer + StartContainer gRPCs. | Kubelet creates and starts the static-pod containers. After this fires, apiserverEtcdReachable and apiserverReady can flip true. |

### MachineHealthCheck.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| MachineHealthCheck | DeriveCondition | controlplane/kubeadm/internal/workload_cluster_conditions.go:66 (`updateManagedEtcdConditions`) | Derives both v1beta1 and v1beta2 conditions from the latest observation. |
| MachineHealthCheck | Observe | controlplane/kubeadm/internal/workload_cluster_etcd.go (etcd client probe path) | MHC polls workload-cluster etcd. |

### Composition.qnt

Composition does not declare new actions; it imports the four
modules above and adds cross-module invariants. Each invariant is
checked by the Go runtime as documented in the trace runtime's
checker tests.

### Remediation.tla

To be populated when `Remediation.tla` lands in Phase 5 of the
proposal.

### LifecycleMultiCluster.qnt

Per-cluster expansion for FM-35 verification. Each action takes a
`cl: ClusterId` parameter and updates the per-cluster slot of the
corresponding state variable. Refines the same Go entry points as
the single-cluster Lifecycle.qnt actions; only the cluster
dimension differs.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| LifecycleMultiCluster | ElectLeader | etcd-side; `controlplane/kubeadm/internal/workload_cluster_etcd.go::ForwardEtcdLeadership` reverse-references this transition. | Per-cluster ElectLeader; cl=0 is the management cluster. |
| LifecycleMultiCluster | AdvanceTerm | etcd-side; observable through `Status.leader` term changes. | Etcd Raft term advances. |
| LifecycleMultiCluster | AddLearner | controlplane/kubeadm/internal/workload_cluster_etcd.go (kubeadm-driven). | Etcd learner added (for cluster cl). |
| LifecycleMultiCluster | PromoteLearner | etcd-side; observable when `is_learner` flips false on `MemberList`. | Learner promoted to voter. |
| LifecycleMultiCluster | RemoveMember | controlplane/kubeadm/internal/workload_cluster_etcd.go:56 (`RemoveEtcdMember`). | Removes etcd member; gated on R-LEAD-STEP-DOWN and D-DRAIN-TIMEOUT. |
| LifecycleMultiCluster | LeaderStepDown | etcd-side passive lease-lapse. | Current leader steps down. |
| LifecycleMultiCluster | MemberHealthChange | controlplane/kubeadm/internal/workload_cluster_conditions.go:66. | KCP refreshes per-member health from observation. |
| LifecycleMultiCluster | BeginJoin | (Bootstrap controller signals join start). | kubeadm-join begins on the new Machine. |
| LifecycleMultiCluster | CompleteJoin | (collapsed from KubeadmJoin's 14 phases for FM-35 focus). | kubeadm-join succeeded; advances phase to JoinComplete. |
| LifecycleMultiCluster | AddMachine | controlplane/kubeadm/internal/controllers/scale.go (`scaleUpControlPlane`). | KCP creates a new control-plane Machine on cluster cl. |
| LifecycleMultiCluster | DeleteFailedMachine | controlplane/kubeadm/internal/controllers/scale.go (`scaleDownControlPlane` failure path). | KCP deletes a Machine that failed kubeadm-join. |
| LifecycleMultiCluster | ResolveNodeRef | internal/controllers/machine/machine_controller_noderef.go. | Machine controller resolves Machine.status.nodeRef. |
| LifecycleMultiCluster | MachineHealthChange | internal/controllers/machinehealthcheck/machinehealthcheck_targets.go:80 (`needsRemediation`). | MHC flips a Machine's health label. |
| LifecycleMultiCluster | BeginDrain | internal/controllers/machine/machine_controller.go:841 (`Reconciler.drainNode`). | KCP-driven drain begins. |
| LifecycleMultiCluster | DrainTimeout | internal/controllers/machine/machine_controller.go:712 (`nodeDrainTimeoutExceeded`). | Drain timeout elapses; force-delete bypasses PDB. |
| LifecycleMultiCluster | OperatorBumpTemplate | api/controlplane/kubeadm/v1beta2/kubeadmcontrolplane_types.go (`spec.template` / `spec.kubernetesVersion`). | Operator bumps desired CP template (upgrade trigger). |
| LifecycleMultiCluster | KcpHostPause | (operational fault — KCP pod's host Node paused / drained). | Fault: KCP reconciler pod's host is paused mid-upgrade. The FM-35 deadlock entry. |
| LifecycleMultiCluster | KcpReconcileResume | (operator workaround — `kubectl delete pod -n kcp-system kcp-controller-...` forces Deployment-driven re-schedule). | Recovery: KCP pod fails over to a healthy non-paused Machine. |
| LifecycleMultiCluster | selfHostedSteadyInit | (initialiser — no Go entry). | 3-CP self-hosted cluster healthy. |
| LifecycleMultiCluster | selfHostedDeadlockInit | (initialiser — no Go entry). | FM-35 deadlock state: KCP host paused mid-upgrade. |
| LifecycleMultiCluster | dualClusterSteadyInit | (initialiser — no Go entry). | Dual-cluster (mgmt + workload) healthy steady state. |
| LifecycleMultiCluster | stepNoRecovery | (step relation — no Go entry). | Step relation excluding KcpReconcileResume + DrainTimeout. |

### SelfHosted.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| SelfHosted | OperatorBumpTemplate | controlplane/kubeadm/api/v1beta2/kubeadmcontrolplane_types.go (`KubeadmControlPlane.spec.template` / spec.kubernetesVersion). | Operator bumps the desired CP template version (e.g. K8s upgrade). |
| SelfHosted | KcpStartUpgrade | controlplane/kubeadm/internal/controllers/upgrade.go (KCP rolling-update entry). | KCP detects template mismatch and begins reconciling the upgrade. |
| SelfHosted | KcpUpgradeMachine | controlplane/kubeadm/internal/controllers/upgrade.go (per-Machine rollout). | KCP rolls a single Machine to the new template. |
| SelfHosted | KcpUpgradeOwnHost | (self-hosted-specific path; no dedicated CAPI entry yet — rolling-update controller treats own-host as any other Machine). | KCP attempts to upgrade the Node hosting its own pod. Pauses the host; KCP cannot reconcile until pod fails over. The FM-35 deadlock entry. |
| SelfHosted | KcpReconcileResume | (operator workaround — manual KCP pod failover via kubectl delete pod or controller-manager pod failover). | KCP reconciler pod fails over to a healthy Machine; reconciliation resumes. |
| SelfHosted | selfHostedSteadyInit | (initialiser — no Go entry). | 3-CP healthy steady-state init. |
| SelfHosted | selfHostedUpgradeMidFlightInit | (initialiser — no Go entry). | Upgrade in flight init. |
| SelfHosted | selfHostedDeadlockInit | (initialiser — no Go entry). | FM-35 deadlock init: KCP host paused mid-upgrade. |
| SelfHosted | stepNoRecovery | (step relation — no Go entry). | Step relation excluding KcpReconcileResume; used to prove deadlock unreachability of recovery. |

## Drift policy

The CI gate requires that every Go reference of the form
`path/to/file.go:LINE` resolves to an extant function declaration.
References that name a function symbolically (without a
`:LINE` suffix) are graded as TBD until a deterministic refinement
landing site is identified. TBD rows are reviewed at every CAEP
status promotion and may not persist past `status:
implementable`.
