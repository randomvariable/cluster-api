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

### CAPD log translation heuristics (issue #25)

| Spec | CAPD log heuristic | Emits action | Purpose |
| ---- | ------------------ | ------------ | ------- |
| EtcdMembership | `msg="Bootstrap etcd voters"` with `voters=[...]` | `Bootstrap` | Seed the voter set from an observed initial control-plane membership. |
| EtcdMembership | `msg="Adding etcd member"` with `node=<name>` | `AddLearner` | Map learner admission during scale-up / join to the checker vocabulary. |
| EtcdMembership | `msg="Observed learner progress"` with `node=<name>, progress=<label>` | `ObserveLearnerProgress` | Carry raft-sync progress into the learner-promotion checker rule. |
| EtcdMembership | `msg="Promoting learner etcd member"` with `node=<name>` | `PromoteLearner` | Map learner promotion to voter. |
| EtcdMembership | `msg="Removing etcd member"` with `node=<name>` | `RemoveMember` | Map scale-down / remediation teardown to member removal. |
| EtcdMembership | `msg="Elected etcd leader"` with `candidate=<name>, term=<n>` | `ElectLeader` | Surface leader-election observations in the checker vocabulary. |
| KubeadmJoin | `msg="Starting kubeadm join"` with `machine=<name>` | `BeginJoin` | Start the kubeadm join phase sequence. |
| KubeadmJoin | `msg="Preflight checks passed"` with `machine=<name>` | `PreflightPass` | Record kubeadm preflight success. |
| KubeadmJoin | `msg="Kubelet started"` with `machine=<name>` | `KubeletStarted` | Record kubelet startup before etcd learner admission. |
| KubeadmJoin | `msg="Added learner to etcd"` with `machine=<name>` | `EtcdAddLearnerSucceeded` | Tie kubeadm join to learner registration. |
| KubeadmJoin | `msg="Etcd quorum reached"` with `machine=<name>` | `EtcdQuorumReady` | Record the learner reaching quorum-healthy state. |
| KubeadmJoin | `msg="Marked control plane node ready"` with `machine=<name>` | `MarkReady` | Record final control-plane readiness in join. |
| KubeadmJoin | `msg="kubeadm join failed"` with `machine=<name>, reason=<reason>` | `JoinFailedAt` | Surface terminal join failures with their categorical reason. |
| KCPReconcile | `msg="Discovered control plane machine"` with `machine=<name>` | `AddMachine` | Seed the KCP reconcile checker's machine set from observed logs. |
| KCPReconcile | `msg="Resolved machine nodeRef"` with `machine=<name>` | `ResolveNodeRef` | Record nodeRef resolution before remediation safety evaluation. |
| KCPReconcile | `msg="Requested remediation"` with `machine=<name>` | `RequestRemediation` | Record remediation intent. |
| KCPReconcile | `msg="Evaluated remediation safety"` with `machine=<name>` | `EvaluateCanSafelyRemediate` | Drive the safety-gate transition in the checker. |
| KCPReconcile | `msg="Completed remediation"` with `machine=<name>` | `CompleteRemediation` | Record successful remediation teardown/replacement completion. |
| MachineHealthCheck | `msg="Derived machine health condition"` with `v1beta1MessageTag`, `v1beta2MessageTag` | `DeriveCondition` | Translate real condition-projection observations into the informativeness checker vocabulary. |

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
| SelfHosted | EnterEtcdRoll | controlplane/kubeadm/internal/controllers/upgrade.go; controlplane/kubeadm/internal/workload_cluster_etcd.go | Concrete upgrade sub-step where self-hosted control-plane upgrade starts rolling its own etcd. |
| SelfHosted | EtcdRollRequiresEtcdWrite | controlplane/kubeadm/internal/workload_cluster_etcd.go:88-108; controlplane/kubeadm/internal/etcd/etcd.go:229-245 | Express the chicken-and-egg trap: rolling self-hosted etcd still requires writes to that same etcd. |
| SelfHosted | EnableEscapeHatch / ResumeEtcdRollWithEscapeHatch | operator-driven workaround (external etcd, staged write, read-only window) | Explicit escape hatch that lets the etcd-roll step proceed without depending on the hosted etcd write path. |
| SelfHosted | EscapeHatchExists / selfHostedEtcdTrapTrace | same | Deepen FM-35 with the concrete etcd-roll trap shape requested by issue #96. |
| SelfHosted | selfHostedSteadyInit | (initialiser — no Go entry). | 3-CP healthy steady-state init. |
| SelfHosted | selfHostedUpgradeMidFlightInit | (initialiser — no Go entry). | Upgrade in flight init. |
| SelfHosted | selfHostedDeadlockInit | (initialiser — no Go entry). | FM-35 deadlock init: KCP host paused mid-upgrade. |
| SelfHosted | stepNoRecovery | (step relation — no Go entry). | Step relation excluding KcpReconcileResume; used to prove deadlock unreachability of recovery. |

### WorkerLifecycle.qnt

Cross-spec composition of Topology + MachineSetPreflight +
InPlaceUpdate. Surfaces multi-controller races no single
Layer-1 spec catches. Anchors below are subsets of the
constituent specs (full anchors live in their respective
sections); only the cross-cutting cell-level joins are
documented here.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| WorkerLifecycle | OperatorBumpTopologyVersion | (operator-driven; `Cluster.spec.topology.version` edit) | Triggers an upgrade sequence; pendingHooks gains BeforeClusterUpgrade only (FM-39 mutual exclusion preserved). |
| WorkerLifecycle | OperatorRequestScaleUp | (operator-driven; `MachineSet.spec.replicas` increment) | Operator scales up an MS during the upgrade window. |
| WorkerLifecycle | FireBeforeClusterUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:39. | On unblock, BeforeClusterUpgrade cleared + AfterClusterUpgrade marked pending; stepPhase → StepCpUpgrade. |
| WorkerLifecycle | CpStepCompletes | (CP rolling abstracted) — refines `desired_state.go:706-715` pending-hooks cascade. | CP version atomically advances; AfterCP/BeforeWorkers/AfterWorkers marked pending. |
| WorkerLifecycle | FireAfterControlPlaneUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:184. | Body (gated by reconcile semantics, abstracted here). |
| WorkerLifecycle | FireBeforeWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:248. | Body. |
| WorkerLifecycle | FireAfterWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:314. | Body; gated on all Machines reaching InPlaceDone. |
| WorkerLifecycle | FireAfterClusterUpgrade | internal/controllers/topology/cluster/reconcile_state.go:229 (precondition cascade :235-250 — full quiescence). | Closes the upgrade sequence; gated on no Machine in flight + all at topologyVersion. |
| WorkerLifecycle | EvaluatePreflight | internal/controllers/machineset/machineset_preflight.go:47, :149. | Per-MS preflight gate (CP stability check); demotes ActionInFlight to ActionBlocked when CP turns unstable. |
| WorkerLifecycle | CompleteScaleUp | (post-preflight branch in machineset_controller.go:828). | MS reverts to NoActionNeeded after successful scale-up. |
| WorkerLifecycle | EvaluateCanUpdateMachineSet | internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go:53. | Sets the cached CanUpdateMachineSet verdict. |
| WorkerLifecycle | SetInPlaceMoveAnnotations | machinedeployment_rollout_rollingupdate.go:455-477. | Stamps the Move/Receive annotations on oldMS/newMS. |
| WorkerLifecycle | StartMoveMachine | internal/controllers/machineset/machineset_controller.go:974. | Per-Machine move (OwnerRef flip + UpdateInProgress + PendingAcknowledgeMove). |
| WorkerLifecycle | AcknowledgeMove | machinedeployment_rollout_rollingupdate.go:111-162. | MD planner adds Machine to AcknowledgedMoveAnnotation on newMS. |
| WorkerLifecycle | CompleteMoveMachine | machineset_controller.go:371-403, :429. | newMS finalises the move; UpdateMachine pending. |
| WorkerLifecycle | CallUpdateMachineHook | internal/controllers/machine/machine_controller_inplace_update.go:43-194. | UpdateMachine hook retry loop. |
| WorkerLifecycle | CompleteInPlaceUpdate | internal/controllers/machine/machine_controller_inplace_update.go:198-227. | Completes the in-place update; Machine version flips. |
| WorkerLifecycle | controlPlaneIsStable (helper) | machineset_preflight.go:149. | Pure predicate; refines the cp-stable check. |
| WorkerLifecycle | hookFires (helper) | (model-only) — abstracts hook outcome. | Pure predicate. |
| WorkerLifecycle | anyMachineInFlight (helper) | (model-only) — refines the implicit quiescence check at `reconcile_state.go:242-250` (`IsAnyUpgrading` etc.). | Pure predicate. |
| WorkerLifecycle | allMachinesDone (helper) | (model-only). | Pure predicate. |

### ClusterE2E.qnt

End-to-end cluster lifecycle: bring-up (InfraCluster → CP →
workers) plus topology hooks, in-place vs rolling upgrade
strategies. Anchors recovered via gopls + grep on
`internal/controllers/cluster/`,
`internal/controllers/machine/`,
`controlplane/kubeadm/internal/controllers/`,
`internal/controllers/topology/cluster/`,
`exp/topology/desiredstate/`.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| ClusterE2E | FireBeforeClusterCreate | internal/controllers/topology/cluster/cluster_controller.go:441 (`callBeforeClusterCreateHook`). | Topology controller fires BeforeClusterCreate; advances cluster from NotCreated to InfraProvisioning. |
| ClusterE2E | InfraClusterProvision | (external infra provider — refines the contract at internal/contract/infrastructurecluster.go via `provisioned` getter; observable side-effect of provider's controller). | Infra provider flips InfraCluster.status.ready=true and sets controlPlaneEndpoint. |
| ClusterE2E | ClusterControllerObservesInfraReady | internal/controllers/cluster/cluster_controller_phases.go:141 (`reconcileInfrastructure`); :185-190 (provisioned read); :219 (controlPlaneEndpoint copy); :245 (InfrastructureProvisioned=true). | Cluster controller observes InfraCluster.status; sets Cluster.status.initialization.infrastructureProvisioned and copies the endpoint into Cluster.spec. |
| ClusterE2E | KcpInitializeControlPlane | controlplane/kubeadm/internal/controllers/scale.go:43 (`initializeControlPlane`); gate at controller.go:296. | KCP creates the first CP Machine (via cloneConfigsAndGenerateMachine). |
| ClusterE2E | BootstrapProviderProvisions | internal/controllers/machine/machine_controller_phases.go:148 (`reconcileBootstrap`); :179, :239 (BootstrapDataSecretCreated=true). | Bootstrap provider (e.g. KubeadmConfig controller) generates cloud-init and sets BootstrapConfig.status.dataSecretName. |
| ClusterE2E | InfraProviderProvisions | internal/controllers/machine/machine_controller_phases.go:244 (`reconcileInfrastructure`); :296 (provisioned read); :375 (InfrastructureProvisioned=true). | Infra provider provisions the per-Machine VM and flips InfraMachine.status.ready=true. |
| ClusterE2E | KubeletRegistersNode | (refines kubelet's local Node registration; cross-spec — already grounded at pkg/kubelet/kubelet_node_status.go:52 in KubeadmJoin.qnt). | Kubelet creates the Node object; Machine controller sets nodeRef. |
| ClusterE2E | CpMachineJoinsEtcd | (refines the kubeadm-join etcd-add-learner + promote-learner sequence — already grounded in EtcdMembership.qnt and KubeadmJoin.qnt at finer grain). | CP Machine becomes part of the etcd member set. |
| ClusterE2E | CpMachineMarkReady | (KCP marking the Machine ready via UpdateMachineConditions — observable via Machine.status.conditions). | CP Machine reaches MachineReady. |
| ClusterE2E | KcpScaleUpControlPlane | controlplane/kubeadm/internal/controllers/scale.go:67 (`scaleUpControlPlane`); :81 (preflightChecks gate). | KCP creates the next CP Machine after the first is healthy. |
| ClusterE2E | KcpMarkInitialized | (refines KCP setting `KCP.status.initialization.controlPlaneInitialized=true`; the contract is tested at controlplane/kubeadm/internal/contract/controlplane.go via `Initialized().Get`). | KCP marks itself Initialized once the first CP Machine joins etcd. |
| ClusterE2E | ClusterControllerObservesCpInitialised | internal/controllers/cluster/cluster_controller_phases.go:251 (`reconcileControlPlane`); :289 (Initialized read); :347 (ControlPlaneInitialized=true). | Cluster controller observes ControlPlane.status.initialization.controlPlaneInitialized and propagates to Cluster.status. |
| ClusterE2E | FireAfterControlPlaneInitialized | internal/controllers/topology/cluster/reconcile_state.go:188 (`callAfterControlPlaneInitialized`). | Topology fires AfterControlPlaneInitialized hook; enables the MD controller. |
| ClusterE2E | MdCreateWorker | internal/controllers/machinedeployment/machinedeployment_controller.go (gated by Cluster.Status.Initialization.ControlPlaneInitialized). | MD controller creates a worker Machine. |
| ClusterE2E | WorkerMarkReady | (refines worker Machine reaching ready after kubelet registers and Node becomes Ready). | Worker Machine reaches MachineReady. |
| ClusterE2E | OperatorBumpVersion | (operator-driven — `Cluster.spec.topology.version`); also stamps the upgrade strategy choice. | Triggers an upgrade sequence. |
| ClusterE2E | FireBeforeClusterUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:39 (`callBeforeClusterUpgradeHook`). | Topology fires BeforeClusterUpgrade. |
| ClusterE2E | CpUpgradeRolling | controlplane/kubeadm/internal/controllers/scale.go:106 (`scaleDownControlPlane`) plus the upgrade orchestrator that sequences delete-and-recreate. | CP Machine rolled to next-step version via delete/recreate. |
| ClusterE2E | CpUpgradeInPlace | internal/controllers/machine/machine_controller_inplace_update.go:43-227 (the in-place update flow already grounded in InPlaceUpdate.qnt). | CP Machine version bumped in place via UpdateMachine hook. |
| ClusterE2E | CpStepCompletes | (transition observable when all CP at nextStepVersion). | All CP Machines at the new step version. |
| ClusterE2E | FireAfterControlPlaneUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:184 (`callAfterControlPlaneUpgradeHook`). | Topology fires AfterControlPlaneUpgrade. |
| ClusterE2E | FireBeforeWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:248 (`callBeforeWorkersUpgradeHook`). | Topology fires BeforeWorkersUpgrade. |
| ClusterE2E | WorkerUpgrade | (rolling or in-place; refines MD upgrade orchestrator + InPlaceUpdate flow). | Worker Machine bumped to next-step version. |
| ClusterE2E | WorkerStepCompletes | (transition observable when all workers at nextStepVersion). | All workers at the new step version. |
| ClusterE2E | FireAfterWorkersUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:314 (`callAfterWorkersUpgradeHook`). | Topology fires AfterWorkersUpgrade. |
| ClusterE2E | FireAfterClusterUpgrade | internal/controllers/topology/cluster/reconcile_state.go:229 (`callAfterClusterUpgrade`); precondition cascade at :235-250 (full quiescence). | Topology fires AfterClusterUpgrade; cluster returns to Stable. |
| ClusterE2E | cpMachinesCreated (helper) | (model-only). | Pure predicate. |
| ClusterE2E | cpMachinesReady (helper) | (model-only). | Pure predicate. |
| ClusterE2E | workerMachinesReady (helper) | (model-only). | Pure predicate. |
| ClusterE2E | allCpAtVersion (helper) | (model-only). | Pure predicate. |
| ClusterE2E | allWorkersAtVersion (helper) | (model-only). | Pure predicate. |
| ClusterE2E | kcpEntryGateOpen (helper) | controlplane/kubeadm/internal/controllers/controller.go:296 (the `!InfrastructureProvisioned \|\| !ControlPlaneEndpoint.IsValid()` short-circuit). | Pure predicate. |

### ClusterE2ERefined.qnt

Refinement of the end-to-end bring-up slice onto the controller-runtime
substrate. The projection forgets queue / worker / leader-election state
 and keeps the ClusterE2E-side lifecycle bits.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | ------------ | ------- |
| ClusterE2ERefined | `ProcessNextWorkItem` / `FM45_PerKeySerialisation` | `pkg/internal/controller/controller.go:194`, `:311`, `:419`; `pkg/controller/priorityqueue/priorityqueue.go:391` | Refine every high-level reconcile body as workqueue dispatch under per-key serialisation. |
| ClusterE2ERefined | `LeaderAcquire` / `LeaderLose` | `pkg/manager/internal.go:650` plus controller-runtime leader-election gate behaviour | Model bring-up work only while leader runnables are active, and replay after leader loss / reacquire. |
| ClusterE2ERefined | `ReconcileBeforeClusterCreate` | `internal/controllers/topology/cluster/cluster_controller.go:441` | Cluster key drives the initial topology hook inside a reconcile dispatch. |
| ClusterE2ERefined | `ClusterControllerObservesInfraReady` | `internal/controllers/cluster/cluster_controller_phases.go:141`, `:219`, `:245` | Cluster reconcile copies the endpoint and marks infrastructure provisioned. |
| ClusterE2ERefined | `KcpInitializeControlPlane` / `KcpMarkInitialized` | `controlplane/kubeadm/internal/controllers/controller.go:296`; `controlplane/kubeadm/internal/controllers/scale.go:43` | Control-plane reconcile preserves the FM-48 gate and later marks KCP initialized after the first CP Machine is ready. |
| ClusterE2ERefined | `BootstrapProviderProvisionsCp`, `InfraProviderProvisionsCp`, `KubeletRegistersCpNode`, `CpMachineMarkReady` | `internal/controllers/machine/machine_controller_phases.go:148`, `:244`, `:375` | Machine-side provisioning chain is replayable under substrate scheduling but preserves ordering. |
| ClusterE2ERefined | `ClusterControllerObservesCpInitialized` | `internal/controllers/cluster/cluster_controller_phases.go:251`, `:289`, `:347` | Cluster reconcile propagates `controlPlaneInitialized` only after KCP has set it. |
| ClusterE2ERefined | `MdCreateWorkerMachine` | `internal/controllers/machinedeployment/machinedeployment_controller.go` gated on `Cluster.Status.Initialization.ControlPlaneInitialized` | Worker creation remains blocked until the Cluster controller has observed CP initialization. |

### ControllerRuntime.qnt

The substrate model. Refines the core mechanics of
sigs.k8s.io/controller-runtime that every CAPI controller is
built on top of: Manager, Controller worker pool, priority
queue, Reconciler result branches, Source/EventHandler/Predicate
pipeline, leader election, cache-vs-APIReader read split.
Anchors recovered via gopls + grep on
`/home/naadir/go/src/sigs.k8s.io/controller-runtime`.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| ControllerRuntime | ManagerStart | pkg/manager/internal.go:347 (`controllerManager.Start`); :349-353 (started flag). | Manager initialisation; not yet leader-elected. |
| ControllerRuntime | LeaderAcquire | pkg/manager/internal.go:619 (`OnStartedLeading` callback); :621 (`startLeaderElectionRunnables`); :625 (`close(cm.elected)`); :650 (`startLeaderElectionRunnables`). | Manager wins the lease; leader-election runnables (controllers + sources) start. |
| ControllerRuntime | LeaderLose | pkg/manager/internal.go:627-637 (`OnStoppedLeading` callback). | Catastrophic: lease lost; runnables halted. |
| ControllerRuntime | ApiServerWrite | (external) — refines a write to the API server that the cache hasn't yet observed. | Increments per-key apiVersion. |
| ControllerRuntime | CacheSync | pkg/cache/cache.go:65 (`Cache` interface); the informer's watch event firing. | Cache catches up to API server; emits a Source event. |
| ControllerRuntime | SourceEmitCreate | pkg/source/source.go:48 (`Source = TypedSource[Request]`); pkg/handler/eventhandler.go:124 (`Create` event dispatch). | Source fires a Create event for a key. |
| ControllerRuntime | EnqueueViaHandler | pkg/handler/eventhandler.go:124-180 (Create/Update/Delete dispatchers); pkg/predicate/predicate.go:33-103 (Predicate filter). | EventHandler optionally enqueues request after Predicate filtering; deduped with respect to in-flight items. |
| ControllerRuntime | EnqueueAfterTimerExpires | pkg/controller/priorityqueue/priorityqueue.go:309-356 (`handleWaitingItems`). | Waiting-tree timer expires; key transitions to ready. |
| ControllerRuntime | ProcessNextWorkItem | pkg/internal/controller/controller.go:419 (`processNextWorkItem`); pkg/controller/priorityqueue/priorityqueue.go:424 (`GetWithPriority`); :391 (per-key locked-set guard); :311 (controller.go per-key serialisation comment). | Worker picks up the next ready item whose key is not in the `locked` set. Multi-worker safe. |
| ControllerRuntime | ReconcileSucceed | pkg/internal/controller/controller.go:508-513 (default success branch); :512 (`Forget`). | Reconcile returned err==nil with zero Result; rate-limiter reset, no requeue. |
| ControllerRuntime | ReconcileRequeueAfter | pkg/internal/controller/controller.go:495-503 (RequeueAfter branch); :501 (`Forget`); :502 (`AddWithOpts(After)`). | Reconcile returned RequeueAfter > 0; key re-queued in waiting tree. |
| ControllerRuntime | ReconcileRequeue | pkg/internal/controller/controller.go:504-507 (deprecated Result.Requeue branch). | Reconcile returned Result{Requeue: true}; AddRateLimited. |
| ControllerRuntime | ReconcileError | pkg/internal/controller/controller.go:483, 487-489 (err != nil non-terminal branch). | Reconcile returned non-terminal error; AddRateLimited; NumRequeues++. |
| ControllerRuntime | ReconcileTerminalError | pkg/internal/controller/controller.go:484-485 (TerminalError branch); pkg/reconcile/reconcile.go:174 (`TerminalError` constructor). | Reconcile returned `reconcile.TerminalError`; key dropped without requeue. |
| ControllerRuntime | EmitFault | pkg/source/source.go:48 (`Source` event emission); pkg/handler/eventhandler.go:124-180 (event dispatch); pkg/internal/controller/controller.go:389-406 (`Enqueue` / workqueue admission). | Abstract a flapping upstream dependency or watch storm that repeatedly produces enqueue-worthy updates for the same key. |
| ControllerRuntime | tokenBucket / `MAX_BURST` / `REFILL_RATE` | pkg/controller/priorityqueue/priorityqueue.go:497-521 (`NumRequeues` / `Forget`); controller-runtime `AddWithOpts(RateLimited)` at `pkg/internal/controller/controller.go:487-489`. | Compact token-bucket abstraction for repeated rate-limited retries under fault storms; models dispatch budget exhaustion without reproducing every concrete backoff clock. |
| ControllerRuntime | RefillTokens | pkg/controller/priorityqueue/priorityqueue.go:309-356 (`handleWaitingItems`) plus rate-limited re-admission. | Abstract background budget recovery between bursts of fault-triggered retries. |
| ControllerRuntime | RateLimitDeny | pkg/internal/controller/controller.go:419 (`processNextWorkItem`); pkg/controller/priorityqueue/priorityqueue.go:424 (`GetWithPriority`). | Model a ready key being deferred because retry budget is exhausted, creating backlog/starvation pressure without silently dropping the item. |
| ControllerRuntime | `FM69_BoundedFaultProgress` / `boundedFaultStormRun` | same controller-runtime queue / retry surfaces above. | Encodes the bounded-fault “legitimate key still completes” scenario requested in issue #30. |
| ControllerRuntime | `FM70_NoLegitReadyBacklog` / `faultStormOverloadRun` | same. | Encodes the overload counterexample where repeated flapping traffic leaves a legitimate key ready but not served. |
| ControllerRuntime | anyWorkerOnKey (helper) | pkg/controller/priorityqueue/priorityqueue.go:391 (`w.locked.Has(item.Key)` guard); pkg/internal/controller/controller.go:311 (per-key serialisation comment). | Pure predicate. |
| ControllerRuntime | hookFires (helper) | (model-only) — abstracts the predicate result. | Pure predicate. |

### CrossControllerCycle.qnt

Two-controller enqueue cycle abstraction for issue #31. Captures the
MachineDeployment controller watching MachineSets and the MachineSet
controller watching MachineDeployments / Machines, with independent queue
slots and per-controller cache views.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| CrossControllerCycle | `CrossEnqueueMdToMs` | `internal/controllers/machinedeployment/machinedeployment_controller.go:106-113` (`Watches(&MachineSet{}, handler.EnqueueRequestsFromMapFunc(r.MachineSetToDeployments))`) | Abstract the MachineDeployment controller re-enqueueing follow-up work from MachineSet changes. |
| CrossControllerCycle | `BeginCycleAtMs` | `internal/controllers/machineset/machineset_controller.go:131-141` (`Watches(&Machine{}, ...)`, `Watches(&MachineDeployment{}, handler.EnqueueRequestsFromMapFunc(mdToMachineSets))`) | Compress the reciprocal MachineSet-side start + cross-enqueue step that closes the cycle back toward the Deployment-side object. |
| CrossControllerCycle | per-controller `cacheVersion` / `apiVersion` | `pkg/client/client.go:40-91` (cache reader split), `pkg/cache/cache.go:65` (watch/cache surface) | Model each controller waiting on the other controller’s cache view to observe the new object version before it can complete reconcile. |
| CrossControllerCycle | `NoCyclicLivelock` / `livelockCycleRun` | same watcher edges above plus `pkg/internal/controller/controller.go:419` (`processNextWorkItem`) | Express the adversarial shape where both controllers are simultaneously in-flight and blocked on each other’s stale cache view. |
| CrossControllerCycle | `CacheStableAllowsCompletion` / `stabilisedCycleRun` | same. | Show the non-livelocked recovery regime where cache stabilisation allows both reconciles to complete. |

### ReflectorRelistStorm.qnt

Watch / reflector compaction abstraction for issue #32. The model keeps
one KCP-relevant machine-create intent, two reflectors, and just enough
watch-session state (`reflectorRV`, `bookmarkLatest`, `relistNeeded`) to
express RV-too-old relists, dropped bookmarks, and duplicate delivery of
the same partial state.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| ReflectorRelistStorm | `BookmarkDropped` / `ApiserverCompact` | `test/infrastructure/inmemory/pkg/server/api/watch.go:173-185`, `test/infrastructure/inmemory/pkg/runtime/cache/cache.go:51`, `test/infrastructure/inmemory/pkg/runtime/cache/client.go:84-95` | Ground the watch bookmark and compaction semantics that force relists after RV-too-old. |
| ReflectorRelistStorm | `ReflectorRelist` / `ReflectorRelistStorm` | same watch/cache surfaces above | Compress a reflector relisting from the apiserver and replaying current object state after compaction/bookmark loss. |
| ReflectorRelistStorm | `CreateMachineOnce` / `CreateDuplicateMachineBug` | `controlplane/kubeadm/internal/controllers/helpers.go:149-193`, `:298-305` | Anchor the duplicate-create risk to `cloneConfigsAndGenerateMachine` and `createMachine`, where KCP creates a replacement Machine and only then waits for cache observation. |
| ReflectorRelistStorm | `NoDuplicateMachineLeak` / `duplicateCreateRelistStormRun` | same | Express the bug candidate where a LIST replay plus later watch replay cause the same create intent to be acted on twice. |
| ReflectorRelistStorm | `DuplicateDeliveryRequiresRelist` / `idempotentRelistStormRun` | same | Capture the idempotent regime where duplicate delivery is tolerated without leaking an extra Machine object. |

### StaleEnqueueShutdown.qnt

Queue/object lifecycle abstraction for issue #33. The model keeps one key,
one queued/in-flight slot, a single object-present bit, and shutdown flags
(`accepting`, `shuttingDown`) so it can express delete-after-enqueue,
NotFound handling, in-flight shutdown drain, and finalizer leakage.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| StaleEnqueueShutdown | `DeleteObjectMidEnqueue` / `HandleNotFound` | `controlplane/kubeadm/internal/controllers/controller.go:182`, `:451`; `controlplane/kubeadm/internal/controllers/helpers.go:59`; `pkg/internal/controller/controller.go:419` | Ground the common controller pattern where a queued key is processed after the backing object has already disappeared and reconcile must treat `IsNotFound` as a no-op instead of dereferencing nil state. |
| StaleEnqueueShutdown | `ManagerShutdown` / `ShutdownDrainCompletes` | `pkg/internal/controller/controller.go:419` (work-item processing) plus the queue/shutdown drain semantics modelled in `ControllerRuntime.qnt` | Capture manager stop while work is already in flight: shutdown stops accepting new work but should still allow the current reconcile to drain. |
| StaleEnqueueShutdown | `AddFinalizerIntent` / `DeleteOwnerDuringFinalizerAdd` / `CleanupOrphanedFinalizer` | `util/patch/patch.go:186`; `util/deprecated/v1beta1/patch/patch.go:181` | Anchor the “delete during finalizer add” / no-orphan-finalizer class to the patch helpers that special-case NotFound during finalizer mutation. |
| StaleEnqueueShutdown | `NoNilReadAfterDelete` / `nilReadAfterDeleteRun` | same | Express the panic-class bug where reconcile proceeds as if the deleted object were still present. |
| StaleEnqueueShutdown | `NoOrphanedFinalizer` / `orphanedFinalizerRun` | same | Express the leak shape where a finalizer remains after the owning object context has already disappeared. |

### WebhookOrdering.qnt

Admission-chain ordering abstraction for issue #34. The model keeps one
 field, one validator observation, mutator/validator fired bits, and a
 reinvocation flag so it can express “validator read stale input, mutator
 defaulted afterwards” plus the converging replay regime.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| WebhookOrdering | `ValidatingFires` / `ObservedValueIsFinal` | `internal/webhooks/cluster.go:754-900` (`DefaultAndValidateVariables`) | Anchor the validator’s decision to the pre-mutation field value seen inside the Cluster topology variable default/validate path. |
| WebhookOrdering | `MutatingFiresDefault` / `MutatingFiresNormalize` | same | Model mutating admission/defaulting in the same logical admission chain that changes the field after a validator has already observed it. |
| WebhookOrdering | `ReinvocationTriggered` / `ReinvocationConverges` | Kubernetes admission reinvocation semantics, composed onto the ClusterClass / topology variable webhook path above | Capture the second-pass validating replay after a mutator changed the object. |
| WebhookOrdering | `MutatorOnlyMovesTowardDefault` / `convergingReinvocationRun` | same plus `internal/topology/variables/clusterclass_variable_validation.go:55-120` | Express the intended safe regime where mutation/defaulting converges and the validating replay sees the final value. |
| WebhookOrdering | `ObservedValueIsFinal` / `staleValidatorReadRun` | same | Express the stale-read counterexample where the validator’s verdict is based on a value later changed by mutation/defaulting. |

### WebhookSelfReference.qnt

Self-referential webhook-outage abstraction for issue #35. The model keeps
one webhook pod phase, one failure policy bit, one upgrade-progress state,
and a single invalid mutation flag so it can express both sides of the
trade-off: fail-closed admission deadlock during an upgrade of the same
cluster hosting the webhook, and the unsafe mutation window opened by
switching the policy to `Ignore`.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| WebhookSelfReference | `WebhookPodRestart` / `WebhookPodUnavailable` | `config/webhook/manifests.yaml`, `bootstrap/kubeadm/config/webhook/manifests.yaml`, `controlplane/kubeadm/config/webhook/manifests.yaml` (`failurePolicy: Fail`) | Ground the outage window where the webhook pod restarts on the same cluster the admission chain is trying to mutate. |
| WebhookSelfReference | `UpgradeStepRequiresAdmission` / `UpgradeProgressDespiteWebhookGap` | same plus `controlplane/kubeadm/internal/controllers/controller.go` KCP upgrade/reconcile path | Capture the fail-closed deadlock candidate when upgrade progress is gated on an unavailable self-hosted webhook. |
| WebhookSelfReference | `SetFailurePolicyIgnore` / `IgnoreWindowRequiresIgnorePolicy` | same manifest anchors | Model the operational escape hatch of temporarily switching the webhook to `Ignore`. |
| WebhookSelfReference | `QueueInvalidMutation` / `NoInvalidMutationDuringIgnoreWindow` | same | Express the unsafe branch where the `Ignore` window admits a mutation the webhook would otherwise have rejected. |
| WebhookSelfReference | `ActivateSafeFallback` / `safeFallbackRun` | same | Express the intended safe regime where progress resumes through an explicit fallback rather than through a broad ignore window. |

### WebhookCABundleStaleness.qnt

Serving-cert / CABundle / apiserver-trust-cache split for issue #36. The
model keeps separate generations for the serving cert, injected CABundle,
and apiserver trust cache so it can express the short x509 outage window
after cert rotation but before the apiserver cache refreshes.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| WebhookCABundleStaleness | `RotateWebhookCert` | `config/certmanager/certificate.yaml`, `bootstrap/kubeadm/config/certmanager/certificate.yaml`, `controlplane/kubeadm/config/certmanager/certificate.yaml` | Anchor cert-manager rotation of the webhook serving cert. |
| WebhookCABundleStaleness | `InjectCABundle` | `config/default/kustomization.yaml`, `bootstrap/kubeadm/config/default/kustomization.yaml`, `controlplane/kubeadm/config/default/kustomization.yaml` (`replacements` / CA injection flow) | Model the CABundle reinjection step landing in the webhook configuration after serving-cert rotation. |
| WebhookCABundleStaleness | `ApiserverRefreshCache` / `CurrentlyTrusted` | webhook-manifest consumption from `config/webhook/manifests.yaml` and peers | Express the split between the injected bundle and the apiserver’s still-stale internal trust cache. |
| WebhookCABundleStaleness | `AdmissionAttempt` / `staleTrustOutageRun` | same | Capture the concrete x509 failure window immediately after cert rotation but before trust-cache refresh. |
| WebhookCABundleStaleness | `CacheRefreshMonotonic` / `refreshRecoveryRun` | same | Show the intended recovery regime once the apiserver cache catches up to the injected bundle. |

### DryRunSideEffects.qnt

Dry-run webhook side-effects contract for issue #38. The model keeps a
declared `sideEffects` value, a single dry-run probe, and a boolean for
whether the webhook actually triggered an external side effect so it can
express the compliance bug directly.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| DryRunSideEffects | `QueueDryRunRequest` | `internal/util/ssa/patch.go:38-43`, `:119`, `controlplane/kubeadm/internal/controllers/inplace_canupdatemachine.go:160`, `:169`, `:178` | Ground the real controller-side SSA dry-run probes already used in repo code paths. |
| DryRunSideEffects | `WebhookHandlesDryRunSafely` / `DryRunHasNoSideEffects` | `config/webhook/manifests.yaml`, `bootstrap/kubeadm/config/webhook/manifests.yaml`, `controlplane/kubeadm/config/webhook/manifests.yaml` (`sideEffects: None`) | Capture the declared dry-run side-effect contract CAPI webhooks advertise. |
| DryRunSideEffects | `WebhookFiresExternalCall` / `violatingDryRunProbeRun` | same | Express the compliance bug where a dry-run probe still triggers a real external side effect. |
| DryRunSideEffects | `TriggeredSideEffectsRequireWebhookFire` | same | Stable bookkeeping fact: side effects cannot occur unless the webhook actually executed. |

### AsymmetricPartition.qnt

Directed-link etcd partition abstraction for issue #39. This is a small
directed analogue of the symmetric `Partition(m)` surface in
`Lifecycle.qnt`, focused specifically on the leader/follower split where
only one heartbeat / ack direction is broken.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| AsymmetricPartition | `BlockDirectionBA` / `BlockDirectionAB` | `formal/specs/Lifecycle.qnt:2023-2042` (`Partition(m)` symmetric grounding) | Replace symmetric reachability loss with a directed A→B / B→A channel model so one side can still believe the peer is alive. |
| AsymmetricPartition | `FollowerStartsElection` | `formal/specs/Lifecycle.qnt:613-628` (`ElectLeader`) and `:858-875` (`LeaderStepDown`) | Model the follower-side term advance when the reverse direction is blocked and it stops receiving the evidence it needs to keep following. |
| AsymmetricPartition | `MinorityLeaderStillAcceptsWrites` / `NoSimultaneousLeaders` | same leader/term surfaces above | Express the dual-leader window the issue is targeting: the original leader remains healthy enough to accept writes while the other side has already advanced term and elected itself. |
| AsymmetricPartition | `RecoveredToSingleLeader` / `recoveredDirectionalPartitionRun` | same | Show the intended recovery regime once the directed block heals and the minority leader steps down. |

### SnapshotRestoreCompaction.qnt

Standalone restore/compaction race abstraction for issue #40. This is a
small operational slice centred on the operator restore step already
modelled in `Lifecycle.qnt`, plus a concurrent KCP member-set update and
an overlapping compaction generation bump.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| SnapshotRestoreCompaction | `BeginSnapshotRestore` / `MemberSetMatchesSnapshotPostRestore` | `formal/specs/Lifecycle.qnt:2522-2581` (`RestoreClusterFromSnapshot`) | Ground the operator-driven disaster-recovery step where an older member-set snapshot is restored. |
| SnapshotRestoreCompaction | `CompactDuringRestore` / `compactionGen` | `formal/specs/Lifecycle.qnt:3000-3060` (`EtcdCompactionStart`) | Model compaction racing with the restore and invalidating the log base the snapshot assumed. |
| SnapshotRestoreCompaction | `KcpReconcileDuringRestore` | same restore grounding plus KCP etcd-member management surface in the lifecycle corpus | Represent KCP continuing to mutate the live etcd member set while the restore is still in flight. |
| SnapshotRestoreCompaction | `NoLogInconsistency` / `restoreCompactionRaceRun` | same | Express the concrete race outcome where restored membership matches the snapshot but log state is inconsistent because compaction stripped the referenced history during the window. |

### DefragQuorumLoss.qnt

Standalone etcd defrag-maintenance model for issue #41. This is a small
3-member quorum slice grounded against the existing quorum arithmetic in
`Lifecycle.qnt`, extended with one defrag pause bit and one concurrent
member glitch.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| DefragQuorumLoss | `BeginDefrag` / `EndDefrag` | `formal/specs/Lifecycle.qnt:525-606` (quorum arithmetic and member health); `formal/failure-modes.md` FM-24 defrag pause provenance | Ground the maintenance window where one member is intentionally paused for defrag work. |
| DefragQuorumLoss | `MemberGlitchDuringDefrag` | `formal/specs/Lifecycle.qnt:2913` (glitch / crash provenance) | Add the second concurrent maintenance fault that turns a safe single-defrag pause into a quorum-loss window. |
| DefragQuorumLoss | `NoQuorumLossUnderSingleMaintenanceFault` / `overlapLossRun` | same quorum arithmetic above | Express the likely counterexample: defragging one member is safe, but overlapping a second glitch drops active voters below quorum. |
| DefragQuorumLoss | `SerialDefragOrdering` / `serialDefragRun` | same | Show the intended regime where only one member is paused for defrag at a time and quorum is preserved. |

### EtcdMembershipBatch.qnt

Standalone add/promote/remove batch model for issue #43. This is a small
4-member etcd slice: an existing 3-voter quorum plus one joining learner
candidate and one departing voter. The spec distinguishes the safe serial
regime from the bad “same reconcile batch” churn where add/promote/remove
effects are mixed without an intermediate healthy checkpoint.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| EtcdMembershipBatch | `AddLearner` / `PromoteLearner` | `formal/specs/EtcdMembership.qnt:143-177`; `formal/specs/Lifecycle.qnt:1415-1465` (`EnterEtcdAddLearner` / `EtcdAddLearnerSucceeded`) | Ground the joining-member path that first adds a learner and then promotes it once caught up. |
| EtcdMembershipBatch | `RemoveMember` | `controlplane/kubeadm/internal/workload_cluster_etcd.go:88-108`; `controlplane/kubeadm/internal/etcd/etcd.go:229-245` | Ground the concrete etcd-member removal path the controller calls once a machine/member is ready to leave. |
| EtcdMembershipBatch | `NoSameBatchAddRemove` / `sameBatchChurnRun` | `formal/specs/Lifecycle.qnt:4185-4206` (documented add/remove flip-flop risk) | Express the issue's counterexample target: one reconcile batch performs both operations together instead of serialising them across a stable quorum checkpoint. |
| EtcdMembershipBatch | `serialMembershipRun` | same | Show the intended safe regime: add learner, promote learner, then remove the departing voter in a later batch. |

### EtcdFiveNodeFailure.qnt

Standalone 5-node / 3-failure etcd recovery corpus for issue #44. This
spec keeps a concrete 5-voter cluster plus two learner candidates and
models three-failure recovery shapes without waiting on the broader
replica-parameterisation work in issue #27.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| EtcdFiveNodeFailure | `TripleFailure` | `formal/specs/Lifecycle.qnt:466-512` and `:5388-5429` (existing 5-node initial shapes) | Ground the production 5-control-plane topology this issue cares about. |
| EtcdFiveNodeFailure | `RequestRemediation` | `formal/specs/Lifecycle.qnt:1845-1889` | Reuse the existing remediation-request vocabulary for failed members. |
| EtcdFiveNodeFailure | `PromoteLearner` | `formal/specs/EtcdMembership.qnt:168-186`; `formal/specs/Lifecycle.qnt:771-792` | Ground learner promotion during recovery. |
| EtcdFiveNodeFailure | `NoDoublePromotionDuringRecovery` / `leaderFollowersLossRun` | same | Express the likely remediation-ordering counterexample where a 3-failure recovery promotes multiple learners in one recovery window. |
| EtcdFiveNodeFailure | `RemediationBoundedPerScenario` / `symmetricTripleLossRun` | same | Express the bounded-remediation counterexample shape for a symmetric 3-failure pattern. |

### KubeletPlegHang.qnt

Standalone slow-CRI / kubelet PLEG hang model for issue #45. The repo
does not carry PLEG-specific controller logic, so the abstraction is
grounded to the existing NodeReady / Machine health surfaces plus the
existing remediation vocabulary in the formal corpus.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| KubeletPlegHang | `nodeReadyDerivedFromPleg` / `PlegThresholdBreached` | `controllers/noderefutil/util.go:62-82`; `internal/controllers/machine/machine_controller_status.go:323-360` | Ground the `NodeReady` derivation surface that Machine / MHC logic ultimately consumes. |
| KubeletPlegHang | `MhcFiresOnNotReady` / `RequestRemediation` | `formal/specs/KCPReconcile.qnt:164-178`; `formal/specs/Lifecycle.qnt:1845-1889`; `formal/specs/MachineSetPreflight.qnt:260-278` | Reuse the existing remediation-request vocabulary rather than inventing a new MHC path. |
| KubeletPlegHang | `CriSlowdown` / `TickPleg` / `CriRecover` | node-health / NodeReady provenance above | Compress the slow-CRI operational cause for a transient PLEG hang that flips `NodeReady` without a persistent machine failure. |
| KubeletPlegHang | `RemediationAfterStableNotReady` / `overeagerRemediationRun` | same | Express the issue’s counterexample target: remediation fires on a transient PLEG-induced NotReady before the CRI recovers. |

### RegistryPullBackoff.qnt

Standalone registry-throttle / bootstrap-timeout model for issue #46.
This spec keeps only the kube-apiserver image pull, a compact backoff
counter, a registry throttle bit, and the control-plane-initialised /
bootstrap-timeout latches.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| RegistryPullBackoff | `KubeletRetryPull` / `pullAttempts` / `pullBackoffUntil` | `api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go:378`; `api/controlplane/kubeadm/v1beta1/condition_consts.go:106` | Ground the user-visible bootstrap symptom surface: image pulls can legitimately sit in `ImagePullBackOff` without a permanent control-plane fault. |
| RegistryPullBackoff | `MarkControlPlaneInitialised` | `controlplane/kubeadm/internal/controllers/status.go` (`setControlPlaneInitialized`); existing bootstrap progression in `formal/specs/ClusterE2ERefined.qnt` | Ground the moment the control plane is considered successfully bootstrapped. |
| RegistryPullBackoff | `BootstrapTimeout` | same control-plane-initialised surface above | Model the KCP-side bootstrap/init timeout firing while image pulls are still retrying under backoff. |
| RegistryPullBackoff | `NoFalseBootstrapFailure` / `timeoutBeforePullClearsRun` | same | Express the issue’s core counterexample: bootstrap fails even though the registry throttle is transient and the image would eventually pull. |
| RegistryPullBackoff | `BootstrapTimeoutAccountsForBackoff` / `boundedThrottleRun` | same | Show the safe regime where the timeout budget exceeds the legitimate transient backoff window. |

### StaticPodMemPressure.qnt

Standalone memory-pressure / eviction model for issue #47. This spec
keeps just the control-plane static pods, one workload pod, a per-pod
priority class, and kubelet-style memory-pressure eviction choice.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| StaticPodMemPressure | `KcpOutputsCorrectPriority` | `bootstrap/kubeadm/types/upstreamv1beta3/types.go:456-457`; rendered bootstrap artifacts under `_artifacts/.../resources/kube-system/Pod/kube-apiserver-*.yaml` show `priorityClassName: system-node-critical` | Ground the customization surface where drift could remove the critical priority from kubeadm-generated static pods, plus concrete rendered output proving the intended value. |
| StaticPodMemPressure | `EnterMemPressure` / `BuildEvictionCandidates` / `EvictWorkload` | operational abstraction over kubelet eviction under node memory pressure; contrasted with CAPI drain logic that explicitly skips static pods in `internal/controllers/machine/drain/filters.go:237` | Model kubelet eviction under MemPressure, which is distinct from CAPI's drain path and therefore worth specifying separately. |
| StaticPodMemPressure | `CriticalStaticPodsImmuneFromEviction` / `misPriorityEvictionRun` | `controlplane/kubeadm/internal/workload_cluster_conditions.go:668-670, 758-966` (static-pod health surfacing on control-plane machines) | Express the issue's counterexample target: if kube-apiserver is mis-priority-classed, MemPressure can evict it mid-reconcile and CAPI will later surface that as a failed static-pod condition. |

### LoadBalancerDrain.qnt

Standalone LB deregistration / connection-drain model for issue #52.
This spec keeps one apiserver target registration bit, one drain-progress
counter, one apiserver liveness bit, and one client-hung flag.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| LoadBalancerDrain | `LbDeregisterTarget` / `LbDrainComplete` | `test/infrastructure/docker/internal/docker/loadbalancer.go:136-203`; `test/infrastructure/docker/internal/controllers/backends/docker/dockermachine_backend.go:414-464` | Ground the provider-side responsibility to update LB targets and the fact that the update/drain is not instantaneous. |
| LoadBalancerDrain | `KillApiserverPod` | `controlplane/kubeadm/internal/controllers/controller.go:1362-1409` (KCP pre-terminate hook sequencing) | Ground the control-plane deletion/termination side where KCP should avoid killing the apiserver before dependent cleanup/drain has finished. |
| LoadBalancerDrain | `ClientHangsOnDereg` / `KcpUpgradeAccountsForLbDrain` | same LB-drain and KCP sequencing surfaces plus `APIServerPodHealthy` health surfacing in `controlplane/kubeadm/internal/workload_cluster_conditions.go:668-670` | Express the issue's counterexample target: existing clients hang on a deregistered-but-not-yet-drained target if KCP kills the apiserver too early. |

### NetworkPolicyMidFlight.qnt

Standalone NetworkPolicy mid-flight connection-cut model for issue #53.
This spec keeps one policy-applied bit, one connection mode, one
termination marker, and explicit “detected vs silent” controller states.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| NetworkPolicyMidFlight | `ApplyNetpol` | operator fault surface; grounded to the repo's split between cached and uncached clients in `controllers/clustercache/cluster_accessor_client.go:75-109, 207-293` | Ground that controllers have different connection modes and that policy can be introduced after those connections already exist. |
| NetworkPolicyMidFlight | `EnforceOnExistingConn` / `EnforceOnNewOnly` | same cached/uncached client split above | Model the two issue-relevant implementations: policy terminates an existing watch connection immediately, or only affects new connections while a long-lived watch silently survives. |
| NetworkPolicyMidFlight | `CachedClientReconnectFails` | `controllers/clustercache/cluster_accessor_client.go:293` (cached client wrapper with timeouts on Get/List) | Ground the fail-fast path for controllers that create new requests instead of holding a long-lived stream. |
| NetworkPolicyMidFlight | `NoSilentControllerStall` / `silentWatchSurvivesRun` | same | Express the issue's counterexample target: a long-lived watch survives the policy cut and the controller stalls without bounded detection. |

### StaticPodHashReloadRace.qnt

Standalone static-pod identity / kubelet-reload race model for issue #48.
This spec keeps two intended static-pod identities, their rendered file
content hash, a desired kubelet config generation, and the kubelet's last
observed reload generation.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| StaticPodHashReloadRace | `WriteStaticPodManifest(intent, hash)` / `manifestHash` | rendered static-pod outputs under `_artifacts/.../resources/kube-system/Pod/*.yaml`; `controlplane/kubeadm/internal/workload_cluster_conditions.go:668-670, 758-966` (health surfacing if the resulting pod identity drifts) | Ground the manifest-writing surface where two distinct intended identities can accidentally collide if keyed only by content hash. |
| StaticPodHashReloadRace | `KubeadmRotate` / `desiredConfigGen` | `controlplane/kubeadm/internal/workload_cluster.go:171-211` (`UpdateClusterConfiguration`) plus `bootstrap/kubeadm/types/upstreamv1beta3/types.go:219` (kubelet config ConfigMap grounding) | Ground the desired kubelet config changing independently from what the kubelet has reloaded. |
| StaticPodHashReloadRace | `KubeletReload` / `kubeletReloadGen` | same kubelet-config ConfigMap surface above | Model the lagging kubelet reload fence that eventually catches up to the desired config generation. |
| StaticPodHashReloadRace | `NoHashCollisionAcrossDistinctIntents` / `hashCollisionRun` | same | Express the issue's counterexample target: two distinct intended static-pod identities collapse to the same manifest hash and only one is observed. |
| StaticPodHashReloadRace | `ReloadEventuallyConverges` / `staleReloadRun` | same | Express the reload-fence target: desired kubelet config generation should not remain permanently ahead of kubelet's observed generation. |

### BootstrapCsrLag.qnt

Standalone CSR approval-lag model for issue #49. This spec keeps only a
small CSR queue, an approval-rate budget, per-CSR submit time, the
kubelet client-cert latch, and a bootstrap timeout counter.

| Spec | Action / invariant | Go / doc reference | Purpose |
| ---- | ------------------ | ------------------ | ------- |
| BootstrapCsrLag | `KubeletSubmitCSR` / `csrQueue` / `submitTime` | `docs/proposals/archived/20210222-kubelet-authentication.md:412-422` (client CSR flow) | Ground the kubelet bootstrap flow where the node submits a CSR and waits for approval before obtaining its client cert. |
| BootstrapCsrLag | `ApprovalControllerProcess` / `approvalRate` | same proposal, especially the approval/signing flow | Model approval-controller lag as a bounded queue-processing rate rather than instantaneous approval. |
| BootstrapCsrLag | `BootstrapTimeout` / `BootstrapTimeoutCoversCsrLatency` | `test/infrastructure/docker/api/v1beta1/condition_consts.go:67-70` (`BootstrapFailed`) | Ground the user-visible failure surface when bootstrap times out even though approval would eventually succeed. |
| BootstrapCsrLag | `NoStrandedKubelet` / `strandedKubeletRun` | same | Express the second issue target: kubelet should not end up without a client cert and without any CSR left in flight. |

### ServiceAccountTokenRotation.qnt

Standalone projected ServiceAccountToken rotation model for issue #73.
This spec keeps the current token version, the token version captured by
a long-running reconcile call, a current expiry time, and whether a 401
triggered a refresh-aware retry.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| ServiceAccountTokenRotation | `RotateToken` / `Returns401` | `test/framework/autoscaler_helpers.go:596-604`; `test/e2e/kcp_remediations.go:709-717` | Ground the concrete token-issuance surface via `TokenRequest` and the fact that tokens are expected to rotate over time. |
| ServiceAccountTokenRotation | `CaptureClient` / `RefreshTokenAndRetry` | `controllers/clustercache/cluster_accessor_client.go`; `controlplane/kubeadm/internal/controllers/remediation.go:656`; `controlplane/kubeadm/internal/cluster.go:136` | Ground the long-lived/cached client surface where a reconcile can hold credentials across time and later reacquire a client. |
| ServiceAccountTokenRotation | `RetryOn401WithRefreshedToken` / `refreshAfter401Run` | same | Show the intended regime where a stale token causes a 401 and reconcile retries with a refreshed token. |
| ServiceAccountTokenRotation | `NoSilentReconcileFailure` / `staleTokenFailureRun` | same | Express the issue's counterexample target: a stale token yields a 401 and reconcile fails without a rotation-aware retry. |

### ConditionMessageTruncation.qnt

Standalone condition-message truncation model for issue #72. This spec
keeps only the full message length, stored message length, whether the
root cause lives in the tail, whether the stored condition still carries
that root cause, and whether a companion event preserved the full text.

| Spec | Action / invariant | Go / API reference | Purpose |
| ---- | ------------------ | ------------------ | ------- |
| ConditionMessageTruncation | `EmitLongCondition` | `internal/controllers/machine/drain/drain.go`; `internal/controllers/topology/cluster/conditions.go:195-276` | Ground the real long condition-message builders that accumulate multi-clause status details. |
| ConditionMessageTruncation | `TruncateKeepingTail` / `TruncateDroppingTail` | `api/bootstrap/kubeadm/v1beta1/kubeadm_types.go:411,418,782`; `api/core/v1beta2/clusterclass_types.go:394,410,706,879,1247,1303` | Ground the concrete 1024-byte validation surfaces where message-bearing fields can be truncated or rejected. |
| ConditionMessageTruncation | `RootCauseSurvivesTruncation` / `tailDroppedRun` | same plus `internal/controllers/machine/drain/drain_test.go:1786-1815` | Express the issue's counterexample target: keeping only the prefix silently drops the root-cause-bearing tail. |
| ConditionMessageTruncation | `EmitCompanionEvent` | same | Capture the alternative safe regime where the condition is shortened but the full diagnostic survives in a companion event. |

### MtuFragmentation.qnt

Standalone MTU/fragmentation model for issue #50. This spec keeps one
effective path MTU, one kubelet-sent etcd snapshot packet size, a DF
flag, optional ICMP "fragmentation needed" visibility, and a bootstrap /
snapshot transfer timeout latch.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| MtuFragmentation | `linkMtu` / `EFFECTIVE_POD_MTU` | `test/e2e/config/docker-dev.yaml` (`vethMTU: 1450`) | Ground the cluster's effective pod-network MTU used by the Docker dev test surface. |
| MtuFragmentation | `LargePacketSent` / `dfFlag` / `IcmpFragNeededLost` | operational PMTU / DF abstraction; contrasted with the static-pod bootstrap data plane exercised in the formal corpus | Model silent fragmentation when DF is set and the sender never receives usable PMTU feedback. |
| MtuFragmentation | `EtcdSnapshotEventuallySucceeds` / `silentFragDropRun` | `etcdadm-controller/docs/topics/etcd/howto/backup-restore.md` snapshot-restore flow | Express the issue's concrete failure: etcd snapshot transfer never completes because packets stay above path MTU and ICMP feedback is missing. |
| MtuFragmentation | `PathMtuDiscoveryConverges` / `convergedPmtuRun` | same | Show the safe regime where PMTU discovery converges, packet size shrinks, and the snapshot transfer succeeds. |

### CniVethRace.qnt

Standalone CNI/veth race model for issue #51. This spec keeps one pod,
one `veth` state, one container-start latch, and a probe/restart loop.
It captures the bootstrap-time race where kubelet starts the container
before the CNI plugin has created the veth.

| Spec | Action / invariant | Go / artifact reference | Purpose |
| ---- | ------------------ | ----------------------- | ------- |
| CniVethRace | `ApplyCni` / `cniApplied` | `docs/book/src/developer/providers/contracts/control-plane.md:17` (CNI explicitly deferred until after control plane instantiation); ClusterResourceSet/CNI artifacts under `_artifacts/...` | Ground that CNI readiness is an external/bootstrap-addon dependency rather than something guaranteed before kubelet begins normal pod lifecycle. |
| CniVethRace | `KubeletStartContainer` / `containerStarted` | kubelet start is abstracted, but the downstream surfaced symptom is the existing node/pod readiness pipeline in `internal/controllers/machine/machine_controller_status.go:323-360` | Model kubelet starting a container even though the network interface has not been created yet. |
| CniVethRace | `CniCreateVeth` / `veth` | same CNI-deferred grounding above | Model the delayed creation of the pod veth by the CNI plugin. |
| CniVethRace | `ProbeFails` / `RestartLoopRequiresRepeatedProbeFailure` | `controllers/noderefutil/util.go:62-82`; `internal/controllers/machine/machine_controller_status.go:323-360` for the broader readiness symptom surface | Capture the operational consequence: TCP/startup probes fail and the container restarts repeatedly while networking is still absent. |
| CniVethRace | `NoContainerStartBeforeCni` / `probeLoopBeforeVethRun` | same | Express the issue's explicit counterexample target: container start precedes CNI/veth readiness. |

### EtcdFiveNodeFailure.qnt

Standalone 5-node / 3-failure etcd recovery corpus for issue #44. This
spec reuses the same quorum arithmetic and learner-promotion vocabulary
as the earlier etcd operational models, but fixes the carrier set at five
voters plus two learners and focuses on concrete three-failure shapes.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| EtcdFiveNodeFailure | `TripleFailure` | `formal/specs/Lifecycle.qnt:466-512` (existing 5-node state carriers) | Ground the concrete five-control-plane baseline and express distinct three-failure patterns without waiting on the blocked replica-parameterisation work. |
| EtcdFiveNodeFailure | `RequestRemediation` | `formal/specs/Lifecycle.qnt:1845-1889` | Ground the remediation-request side of recovery ordering. |
| EtcdFiveNodeFailure | `PromoteLearner` | `formal/specs/EtcdMembership.qnt:168-191`; `formal/specs/Lifecycle.qnt:771-796` | Ground learner promotion during quorum restoration. |
| EtcdFiveNodeFailure | `NoDoublePromotionDuringRecovery` / `leaderFollowersLossRun` | same | Express the likely counterexample where an over-eager recovery path promotes multiple learners while still processing the same 3-failure incident. |
| EtcdFiveNodeFailure | `RemediationBoundedPerScenario` / `symmetricTripleLossRun` | same | Bound the amount of remediation churn per 3-failure scenario and surface any “keep requesting forever” pattern as a counterexample. |
| EtcdFiveNodeFailure | `sequentialRecoveryRun` | same | Show the intended safe regime: one promotion, one recovery, then end the recovery window. |

### EtcdWalFaults.qnt

Standalone WAL-corruption / disk-full member-state model for issue #42.
This is a small 3-member etcd health slice grounded against the existing
remediation and opaque-failure vocabulary in `Lifecycle.qnt`, plus the
generic custom-condition / crash provenance already used elsewhere in the
 corpus.

| Spec | Action / invariant | Go / spec reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| EtcdWalFaults | `WalCorrupt` | `formal/specs/Lifecycle.qnt:2913` (opaque crash provenance) | Model a bit-flip / WAL-corruption state that only becomes externally visible once the member crashes on restart. |
| EtcdWalFaults | `MarkDiskFull` | `formal/specs/Lifecycle.qnt:3522-3764` (`DiskPressure` / custom-condition provenance) | Model the `mvcc: database space exceeded` style state where writes fail and the member effectively leaves healthy quorum participation. |
| EtcdWalFaults | `ObserveOpaqueMemberLoss` / `RequestRemediation` | `formal/specs/Lifecycle.qnt:1845-1889` (`RequestRemediation`) | Ground the KCP-side detection + remediation path once a member loss becomes externally visible. |
| EtcdWalFaults | `KcpDetectsAndRemediates` / `detectedFaultRun` | same | Capture the intended remediation regime once the opaque failure is observed. |
| EtcdWalFaults | `NoSilentMemberLoss` / `silentCorruptionRun` | same | Express the counterexample where corruption/crash removes a member from effective quorum without any detection/remediation signal. |

### MachineDeploymentRollout.qnt

MachineDeployment rollout abstraction for issue #14. Focuses on
rolling-update surge / availability bounds, concurrent old-MS
scale-down versus MachineHealthCheck remediation, and
PDB-blocked drain timeout requeue behaviour.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | ------------ | ------- |
| MachineDeploymentRollout | BeginRolloutStep | `internal/controllers/machinedeployment/machinedeployment_rolling.go` (rollout planner entry; abstracted) | Start a new rollout generation by aligning the active template to the desired template. |
| MachineDeploymentRollout | CreateNewMS | `internal/controllers/machinedeployment/machinedeployment_sync.go` (new MachineSet creation path; abstracted) | Create a replacement Machine under the new template subject to surge budget. |
| MachineDeploymentRollout | MarkProvisionedHealthy | `internal/controllers/machine/machine_controller.go` (Machine becoming Ready; abstracted) | Replacement Machine reaches Healthy and contributes to availability. |
| MachineDeploymentRollout | ScaleDownOldMS | `internal/controllers/machinedeployment/machinedeployment_rolling.go` (old MachineSet scale-down; abstracted) | Rollout planner selects an old Machine for drain / deletion after replacement capacity exists. |
| MachineDeploymentRollout | MHCFlagUnhealthy | `internal/controllers/machinehealthcheck/` (unhealthy target detection; abstracted) | MachineHealthCheck marks a Machine unhealthy. |
| MachineDeploymentRollout | RemediateUnhealthy | `internal/controllers/machinehealthcheck/machinehealthcheck_targets.go` plus Machine deletion path | MHC-driven deletion of an unhealthy Machine, gated against conflicting rollout ownership. |
| MachineDeploymentRollout | DrainProgressToDeleting | `internal/controllers/machine/drain/drain.go` | Drain succeeds and the selected Machine transitions to deletion. |
| MachineDeploymentRollout | DrainTimeout | `internal/controllers/machine/drain/drain.go` (`nodeDrainTimeout`) | PDB-blocked drain times out and requeues replacement demand instead of silently disappearing. |
| MachineDeploymentRollout | CompleteDeletion | `internal/controllers/machine/machine_controller.go` (delete finalisation; abstracted) | Machine object is fully removed and rollout bookkeeping clears ownership flags. |
| MachineDeploymentRollout | OperatorChangesReplicas | Operator edit to `MachineDeployment.spec.replicas` | Replica target changes mid-flight. |
| MachineDeploymentRollout | OperatorChangesTemplate | Operator edit to `MachineDeployment.spec.template` | Template changes mid-flight, aborting the current rollout generation. |
| MachineDeploymentRollout | MachineDeletionRaceWithMHC | (model-only bug action) | Synthetic stale-ownership race used only to demonstrate a conflicting-delete counterexample. |

### MachineDeploymentRolloutRefined.qnt

Refinement of `MachineDeploymentRollout.qnt` onto a one-key
controller-runtime substrate. Verifies that the rollout body
actions only happen while the MachineDeployment key is in flight
and that FM-45 per-key serialisation still holds.

| Spec | Action | Go reference | Purpose |
| ---- | ------ | ------------ | ------- |
| MachineDeploymentRolloutRefined | ManagerStartAndLeader | `pkg/manager/internal.go:347`, `:619-625`, `:650` | Substrate manager / leader-election bootstrap. |
| MachineDeploymentRolloutRefined | ProcessNextWorkItem | `pkg/internal/controller/controller.go:419` | Substrate worker dispatch for the MD key. |
| MachineDeploymentRolloutRefined | ReconcileFinishRequeueAfter | `pkg/internal/controller/controller.go:495-503` | RequeueAfter branch returning the key to waiting. |
| MachineDeploymentRolloutRefined | TimerExpires | `pkg/controller/priorityqueue/priorityqueue.go:309-356` | Waiting item becomes ready again. |
| MachineDeploymentRolloutRefined | BeginRolloutStep | `internal/controllers/machinedeployment/` rollout planner entry (abstracted) | Rollout body action, gated by reconcile-in-flight. |
| MachineDeploymentRolloutRefined | CreateNewMS | `internal/controllers/machinedeployment/` new MachineSet / replacement creation (abstracted) | Replacement creation while the MD key is in flight. |
| MachineDeploymentRolloutRefined | MarkProvisionedHealthy | Machine Ready observation (abstracted) | Replacement contributes to availability. |
| MachineDeploymentRolloutRefined | ScaleDownOldMS | old MachineSet scale-down (abstracted) | Rollout-owned old-Machine drain. |
| MachineDeploymentRolloutRefined | MHCFlagUnhealthy | MHC target detection (abstracted) | Unhealthy signal enqueued through the same MD reconcile ownership model. |
| MachineDeploymentRolloutRefined | RemediateUnhealthy | Machine remediation path (abstracted) | MHC-owned delete path, still single-key serialised. |
| MachineDeploymentRolloutRefined | DrainProgressToDeleting / DrainTimeout / CompleteDeletion | `internal/controllers/machine/drain/drain.go` + Machine delete finalisation | Body actions under the in-flight reconcile guard. |

### ClusterClassPatches.qnt

ClusterClass patch-engine abstraction for issue #15. Focuses on the
ordered accumulation loop in the topology patch engine, definition-scoped
variable visibility, per-MachineDeployment override precedence, and the
webhook-side immutable / variable validation gates.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| ClusterClassPatches | `PatchAppendOrder` / `ConflictingPatchOnSameField` / ordered merge | `internal/controllers/topology/cluster/patches/engine.go:66-127` | Loop over `ClusterClass.Spec.Patches` in declaration order; accumulate later patch effects on top of earlier ones. |
| ClusterClassPatches | `mergeDeterministic` / `mergeDeterministicAllOrders` | `internal/controllers/topology/cluster/patches/engine.go:92-127` | Compare stable independent-field merges against a canonical order; overlapping field writes are logged as counterexample candidates. |
| ClusterClassPatches | `definitionsFrom`, `noPhantomVar` | `internal/controllers/topology/cluster/patches/engine.go:99-106`, `:164-241` | Model the `definitionFrom`-scoped variable slice used to calculate patch-visible variables. |
| ClusterClassPatches | patch application to templates | `internal/controllers/topology/cluster/patches/engine.go:435-513` | RFC6902 patch accumulation into the request item before desired-state projection. |
| ClusterClassPatches | `MergedTemplateApplied` / desired object projection | `internal/controllers/topology/cluster/patches/engine.go:534-632` | Apply the merged template back onto desired objects after all patches complete. |
| ClusterClassPatches | `immutablePreserved` | `internal/controllers/topology/cluster/patches/patch.go:61-116` | Preserve fields that the topology controller owns separately (analogous to immutable / controller-owned fields not being overwritten by later patch materialisation). |
| ClusterClassPatches | JSON patch shape + variable references | `internal/webhooks/patch_validation.go:37-140`, `:320-454`, `:526-559` | Validate patch names, selectors, JSON patch structure, and variable references. |
| ClusterClassPatches | `OperatorAddsVariable` / `OperatorRemovesVariable` / `noPhantomVar` | `internal/webhooks/cluster.go:128-130`, `:754-896` | Default and validate Cluster / MachineDeployment override variables in a single webhook pass to avoid races. |
| ClusterClassPatches | `ClusterClassImmutableFieldChanges` / `immutableMergedCandidate` | `internal/webhooks/cluster.go:898-933` plus variable CEL validation in `internal/topology/variables/cluster_variable_validation_test.go:2240-2320` | Immutable-field changes are rejected at validation time; a stronger candidate that inspects the pre-validation merged template is intentionally logged as a counterexample. |
| ClusterClassPatches | `OverrideMachineDeploymentTemplate` / `overridesSurviveCC` | `internal/controllers/topology/cluster/patches/engine.go:203-241`, `internal/webhooks/cluster.go:804-817`, `:866-879` | Preserve per-MachineDeployment overrides as a separate, later layer even when ClusterClass patch order changes. |

### ClusterClassTopologyRace.qnt

Standalone ClusterClass / ClusterTopology torn-read model for issue #84.
This spec keeps a single ClusterClass version number, one topology-side
observed version, one variable-definition state, and one torn-read flag.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| ClusterClassTopologyRace | `UpdateClusterClass` / `FinishClusterClassUpdate` | `internal/controllers/topology/cluster/cluster_controller.go:354`, `internal/webhooks/cluster.go:754-756` | Ground the fact that topology reconciliation reads ClusterClass and defaults/validates variables against it while updates can still be in flight. |
| ClusterClassTopologyRace | `TopologyReadsPinnedVersion` / `TopologyReadsMidUpdate` | `internal/controllers/topology/cluster/cluster_controller.go:354`, `internal/topology/variables/utils.go:78` | Distinguish the safe version-pinned read from the adversarial mid-update torn read where variable-definition validation would surface an aggregate error. |
| ClusterClassTopologyRace | `ConsistentCCViewPerReconcile` / `tornReadRun` | same | Express the issue's counterexample target: a reconcile observes a torn ClusterClass definition set and produces an invalid merged template. |

### ClusterResourceSetTiming.qnt

Standalone ClusterResourceSet timing model for issue #85. This spec keeps
just control-plane initialisation, kubelet-join completion, the CRS
strategy (`ApplyOnce` vs `Reconcile`), and whether the applied payload
ever becomes effective.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| ClusterResourceSetTiming | `CrsApplyOnInit` | `internal/controllers/clusterresourceset/clusterresourceset_controller.go:292-447`, `internal/controllers/clusterresourceset/clusterresourceset_scope.go:81-87` | Ground the real strategy split where CRS either applies once or keeps reconciling until resources converge. |
| ClusterResourceSetTiming | `MarkControlPlaneInitialised` / `KubeletsJoin` | `internal/controllers/topology/cluster/cluster_controller.go:354` | Ground the race between control-plane init and later kubelet/node join readiness. |
| ClusterResourceSetTiming | `ApplyOnceEventuallyTakesEffect` / `applyBeforeJoinRun` | same | Express the issue's counterexample: `ApplyOnce` consumes the one-shot apply window before kubelets have joined, so the payload never takes effect. |

### AutoscalerKcpSurgeRace.qnt

Standalone autoscaler + KCP surge-race model for issue #87. This spec
keeps autoscaler desired replicas, KCP rollout desired replicas, the
actual worker replica count, and whether the two actors have arbitrated a
single source of truth.

| Spec | Action / invariant | Go / API reference | Purpose |
| ---- | ------------------ | ------------------ | ------- |
| AutoscalerKcpSurgeRace | `AutoscalerSetReplicas` | `api/core/v1beta1/cluster_types.go:733,921` | Ground the fact that an external actor like cluster-autoscaler may manage replica count. |
| AutoscalerKcpSurgeRace | `KcpUpgradeRoll` / `ApplyRolloutSurge` | `internal/controllers/machinedeployment/mdutil/util.go:295-302,336,663-684`; `internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go:481-515` | Ground the rollout side's use of `replicas + maxSurge` while a rolling update is in progress. |
| AutoscalerKcpSurgeRace | `SurgeBoundUnderConcurrentScale` / `concurrentScaleRollRun` | same | Express the issue's core counterexample: autoscaler scale-up and rollout surge both grow the pool before a single desired count is arbitrated. |
| AutoscalerKcpSurgeRace | `AutoscalerKcpArbitrated` / `serializedScaleRollRun` | same | Show the safe regime where autoscaler intent is incorporated before rollout surge is computed. |

### EtcdKubernetesVersionSkew.qnt

Standalone mid-rollout etcd-version × Kubernetes-version dependency model
for issue #81. This spec keeps the control-plane Kubernetes version, the
explicit `etcdImageTag`, old/new replica counts, and a preflight/dependency
trap bit.

| Spec | Action / invariant | Go / test reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| EtcdKubernetesVersionSkew | `StartKubernetesUpgrade` / `FinishKubernetesRoll` | `test/framework/controlplane_helpers.go:340-341`; `test/framework/cluster_topology_helpers.go:98-100` | Ground the fact that Kubernetes version and `etcdImageTag` are separate upgrade knobs in the real topology/control-plane helpers. |
| EtcdKubernetesVersionSkew | `BumpEtcdTagOrdered` / `BumpEtcdTagMidRollout` | same plus `test/e2e/cluster_upgrade.go:184,221` | Model the difference between bumping etcd only after the control-plane rollout has settled vs bumping etcd while the rollout is still mid-flight. |
| EtcdKubernetesVersionSkew | `PreflightBlocksUnsupportedOrder` | `internal/controllers/machineset/machineset_preflight.go:100-122,191-220` | Ground the fact that version-skew ordering is enforced on the Kubernetes side, which the model abstracts as a preflight gate that should trip on unsupported ordering. |
| EtcdKubernetesVersionSkew | `NoMidRolloutDependencyTrap` / `midRolloutEtcdBumpRun` | same | Express the issue's counterexample target: etcd is bumped while the control plane is still mid-rollout, tripping a dependency trap before convergence. |

### RollbackSurgeRace.qnt

Standalone rollback-during-partial-cycle surge model for issue #82. This
spec keeps only old/new replica counts, desired replicas, `maxSurge`, and
a rollback-requested bit.

| Spec | Action / invariant | Go / test reference | Purpose |
| ---- | ------------------ | ------------------- | ------- |
| RollbackSurgeRace | `StartSurge` / `DrainOldReplica` | `internal/controllers/machinedeployment/mdutil/util.go:295-302,336,663-684`; `internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go:481-515` | Ground the standard rolling-update surge arithmetic and drain ordering. |
| RollbackSurgeRace | `RequestRollback` / `ApplyRollbackSurge` | `internal/controllers/machineset/machineset_controller_test.go:2724` (rollback partial changes test intent) | Ground the operator rollback arriving mid-cycle while surge replicas still exist. |
| RollbackSurgeRace | `NoTransientSurgeBeyondBound` / `rollbackMidCycleRun` | same | Express the issue's counterexample target: rollback reintroduces old replicas before surge cleanup, temporarily exceeding the intended bound. |
| RollbackSurgeRace | `RollbackAppliedAfterDrainPoint` / `serializedRollbackRun` | same | Show the safe regime where rollback waits until the drain point before restoring old replicas. |

### ConcurrentClusterSpecEdits.qnt

Standalone concurrent `Cluster.spec` edit model for issue #65. This spec
keeps the desired version, desired replicas, operator intent bits, and a
compact split between old-version and new-version replica counts.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| ConcurrentClusterSpecEdits | `OperatorEditVersion` / `FreshApplyReplicaEdit` | `internal/controllers/topology/cluster/structuredmerge/serversidepathhelper.go`; `internal/controllers/topology/cluster/structuredmerge/serversidepathhelper_test.go:50-51, 637-638` | Ground the SSA/co-authorship surface where concurrent operators edit different Cluster spec fields. |
| ConcurrentClusterSpecEdits | `StaleApplyReplicaEdit` | same SSA/co-authorship surface | Express the stale full-object apply path that can overwrite a concurrently written version field while still applying the replica edit. |
| ConcurrentClusterSpecEdits | `AddSurgeReplica` / `AddScaleReplica` | `controlplane/kubeadm/internal/controllers/scale.go` | Ground the fact that version rollouts and replica scale-up both change the actual control-plane population and can interact on surge bounds. |
| ConcurrentClusterSpecEdits | `NoLostEdit` / `lostEditRun` | same | Express the issue's first counterexample target: both operators' intents exist, but the final applied spec silently drops one of them. |
| ConcurrentClusterSpecEdits | `NoSurgeBoundViolation` / `surgeRaceRun` | same | Express the second counterexample target: concurrent rollout and scale-up temporarily exceed `desiredReplicas + maxSurge`. |

### ClusterEditDeleteRace.qnt

Standalone Cluster edit/delete race model for issue #68. This spec keeps
only object existence, desired spec generation, last persisted write
generation, and whether a delete was observed before a stale write landed.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| ClusterEditDeleteRace | `BeginSpecEdit` / `PersistSpecWrite` | `util/patch/patch.go:186`; `util/deprecated/v1beta1/patch/patch.go:181` | Ground the normal edit / patch path that can still be in flight when a delete lands. |
| ClusterEditDeleteRace | `DeleteCluster` / `IgnoreNotFoundAfterDelete` | same patch helpers plus the existing stale-enqueue delete surfaces used in `StaleEnqueueShutdown.qnt` | Ground the clean path where delete wins and later writes observe `IsNotFound` / absent state. |
| ClusterEditDeleteRace | `NoWriteAfterDeleteObserved` / `deleteMidEditRun` | same | Express the issue's counterexample target: a stale write still lands after delete has already been observed. |

### BootstrapInfraReadyRace.qnt

Standalone Machine readiness race model for issue #86. This spec keeps
bootstrap readiness, infrastructure readiness, the Machine-ready bit, and
a compact `lastObserved` view that captures which child readiness events
the Machine controller has seen.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| BootstrapInfraReadyRace | `BootstrapFlipsReady` / `MachineReconcileBootstrapOnly` | `internal/controllers/machine/machine_controller_status.go:78-164`; `internal/controllers/machine/machine_controller_phases.go:180-205` | Ground the bootstrap-side readiness mirror from the bootstrap config into Machine conditions / status. |
| BootstrapInfraReadyRace | `InfraFlipsReady` / `MachineReconcileInfraOnly` | `internal/controllers/machine/machine_controller_status.go:167-255`; `internal/controllers/machine/machine_controller_phases.go:305-373` | Ground the infrastructure-side readiness mirror from the infra machine into Machine conditions / status. |
| BootstrapInfraReadyRace | `NoStuckUnreadyDespiteBothChildrenReady` / `missingInfraEventRun` | same | Express the issue’s counterexample target: both children are ready in truth, but the Machine reconcile never observes the infra-ready edge and remains stuck unready. |

### StatusSubresourceLag.qnt

Standalone spec/status lag model for issue #70. This spec keeps a spec
generation, a status generation, a compact status phase, and one flag
recording whether another controller already took a stale decision based
on lagging status.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| StatusSubresourceLag | `UpdateSpecTemplate` | `internal/controllers/machineset/machineset_controller.go`; `internal/controllers/machineset/machineset_preflight.go` | Ground the spec-template change side where generation moves first. |
| StatusSubresourceLag | `UpdateStatusSubresource` | `internal/controllers/cluster/cluster_controller_status.go:45-112`; `internal/controllers/machine/machine_controller_status.go:900-932`; `internal/controllers/machinedeployment/machinedeployment_status.go:90-110` | Ground the fact that phase/status are written through a separate status-subresource update path later than the spec write. |
| StatusSubresourceLag | `LevelTriggeredControllersTolerateLag` / `staleStatusDecisionRun` | same | Express the issue's counterexample target: another controller acts on stale `status.phase=Running` even though the new spec generation implies a scaling/upgrade transition. |

### MachinePoolScaleConflict.qnt

Standalone MachinePool provider-managed scale vs CAPI desired scale model
for issue #89. This spec keeps one MachinePool desired replica count,
one provider-managed actual count, and one coarse `lastReconcile` owner
marker.

| Spec | Action / invariant | Go / API reference | Purpose |
| ---- | ------------------ | ------------------ | ------- |
| MachinePoolScaleConflict | `CapiSetReplicas` | `exp/topology/desiredstate/desired_state.go:1337-1415` | Ground the CAPI-side desired-state path that computes `MachinePool.spec.replicas`. |
| MachinePoolScaleConflict | `ProviderRebalance` / `providerOwnsScale` | `api/core/v1beta1/cluster_types.go:733,921` (external autoscaler ownership hint) | Ground the fact that an external provider/autoscaler may also own the actual pool size. |
| MachinePoolScaleConflict | `EventualConvergence` / `arbitratedScaleRun` | same | Show the safe regime where scale ownership is arbitrated and spec converges to the provider's actual size. |
| MachinePoolScaleConflict | `NoOscillation` / `oscillationRun` | same | Express the issue's counterexample target: CAPI and provider alternately rewrite desired vs actual scale and never converge. |

### KcpMhcDeleteRace.qnt

Standalone KCP + MHC concurrent-delete race model for issue #83. This
spec keeps one unhealthy old machine, one replacement machine, KCP/MHC
selection bits, and which actor currently owns deletion.

| Spec | Action / invariant | Go reference | Purpose |
| ---- | ------------------ | ------------ | ------- |
| KcpMhcDeleteRace | `KcpPickReplacement` / `CreateReplacement` | `controlplane/kubeadm/internal/controllers/scale.go`; `controlplane/kubeadm/internal/controllers/helpers.go` | Ground the KCP-side replacement selection and creation path during rolling repair / scale decisions. |
| KcpMhcDeleteRace | `MhcFlagUnhealthyOld` / `ConcurrentDeleteOldByMhc` | `internal/controllers/machinehealthcheck/machinehealthcheck_controller.go:421-521,795-813` | Ground the MHC-side unhealthy selection and remediation-request/delete authority on the same old machine. |
| KcpMhcDeleteRace | `NoDoubleDelete` / `concurrentDeleteRun` | same plus existing `KCPReconcile.qnt` remediation vocabulary | Express the issue's first counterexample: both KCP and MHC believe they own deletion of the same machine. |
| KcpMhcDeleteRace | `NoReplacementCannibalisation` / `replacementCannibalisedRun` | same | Express the second counterexample: the newly created replacement lands on the same node/failure domain and is immediately selected for MHC-driven deletion. |

### ControllerManagerReplay.qnt

Standalone controller-manager OOM / leader failover / replay model for
issue #90. This spec keeps the current leader replica, leader-alive bit,
cache generation, one durable side effect, and one in-memory completion
marker that is lost when the leader dies.

| Spec | Action / invariant | Go / formal reference | Purpose |
| ---- | ------------------ | --------------------- | ------- |
| ControllerManagerReplay | `OomKillLeader` / `LeaseExpiryAndFailover` | `formal/specs/ControllerRuntime.qnt`; `test/framework/cluster_proxy.go:58` | Ground the fact that leader-election loss and controller restarts already induce replay/retry windows in the existing substrate. |
| ControllerManagerReplay | `ReplayFromDurableState` | same substrate grounding | Show the safe replay regime: the new leader infers from durable state that the effect already happened and only restores its in-memory marker. |
| ControllerManagerReplay | `ReplayDoubleEffect` / `NoDoubleEffect` | same | Express the issue's counterexample target: the new leader replays an already-applied effect because only in-memory state recorded completion. |

### ControllerLeaderSplitBrain.qnt

Standalone management-cluster apiserver split-brain model for issue #94.
This spec keeps only the controller-manager lease view, a durable effect
count, and whether the lease has converged back to one writer.

| Spec | Action / invariant | Go / formal reference | Purpose |
| ---- | ------------------ | --------------------- | ------- |
| ControllerLeaderSplitBrain | `LeaseSplit` / `LeaseConvergeToA` / `LeaseConvergeToB` | controller-manager leader-election flags in `main.go`, `controlplane/kubeadm/main.go`; `formal/specs/ControllerManagerReplay.qnt` | Ground the concrete lease-based leader-election surface and the fact that failover/replay already exists as a formal substrate. |
| ControllerLeaderSplitBrain | `ApplyEffectByA` / `ApplyEffectByB` | same | Model two active leaders each applying the same controller effect during a split-brain window. |
| ControllerLeaderSplitBrain | `NoDuplicateEffectAcrossLeaders` / `splitBrainRun` | same | Express the issue's counterexample target: lease split-brain yields duplicate effect application before convergence. |

### RuntimeSDK.qnt

Runtime extension discovery / registration / retry abstraction for
issue #16. Focuses on the `ExtensionConfig` controller's warm-up and
discovery loop, the runtime client's registration / unregister / cached
call surface, and transport-level replay after restart or partial
failure.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| RuntimeSDK | `RegisterExtension` / `WithdrawExtension` | `exp/runtime/client/client.go:50-93` | Abstract `RuntimeClient.Register` / `Unregister` as the registry membership boundary observed by controllers. |
| RuntimeSDK | `DiscoveryReconcile` / `discoveryConsistent` | `internal/controllers/extensionconfig/extensionconfig_controller.go:108-188`, `:244-297` | Model warm-up readiness, discovery reconcile, and the status/condition update that makes an extension discoverable. |
| RuntimeSDK | `CacheStaleAfterRestartAction` | `internal/controllers/extensionconfig/extensionconfig_controller.go:139-145` plus warm-up runnable registration at `:119-126` | Controller restart invalidates in-memory registry/cache assumptions until warm-up / discovery re-establishes them. |
| RuntimeSDK | `VersionNegotiate` / `ExtensionVersionMismatch` | `exp/runtime/catalog/catalog.go:94-196`, `:214-275` | GroupVersionHook registration and request/response typing act as the version-negotiation contract before an extension becomes invokable. |
| RuntimeSDK | `InvokeHook` / `ConcurrentInvocation` / `idempotentHookUnderRetry` | `exp/runtime/client/client.go:39-48`, `:81-93` | Cached `CallExtension` / `CallAllExtensions` responses separate transport replay from effect-level application. |
| RuntimeSDK | `ExtensionPartialFailure` / `partialFailureRecoverable` | `exp/runtime/client/client.go:81-93` | Partial failure of one handler in an N-extension set must preserve already-completed prefix effects. |
| RuntimeSDK | discovery response cache | `exp/runtime/server/server.go:237-256` | Discovery returns a cached handler set assembled from registered handlers; the model abstracts that as `lastSeen` / `discoveryGen`. |
| RuntimeSDK | transport path registration | `exp/runtime/server/server.go:159-194`, `:258-292` | Handler registration binds hook names to concrete paths and marshalled request/response objects before invocation. |

### Finalizers.qnt

Finalizer-chain abstraction for issue #18. Focuses on the ordered
deletion choreography across Cluster, KCP, MachineDeployment,
MachineSet, Machine, and the provider / bootstrap leaves. The stable
battery verifies safety properties of the live chain; two stronger
ordering / liveness obligations are documented as deliberate
counterexample candidates.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| Finalizers | `RemoveFinalizer(ClusterObj)` / `topologicalOrder` | `internal/controllers/cluster/cluster_controller.go:330-490` | Cluster finalizer removal is delayed until descendant objects are deleting / cleared. |
| Finalizers | `RemoveFinalizer(ControlPlaneObj)` | `controlplane/kubeadm/internal/controllers/controller.go:674-742` | KCP delete path removes the control-plane finalizer only after its owned Machines are gone or handed off. |
| Finalizers | `RemoveFinalizer(MachineDeploymentObj)` | `internal/controllers/machinedeployment/machinedeployment_controller.go:464-472` | MachineDeployment finalizer is held until descendant MachineSets disappear. |
| Finalizers | `RemoveFinalizer(MachineSetObj)` / `ownerDeletionWaitsForChildrenCandidate` | `internal/controllers/machineset/machineset_controller.go:567-575` | MachineSet finalizer removal is ordered after descendant Machines complete deletion; the stronger candidate logs what breaks if that order is violated. |
| Finalizers | `RemoveFinalizer(MachineObj)` / `NodeDrainBlockedAction` / `InfraDeletionBlocked` | `internal/controllers/machine/machine_controller.go:465-665`, `:1034-1051`, `internal/controllers/machine/drain/drain.go` | Machine delete waits on node drain, infrastructure deletion, and bootstrap deletion before removing the Machine finalizer. |
| Finalizers | `RemoveFinalizer(InfraMachineObj)` | `internal/controllers/machine/machine_controller.go:607-665` | Provider-side delete acknowledgement is abstracted as the infra leaf finalizer clearing once quota / in-use blocks are gone. |
| Finalizers | `RemoveFinalizer(BootstrapConfigObj)` | `internal/controllers/machine/machine_controller.go:621-665` | Bootstrap leaf cleanup is ordered underneath Machine delete. |
| Finalizers | `ControllerCrashMidFinalize` / `cacheLagDelay` | `internal/controllers/cluster/cluster_controller.go:330-490`, `controlplane/kubeadm/internal/controllers/controller.go:674-742`, `internal/controllers/machine/machine_controller.go:465-665` | Reconciler crashes / informer lag are abstracted as cache-delay stalls that defer acknowledgement without mutating ownership. |
| Finalizers | `RemoveFinalizer(ClusterResourceSet)` | `internal/controllers/clusterresourceset/clusterresourceset_controller.go:220-256` | ClusterResourceSet delete path demonstrates an additional finalizer-bearing controller outside the core Cluster→Machine chain. |
| Finalizers | `RemoveFinalizer(ExtensionConfig)` | `internal/controllers/extensionconfig/extensionconfig_controller.go:215-217` | ExtensionConfig delete path is another leaf-style controller finalizer used to ground idempotent removal semantics. |

### Pivot.qnt

Clusterctl move / pivot abstraction for issue #17. Focuses on the
source-cluster pause, backup / restore onto the destination graph,
reverse-order source teardown with finalizer stripping, and the final
resume once the destination graph is complete.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| Pivot | `Pause` / `paused` gate | `cmd/clusterctl/client/cluster/mover.go` (`setClusterPause`, pause / unpause orchestration in `move`) | Abstract the source- and destination-cluster pause window that brackets the transfer. |
| Pivot | `Backup` / `backedUp` | `cmd/clusterctl/client/cluster/objectgraph.go` (`Discovery`, graph capture) plus backup phase in `cmd/clusterctl/client/cluster/mover.go` | Capture the source owner graph before restore begins. |
| Pivot | `RestoreToTarget` / `objectConservation` | `cmd/clusterctl/client/cluster/mover.go` (create-on-target ordering during move) | Restore objects onto the destination only after their owners are already present there. |
| Pivot | `ownerReadyOnDst` / `noOrphan` | `cmd/clusterctl/client/cluster/objectgraph.go` owner-graph traversal and topological ordering | Preserve owner closure on the destination graph while allowing temporary duplication across source and destination. |
| Pivot | `RemoveOwnerRefsOnSrc` / `RemoveFinalizersOnSrc` / `finalizerOrdered` | `cmd/clusterctl/client/cluster/mover.go` source delete path, including finalizer stripping before delete completion | Model reverse-order source teardown after destination restore succeeds. |
| Pivot | `secretsCloned` | `cmd/clusterctl/client/cluster/mover.go` + `cmd/clusterctl/client/cluster/objectgraph.go` move graph includes secrets linked into the hierarchy | Preserve required secret payloads for moved cluster / machine objects before destination resume. |
| Pivot | `MidPivotControllerCrash` / `MidPivotNetworkPartition` / `partialPivotRecoverable` | `cmd/clusterctl/client/cluster/mover.go` retry surface and error-return path | Represent mid-transfer failure that leaves the move retryable or returns a clean error. |
| Pivot | `MidPivotMissingCRD` / `ReturnCleanError` | `cmd/clusterctl/client/cluster/objectgraph.go` discovery / type resolution prerequisites | Missing destination CRDs are surfaced as a clean move failure rather than a silent partial commit. |
| Pivot | `crashMutualExclusionCandidate` | `cmd/clusterctl/client/cluster/mover.go` (move is not transactional across clusters) | Stronger candidate logs what breaks if a crash leaves the same object live in both clusters with neither side paused. |
| Pivot | `partialPivotOrphanCandidate` | `cmd/clusterctl/client/cluster/objectgraph.go` owner-graph preservation assumptions | Stronger candidate logs the partial-restore orphan case where a leaf appears on the destination before its owner chain. |

### ConversionWebhook.qnt

v1beta1 ↔ v1beta2 conversion-webhook abstraction for issue #19.
Focuses on round-trip preservation, legacy/new status shuttling via
`Deprecated.V1Beta1` and `V1Beta2`, default-fill reads that must not
mutate stored data, and cross-version failure when the conversion
webhook is unavailable.

| Spec | Action / invariant surface | Go reference | Purpose |
| ---- | -------------------------- | ------------ | ------- |
| ConversionWebhook | `ConvertToV1Beta2` / `ConvertToV1Beta1` | `api/core/v1beta1/conversion.go:47-132`, `api/core/v1beta1/conversion.go:1287-1652` | Abstract the spoke↔hub conversions and the explicit status-field shuttling between legacy and new status compartments. |
| ConversionWebhook | `RoundTripV1Beta1ToV1Beta2ToV1Beta1` / `roundTripSpec` | `api/core/v1beta1/conversion_test.go:45-93`, `util/conversion/conversion.go:190-275` | Model the fuzzed hub-spoke-hub / spoke-hub-spoke round-trip guarantee that spec payload is preserved. |
| ConversionWebhook | `roundTripStatusInformative` | `api/core/v1beta1/conversion.go:1292-1303`, `api/core/v1beta1/conversion.go:1366-1425`, `api/core/v1beta1/conversion.go:1604-1651` | Capture the information-preservation obligation across legacy conditions, `Deprecated.V1Beta1`, and `V1Beta2` status compartments. |
| ConversionWebhook | `webhookFailureSafe` / `WebhookTimeout` | `internal/topology/upgrade/clusterctl_upgrade_test.go:1223-1277` | Conversion-webhook failures must return a clean error and leave the stored object untouched. |
| ConversionWebhook | `WebhookOutageFallbackToNoneConverter` / `noneConverterCrossVersionCandidate` | `cmd/clusterctl/client/convert/resource.go:53`, `util/conversion/conversion.go:43-123` | Ground the risky fallback surface where down-conversion preservation relies on annotation-backed restore data rather than silent cross-version reads. |
| ConversionWebhook | `DefaultsAppliedDuringRead` / `defaultsIdempotent` | `internal/topology/upgrade/clusterctl_upgrade_test.go:1208-1258` | Defaulting during read may change the served view, but must not mutate the stored object across repeated reads. |
| ConversionWebhook | `StatusFieldOnlyInOneVersion` / `informationLossDocumented` | `util/conversion/conversion.go:43-123` | Fields preserved only via the conversion annotation or one-version-only status compartments must be explicitly documented as drop-on-conversion. |

### KubeletPKI.qnt

| Quint module | Action / invariant | Concrete grounding | Why this abstraction is faithful |
|---|---|---|---|
| KubeletPKI | `CreateOwnedKubeconfig` / `RotateOwnedKubeconfig` | `controlplane/kubeadm/internal/controllers/helpers.go:48-98`, `util/kubeconfig/kubeconfig.go:119-213` | Abstract the owned kubeconfig Secret lifecycle that KCP creates and later regenerates when client certs need rotation. |
| KubeletPKI | `ownedSecretOnlyRotates` | `controlplane/kubeadm/internal/controllers/helpers.go:81-95`, `:101-125` | Rotation is guarded on KCP ownership; user-provided or otherwise unowned secrets are observed but not regenerated. |
| KubeletPKI | `rotationRequiresThreshold` | `controlplane/kubeadm/internal/controllers/helpers.go:86-96`, `util/kubeconfig/kubeconfig.go:164-188`, `util/certs/consts.go:25-30` | `NeedsClientCertRotation` gates regeneration on the renewal window (`DefaultCertDuration / 2`). |
| KubeletPKI | `rotationPreservesEndpoint` | `util/kubeconfig/kubeconfig.go:193-213` | Regeneration reuses the endpoint parsed from the existing kubeconfig instead of rewriting it to a new control-plane address. |
| KubeletPKI | `GenerateInitialCA` / `caNotRecreatedAfterInit` | `controlplane/kubeadm/internal/controllers/controller.go:590-668` | Cluster CA material may be generated before KCP initialization, but once initialized missing CA is an error and regeneration is unsupported. |
| KubeletPKI | `ObserveMissingCARequeue` / `missingCARequeues` | `controlplane/kubeadm/internal/controllers/helpers.go:57-72`, `util/kubeconfig/kubeconfig.go:216-237` | Missing dependent CA causes kubeconfig creation to requeue rather than silently minting credentials without a signing authority. |

### TopologyRefined.qnt

Refinement of `Topology.qnt` onto the ControllerRuntime
substrate. Composed state machine: substrate's worker-pool
dispatch fires Topology body actions only while the cluster's
key is in flight (`reconcileInFlight`). Verifies that every
Topology safety invariant survives multi-worker concurrent
substrate semantics. WORKERS = 1.to(2).

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| TopologyRefined | ManagerStart | pkg/manager/internal.go:347. | Substrate copy. |
| TopologyRefined | LeaderAcquire | pkg/manager/internal.go:619, :650. | Substrate copy. |
| TopologyRefined | ProcessNextWorkItem | pkg/internal/controller/controller.go:419. | Substrate copy. |
| TopologyRefined | ReconcileFinishRequeueAfter | pkg/internal/controller/controller.go:495-503. | Substrate copy. |
| TopologyRefined | TimerExpires | pkg/controller/priorityqueue/priorityqueue.go:309-356. | Substrate copy. |
| TopologyRefined | EventEnqueue | pkg/handler/eventhandler.go:124-180. | Substrate copy. |
| TopologyRefined | EvaluateHook | exp/topology/desiredstate/lifecycle_hooks.go (every `RuntimeClient.CallAllExtensions` site). | Hook call fires inside reconcile dispatch. |
| TopologyRefined | ReconcileBeforeClusterCreate | internal/controllers/topology/cluster/cluster_controller.go:441 (`callBeforeClusterCreateHook`). | Body of Reconcile loop. |
| TopologyRefined | ControlPlaneProvisioned | (observable) `reconcile_state.go:218` (`isControlPlaneInitialized`). | Body. |
| TopologyRefined | FireAfterControlPlaneInitialized | internal/controllers/topology/cluster/reconcile_state.go:188. | Body. |
| TopologyRefined | OperatorBumpTopologyVersion | (operator-driven, fires outside reconcile). | Watch event re-enqueues. |
| TopologyRefined | ComputeUpgradePlanOneMinor | exp/topology/desiredstate/upgrade_plan.go:48, :334. | Body. |
| TopologyRefined | ReconcileBeforeClusterUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:39. | Body. |
| TopologyRefined | ReconcileBeforeControlPlaneUpgrade | exp/topology/desiredstate/lifecycle_hooks.go:128. | Body. |
| TopologyRefined | ControlPlaneStepCompletes | (observable) desired_state.go:574. | Body. |

### InPlaceUpdateRefined.qnt

Refinement of (a slice of) `InPlaceUpdate.qnt` onto the
substrate. Demonstrates per-Machine reconciles dispatched by
multiple workers concurrently, with FM-45 ensuring the same
Machine is never reconciled by two workers at once. WORKERS =
1.to(2), MACHINES = 1.to(2).

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| InPlaceUpdateRefined | ManagerStartAndLeader | pkg/manager/internal.go:347, :619-625, :650. | Substrate copy. |
| InPlaceUpdateRefined | ProcessNextWorkItem | pkg/internal/controller/controller.go:419, :311. | Substrate copy. |
| InPlaceUpdateRefined | ReconcileFinishRequeueAfter | pkg/internal/controller/controller.go:495-503. | Substrate copy. |
| InPlaceUpdateRefined | TimerExpires | pkg/controller/priorityqueue/priorityqueue.go:309-356. | Substrate copy. |
| InPlaceUpdateRefined | CallUpdateMachineHook | internal/controllers/machine/machine_controller_inplace_update.go:43, :142, :155-156, :185-189, :192-193. | Hook call body (gated by reconcileInFlightOn). |
| InPlaceUpdateRefined | CompleteInPlaceUpdate | internal/controllers/machine/machine_controller_inplace_update.go:198, :221. | Body. |
| InPlaceUpdateRefined | OperatorRegisterMultiple | (operator-driven; fires outside). | Misconfiguration. |

### MachineSetPreflightRefined.qnt

Refinement of (a slice of) `MachineSetPreflight.qnt` onto the
substrate. Demonstrates the `RequeueAfter` requeue loop driven
by `preflightFailedRequeueAfter` (15s). WORKERS = 1.to(2),
MS_KEYS = 1.to(2).

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| MachineSetPreflightRefined | ManagerStartAndLeader | pkg/manager/internal.go:347, :619-625, :650. | Substrate copy. |
| MachineSetPreflightRefined | ProcessNextWorkItem | pkg/internal/controller/controller.go:419, :311. | Substrate copy. |
| MachineSetPreflightRefined | ReconcileFinishRequeueAfter | pkg/internal/controller/controller.go:495-503. | Substrate copy; matches `preflightFailedRequeueAfter` (machineset_preflight.go:45). |
| MachineSetPreflightRefined | ReconcileFinishSuccess | pkg/internal/controller/controller.go:508-513. | Substrate copy. |
| MachineSetPreflightRefined | TimerExpires | pkg/controller/priorityqueue/priorityqueue.go:309-356. | Substrate copy. |
| MachineSetPreflightRefined | KcpBeginUpgrade | (CP-side abstracted; refines `ControlPlane.IsUpgrading` flipping true at machineset_preflight.go:179). | External event triggering watch. |
| MachineSetPreflightRefined | KcpFinishUpgrade | (CP-side abstracted; mirrors KcpBeginUpgrade reverse). | External event triggering watch. |
| MachineSetPreflightRefined | OperatorRequestScaleUp | (operator-driven; refines a `MachineSet.Spec.Replicas` increment). | External event triggering watch. |
| MachineSetPreflightRefined | EvaluatePreflight | internal/controllers/machineset/machineset_preflight.go:47 (`runPreflightChecks`); call sites at machineset_controller.go:828, :1633. | Body (gated by reconcileInFlightOn). |
| MachineSetPreflightRefined | CompleteScaleUp | (post-preflight branch in `(*Reconciler).reconcile`). | Body. |

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
