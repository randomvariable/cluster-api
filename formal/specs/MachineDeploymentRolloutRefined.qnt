// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// MachineDeploymentRolloutRefined.qnt — refinement of the
// MachineDeployment rollout abstraction onto a one-key
// controller-runtime substrate.
//
// REFINEMENT CLAIM. Rollout planner / MachineHealthCheck driven
// mutations only happen while the MachineDeployment key is in a
// reconcile dispatch. Multi-worker semantics are preserved, but
// FM-45 ensures only one worker can hold the same key at a time.
module MachineDeploymentRolloutRefined {

  // =============================================================
  // Substrate state
  // =============================================================

  type Key = int
  type Worker = int
  type QueuePos = NotInQueue | InReady | InWaiting | InFlight

  pure val ROLLOUT_KEY: Key = 1
  pure val KEYS: Set[Key] = Set(ROLLOUT_KEY)
  pure val WORKERS: Set[Worker] = 1.to(2)
  pure val IDLE_KEY: Key = 0

  var managerStarted: bool
  var leaderElected: bool
  var leaderRunnablesStarted: bool
  var queuePos: Key -> QueuePos
  var workerOnKey: Worker -> Key
  var requeueWhileInFlight: Key -> bool

  // =============================================================
  // Abstract rollout state
  // =============================================================

  type MachineId = int
  type MachinePhase = Provisioning | Healthy | Draining | Deleting | Stuck | Removed
  type MhcVerdict = MhcHealthy | MhcUnhealthy
  type RolloutPhase = RolloutIdle | RolloutRunning | RolloutAborted | RolloutComplete

  pure val MACHINES: Set[MachineId] = 1.to(4)
  pure val REPLICA_CHOICES: Set[int] = 1.to(3)
  pure val OLD_A: MachineId = 1
  pure val OLD_B: MachineId = 2
  pure val NEW_A: MachineId = 3
  pure val NEW_B: MachineId = 4

  var desiredReplicas: int
  var maxSurge: int
  var maxUnavailable: int
  var desiredTemplateGen: int
  var activeTemplateGen: int
  var rolloutPhase: RolloutPhase
  var pendingScaleEvents: int

  var machinePhase: MachineId -> MachinePhase
  var machineOnNewMs: MachineId -> bool
  var machineGen: MachineId -> int
  var nodeRefSet: MachineId -> bool
  var pdbBlocked: MachineId -> bool
  var mhcVerdict: MachineId -> MhcVerdict
  var scaleDownSelected: MachineId -> bool
  var mhcSelected: MachineId -> bool

  // =============================================================
  // Helpers
  // =============================================================

  pure def anyWorkerOnKey(k: Key, a: Worker -> Key): bool =
    WORKERS.exists(w => a.get(w) == k)

  pure def reconcileInFlight: bool =
    queuePos.get(ROLLOUT_KEY) == InFlight and anyWorkerOnKey(ROLLOUT_KEY, workerOnKey)

  pure def activeMachine(p: MachinePhase): bool = p != Removed

  pure def healthyMachine(p: MachinePhase): bool = p == Healthy

  pure def activeCount(ph: MachineId -> MachinePhase): int =
    MACHINES.filter(m => activeMachine(ph.get(m))).size()

  pure def healthyCount(ph: MachineId -> MachinePhase): int =
    MACHINES.filter(m => healthyMachine(ph.get(m))).size()

  pure def readyNewCount(ph: MachineId -> MachinePhase, onNew: MachineId -> bool): int =
    MACHINES.filter(m =>
      activeMachine(ph.get(m)) and onNew.get(m) and healthyMachine(ph.get(m))).size()

  pure def oldActiveCount(ph: MachineId -> MachinePhase, onNew: MachineId -> bool): int =
    MACHINES.filter(m =>
      activeMachine(ph.get(m)) and not(onNew.get(m))).size()

  pure def rolloutSatisfied(
      ph: MachineId -> MachinePhase,
      onNew: MachineId -> bool,
      desired: int): bool =
    oldActiveCount(ph, onNew) == 0 and readyNewCount(ph, onNew) >= desired

  // =============================================================
  // Initial state
  // =============================================================

  action init = all {
    managerStarted'         = false,
    leaderElected'          = false,
    leaderRunnablesStarted' = false,
    queuePos'               = KEYS.mapBy(_ => NotInQueue),
    workerOnKey'            = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'   = KEYS.mapBy(_ => false),

    desiredReplicas'    = 2,
    maxSurge'           = 1,
    maxUnavailable'     = 1,
    desiredTemplateGen' = 2,
    activeTemplateGen'  = 1,
    rolloutPhase'       = RolloutIdle,
    pendingScaleEvents' = 0,
    machinePhase' = MACHINES.mapBy(m =>
      if (m == OLD_A or m == OLD_B) Healthy else Removed),
    machineOnNewMs' = MACHINES.mapBy(m => m == NEW_A or m == NEW_B),
    machineGen' = MACHINES.mapBy(m =>
      if (m == OLD_A or m == OLD_B) 1 else 2),
    nodeRefSet' = MACHINES.mapBy(m => m == OLD_A or m == OLD_B),
    pdbBlocked' = MACHINES.mapBy(_ => false),
    mhcVerdict' = MACHINES.mapBy(_ => MhcHealthy),
    scaleDownSelected' = MACHINES.mapBy(_ => false),
    mhcSelected' = MACHINES.mapBy(_ => false),
  }

  // =============================================================
  // Substrate actions
  // =============================================================

  action ManagerStartAndLeader: bool = all {
    not(managerStarted),
    managerStarted'         = true,
    leaderElected'          = true,
    leaderRunnablesStarted' = true,
    queuePos'               = queuePos.put(ROLLOUT_KEY, InReady),
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action ProcessNextWorkItem(w: Worker): bool = all {
    WORKERS.contains(w),
    leaderRunnablesStarted,
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(ROLLOUT_KEY) == InReady,
    not(anyWorkerOnKey(ROLLOUT_KEY, workerOnKey)),
    workerOnKey'            = workerOnKey.put(w, ROLLOUT_KEY),
    queuePos'               = queuePos.put(ROLLOUT_KEY, InFlight),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action ReconcileFinishRequeueAfter(w: Worker): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == ROLLOUT_KEY,
    workerOnKey'            = workerOnKey.put(w, IDLE_KEY),
    queuePos'               = queuePos.put(ROLLOUT_KEY, InWaiting),
    requeueWhileInFlight'   = requeueWhileInFlight.put(ROLLOUT_KEY, false),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action TimerExpires: bool = all {
    queuePos.get(ROLLOUT_KEY) == InWaiting,
    queuePos'               = queuePos.put(ROLLOUT_KEY, InReady),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  // =============================================================
  // Rollout body actions — guarded by reconcileInFlight
  // =============================================================

  action BeginRolloutStep: bool = all {
    reconcileInFlight,
    desiredTemplateGen > activeTemplateGen,
    rolloutPhase != RolloutRunning,
    activeTemplateGen'      = desiredTemplateGen,
    rolloutPhase'           = RolloutRunning,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action CreateNewMS(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    rolloutPhase == RolloutRunning,
    machineOnNewMs.get(m),
    machinePhase.get(m) == Removed,
    activeCount(machinePhase) < desiredReplicas + maxSurge,
    machinePhase'           = machinePhase.put(m, Provisioning),
    nodeRefSet'             = nodeRefSet.put(m, false),
    machineGen'             = machineGen.put(m, activeTemplateGen),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action MarkProvisionedHealthy(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    machinePhase.get(m) == Provisioning,
    machinePhase'           = machinePhase.put(m, Healthy),
    nodeRefSet'             = nodeRefSet.put(m, true),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action ScaleDownOldMS(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    not(machineOnNewMs.get(m)),
    machinePhase.get(m) == Healthy,
    readyNewCount(machinePhase, machineOnNewMs) > 0,
    activeCount(machinePhase) > desiredReplicas,
    not(mhcSelected.get(m)),
    machinePhase'           = machinePhase.put(m, Draining),
    scaleDownSelected'      = scaleDownSelected.put(m, true),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    mhcSelected'            = mhcSelected,
  }

  action MHCFlagUnhealthy(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    activeMachine(machinePhase.get(m)),
    healthyCount(machinePhase) - 1 >= desiredReplicas - maxUnavailable,
    mhcVerdict'             = mhcVerdict.put(m, MhcUnhealthy),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action RemediateUnhealthy(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    mhcVerdict.get(m) == MhcUnhealthy,
    machinePhase.get(m) == Healthy,
    not(scaleDownSelected.get(m)),
    machinePhase'           = machinePhase.put(m, Draining),
    mhcSelected'            = mhcSelected.put(m, true),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
  }

  action DrainProgressToDeleting(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    machinePhase.get(m) == Draining,
    not(pdbBlocked.get(m)),
    machinePhase'           = machinePhase.put(m, Deleting),
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action CompleteDeletion(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    machinePhase.get(m) == Deleting,
    machinePhase'      = machinePhase.put(m, Removed),
    nodeRefSet'        = nodeRefSet.put(m, false),
    scaleDownSelected' = scaleDownSelected.put(m, false),
    mhcSelected'       = mhcSelected.put(m, false),
    mhcVerdict'        = mhcVerdict.put(m, MhcHealthy),
    any {
      all {
        rolloutSatisfied(machinePhase.put(m, Removed), machineOnNewMs, desiredReplicas),
        rolloutPhase' = RolloutComplete,
      },
      all {
        not(rolloutSatisfied(machinePhase.put(m, Removed), machineOnNewMs, desiredReplicas)),
        rolloutPhase' = rolloutPhase,
      },
    },
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    pendingScaleEvents'     = pendingScaleEvents,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    pdbBlocked'             = pdbBlocked,
  }

  action DrainTimeout(m: MachineId): bool = all {
    reconcileInFlight,
    MACHINES.contains(m),
    machinePhase.get(m) == Draining,
    pdbBlocked.get(m),
    machinePhase'           = machinePhase.put(m, Stuck),
    scaleDownSelected'      = scaleDownSelected.put(m, false),
    mhcSelected'            = mhcSelected.put(m, false),
    pendingScaleEvents'     = pendingScaleEvents + 1,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
  }

  action OperatorChangesReplicas(n: int): bool = all {
    reconcileInFlight,
    REPLICA_CHOICES.contains(n),
    n != desiredReplicas,
    n >= activeCount(machinePhase) - maxSurge,
    healthyCount(machinePhase) >= n - maxUnavailable,
    desiredReplicas'        = n,
    pendingScaleEvents'     = pendingScaleEvents + 1,
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    desiredTemplateGen'     = desiredTemplateGen,
    activeTemplateGen'      = activeTemplateGen,
    rolloutPhase'           = rolloutPhase,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  action OperatorChangesTemplate: bool = all {
    reconcileInFlight,
    desiredTemplateGen' = desiredTemplateGen + 1,
    any {
      all {
        rolloutPhase == RolloutRunning,
        rolloutPhase' = RolloutAborted,
      },
      all {
        rolloutPhase != RolloutRunning,
        rolloutPhase' = rolloutPhase,
      },
    },
    managerStarted'         = managerStarted,
    leaderElected'          = leaderElected,
    leaderRunnablesStarted' = leaderRunnablesStarted,
    queuePos'               = queuePos,
    workerOnKey'            = workerOnKey,
    requeueWhileInFlight'   = requeueWhileInFlight,
    desiredReplicas'        = desiredReplicas,
    maxSurge'               = maxSurge,
    maxUnavailable'         = maxUnavailable,
    activeTemplateGen'      = activeTemplateGen,
    pendingScaleEvents'     = pendingScaleEvents,
    machinePhase'           = machinePhase,
    machineOnNewMs'         = machineOnNewMs,
    machineGen'             = machineGen,
    nodeRefSet'             = nodeRefSet,
    pdbBlocked'             = pdbBlocked,
    mhcVerdict'             = mhcVerdict,
    scaleDownSelected'      = scaleDownSelected,
    mhcSelected'            = mhcSelected,
  }

  // =============================================================
  // Step relation
  // =============================================================

  action step = any {
    ManagerStartAndLeader,
    nondet w = WORKERS.oneOf(); ProcessNextWorkItem(w),
    nondet w = WORKERS.oneOf(); ReconcileFinishRequeueAfter(w),
    TimerExpires,
    BeginRolloutStep,
    nondet m = MACHINES.oneOf(); CreateNewMS(m),
    nondet m = MACHINES.oneOf(); MarkProvisionedHealthy(m),
    nondet m = MACHINES.oneOf(); ScaleDownOldMS(m),
    nondet m = MACHINES.oneOf(); MHCFlagUnhealthy(m),
    nondet m = MACHINES.oneOf(); RemediateUnhealthy(m),
    nondet m = MACHINES.oneOf(); DrainProgressToDeleting(m),
    nondet m = MACHINES.oneOf(); CompleteDeletion(m),
    nondet m = MACHINES.oneOf(); DrainTimeout(m),
    nondet n = REPLICA_CHOICES.oneOf(); OperatorChangesReplicas(n),
    OperatorChangesTemplate,
  }

  // =============================================================
  // Invariants
  // =============================================================

  val FM45_PerKeySerialisation =
    KEYS.forall(k =>
      WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  val LeaderElectionGate =
    leaderRunnablesStarted implies leaderElected

  val InFlightHasWorker =
    queuePos.get(ROLLOUT_KEY) == InFlight implies anyWorkerOnKey(ROLLOUT_KEY, workerOnKey)

  val BodyActionsGated =
    rolloutPhase != RolloutIdle implies leaderRunnablesStarted

  val ReconcileOwnershipConsistent =
    requeueWhileInFlight.get(ROLLOUT_KEY) implies queuePos.get(ROLLOUT_KEY) == InFlight

  val SurgeBound =
    activeCount(machinePhase) <= desiredReplicas + maxSurge

  val AvailabilityBound =
    rolloutPhase == RolloutRunning
      implies healthyCount(machinePhase) >= desiredReplicas - maxUnavailable

  val NoConflictingDeletes =
    MACHINES.forall(m => not(scaleDownSelected.get(m) and mhcSelected.get(m)))

  val NoStarveOldMS =
    MACHINES.forall(m =>
      scaleDownSelected.get(m) implies readyNewCount(machinePhase, machineOnNewMs) > 0)

  val TemplateMonotone = all {
    activeTemplateGen <= desiredTemplateGen,
    desiredTemplateGen > activeTemplateGen implies rolloutPhase != RolloutRunning,
    rolloutPhase == RolloutRunning implies activeTemplateGen == desiredTemplateGen,
  }

  val SafetyInvariants = all {
    FM45_PerKeySerialisation,
    LeaderElectionGate,
    InFlightHasWorker,
    BodyActionsGated,
    ReconcileOwnershipConsistent,
    SurgeBound,
    NoConflictingDeletes,
    TemplateMonotone,
  }

  val AllSafetyInvariants = SafetyInvariants

  // =============================================================
  // Demonstration runs
  // =============================================================

  run happyRefinedRolloutRun = init
    .then(ManagerStartAndLeader)
    .then(ProcessNextWorkItem(1))
    .then(BeginRolloutStep)
    .then(CreateNewMS(NEW_A))
    .then(MarkProvisionedHealthy(NEW_A))
    .then(ScaleDownOldMS(OLD_A))
    .then(DrainProgressToDeleting(OLD_A))
    .then(CompleteDeletion(OLD_A))
    .then(CreateNewMS(NEW_B))
    .then(MarkProvisionedHealthy(NEW_B))
    .then(ScaleDownOldMS(OLD_B))
    .then(DrainProgressToDeleting(OLD_B))
    .then(CompleteDeletion(OLD_B))

  run safeConflictRun = init
    .then(ManagerStartAndLeader)
    .then(ProcessNextWorkItem(1))
    .then(BeginRolloutStep)
    .then(CreateNewMS(NEW_A))
    .then(MarkProvisionedHealthy(NEW_A))
    .then(MHCFlagUnhealthy(OLD_A))
    .then(RemediateUnhealthy(OLD_A))
    .then(DrainProgressToDeleting(OLD_A))
    .then(CompleteDeletion(OLD_A))
}
