// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ClusterE2E.qnt — End-to-end cluster lifecycle model.
//
// One spec covering the full handshake chain from operator-creates-Cluster
// to running-cluster-with-workers-being-upgraded:
//
//   Phase 1 — Cluster created (managed topology). Topology reconciler
//             fires BeforeClusterCreate hook.
//   Phase 2 — InfrastructureCluster controller provisions LB / endpoint;
//             flips InfraCluster.status.ready=true; Cluster controller
//             reads ControlPlaneEndpoint and flips
//             Cluster.status.initialization.infrastructureProvisioned=true.
//   Phase 3 — KCP controller observes infraProvisioned + valid endpoint;
//             initialises first CP Machine via initializeControlPlane
//             (refines `controlplane/kubeadm/internal/controllers/scale.go:43`).
//   Phase 4 — InfraMachine + BootstrapConfig provisioning per CP Machine.
//             Machine flips through bootstrapDataSecretCreated +
//             infrastructureProvisioned + nodeRef set.
//   Phase 5 — KCP scales to N CP Machines via scaleUpControlPlane.
//   Phase 6 — KCP marks ControlPlane.status.initialization.controlPlaneInitialized;
//             Cluster controller observes and flips
//             Cluster.status.initialization.controlPlaneInitialized=true.
//             Topology fires AfterControlPlaneInitialized hook.
//   Phase 7 — MachineDeployment controller observes controlPlaneInitialized;
//             creates worker MachineSets / Machines; same per-Machine
//             provisioning chain.
//   Phase 8 — Cluster reaches Stable.
//   Phase 9 — Operator bumps topology.version. Per-step:
//             BeforeClusterUpgrade → BeforeControlPlaneUpgrade → CP rolls
//             (rolling OR in-place) → AfterControlPlaneUpgrade →
//             BeforeWorkersUpgrade → workers roll (rolling OR in-place)
//             → AfterWorkersUpgrade. After all steps: AfterClusterUpgrade.
//
// SCOPE. 3-CP cluster, 1 worker MachineDeployment with 2 workers.
// One initial topology version + one upgrade step (e.g. v36→v37).
// Both rolling and in-place upgrade paths modelled per CP and per
// worker.
//
// LSP grounding (gopls go_search + grep on the formality working
// tree). All anchors below reference Cluster API at HEAD of branch
// `formality`. See abstraction-mapping.md §ClusterE2E.qnt.
//
//   internal/controllers/cluster/cluster_controller_phases.go
//     :141  Reconciler.reconcileInfrastructure (Cluster controller
//            reads InfraCluster status, copies ControlPlaneEndpoint,
//            sets infrastructureProvisioned=true)
//     :245  cluster.Status.Initialization.InfrastructureProvisioned
//            assignment
//     :251  Reconciler.reconcileControlPlane (Cluster controller
//            reads ControlPlane status, sets controlPlaneInitialized)
//     :347  cluster.Status.Initialization.ControlPlaneInitialized
//            assignment
//
//   internal/controllers/machine/machine_controller_phases.go
//     :148  Reconciler.reconcileBootstrap (Machine controller reads
//            BootstrapConfig.status.dataSecretName, sets
//            BootstrapDataSecretCreated)
//     :179, :239  m.Status.Initialization.BootstrapDataSecretCreated = true
//     :244  Reconciler.reconcileInfrastructure (Machine controller
//            reads InfraMachine.status.ready)
//     :375  m.Status.Initialization.InfrastructureProvisioned = true
//
//   controlplane/kubeadm/internal/controllers/controller.go
//     :265  KCP gate: !kcp.Status.Initialization.ControlPlaneInitialized
//     :296  KCP early-return: !cluster.Status.Initialization.InfrastructureProvisioned
//            || !cluster.Spec.ControlPlaneEndpoint.IsValid()
//   controlplane/kubeadm/internal/controllers/scale.go
//     :43   KubeadmControlPlaneReconciler.initializeControlPlane
//            (creates first CP Machine)
//     :67   KubeadmControlPlaneReconciler.scaleUpControlPlane
//            (creates additional CP Machines after first)
//     :81   preflightChecks gate on scale-up
//     :106  scaleDownControlPlane
//
//   internal/controllers/topology/cluster/cluster_controller.go
//     :441  callBeforeClusterCreateHook
//   internal/controllers/topology/cluster/reconcile_state.go
//     :188  callAfterControlPlaneInitialized
//     :229  callAfterClusterUpgrade
//   exp/topology/desiredstate/lifecycle_hooks.go
//     :39   callBeforeClusterUpgradeHook
//     :128  callBeforeControlPlaneUpgradeHook
//     :184  callAfterControlPlaneUpgradeHook
//     :248  callBeforeWorkersUpgradeHook
//     :314  callAfterWorkersUpgradeHook
//
//   internal/controllers/machine/machine_controller_inplace_update.go
//     :43   reconcileInPlaceUpdate (in-place update body)
//     :142  callUpdateMachineHook
//     :198  completeInPlaceUpdate
//   internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go
//     :53   canUpdateMachineSetInPlace
//
// COMPOSITION. This spec deliberately consolidates state from
// Topology.qnt, InPlaceUpdate.qnt, MachineSetPreflight.qnt and
// Lifecycle.qnt at a coarser abstraction level — the goal is to
// surface CROSS-CONTROLLER ordering invariants, not to repeat
// per-controller details verified elsewhere.
module ClusterE2E {

  // ===============================================================
  // Type space
  // ===============================================================

  type Version = int
  type MachineId = int

  // Cluster phase. Refines the implicit state machine carried by
  // Cluster.status.initialization fields plus
  // Topology.qnt clusterPhase.
  type ClusterPhase =
    | NotCreated            // operator hasn't submitted Cluster CR
    | InfraProvisioning     // InfraCluster provisioning, no endpoint yet
    | InfraReady            // ControlPlaneEndpoint set; KCP can start
    | CPInitialising        // KCP creating first CP Machine
    | CPInitialised         // KCP marked ControlPlaneInitialized=true
                            // AND Cluster has propagated to its own status
    | WorkersStarting       // MD controller observed initialised; creating
                            // first MachineSet/Machines
    | Stable                // Steady state — no upgrade in flight
    | Upgrading             // Operator bumped version; upgrade plan in flight

  // Per-Machine phase. Refines the
  // Machine.Status.Initialization fields at
  // `internal/controllers/machine/machine_controller_phases.go`.
  type MachinePhase =
    | MachineNotCreated
    | InfraMachineCreating  // InfraMachine CR created; not yet provisioned
    | BootstrapCreating     // BootstrapConfig CR created; secret pending
    | MachineProvisioned    // both Bootstrap and Infra ready; node not registered
    | MachineRegistered     // node registered (NodeRef set), kubelet up
    | MachineJoinedEtcd     // (CP only) joined etcd member set
    | MachineReady          // fully part of cluster
    | MachineUpdatingInPlace // in-place update via UpdateMachine hook
    | MachineDeleted        // deleted (rolling-update replaced)

  // Whether a Machine is a control-plane or worker.
  type MachineRole = ControlPlane | Worker

  // Upgrade-step strategy for a Machine. Refines the choice
  // between rolling (delete-and-recreate) and in-place update.
  type UpgradeStrategy =
    | StrategyRolling
    | StrategyInPlace

  // Per-step phase (Topology-side).
  type StepPhase =
    | StepIdle
    | StepCpUpgrade
    | StepCpDone
    | StepWorkersUpgrade
    | StepWorkersDone

  // ===============================================================
  // Bounds
  // ===============================================================

  pure val CP_MACHINES: Set[MachineId] = 1.to(3)
  pure val WORKER_MACHINES: Set[MachineId] = 4.to(5)
  pure val ALL_MACHINES: Set[MachineId] = CP_MACHINES.union(WORKER_MACHINES)

  // ===============================================================
  // State variables — Cluster level
  // ===============================================================

  var clusterPhase: ClusterPhase
  var topologyVersion: Version          // operator-desired version
  var infraProvisioned: bool             // Cluster.status.initialization.infrastructureProvisioned
  var controlPlaneEndpointSet: bool      // Cluster.spec.controlPlaneEndpoint.Host filled
  var controlPlaneInitialised: bool      // Cluster.status.initialization.controlPlaneInitialized
  var stepPhase: StepPhase

  // ===============================================================
  // State variables — Topology hooks
  // ===============================================================

  type Hook =
    | BeforeClusterCreate
    | AfterControlPlaneInitialized
    | BeforeClusterUpgrade
    | BeforeControlPlaneUpgrade
    | AfterControlPlaneUpgrade
    | BeforeWorkersUpgrade
    | AfterWorkersUpgrade
    | AfterClusterUpgrade

  var pendingHooks: Set[Hook]
  var beforeClusterCreateUnblocked: bool   // pre-condition for KCP to start

  // ===============================================================
  // State variables — InfrastructureCluster
  // ===============================================================

  // Refines an external infra provider (vSphereCluster /
  // AWSCluster) flipping `status.ready=true` and setting
  // `status.controlPlaneEndpoint`.
  var infraClusterReady: bool

  // ===============================================================
  // State variables — per-Machine
  // ===============================================================

  var machinePhase: MachineId -> MachinePhase
  var machineRole: MachineId -> MachineRole
  var machineVersion: MachineId -> Version
  var machineCreated: MachineId -> bool       // Machine CR exists
  var machineInfraReady: MachineId -> bool    // InfraMachine.status.ready
  var machineBootstrapReady: MachineId -> bool // BootstrapConfig.status.dataSecretName set
  var machineNodeRef: MachineId -> bool       // Machine.status.nodeRef set

  // ===============================================================
  // State variables — KCP
  // ===============================================================

  var kcpReplicas: int                          // KCP.spec.replicas
  var kcpInitialized: bool                       // KCP.status.initialization.controlPlaneInitialized

  // ===============================================================
  // State variables — MachineDeployment
  // ===============================================================

  var mdReplicas: int                           // MD.spec.replicas
  var mdEnabled: bool                           // MD reconciler is allowed to act

  // ===============================================================
  // State variables — Upgrade
  // ===============================================================

  var cpDesiredVersion: Version                 // KCP picked-up version
  var nextUpgradeStepVersion: Version           // version of current upgrade step
  var upgradeStrategy: UpgradeStrategy           // operator-chosen strategy

  // ===============================================================
  // Pure helpers
  // ===============================================================

  pure def cpMachinesCreated(mc: MachineId -> bool): Set[MachineId] =
    CP_MACHINES.filter(m => mc.get(m))

  pure def cpMachinesReady(mp: MachineId -> MachinePhase): Set[MachineId] =
    CP_MACHINES.filter(m =>
      mp.get(m) == MachineReady or mp.get(m) == MachineJoinedEtcd)

  pure def workerMachinesReady(mp: MachineId -> MachinePhase): Set[MachineId] =
    WORKER_MACHINES.filter(m => mp.get(m) == MachineReady)

  pure def allCpAtVersion(v: Version, mc: MachineId -> bool, mv: MachineId -> Version): bool =
    CP_MACHINES.forall(m => mc.get(m) implies mv.get(m) == v)

  pure def allWorkersAtVersion(v: Version, mc: MachineId -> bool, mv: MachineId -> Version): bool =
    WORKER_MACHINES.forall(m => mc.get(m) implies mv.get(m) == v)

  // KCP entry-gate refines `controller.go:296` —
  // `!cluster.Status.Initialization.InfrastructureProvisioned ||
  //  !cluster.Spec.ControlPlaneEndpoint.IsValid()`.
  pure def kcpEntryGateOpen(infra: bool, endpoint: bool): bool =
    infra and endpoint

  // ===============================================================
  // Initial state
  // ===============================================================

  action init = all {
    clusterPhase'             = NotCreated,
    topologyVersion'          = 36,
    infraProvisioned'         = false,
    controlPlaneEndpointSet'  = false,
    controlPlaneInitialised'  = false,
    stepPhase'                = StepIdle,
    pendingHooks'             = Set(BeforeClusterCreate),
    beforeClusterCreateUnblocked' = false,
    infraClusterReady'        = false,
    machinePhase'             = ALL_MACHINES.mapBy(_ => MachineNotCreated),
    machineRole'              = ALL_MACHINES.mapBy(m =>
                                  if (CP_MACHINES.contains(m)) ControlPlane
                                  else Worker),
    machineVersion'           = ALL_MACHINES.mapBy(_ => 0),
    machineCreated'           = ALL_MACHINES.mapBy(_ => false),
    machineInfraReady'        = ALL_MACHINES.mapBy(_ => false),
    machineBootstrapReady'    = ALL_MACHINES.mapBy(_ => false),
    machineNodeRef'           = ALL_MACHINES.mapBy(_ => false),
    kcpReplicas'              = 3,
    kcpInitialized'           = false,
    mdReplicas'               = 2,
    mdEnabled'                = false,
    cpDesiredVersion'         = 0,
    nextUpgradeStepVersion'   = 0,
    upgradeStrategy'          = StrategyRolling,
  }

  // ===============================================================
  // Phase 1 — Cluster create + BeforeClusterCreate hook
  // ===============================================================

  // FireBeforeClusterCreate refines
  // `internal/controllers/topology/cluster/cluster_controller.go:441`
  // (`Reconciler.callBeforeClusterCreateHook`). Unblocks the
  // ClusterTopology controller to proceed to compute the
  // InfraCluster reference and create it.
  action FireBeforeClusterCreate: bool = all {
    clusterPhase == NotCreated,
    pendingHooks.contains(BeforeClusterCreate),
    pendingHooks'                = pendingHooks.exclude(Set(BeforeClusterCreate))
                                       .union(Set(AfterControlPlaneInitialized)),
    beforeClusterCreateUnblocked' = true,
    clusterPhase'                = InfraProvisioning,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 2 — InfrastructureCluster provisioning
  // ===============================================================

  // InfraClusterProvision refines an external infra provider
  // flipping its `status.ready=true`. The Cluster controller
  // reads this in `reconcileInfrastructure` at
  // `cluster_controller_phases.go:185-190`.
  action InfraClusterProvision: bool = all {
    clusterPhase == InfraProvisioning,
    not(infraClusterReady),
    infraClusterReady'  = true,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ClusterControllerObservesInfraReady refines
  // `Reconciler.reconcileInfrastructure` at
  // `cluster_controller_phases.go:141`: reads
  // InfraCluster.status.controlPlaneEndpoint (line 219), sets
  // `cluster.Spec.ControlPlaneEndpoint`, and at line 245 sets
  // `cluster.Status.Initialization.InfrastructureProvisioned = true`.
  action ClusterControllerObservesInfraReady: bool = all {
    clusterPhase == InfraProvisioning,
    infraClusterReady,
    not(infraProvisioned),
    infraProvisioned'         = true,
    controlPlaneEndpointSet'  = true,
    clusterPhase'             = InfraReady,
    // Frame:
    topologyVersion'             = topologyVersion,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 3-4 — KCP creates first CP Machine + provisioning
  // ===============================================================

  // KcpInitializeControlPlane refines
  // `(*KubeadmControlPlaneReconciler).initializeControlPlane` at
  // `controlplane/kubeadm/internal/controllers/scale.go:43`. Pre:
  // KCP entry gate at `controller.go:296`. Creates the first CP
  // Machine (m=1).
  action KcpInitializeControlPlane: bool = all {
    clusterPhase == InfraReady,
    kcpEntryGateOpen(infraProvisioned, controlPlaneEndpointSet),
    not(machineCreated.get(1)),
    cpMachinesCreated(machineCreated).size() == 0,
    machineCreated'         = machineCreated.put(1, true),
    machinePhase'           = machinePhase.put(1, InfraMachineCreating),
    machineVersion'         = machineVersion.put(1, topologyVersion),
    cpDesiredVersion'       = topologyVersion,
    clusterPhase'           = CPInitialising,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // BootstrapProviderProvisions refines the bootstrap provider
  // (e.g. KubeadmConfig controller) generating cloud-init and
  // setting `BootstrapConfig.status.dataSecretName`. Read by the
  // Machine controller at
  // `machine_controller_phases.go:179, :239`.
  action BootstrapProviderProvisions(m: MachineId): bool = all {
    ALL_MACHINES.contains(m),
    machineCreated.get(m),
    not(machineBootstrapReady.get(m)),
    machineBootstrapReady'  = machineBootstrapReady.put(m, true),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // InfraProviderProvisions refines an external infra provider
  // (e.g. vsphere-machine-controller) flipping its
  // `InfraMachine.status.ready=true`. Read by the Machine
  // controller's reconcileInfrastructure at
  // `machine_controller_phases.go:296`.
  action InfraProviderProvisions(m: MachineId): bool = all {
    ALL_MACHINES.contains(m),
    machineCreated.get(m),
    machineBootstrapReady.get(m),
    not(machineInfraReady.get(m)),
    machineInfraReady'      = machineInfraReady.put(m, true),
    machinePhase'           = machinePhase.put(m, MachineProvisioned),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // KubeletRegistersNode refines the kubelet's local Node
  // registration via kubelet_node_status.go (already grounded in
  // KubeadmJoin.qnt). Sets Machine.status.nodeRef.
  action KubeletRegistersNode(m: MachineId): bool = all {
    ALL_MACHINES.contains(m),
    machinePhase.get(m) == MachineProvisioned,
    not(machineNodeRef.get(m)),
    machineNodeRef'         = machineNodeRef.put(m, true),
    machinePhase'           = machinePhase.put(m, MachineRegistered),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // CpMachineJoinsEtcd refines the kubeadm-join etcd-add-learner
  // → promote-learner sequence (already in KubeadmJoin.qnt at
  // a finer grain). Marks the CP Machine as part of the etcd
  // member set.
  action CpMachineJoinsEtcd(m: MachineId): bool = all {
    CP_MACHINES.contains(m),
    machinePhase.get(m) == MachineRegistered,
    machinePhase'           = machinePhase.put(m, MachineJoinedEtcd),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // CpMachineMarkReady refines KCP marking the CP Machine ready
  // (UpdateMachineConditions etc.).
  action CpMachineMarkReady(m: MachineId): bool = all {
    CP_MACHINES.contains(m),
    machinePhase.get(m) == MachineJoinedEtcd,
    machinePhase'           = machinePhase.put(m, MachineReady),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 5 — KCP scales to N CP Machines
  // ===============================================================

  // KcpScaleUpControlPlane refines
  // `(*KubeadmControlPlaneReconciler).scaleUpControlPlane` at
  // `scale.go:67`. Pre: at least one CP Machine ready
  // (preflightChecks at line 81); creates next CP Machine.
  action KcpScaleUpControlPlane(m: MachineId): bool = all {
    CP_MACHINES.contains(m),
    clusterPhase == CPInitialising,
    kcpEntryGateOpen(infraProvisioned, controlPlaneEndpointSet),
    not(machineCreated.get(m)),
    cpMachinesReady(machinePhase).size() >= 1,
    cpMachinesCreated(machineCreated).size() < kcpReplicas,
    machineCreated'         = machineCreated.put(m, true),
    machinePhase'           = machinePhase.put(m, InfraMachineCreating),
    machineVersion'         = machineVersion.put(m, cpDesiredVersion),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 6 — KCP marks Initialized; Cluster propagates
  // ===============================================================

  // KcpMarkInitialized refines KCP marking
  // `KCP.status.initialization.controlPlaneInitialized=true` once
  // the first CP Machine is healthy (joined etcd, ready).
  action KcpMarkInitialized: bool = all {
    clusterPhase == CPInitialising,
    cpMachinesReady(machinePhase).size() >= 1,
    not(kcpInitialized),
    kcpInitialized'  = true,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ClusterControllerObservesCpInitialised refines
  // `Reconciler.reconcileControlPlane` at
  // `cluster_controller_phases.go:251-349`: reads
  // `ControlPlane.status.initialization.controlPlaneInitialized`
  // (line 289) and at line 347 sets
  // `cluster.Status.Initialization.ControlPlaneInitialized = true`.
  action ClusterControllerObservesCpInitialised: bool = all {
    clusterPhase == CPInitialising,
    kcpInitialized,
    not(controlPlaneInitialised),
    controlPlaneInitialised'  = true,
    clusterPhase'             = CPInitialised,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // FireAfterControlPlaneInitialized refines
  // `internal/controllers/topology/cluster/reconcile_state.go:188`
  // (`Reconciler.callAfterControlPlaneInitialized`).
  action FireAfterControlPlaneInitialized: bool = all {
    clusterPhase == CPInitialised,
    pendingHooks.contains(AfterControlPlaneInitialized),
    pendingHooks'  = pendingHooks.exclude(Set(AfterControlPlaneInitialized)),
    mdEnabled'     = true,
    clusterPhase'  = WorkersStarting,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 7 — Worker MD/MS create workers
  // ===============================================================

  // MdCreateWorker refines the MachineDeployment controller
  // creating Machines via its MachineSet. Pre: mdEnabled (which
  // requires CP initialized — refines the MD reconciler's gate
  // on `Cluster.Status.Initialization.ControlPlaneInitialized`).
  action MdCreateWorker(m: MachineId): bool = all {
    WORKER_MACHINES.contains(m),
    mdEnabled,
    not(machineCreated.get(m)),
    machineCreated'         = machineCreated.put(m, true),
    machinePhase'           = machinePhase.put(m, InfraMachineCreating),
    machineVersion'         = machineVersion.put(m, cpDesiredVersion),
    clusterPhase'           = if (workerMachinesReady(machinePhase).size() + 1 == mdReplicas) Stable
                              else clusterPhase,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // WorkerMarkReady — once worker Machine is registered, mark
  // ready (no etcd join for workers).
  action WorkerMarkReady(m: MachineId): bool = all {
    WORKER_MACHINES.contains(m),
    machinePhase.get(m) == MachineRegistered,
    machinePhase'           = machinePhase.put(m, MachineReady),
    clusterPhase'           = if (clusterPhase == WorkersStarting
                                  and workerMachinesReady(machinePhase).size() + 1 == mdReplicas
                                  and cpMachinesReady(machinePhase).size() == kcpReplicas)
                                 Stable
                              else clusterPhase,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Phase 9 — Upgrade flow
  // ===============================================================

  // OperatorBumpVersion refines an operator editing
  // `Cluster.spec.topology.version`.
  action OperatorBumpVersion(v: Version, strat: UpgradeStrategy): bool = all {
    clusterPhase == Stable,
    v > topologyVersion,
    topologyVersion'          = v,
    nextUpgradeStepVersion'   = topologyVersion + 1,
    upgradeStrategy'          = strat,
    pendingHooks'             = pendingHooks.union(Set(BeforeClusterUpgrade,
                                                        AfterClusterUpgrade)),
    clusterPhase'             = Upgrading,
    // Frame:
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
  }

  // FireBeforeClusterUpgrade refines
  // `exp/topology/desiredstate/lifecycle_hooks.go:39`
  // (`callBeforeClusterUpgradeHook`). Removes BeforeClusterUpgrade
  // from pending; advances stepPhase.
  action FireBeforeClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    pendingHooks.contains(BeforeClusterUpgrade),
    pendingHooks'  = pendingHooks.exclude(Set(BeforeClusterUpgrade)),
    stepPhase'     = StepCpUpgrade,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // CpUpgradeRolling refines KCP rolling-update behaviour: an
  // outdated CP Machine is deleted (placeholder for the rolling
  // replacement) and the new CP Machine version is set
  // immediately to nextUpgradeStepVersion. Refines KCP's
  // selectMachineForInPlaceUpdateOrScaleDown +
  // scaleDownControlPlane at `scale.go:106` and the surrounding
  // upgrade orchestrator.
  action CpUpgradeRolling(m: MachineId): bool = all {
    CP_MACHINES.contains(m),
    clusterPhase == Upgrading,
    stepPhase == StepCpUpgrade,
    upgradeStrategy == StrategyRolling,
    machineCreated.get(m),
    machineVersion.get(m) < nextUpgradeStepVersion,
    machineVersion'         = machineVersion.put(m, nextUpgradeStepVersion),
    machinePhase'           = machinePhase.put(m, MachineReady),
    cpDesiredVersion'       = nextUpgradeStepVersion,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // CpUpgradeInPlace refines the in-place CP path: the
  // UpdateMachine hook is called and on completion the
  // Machine version is bumped without delete/recreate. Refines
  // `internal/controllers/machine/machine_controller_inplace_update.go:43-227`.
  action CpUpgradeInPlace(m: MachineId): bool = all {
    CP_MACHINES.contains(m),
    clusterPhase == Upgrading,
    stepPhase == StepCpUpgrade,
    upgradeStrategy == StrategyInPlace,
    machineCreated.get(m),
    machineVersion.get(m) < nextUpgradeStepVersion,
    machineVersion'         = machineVersion.put(m, nextUpgradeStepVersion),
    machinePhase'           = machinePhase.put(m, MachineReady),
    cpDesiredVersion'       = nextUpgradeStepVersion,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // CpStepCompletes — when all CP Machines have reached
  // nextUpgradeStepVersion, transition to StepCpDone.
  action CpStepCompletes: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCpUpgrade,
    allCpAtVersion(nextUpgradeStepVersion, machineCreated, machineVersion),
    pendingHooks'  = pendingHooks.union(Set(AfterControlPlaneUpgrade,
                                              BeforeWorkersUpgrade,
                                              AfterWorkersUpgrade)),
    stepPhase'     = StepCpDone,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // FireAfterControlPlaneUpgrade refines
  // `lifecycle_hooks.go:184` (`callAfterControlPlaneUpgradeHook`).
  action FireAfterControlPlaneUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCpDone,
    pendingHooks.contains(AfterControlPlaneUpgrade),
    pendingHooks'  = pendingHooks.exclude(Set(AfterControlPlaneUpgrade)),
    stepPhase'     = StepWorkersUpgrade,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // FireBeforeWorkersUpgrade refines
  // `lifecycle_hooks.go:248`.
  action FireBeforeWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    pendingHooks.contains(BeforeWorkersUpgrade),
    pendingHooks'  = pendingHooks.exclude(Set(BeforeWorkersUpgrade)),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // WorkerUpgrade — applies whichever strategy is selected.
  action WorkerUpgrade(m: MachineId): bool = all {
    WORKER_MACHINES.contains(m),
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    not(pendingHooks.contains(BeforeWorkersUpgrade)),
    machineCreated.get(m),
    machineVersion.get(m) < nextUpgradeStepVersion,
    machineVersion'         = machineVersion.put(m, nextUpgradeStepVersion),
    machinePhase'           = machinePhase.put(m, MachineReady),
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machineRole'                 = machineRole,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // WorkerStepCompletes — all workers at the new step version.
  action WorkerStepCompletes: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    not(pendingHooks.contains(BeforeWorkersUpgrade)),
    allWorkersAtVersion(nextUpgradeStepVersion, machineCreated, machineVersion),
    stepPhase'  = StepWorkersDone,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    pendingHooks'                = pendingHooks,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // FireAfterWorkersUpgrade refines `lifecycle_hooks.go:314`.
  action FireAfterWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersDone,
    pendingHooks.contains(AfterWorkersUpgrade),
    pendingHooks'  = pendingHooks.exclude(Set(AfterWorkersUpgrade)),
    stepPhase'     = StepIdle,
    // Frame:
    clusterPhase'                = clusterPhase,
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // FireAfterClusterUpgrade refines
  // `internal/controllers/topology/cluster/reconcile_state.go:229`.
  action FireAfterClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    nextUpgradeStepVersion >= topologyVersion,
    cpDesiredVersion == topologyVersion,
    allCpAtVersion(topologyVersion, machineCreated, machineVersion),
    allWorkersAtVersion(topologyVersion, machineCreated, machineVersion),
    pendingHooks.contains(AfterClusterUpgrade),
    pendingHooks'  = pendingHooks.exclude(Set(AfterClusterUpgrade)),
    clusterPhase'  = Stable,
    // Frame:
    topologyVersion'             = topologyVersion,
    infraProvisioned'            = infraProvisioned,
    controlPlaneEndpointSet'     = controlPlaneEndpointSet,
    controlPlaneInitialised'     = controlPlaneInitialised,
    stepPhase'                   = stepPhase,
    beforeClusterCreateUnblocked' = beforeClusterCreateUnblocked,
    infraClusterReady'           = infraClusterReady,
    machinePhase'                = machinePhase,
    machineRole'                 = machineRole,
    machineVersion'              = machineVersion,
    machineCreated'              = machineCreated,
    machineInfraReady'           = machineInfraReady,
    machineBootstrapReady'       = machineBootstrapReady,
    machineNodeRef'              = machineNodeRef,
    kcpReplicas'                 = kcpReplicas,
    kcpInitialized'              = kcpInitialized,
    mdReplicas'                  = mdReplicas,
    mdEnabled'                   = mdEnabled,
    cpDesiredVersion'            = cpDesiredVersion,
    nextUpgradeStepVersion'      = nextUpgradeStepVersion,
    upgradeStrategy'             = upgradeStrategy,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    FireBeforeClusterCreate,
    InfraClusterProvision,
    ClusterControllerObservesInfraReady,
    KcpInitializeControlPlane,
    nondet m = ALL_MACHINES.oneOf(); BootstrapProviderProvisions(m),
    nondet m = ALL_MACHINES.oneOf(); InfraProviderProvisions(m),
    nondet m = ALL_MACHINES.oneOf(); KubeletRegistersNode(m),
    nondet m = CP_MACHINES.oneOf(); CpMachineJoinsEtcd(m),
    nondet m = CP_MACHINES.oneOf(); CpMachineMarkReady(m),
    nondet m = CP_MACHINES.oneOf(); KcpScaleUpControlPlane(m),
    KcpMarkInitialized,
    ClusterControllerObservesCpInitialised,
    FireAfterControlPlaneInitialized,
    nondet m = WORKER_MACHINES.oneOf(); MdCreateWorker(m),
    nondet m = WORKER_MACHINES.oneOf(); WorkerMarkReady(m),
    nondet v = Set(37, 38).oneOf();
      nondet s = Set(StrategyRolling, StrategyInPlace).oneOf();
      OperatorBumpVersion(v, s),
    FireBeforeClusterUpgrade,
    nondet m = CP_MACHINES.oneOf(); CpUpgradeRolling(m),
    nondet m = CP_MACHINES.oneOf(); CpUpgradeInPlace(m),
    CpStepCompletes,
    FireAfterControlPlaneUpgrade,
    FireBeforeWorkersUpgrade,
    nondet m = WORKER_MACHINES.oneOf(); WorkerUpgrade(m),
    WorkerStepCompletes,
    FireAfterWorkersUpgrade,
    FireAfterClusterUpgrade,
  }

  // ===============================================================
  // Cross-cutting safety invariants
  // ===============================================================

  // FM-48: KCP MUST NOT create CP Machines until InfraCluster is
  // ready and ControlPlaneEndpoint is set. Refines the
  // controller.go:296 early-return.
  val FM48_NoCpBeforeInfraReady =
    cpMachinesCreated(machineCreated).size() > 0
      implies (infraProvisioned and controlPlaneEndpointSet)

  // FM-49: MachineDeployment MUST NOT create worker Machines
  // before ControlPlaneInitialized. Refines the MD reconciler's
  // gate on Cluster.Status.Initialization.ControlPlaneInitialized.
  val FM49_NoWorkersBeforeCpInit =
    WORKER_MACHINES.exists(m => machineCreated.get(m))
      implies controlPlaneInitialised

  // FM-50: ControlPlaneEndpoint, once set, never reverts to
  // unset (monotonicity). Refines the lack of any code path
  // that clears `Cluster.Spec.ControlPlaneEndpoint`.
  // (State invariant version: if endpoint was ever set in this
  // execution, it remains set.)
  val FM50_EndpointMonotonic =
    (clusterPhase == InfraReady or clusterPhase == CPInitialising
     or clusterPhase == CPInitialised or clusterPhase == WorkersStarting
     or clusterPhase == Stable or clusterPhase == Upgrading)
      implies controlPlaneEndpointSet

  // BootstrapBeforeInfra — InfraMachine ready implies
  // BootstrapConfig was ready first (Machine controller
  // sequences these, see Machine.Status.Initialization fields).
  val BootstrapBeforeInfra =
    ALL_MACHINES.forall(m =>
      machineInfraReady.get(m) implies machineBootstrapReady.get(m))

  // NodeRefAfterProvisioned — NodeRef is only set on a Machine
  // that has reached MachineRegistered or beyond, i.e. both
  // Bootstrap and Infra are ready.
  val NodeRefAfterProvisioned =
    ALL_MACHINES.forall(m =>
      machineNodeRef.get(m)
        implies (machineBootstrapReady.get(m) and machineInfraReady.get(m)))

  // EtcdJoinOnlyForCp — only CP Machines reach MachineJoinedEtcd.
  val EtcdJoinOnlyForCp =
    ALL_MACHINES.forall(m =>
      machinePhase.get(m) == MachineJoinedEtcd
        implies machineRole.get(m) == ControlPlane)

  // KcpInitializedRequiresFirstCp — KCP cannot mark Initialized
  // without at least one CP Machine ready.
  val KcpInitializedRequiresFirstCp =
    kcpInitialized
      implies cpMachinesReady(machinePhase).size() >= 1

  // ClusterCpInitializedRequiresKcp — Cluster controller cannot
  // flip controlPlaneInitialised without KCP marking initialized
  // first. Refines the read at cluster_controller_phases.go:289.
  val ClusterCpInitializedRequiresKcp =
    controlPlaneInitialised implies kcpInitialized

  // MdEnabledRequiresCpInit — MD controller is gated on CP
  // initialization.
  val MdEnabledRequiresCpInit =
    mdEnabled implies controlPlaneInitialised

  // BeforeClusterUpgradeOrdering — BeforeClusterUpgrade is
  // cleared from pending before stepPhase advances out of
  // StepIdle (this is the invariant the action enforces). Note
  // the temporal "before any CP version pickup in the sequence"
  // is enforced operationally by FireBeforeClusterUpgrade's
  // precondition that pendingHooks must contain
  // BeforeClusterUpgrade and stepPhase == StepIdle, plus the
  // AfterControlPlaneUpgrade pending bit only being added when
  // CpStepCompletes fires (after the version pickup).
  val BeforeClusterUpgradeOrdering =
    (stepPhase != StepIdle and clusterPhase == Upgrading)
      implies not(pendingHooks.contains(BeforeClusterUpgrade))

  // AfterClusterUpgradeAtTarget — once Stable AND there is no
  // AfterClusterUpgrade pending (i.e. the sequence has
  // finalised), the CP and workers must be at topologyVersion.
  val AfterClusterUpgradeAtTarget =
    (clusterPhase == Stable
     and not(pendingHooks.contains(AfterClusterUpgrade)))
      implies (allCpAtVersion(topologyVersion, machineCreated, machineVersion)
               and allWorkersAtVersion(topologyVersion, machineCreated, machineVersion))

  val SafetyInvariants = all {
    FM48_NoCpBeforeInfraReady,
    FM49_NoWorkersBeforeCpInit,
    FM50_EndpointMonotonic,
    BootstrapBeforeInfra,
    NodeRefAfterProvisioned,
    EtcdJoinOnlyForCp,
    KcpInitializedRequiresFirstCp,
    ClusterCpInitializedRequiresKcp,
    MdEnabledRequiresCpInit,
    BeforeClusterUpgradeOrdering,
    AfterClusterUpgradeAtTarget,
  }

  // ===============================================================
  // LLM-discovered invariant candidates (issue #10)
  // ===============================================================
  // Candidate invariants surfaced by an offline pass with the
  // hack/tools/llm-invariant-discovery.py tool. Every entry below
  // was added to the spec, then verified with a random walk
  // (300 traces × 60 steps via `quint run --invariant=<name>`)
  // BEFORE being included in AllSafetyInvariants. Promoted entries
  // are listed in formal/llm-invariants.md alongside their
  // verification commands and confidence ratings.

  // L1: A modelled CP-id Machine, once created, has role = ControlPlane.
  // CP_MACHINES is the modelling partition; the spec never flips a
  // CP id to a worker role.
  val CpRoleAssignmentStable =
    CP_MACHINES.forall(m =>
      machineCreated.get(m) implies machineRole.get(m) == ControlPlane)

  // L2: A modelled worker-id Machine, once created, has role = Worker.
  val WorkerRoleAssignmentStable =
    WORKER_MACHINES.forall(m =>
      machineCreated.get(m) implies machineRole.get(m) == Worker)

  // L4: infraProvisioned = true is only set by the Cluster
  // controller after observing InfraCluster.status.ready=true. The
  // model action ClusterControllerObservesInfraReady refines that
  // step; its precondition includes infraClusterReady.
  val InfraProvisionedRequiresInfraClusterReady =
    infraProvisioned implies infraClusterReady

  // L5: ControlPlaneEndpoint is set by the Cluster controller from
  // InfraCluster.status.controlPlaneEndpoint. The endpoint cannot
  // leak into the Cluster spec ahead of InfraCluster signalling
  // readiness.
  val EndpointSetRequiresInfraClusterReady =
    controlPlaneEndpointSet implies infraClusterReady

  // L6: Once the cluster has reached Stable, no upgrade-step is
  // mid-flight. The Topology controller only enters Upgrading after
  // bumping topologyVersion; Stable is reachable only after the
  // step-phase has cycled back to StepIdle.
  val StableImpliesStepIdle =
    clusterPhase == Stable implies stepPhase == StepIdle

  val LLMCandidateInvariants = all {
    CpRoleAssignmentStable,
    WorkerRoleAssignmentStable,
    InfraProvisionedRequiresInfraClusterReady,
    EndpointSetRequiresInfraClusterReady,
    StableImpliesStepIdle,
  }

  val AllSafetyInvariants = all {
    SafetyInvariants,
    LLMCandidateInvariants,
  }

  // ===============================================================
  // Liveness properties (issue #24 — Apalache temporal checks)
  // ===============================================================

  val allVars = (clusterPhase, topologyVersion, infraProvisioned,
    controlPlaneEndpointSet, controlPlaneInitialised, stepPhase,
    pendingHooks, beforeClusterCreateUnblocked, infraClusterReady,
    machinePhase, machineRole, machineVersion, machineCreated,
    machineInfraReady, machineBootstrapReady, machineNodeRef,
    kcpReplicas, kcpInitialized, mdReplicas, mdEnabled,
    cpDesiredVersion, nextUpgradeStepVersion, upgradeStrategy)

  temporal BringUpFair =
    strongFair(FireBeforeClusterCreate, allVars)
    and strongFair(InfraClusterProvision, allVars)
    and strongFair(ClusterControllerObservesInfraReady, allVars)
    and strongFair(KcpInitializeControlPlane, allVars)
    and strongFair(any { nondet m = ALL_MACHINES.oneOf(); BootstrapProviderProvisions(m) }, allVars)
    and strongFair(any { nondet m = ALL_MACHINES.oneOf(); InfraProviderProvisions(m) }, allVars)
    and strongFair(any { nondet m = ALL_MACHINES.oneOf(); KubeletRegistersNode(m) }, allVars)
    and strongFair(any { nondet m = CP_MACHINES.oneOf(); CpMachineJoinsEtcd(m) }, allVars)
    and strongFair(any { nondet m = CP_MACHINES.oneOf(); CpMachineMarkReady(m) }, allVars)
    and strongFair(any { nondet m = CP_MACHINES.oneOf(); KcpScaleUpControlPlane(m) }, allVars)
    and strongFair(KcpMarkInitialized, allVars)
    and strongFair(ClusterControllerObservesCpInitialised, allVars)
    and strongFair(any { nondet m = WORKER_MACHINES.oneOf(); MdCreateWorker(m) }, allVars)
    and strongFair(any { nondet m = WORKER_MACHINES.oneOf(); WorkerMarkReady(m) }, allVars)

  // CE1 — once bring-up is scheduled fairly, the endpoint is eventually set.
  temporal CE1_EventuallyEndpointSet =
    BringUpFair
    implies eventually(controlPlaneEndpointSet)

  // CE2 — the cluster eventually reaches a control-plane-initialised-or-better state.
  temporal CE2_EventuallyControlPlaneInitialised =
    BringUpFair
    implies eventually(controlPlaneInitialised or clusterPhase == WorkersStarting or clusterPhase == Stable or clusterPhase == Upgrading)

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyBringUpRun — full cluster bring-up to Stable.
  run happyBringUpRun = init
    .then(FireBeforeClusterCreate)
    .then(InfraClusterProvision)
    .then(ClusterControllerObservesInfraReady)
    .then(KcpInitializeControlPlane)
    .then(BootstrapProviderProvisions(1))
    .then(InfraProviderProvisions(1))
    .then(KubeletRegistersNode(1))
    .then(CpMachineJoinsEtcd(1))
    .then(CpMachineMarkReady(1))
    .then(KcpScaleUpControlPlane(2))
    .then(BootstrapProviderProvisions(2))
    .then(InfraProviderProvisions(2))
    .then(KubeletRegistersNode(2))
    .then(CpMachineJoinsEtcd(2))
    .then(CpMachineMarkReady(2))
    .then(KcpScaleUpControlPlane(3))
    .then(BootstrapProviderProvisions(3))
    .then(InfraProviderProvisions(3))
    .then(KubeletRegistersNode(3))
    .then(CpMachineJoinsEtcd(3))
    .then(CpMachineMarkReady(3))
    .then(KcpMarkInitialized)
    .then(ClusterControllerObservesCpInitialised)
    .then(FireAfterControlPlaneInitialized)
    .then(MdCreateWorker(4))
    .then(BootstrapProviderProvisions(4))
    .then(InfraProviderProvisions(4))
    .then(KubeletRegistersNode(4))
    .then(WorkerMarkReady(4))
    .then(MdCreateWorker(5))
    .then(BootstrapProviderProvisions(5))
    .then(InfraProviderProvisions(5))
    .then(KubeletRegistersNode(5))
    .then(WorkerMarkReady(5))

  // happyRollingUpgradeRun — bring-up to Stable, then operator
  // bumps version with rolling strategy.
  run happyRollingUpgradeRun = happyBringUpRun
    .then(OperatorBumpVersion(37, StrategyRolling))
    .then(FireBeforeClusterUpgrade)
    .then(CpUpgradeRolling(1))
    .then(CpUpgradeRolling(2))
    .then(CpUpgradeRolling(3))
    .then(CpStepCompletes)
    .then(FireAfterControlPlaneUpgrade)
    .then(FireBeforeWorkersUpgrade)
    .then(WorkerUpgrade(4))
    .then(WorkerUpgrade(5))
    .then(WorkerStepCompletes)
    .then(FireAfterWorkersUpgrade)
    .then(FireAfterClusterUpgrade)

  // happyInPlaceUpgradeRun — same as above but in-place
  // strategy.
  run happyInPlaceUpgradeRun = happyBringUpRun
    .then(OperatorBumpVersion(37, StrategyInPlace))
    .then(FireBeforeClusterUpgrade)
    .then(CpUpgradeInPlace(1))
    .then(CpUpgradeInPlace(2))
    .then(CpUpgradeInPlace(3))
    .then(CpStepCompletes)
    .then(FireAfterControlPlaneUpgrade)
    .then(FireBeforeWorkersUpgrade)
    .then(WorkerUpgrade(4))
    .then(WorkerUpgrade(5))
    .then(WorkerStepCompletes)
    .then(FireAfterWorkersUpgrade)
    .then(FireAfterClusterUpgrade)

}
