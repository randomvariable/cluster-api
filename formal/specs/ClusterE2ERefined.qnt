// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ClusterE2ERefined.qnt — refinement of a compact ClusterE2E slice
// onto the ControllerRuntime substrate.
//
// REFINEMENT CLAIM. Cluster bring-up transitions fire only while a
// worker holds one of the controller keys in flight. The refined model
// preserves the cross-controller ordering invariants from ClusterE2E
// (FM-48/49/50) together with the per-key serialisation guarantee from
// ControllerRuntime (FM-45), even across leader loss / reacquire.
//
// SCOPE. One Cluster, one initial control-plane Machine, one worker
// Machine, and three queue keys representing the Cluster controller,
// KCP controller, and Machine/MD side-effects.
module ClusterE2ERefined {

  // ===============================================================
  // Substrate state
  // ===============================================================

  type Key = int
  type Worker = int
  type QueuePos = NotInQueue | InReady | InWaiting | InFlight

  pure val CLUSTER_KEY: Key = 1
  pure val CONTROLPLANE_KEY: Key = 2
  pure val MACHINE_KEY: Key = 3
  pure val KEYS: Set[Key] = Set(CLUSTER_KEY, CONTROLPLANE_KEY, MACHINE_KEY)
  pure val WORKERS: Set[Worker] = 1.to(2)
  pure val IDLE_KEY: Key = 0

  var managerStarted: bool
  var leaderElected: bool
  var leaderRunnablesStarted: bool
  var queuePos: Key -> QueuePos
  var workerOnKey: Worker -> Key
  var requeueWhileInFlight: Key -> bool

  // ===============================================================
  // Abstract ClusterE2E state (compact bring-up slice)
  // ===============================================================

  type ClusterPhase =
    | NotCreated
    | InfraProvisioning
    | InfraReady
    | CPInitialising
    | CPInitialised
    | WorkersStarting
    | Stable

  var clusterPhase: ClusterPhase
  var infraClusterReady: bool
  var infraProvisioned: bool
  var controlPlaneEndpointSet: bool
  var kcpInitialized: bool
  var controlPlaneInitialised: bool
  var mdEnabled: bool

  var cpMachineCreated: bool
  var cpBootstrapReady: bool
  var cpInfraReady: bool
  var cpNodeRef: bool
  var cpMachineReady: bool

  var workerMachineCreated: bool
  var workerBootstrapReady: bool
  var workerInfraReady: bool
  var workerNodeRef: bool
  var workerMachineReady: bool

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def anyWorkerOnKey(k: Key, a: Worker -> Key): bool =
    WORKERS.exists(w => a.get(w) == k)

  pure def reconcileInFlightOn(k: Key, a: Worker -> Key, qp: Key -> QueuePos): bool =
    qp.get(k) == InFlight and anyWorkerOnKey(k, a)

  // ===============================================================
  // Initial state
  // ===============================================================

  action init = all {
    managerStarted'         = false,
    leaderElected'          = false,
    leaderRunnablesStarted' = false,
    queuePos'               = KEYS.mapBy(_ => NotInQueue),
    workerOnKey'            = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'   = KEYS.mapBy(_ => false),

    clusterPhase'           = NotCreated,
    infraClusterReady'      = false,
    infraProvisioned'       = false,
    controlPlaneEndpointSet' = false,
    kcpInitialized'         = false,
    controlPlaneInitialised' = false,
    mdEnabled'              = false,

    cpMachineCreated'       = false,
    cpBootstrapReady'       = false,
    cpInfraReady'           = false,
    cpNodeRef'              = false,
    cpMachineReady'         = false,

    workerMachineCreated'   = false,
    workerBootstrapReady'   = false,
    workerInfraReady'       = false,
    workerNodeRef'          = false,
    workerMachineReady'     = false,
  }

  // ===============================================================
  // Substrate actions
  // ===============================================================

  action ManagerStart: bool = all {
    not(managerStarted),
    managerStarted'         = true,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action LeaderAcquire: bool = all {
    managerStarted,
    not(leaderElected),
    leaderElected'          = true,
    leaderRunnablesStarted' = true,
    queuePos'               = queuePos.put(CLUSTER_KEY,
                                if (queuePos.get(CLUSTER_KEY) == NotInQueue) InReady
                                else queuePos.get(CLUSTER_KEY)),
    managerStarted'         = managerStarted,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action LeaderLose: bool = all {
    leaderElected,
    leaderElected'          = false,
    leaderRunnablesStarted' = false,
    queuePos'               = KEYS.mapBy(k =>
                                if (queuePos.get(k) == InFlight) InReady
                                else queuePos.get(k)),
    workerOnKey'            = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'   = KEYS.mapBy(k =>
                                if (queuePos.get(k) == InFlight) false
                                else requeueWhileInFlight.get(k)),
    managerStarted'         = managerStarted,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action ProcessNextWorkItem(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    KEYS.contains(k),
    leaderRunnablesStarted,
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(k) == InReady,
    not(anyWorkerOnKey(k, workerOnKey)),
    workerOnKey'            = workerOnKey.put(w, k),
    queuePos'               = queuePos.put(k, InFlight),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action ReconcileFinishSuccess(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    KEYS.contains(k),
    workerOnKey.get(w) == k,
    workerOnKey'            = workerOnKey.put(w, IDLE_KEY),
    queuePos'               = queuePos.put(k,
                                if (requeueWhileInFlight.get(k)) InReady
                                else NotInQueue),
    requeueWhileInFlight'   = requeueWhileInFlight.put(k, false),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action ReconcileFinishRequeueAfter(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    KEYS.contains(k),
    workerOnKey.get(w) == k,
    workerOnKey'            = workerOnKey.put(w, IDLE_KEY),
    queuePos'               = queuePos.put(k,
                                if (requeueWhileInFlight.get(k)) InReady
                                else InWaiting),
    requeueWhileInFlight'   = requeueWhileInFlight.put(k, false),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action TimerExpires(k: Key): bool = all {
    KEYS.contains(k),
    queuePos.get(k) == InWaiting,
    queuePos'               = queuePos.put(k, InReady),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action EventEnqueue(k: Key): bool = all {
    KEYS.contains(k),
    any {
      all {
        queuePos.get(k) == InFlight,
        requeueWhileInFlight' = requeueWhileInFlight.put(k, true),
        queuePos'             = queuePos,
      },
      all {
        queuePos.get(k) != InFlight,
        requeueWhileInFlight' = requeueWhileInFlight,
        queuePos'             = queuePos.put(k,
                                  if (queuePos.get(k) == NotInQueue or queuePos.get(k) == InWaiting) InReady
                                  else queuePos.get(k)),
      },
    },
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    workerOnKey'            = workerOnKey,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  // ===============================================================
  // External observations / watches
  // ===============================================================

  action InfraClusterProvision: bool = all {
    clusterPhase == InfraProvisioning,
    not(infraClusterReady),
    infraClusterReady'      = true,
    queuePos'               = queuePos.put(CLUSTER_KEY,
                                if (queuePos.get(CLUSTER_KEY) == InFlight) queuePos.get(CLUSTER_KEY)
                                else InReady),
    requeueWhileInFlight'   = if (queuePos.get(CLUSTER_KEY) == InFlight)
                                requeueWhileInFlight.put(CLUSTER_KEY, true)
                              else requeueWhileInFlight,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    workerOnKey'            = workerOnKey,
    clusterPhase'           = clusterPhase,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  // ===============================================================
  // Reconcile body actions
  // ===============================================================

  action ReconcileBeforeClusterCreate: bool = all {
    reconcileInFlightOn(CLUSTER_KEY, workerOnKey, queuePos),
    clusterPhase == NotCreated,
    clusterPhase'           = InfraProvisioning,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action ClusterControllerObservesInfraReady: bool = all {
    reconcileInFlightOn(CLUSTER_KEY, workerOnKey, queuePos),
    clusterPhase == InfraProvisioning,
    infraClusterReady,
    clusterPhase'           = InfraReady,
    infraProvisioned'       = true,
    controlPlaneEndpointSet' = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action KcpInitializeControlPlane: bool = all {
    reconcileInFlightOn(CONTROLPLANE_KEY, workerOnKey, queuePos),
    clusterPhase == InfraReady,
    infraProvisioned,
    controlPlaneEndpointSet,
    not(cpMachineCreated),
    clusterPhase'           = CPInitialising,
    cpMachineCreated'       = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action BootstrapProviderProvisionsCp: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    cpMachineCreated,
    not(cpBootstrapReady),
    cpBootstrapReady'       = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action InfraProviderProvisionsCp: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    cpBootstrapReady,
    not(cpInfraReady),
    cpInfraReady'           = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action KubeletRegistersCpNode: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    cpBootstrapReady,
    cpInfraReady,
    not(cpNodeRef),
    cpNodeRef'              = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action CpMachineMarkReady: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    cpBootstrapReady,
    cpInfraReady,
    cpNodeRef,
    not(cpMachineReady),
    cpMachineReady'         = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action KcpMarkInitialized: bool = all {
    reconcileInFlightOn(CONTROLPLANE_KEY, workerOnKey, queuePos),
    cpMachineReady,
    not(kcpInitialized),
    kcpInitialized'         = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action ClusterControllerObservesCpInitialized: bool = all {
    reconcileInFlightOn(CLUSTER_KEY, workerOnKey, queuePos),
    kcpInitialized,
    not(controlPlaneInitialised),
    clusterPhase'           = CPInitialised,
    controlPlaneInitialised' = true,
    mdEnabled'              = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action MdCreateWorkerMachine: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    mdEnabled,
    controlPlaneInitialised,
    not(workerMachineCreated),
    clusterPhase'           = WorkersStarting,
    workerMachineCreated'   = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action BootstrapProviderProvisionsWorker: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    workerMachineCreated,
    not(workerBootstrapReady),
    workerBootstrapReady'   = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action InfraProviderProvisionsWorker: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    workerBootstrapReady,
    not(workerInfraReady),
    workerInfraReady'       = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerNodeRef'          = workerNodeRef,
    workerMachineReady'     = workerMachineReady,
  }

  action KubeletRegistersWorkerNode: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    workerBootstrapReady,
    workerInfraReady,
    not(workerNodeRef),
    workerNodeRef'          = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    clusterPhase'           = clusterPhase,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerMachineReady'     = workerMachineReady,
  }

  action WorkerMachineMarkReady: bool = all {
    reconcileInFlightOn(MACHINE_KEY, workerOnKey, queuePos),
    workerBootstrapReady,
    workerInfraReady,
    workerNodeRef,
    not(workerMachineReady),
    clusterPhase'           = Stable,
    workerMachineReady'     = true,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    infraClusterReady'      = infraClusterReady,
    infraProvisioned'       = infraProvisioned,
    controlPlaneEndpointSet' = controlPlaneEndpointSet,
    kcpInitialized'         = kcpInitialized,
    controlPlaneInitialised' = controlPlaneInitialised,
    mdEnabled'              = mdEnabled,
    cpMachineCreated'       = cpMachineCreated,
    cpBootstrapReady'       = cpBootstrapReady,
    cpInfraReady'           = cpInfraReady,
    cpNodeRef'              = cpNodeRef,
    cpMachineReady'         = cpMachineReady,
    workerMachineCreated'   = workerMachineCreated,
    workerBootstrapReady'   = workerBootstrapReady,
    workerInfraReady'       = workerInfraReady,
    workerNodeRef'          = workerNodeRef,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    ManagerStart,
    LeaderAcquire,
    LeaderLose,
    nondet w = WORKERS.oneOf(); nondet k = KEYS.oneOf(); ProcessNextWorkItem(w, k),
    nondet w = WORKERS.oneOf(); nondet k = KEYS.oneOf(); ReconcileFinishSuccess(w, k),
    nondet w = WORKERS.oneOf(); nondet k = KEYS.oneOf(); ReconcileFinishRequeueAfter(w, k),
    nondet k = KEYS.oneOf(); TimerExpires(k),
    nondet k = KEYS.oneOf(); EventEnqueue(k),
    InfraClusterProvision,
    ReconcileBeforeClusterCreate,
    ClusterControllerObservesInfraReady,
    KcpInitializeControlPlane,
    BootstrapProviderProvisionsCp,
    InfraProviderProvisionsCp,
    KubeletRegistersCpNode,
    CpMachineMarkReady,
    KcpMarkInitialized,
    ClusterControllerObservesCpInitialized,
    MdCreateWorkerMachine,
    BootstrapProviderProvisionsWorker,
    InfraProviderProvisionsWorker,
    KubeletRegistersWorkerNode,
    WorkerMachineMarkReady,
  }

  action randomStep = step

  // ===============================================================
  // Invariants
  // ===============================================================

  val FM45_PerKeySerialisation =
    KEYS.forall(k => WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  val LeaderElectionGate =
    leaderRunnablesStarted implies leaderElected

  val InFlightHasWorker =
    KEYS.forall(k => queuePos.get(k) == InFlight implies anyWorkerOnKey(k, workerOnKey))

  val FM48_NoCpBeforeInfraReady =
    cpMachineCreated implies (infraProvisioned and controlPlaneEndpointSet)

  val FM49_NoWorkersBeforeCpInit =
    workerMachineCreated implies controlPlaneInitialised

  val FM50_EndpointMonotonic =
    (clusterPhase == InfraReady or clusterPhase == CPInitialising
      or clusterPhase == CPInitialised or clusterPhase == WorkersStarting
      or clusterPhase == Stable) implies controlPlaneEndpointSet

  val EndpointSetRequiresInfraClusterReady =
    controlPlaneEndpointSet implies infraClusterReady

  val ClusterCpInitializedRequiresKcp =
    controlPlaneInitialised implies kcpInitialized

  val MdEnabledRequiresCpInit =
    mdEnabled implies controlPlaneInitialised

  val StableImpliesReadyMachines =
    clusterPhase == Stable implies (cpMachineReady and workerMachineReady)

  val AllSafetyInvariants = all {
    FM45_PerKeySerialisation,
    LeaderElectionGate,
    InFlightHasWorker,
    FM48_NoCpBeforeInfraReady,
    FM49_NoWorkersBeforeCpInit,
    FM50_EndpointMonotonic,
    EndpointSetRequiresInfraClusterReady,
    ClusterCpInitializedRequiresKcp,
    MdEnabledRequiresCpInit,
    StableImpliesReadyMachines,
  }

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  run happyRefinedBringUpRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(ProcessNextWorkItem(1, CLUSTER_KEY))
    .then(ReconcileBeforeClusterCreate)
    .then(ReconcileFinishSuccess(1, CLUSTER_KEY))
    .then(InfraClusterProvision)
    .then(ProcessNextWorkItem(1, CLUSTER_KEY))
    .then(ClusterControllerObservesInfraReady)
    .then(ReconcileFinishSuccess(1, CLUSTER_KEY))
    .then(EventEnqueue(CONTROLPLANE_KEY))
    .then(ProcessNextWorkItem(1, CONTROLPLANE_KEY))
    .then(KcpInitializeControlPlane)
    .then(ReconcileFinishSuccess(1, CONTROLPLANE_KEY))
    .then(EventEnqueue(MACHINE_KEY))
    .then(ProcessNextWorkItem(1, MACHINE_KEY))
    .then(BootstrapProviderProvisionsCp)
    .then(InfraProviderProvisionsCp)
    .then(KubeletRegistersCpNode)
    .then(CpMachineMarkReady)
    .then(ReconcileFinishSuccess(1, MACHINE_KEY))
    .then(EventEnqueue(CONTROLPLANE_KEY))
    .then(ProcessNextWorkItem(1, CONTROLPLANE_KEY))
    .then(KcpMarkInitialized)
    .then(ReconcileFinishSuccess(1, CONTROLPLANE_KEY))
    .then(EventEnqueue(CLUSTER_KEY))
    .then(ProcessNextWorkItem(1, CLUSTER_KEY))
    .then(ClusterControllerObservesCpInitialized)
    .then(ReconcileFinishSuccess(1, CLUSTER_KEY))
    .then(EventEnqueue(MACHINE_KEY))
    .then(ProcessNextWorkItem(1, MACHINE_KEY))
    .then(MdCreateWorkerMachine)
    .then(BootstrapProviderProvisionsWorker)
    .then(InfraProviderProvisionsWorker)
    .then(KubeletRegistersWorkerNode)
    .then(WorkerMachineMarkReady)
    .then(ReconcileFinishSuccess(1, MACHINE_KEY))

  run leaderLossReplayRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(ProcessNextWorkItem(1, CLUSTER_KEY))
    .then(ReconcileBeforeClusterCreate)
    .then(LeaderLose)
    .then(LeaderAcquire)
    .then(ProcessNextWorkItem(2, CLUSTER_KEY))
    .then(ReconcileFinishSuccess(2, CLUSTER_KEY))
    .then(InfraClusterProvision)
    .then(ProcessNextWorkItem(1, CLUSTER_KEY))
    .then(ClusterControllerObservesInfraReady)
    .then(ReconcileFinishSuccess(1, CLUSTER_KEY))
}
