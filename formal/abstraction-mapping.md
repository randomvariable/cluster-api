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

### InPlaceUpdate.qnt

In-place machine update choreography across MachineDeployment,
MachineSet, and Machine controllers (CAEP "in-place updates",
feature gate `InPlaceUpdates`). Anchors recovered via gopls +
grep on `feature/feature.go`,
`api/runtime/hooks/v1alpha1/inplaceupdate_types.go`,
`api/core/v1beta2/{machine,machineset}_types.go`,
`internal/controllers/machinedeployment/`,
`internal/controllers/machineset/`, and
`internal/controllers/machine/machine_controller_inplace_update.go`.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| InPlaceUpdate | EvaluateCanUpdateMachineSet | internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go:53 (`rolloutPlanner.canUpdateMachineSetInPlace`); :120 (`canExtensionsUpdateMachineSet`); :88-99 (cache check); api/runtime/hooks/v1alpha1/inplaceupdate_types.go:165 (`CanUpdateMachineSet` hook). | Rollout planner consults the runtime extension to decide if MS spec changes can be patched in place; verdict is cached. Zero or >1 extensions ⇒ fall back to rolling. |
| InPlaceUpdate | SetMoveAnnotations | internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go:455-477 (oldMS gets `MachineSetMoveMachinesToMachineSetAnnotation`; newMS gets `MachineSetReceiveMachinesFromMachineSetsAnnotation`); api/core/v1beta2/machineset_types.go:43, :51 (annotation constants). | Rollout planner stamps the two-way handshake annotations on oldMS and newMS so the MS controller can move Machines instead of deleting them. |
| InPlaceUpdate | StartMoveMachine | internal/controllers/machineset/machineset_controller.go:806 (scale-down dispatch when `MoveMachinesTo` annotation set); :974 (`Reconciler.startMoveMachines`); :990-995 (validates target MS has `ReceiveMachinesFrom` listing source); :1046-1052 (OwnerRef flip); :1064 (label flip); :1070-1071 (sets `UpdateInProgressAnnotation` and `PendingAcknowledgeMoveAnnotation` on Machine); :1017 (skips Machines with `inplace.IsUpdateInProgress`). | Source MS performs the move: ownership + label flip, sets the per-Machine in-place markers. |
| InPlaceUpdate | AcknowledgeMove | internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go:111-162 (`reconcileReplicasPendingAcknowledgeMove`); :162 (writes `AcknowledgedMoveAnnotation` on newMS); api/core/v1beta2/machineset_types.go:58 (annotation constant). | Rollout planner inspects newMS's machines; for each with `PendingAcknowledgeMoveAnnotation`, adds the name to `AcknowledgedMoveAnnotation` on newMS. |
| InPlaceUpdate | CompleteMoveMachine | internal/controllers/machineset/machineset_controller.go:371-403 (newMS reconcile suffix); :381-386 (drop `PendingAcknowledgeMoveAnnotation` after newMS lists Machine in `AcknowledgedMoveAnnotation`); :397 (call `completeMoveMachine`); :429 (function definition); :458, :481 (writes `UpdateInProgressAnnotation` on InfraMachine and BootstrapConfig); :403 (`hooks.MarkObjectAsPending(UpdateMachine)`); internal/hooks/tracking.go:36 (MarkAsPending). | Target MS finalises the move: clears acknowledge bit, syncs InfraMachine/BootstrapConfig with desired state + UpdateInProgress annotation, marks UpdateMachine hook as pending on the Machine. |
| InPlaceUpdate | CallUpdateMachineHook | internal/controllers/machine/machine_controller_inplace_update.go:43 (`Reconciler.reconcileInPlaceUpdate` entry); :74-99 (gate cascade — feature, UpdateInProgress on Machine + Infra + Bootstrap, infra provisioned, bootstrap secret, NodeRef); :142 (`callUpdateMachineHook`); :148 (`GetAllExtensions`); :152-156 (zero / multi-extension errors); :181 (`CallAllExtensions`); :185-189 (RetryAfter > 0 → in progress); :192-193 (RetryAfter = 0 → done); api/runtime/hooks/v1alpha1/inplaceupdate_types.go:213 (`UpdateMachine` hook); :198-207 (response status discriminator). | Machine controller calls the runtime extension; idempotent retry loop. |
| InPlaceUpdate | CompleteInPlaceUpdate | internal/controllers/machine/machine_controller_inplace_update.go:198 (`completeInPlaceUpdate`); :201-203 (remove UpdateInProgress from Machine); :208-210 (remove from InfraMachine); :213-216 (remove from BootstrapConfig); :221 (`hooks.MarkAsDone(UpdateMachine)`); internal/hooks/tracking.go:98 (MarkAsDone). | Machine controller clears all three UpdateInProgress annotations and marks the UpdateMachine hook done; Machine version advances to newMS template. |
| InPlaceUpdate | CleanupOrphanedHook | internal/controllers/machine/machine_controller_inplace_update.go:54-66 (cleanup branch); :60 (calls `completeInPlaceUpdate` to drop orphaned hook + annotations). | Defensive cleanup: when operator strips `UpdateInProgressAnnotation` mid-flight but the UpdateMachine hook is still pending, the controller cleans up the orphan. |
| InPlaceUpdate | OperatorRegisterMultipleUpdateMachineExtensions | (operator-driven misconfiguration) — observed at `machine_controller_inplace_update.go:155-156` ("found multiple UpdateMachine hooks: only one hook is supported"). | Operator registers >1 extension; hook call fails with explicit error. |
| InPlaceUpdate | OperatorRemoveUpdateInProgress | (operator-driven exogenous fault) — handled by the cleanup branch at `machine_controller_inplace_update.go:54-66`. | Operator strips the `UpdateInProgressAnnotation` from a Machine; the controller's cleanup branch handles it. |
| InPlaceUpdate | canUpdateInPlace (helper) | internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go:53-115 (the `canUpdateMachineSetInPlace` function returning bool). | Pure predicate. |
| InPlaceUpdate | hookGateOpen (helper) | internal/controllers/machine/machine_controller_inplace_update.go:74-99 (the precondition cascade for calling the UpdateMachine hook). | Pure predicate refining the upstream gate. |

### Topology.qnt

ClusterTopology reconciler + Runtime SDK lifecycle hooks. Anchors
recovered via gopls `go_search` (`topology reconciler`,
`BeforeClusterUpgrade`, `AfterClusterUpgrade hook`,
`computeControlPlaneVersion`, `IsControlPlaneStable`) and `grep -nE`
on the controller and lifecycle-hook files; line numbers refer to
the working tree at HEAD of the `formality` branch.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| Topology | EvaluateHook | exp/topology/desiredstate/lifecycle_hooks.go (every `RuntimeClient.CallAllExtensions(...)` call: lines 100, 158, 218, 282, 348); `internal/controllers/topology/cluster/cluster_controller.go:468` (BeforeClusterCreate); :582 (BeforeClusterDelete); `reconcile_state.go:205, 274` (AfterControlPlaneInitialized, AfterClusterUpgrade). | Abstract step: the runtime extension server returns a HookOk / HookBlock / HookNotConfigured outcome. Records lastHookOutcome[h]. |
| Topology | ReconcileBeforeClusterCreate | internal/controllers/topology/cluster/cluster_controller.go:441 (`Reconciler.callBeforeClusterCreateHook`); precondition `!Spec.InfrastructureRef.IsDefined() && !Spec.ControlPlaneRef.IsDefined()` at line 446. | Topology controller calls BeforeClusterCreate; on unblock, marks AfterControlPlaneInitialized pending and proceeds to provision. |
| Topology | ControlPlaneProvisioned | (observable) `internal/controllers/topology/cluster/reconcile_state.go:218` (`isControlPlaneInitialized` checks `ClusterControlPlaneInitializedCondition == True`). | KCP completes initial CP provision; sets cpVersion to topologyVersion and seeds workers at the same version. |
| Topology | FireAfterControlPlaneInitialized | internal/controllers/topology/cluster/reconcile_state.go:188 (`Reconciler.callAfterControlPlaneInitialized`); fires the hook once when CP reaches Initialized=True (line 199); `MarkAsDone` at line 209. | Closes the AfterControlPlaneInitialized intent; transitions cluster to Stable. |
| Topology | OperatorBumpTopologyVersion | (operator-driven) `Cluster.spec.topology.version` field. The next reconcile observes the mismatch in `computeControlPlaneVersion` (`exp/topology/desiredstate/desired_state.go:535`) and `ComputeUpgradePlan` (`upgrade_plan.go:48`). | Operator triggers an upgrade by editing the topology version. |
| Topology | OperatorAddBeforeUpgradeAnnotation | (operator-driven) annotation key with prefix `before-upgrade.hook.cluster.cluster.x-k8s.io/` (`api/core/v1beta2/common_types.go:219`); observed at `lifecycle_hooks.go:44-48`. | Operator sets a hook annotation that blocks BeforeClusterUpgrade. |
| Topology | OperatorRemoveBeforeUpgradeAnnotation | (operator-driven) removes the annotation; the next reconcile observes the empty hookAnnotations list at `lifecycle_hooks.go:49`. | Operator clears their hold. |
| Topology | ComputeUpgradePlanOneMinor | exp/topology/desiredstate/upgrade_plan.go:48 (`ComputeUpgradePlan`); :334 (`GetUpgradePlanOneMinor`); :360 (`GetUpgradePlanFromClusterClassVersions`). | Computes the per-step CP and worker upgrade plans. The model uses one-minor steps; an extension-driven plan is equivalent in shape. |
| Topology | ReconcileBeforeClusterUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:39 (`generator.callBeforeClusterUpgradeHook`); precondition at line 42 (`!IsPending(AfterClusterUpgrade)`); annotation check at lines 44-72; `MarkAsPending(AfterClusterUpgrade)` at `desired_state.go:676`. | Sequence-start hook; on unblock, marks AfterClusterUpgrade pending and transitions to first CP step. Honoured-by-annotation branch. |
| Topology | ReconcileBeforeControlPlaneUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:128 (`generator.callBeforeControlPlaneUpgradeHook`); call site `desired_state.go:692`; pending-marking cascade at lines 706-715. | Per-step CP gate; on unblock, picks up next CP version and marks AfterCP/Workers hooks pending as appropriate. |
| Topology | ControlPlaneStepCompletes | (observable) `desired_state.go:574` — `ControlPlane.IsUpgrading()` flips from true to false; `s.UpgradeTracker.ControlPlane.IsUpgrading = true` becomes false on the next reconcile. | KCP finishes the rolling upgrade for one step. |
| Topology | ReconcileAfterControlPlaneUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:184 (`generator.callAfterControlPlaneUpgradeHook`); precondition at line 189 (`IsPending(AfterControlPlaneUpgrade)`); call site `desired_state.go:591`; `MarkAsDone` at line 232. | Closes the AfterCPUpgrade intent; gates worker progression. |
| Topology | ReconcileBeforeWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:248 (`generator.callBeforeWorkersUpgradeHook`); precondition at line 253 (`IsPending(BeforeWorkersUpgrade)`); call site `desired_state.go:604`; `MarkAsDone` at line 297. | Per-step worker gate; on unblock, marks MDs as upgrading. |
| Topology | MachineDeploymentStepCompletes | (observable) `s.UpgradeTracker.MachineDeployments.UpgradingNames()` shrinks; refines the upgrading-set transition in `exp/topology/scope/upgradetracker.go:242`. | One MD finishes its rolling update; clears its name from the upgrading set. |
| Topology | ReconcileAfterWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:314 (`generator.callAfterWorkersUpgradeHook`); call site `desired_state.go:644`; `MarkAsDone` at line 362. | Closes the AfterWorkersUpgrade intent; pops the upgrade-plan head. |
| Topology | FinishStepNoWorkers | (model-only) — covers the case where workers don't share this step (CP-only step). The Go counterpart is the falsy branch of `desired_state.go:707-711` (workers not at this nextVersion). | Pops the CP plan head without firing worker hooks. |
| Topology | ReconcileAfterClusterUpgrade | internal/controllers/topology/cluster/reconcile_state.go:229 (`Reconciler.callAfterClusterUpgrade`); precondition cascade at lines 235-250; `MarkAsDone` at line 286. | Closes the upgrade sequence; transitions cluster from Upgrading to Stable. |
| Topology | OperatorRequestDelete | (operator-driven) `kubectl delete cluster`; the next reconcile observes `DeletionTimestamp != nil` at `cluster_controller.go:319`. | Operator initiates cluster deletion. |
| Topology | ReconcileBeforeClusterDelete | internal/controllers/topology/cluster/cluster_controller.go:550 (`Reconciler.reconcileDelete`); precondition at line 557 (`!hooks.IsOkToDelete(cluster)`); `MarkAsOkToDelete` at line 595 (refines `internal/hooks/tracking.go:142`). | Delete-sequence-start hook; on unblock, stamps the OkToDelete annotation. |
| Topology | FinaliseDelete | (observable) `cluster_controller.go:601` returns; the cluster object is then garbage-collected by Kubernetes. | Cluster reaches Deleted phase. |
| Topology | controlPlaneIsStable (helper) | exp/topology/scope/upgradetracker.go:188 (`ControlPlaneUpgradeTracker.IsControlPlaneStable`). | Pure predicate refining the upstream stability check. |
| Topology | anyMdUpgrading (helper) | exp/topology/scope/upgradetracker.go:256 (`WorkerUpgradeTracker.IsAnyUpgrading`). | Pure predicate. |
| Topology | upgradeConcurrencyReached (helper) | exp/topology/scope/upgradetracker.go:261 (`WorkerUpgradeTracker.UpgradeConcurrencyReached`). | Pure predicate; default concurrency is 1. |
| Topology | hookFires (helper) | exp/topology/desiredstate/lifecycle_hooks.go (every `GetAllExtensions(...)` call returning `len == 0`); the BeforeClusterUpgrade-annotation branch at lines 44-72. | Pure predicate refining the hook-firing condition. |

### MachineSetPreflight.qnt

FM-33 — worker-MachineSet preflight gating. Anchors discovered
via gopls `go_search` (`controlPlaneStablePreflightCheck`,
`runPreflightChecks`, `reconcileUnhealthyMachines`) and `grep -nE` on
the preflight file; line numbers refer to the working tree at HEAD
of the `formality` branch.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| MachineSetPreflight | KcpBeginUpgrade | controlplane/kubeadm/internal/controllers/upgrade.go (KCP rolling-update entry; observable side-effect: `ControlPlane.IsUpgrading()` flips true at `internal/controllers/machineset/machineset_preflight.go:179`). | Abstract CP-side action: KCP starts a rolling upgrade. Captured by the workers as `cpUpgradeInProgress = true`. |
| MachineSetPreflight | KcpFinishUpgrade | controlplane/kubeadm/internal/controllers/upgrade.go (steady-state branch; observable: `ControlPlane.IsUpgrading()` returns false). | Abstract CP-side action: KCP finishes upgrade. Captured by `cpUpgradeInProgress = false`. |
| MachineSetPreflight | OperatorBumpMsVersion | api/core/v1beta2/machineset_types.go (`MachineSetSpec.Template.Spec.Version`); reconciliation observes the new value at `internal/controllers/machineset/machineset_preflight.go:101-106` (`ms.Spec.Template.Spec.Version` parsed via `semver.ParseTolerant`). | Operator bumps the MachineSet's worker template version. Triggers re-evaluation against version-skew checks. |
| MachineSetPreflight | RequestScaleUp | internal/controllers/machineset/machineset_controller.go:828 (scale-up call site; calls `runPreflightChecks(ctx, cluster, ms, "Scale up")`). | Worker scale-up requested. The Go reconciler runs the preflight gate before creating any new Machine. |
| MachineSetPreflight | RequestRemediation | internal/controllers/machineset/machineset_controller.go:1493 (`Reconciler.reconcileUnhealthyMachines`); preflight call at line 1633 (`runPreflightChecks(... "Machine remediation")`). | MHC has flagged a worker as unhealthy; preflight gate must pass before MachineOwnerRemediated is flipped. |
| MachineSetPreflight | EvaluatePreflight | internal/controllers/machineset/machineset_preflight.go:47 (`Reconciler.runPreflightChecks` — orchestrator); :144 (`shouldRun` — per-check skip predicate); :149 (`controlPlaneStablePreflightCheck`); :190 (`kubernetesVersionPreflightCheck`); :206 (`kubeadmVersionPreflightCheck`); :226 (`controlPlaneVersionPreflightCheck`); :236 (`skippedPreflightChecks`). | Runs the four preflight checks against (cpVersion, msVersion, cpUpgradeInProgress). Sets workerPreflightBlocked + workerBlockReason; advances decision to ActionInFlight on pass or ActionBlocked on fail. |
| MachineSetPreflight | CompleteScaleUp | internal/controllers/machineset/machineset_controller.go:828 (post-preflight branch — when `runPreflightChecks` returns nil errors and empty preflightCheckErrMessages, the controller proceeds to `r.createMachines` at the same call site; the abstract action models the Machine becoming ready and joining workerMachines). | Scale-up Machine joins the MachineSet after preflight admitted the request. |
| MachineSetPreflight | CompleteRemediation | internal/controllers/machineset/machineset_controller.go:1633 (post-preflight branch in `reconcileUnhealthyMachines`: when preflight returns no errors, the loop falls through to flip MachineOwnerRemediated true and the Machine controller deletes-and-recreates the unhealthy Machine). | Worker remediation completes after preflight admitted the request. Machine flipped from UnhealthyWorker to HealthyWorker. |
| MachineSetPreflight | WorkerHealthChange | (exogenous fault) — observed via `Machine.status.conditions[NodeHealthy]` flipping; the source of truth is the workload-cluster Node condition reflected by the Machine controller in `internal/controllers/machine/machine_controller_status.go`. | Fault action: a worker flips between HealthyWorker / UnhealthyWorker / UnknownHealthWorker. Drives the RequestRemediation precondition. |
| MachineSetPreflight | fm33ScaleUpDuringCpUpgradeInit | (initialiser — no Go entry). | FM-33 scenario init: scale-up requested while KCP mid-upgrade (CpUnstable). |
| MachineSetPreflight | fm33VersionSkewInit | (initialiser — no Go entry). | FM-33 scenario init: MS template version exceeds CP version (KubernetesVersionSkewViolation). |
| MachineSetPreflight | fm33RemediationDuringUpgradeInit | (initialiser — no Go entry). | FM-33 scenario init: remediation requested while KCP mid-upgrade. |

## Drift policy

The CI gate requires that every Go reference of the form
`path/to/file.go:LINE` resolves to an extant function declaration.
References that name a function symbolically (without a
`:LINE` suffix) are graded as TBD until a deterministic refinement
landing site is identified. TBD rows are reviewed at every CAEP
status promotion and may not persist past `status:
implementable`.
