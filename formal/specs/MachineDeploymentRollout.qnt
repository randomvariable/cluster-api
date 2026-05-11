// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// MachineDeploymentRollout.qnt — abstract MachineDeployment
// rollout model focused on the concurrency between:
//   - rolling-update surge / scale-down,
//   - MachineHealthCheck remediation,
//   - PDB-blocked drain and timeout,
//   - operator-driven replica / template changes.
//
// SCOPE. One MachineDeployment, two old Machines, and room for two
// replacement Machines. The model is intentionally small enough to
// fit the existing formal-corpus workflow while still making the
// scale-down-versus-remediation race explicit.
module MachineDeploymentRollout {

  // =============================================================
  // Types and bounds
  // =============================================================

  type MachineId = int

  type MachinePhase =
    | Provisioning
    | Healthy
    | Draining
    | Deleting
    | Stuck
    | Removed

  type MhcVerdict =
    | MhcHealthy
    | MhcUnhealthy

  type RolloutPhase =
    | RolloutIdle
    | RolloutRunning
    | RolloutAborted
    | RolloutComplete

  pure val MACHINES: Set[MachineId] = 1.to(4)
  pure val REPLICA_CHOICES: Set[int] = 1.to(3)

  pure val OLD_A: MachineId = 1
  pure val OLD_B: MachineId = 2
  pure val NEW_A: MachineId = 3
  pure val NEW_B: MachineId = 4

  // =============================================================
  // State
  // =============================================================

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
  // Actions
  // =============================================================

  action BeginRolloutStep: bool = all {
    desiredTemplateGen > activeTemplateGen,
    rolloutPhase != RolloutRunning,
    activeTemplateGen'  = desiredTemplateGen,
    rolloutPhase'       = RolloutRunning,
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    pendingScaleEvents' = pendingScaleEvents,
    machinePhase'       = machinePhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action CreateNewMS(m: MachineId): bool = all {
    MACHINES.contains(m),
    rolloutPhase == RolloutRunning,
    machineOnNewMs.get(m),
    machinePhase.get(m) == Removed,
    activeCount(machinePhase) < desiredReplicas + maxSurge,
    machinePhase'       = machinePhase.put(m, Provisioning),
    nodeRefSet'         = nodeRefSet.put(m, false),
    machineGen'         = machineGen.put(m, activeTemplateGen),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action MarkProvisionedHealthy(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == Provisioning,
    machinePhase'       = machinePhase.put(m, Healthy),
    nodeRefSet'         = nodeRefSet.put(m, true),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action ScaleDownOldMS(m: MachineId): bool = all {
    MACHINES.contains(m),
    not(machineOnNewMs.get(m)),
    machinePhase.get(m) == Healthy,
    readyNewCount(machinePhase, machineOnNewMs) > 0,
    activeCount(machinePhase) > desiredReplicas,
    not(mhcSelected.get(m)),
    machinePhase'       = machinePhase.put(m, Draining),
    scaleDownSelected'  = scaleDownSelected.put(m, true),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    mhcSelected'        = mhcSelected,
  }

  action MHCFlagUnhealthy(m: MachineId): bool = all {
    MACHINES.contains(m),
    activeMachine(machinePhase.get(m)),
    healthyCount(machinePhase) - 1 >= desiredReplicas - maxUnavailable,
    mhcVerdict'         = mhcVerdict.put(m, MhcUnhealthy),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machinePhase'       = machinePhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action RemediateUnhealthy(m: MachineId): bool = all {
    MACHINES.contains(m),
    mhcVerdict.get(m) == MhcUnhealthy,
    machinePhase.get(m) == Healthy,
    not(scaleDownSelected.get(m)),
    machinePhase'       = machinePhase.put(m, Draining),
    mhcSelected'        = mhcSelected.put(m, true),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
  }

  action EvictPodsBlockedByPDB(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == Draining,
    pdbBlocked.get(m),
    pdbBlocked'         = pdbBlocked.put(m, false),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machinePhase'       = machinePhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action DrainProgressToDeleting(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == Draining,
    not(pdbBlocked.get(m)),
    machinePhase'       = machinePhase.put(m, Deleting),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action CompleteDeletion(m: MachineId): bool = all {
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
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    pdbBlocked'         = pdbBlocked,
  }

  action DrainTimeout(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == Draining,
    pdbBlocked.get(m),
    machinePhase'       = machinePhase.put(m, Stuck),
    scaleDownSelected'  = scaleDownSelected.put(m, false),
    mhcSelected'        = mhcSelected.put(m, false),
    pendingScaleEvents' = pendingScaleEvents + 1,
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
  }

  action OperatorChangesReplicas(n: int): bool = all {
    REPLICA_CHOICES.contains(n),
    n != desiredReplicas,
    n >= activeCount(machinePhase) - maxSurge,
    healthyCount(machinePhase) >= n - maxUnavailable,
    desiredReplicas'    = n,
    pendingScaleEvents' = pendingScaleEvents + 1,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    machinePhase'       = machinePhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  action OperatorChangesTemplate: bool = all {
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
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    activeTemplateGen'  = activeTemplateGen,
    pendingScaleEvents' = pendingScaleEvents,
    machinePhase'       = machinePhase,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
    scaleDownSelected'  = scaleDownSelected,
    mhcSelected'        = mhcSelected,
  }

  // Bug-model action used only for the counterexample run. This
  // simulates a stale MHC decision landing on the same Machine the
  // rollout planner already picked as a scale-down victim.
  action MachineDeletionRaceWithMHC(m: MachineId): bool = all {
    MACHINES.contains(m),
    not(machineOnNewMs.get(m)),
    machinePhase.get(m) == Healthy,
    mhcVerdict.get(m) == MhcUnhealthy,
    readyNewCount(machinePhase, machineOnNewMs) > 0,
    machinePhase'       = machinePhase.put(m, Draining),
    scaleDownSelected'  = scaleDownSelected.put(m, true),
    mhcSelected'        = mhcSelected.put(m, true),
    desiredReplicas'    = desiredReplicas,
    maxSurge'           = maxSurge,
    maxUnavailable'     = maxUnavailable,
    desiredTemplateGen' = desiredTemplateGen,
    activeTemplateGen'  = activeTemplateGen,
    rolloutPhase'       = rolloutPhase,
    pendingScaleEvents' = pendingScaleEvents,
    machineOnNewMs'     = machineOnNewMs,
    machineGen'         = machineGen,
    nodeRefSet'         = nodeRefSet,
    pdbBlocked'         = pdbBlocked,
    mhcVerdict'         = mhcVerdict,
  }

  // =============================================================
  // Step relations
  // =============================================================

  action step = any {
    BeginRolloutStep,
    nondet m = MACHINES.oneOf(); CreateNewMS(m),
    nondet m = MACHINES.oneOf(); MarkProvisionedHealthy(m),
    nondet m = MACHINES.oneOf(); ScaleDownOldMS(m),
    nondet m = MACHINES.oneOf(); MHCFlagUnhealthy(m),
    nondet m = MACHINES.oneOf(); RemediateUnhealthy(m),
    nondet m = MACHINES.oneOf(); EvictPodsBlockedByPDB(m),
    nondet m = MACHINES.oneOf(); DrainProgressToDeleting(m),
    nondet m = MACHINES.oneOf(); CompleteDeletion(m),
    nondet m = MACHINES.oneOf(); DrainTimeout(m),
    nondet n = REPLICA_CHOICES.oneOf(); OperatorChangesReplicas(n),
    OperatorChangesTemplate,
  }

  action stepWithBug = any {
    step,
    nondet m = MACHINES.oneOf(); MachineDeletionRaceWithMHC(m),
  }

  // =============================================================
  // Invariants
  // =============================================================

  val SurgeBound =
    activeCount(machinePhase) <= desiredReplicas + maxSurge

  val AvailabilityBound =
    rolloutPhase == RolloutRunning
      implies healthyCount(machinePhase) >= desiredReplicas - maxUnavailable

  val NoConflictingDeletes =
    MACHINES.forall(m =>
      not(scaleDownSelected.get(m) and mhcSelected.get(m)))

  val NoStarveOldMS =
    MACHINES.forall(m =>
      scaleDownSelected.get(m) implies readyNewCount(machinePhase, machineOnNewMs) > 0)

  val TemplateMonotone = all {
    activeTemplateGen <= desiredTemplateGen,
    desiredTemplateGen > activeTemplateGen implies rolloutPhase != RolloutRunning,
    rolloutPhase == RolloutRunning implies activeTemplateGen == desiredTemplateGen,
  }

  val PdbBlockedDrainStalls =
    MACHINES.forall(m =>
      machinePhase.get(m) == Draining and pdbBlocked.get(m)
        implies (nodeRefSet.get(m)
                 and (scaleDownSelected.get(m) or mhcSelected.get(m))))

  val DrainTimeoutEventuallyRequeues =
    MACHINES.forall(m =>
      machinePhase.get(m) == Stuck implies pendingScaleEvents > 0)

  val MhcCannotDeleteScaleDownVictim =
    MACHINES.forall(m => mhcSelected.get(m) implies not(scaleDownSelected.get(m)))

  val RemovedMachinesDeselected =
    MACHINES.forall(m =>
      machinePhase.get(m) == Removed
        implies (not(scaleDownSelected.get(m))
                 and not(mhcSelected.get(m))
                 and not(nodeRefSet.get(m))))

  val AllSafetyInvariants = all {
    SurgeBound,
    NoConflictingDeletes,
    TemplateMonotone,
    PdbBlockedDrainStalls,
    DrainTimeoutEventuallyRequeues,
    MhcCannotDeleteScaleDownVictim,
    RemovedMachinesDeselected,
  }

  // =============================================================
  // Demonstration runs
  // =============================================================

  run happyRolloutRun = init
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

  run conflictingDeleteRaceRun = init
    .then(BeginRolloutStep)
    .then(CreateNewMS(NEW_A))
    .then(MarkProvisionedHealthy(NEW_A))
    .then(MHCFlagUnhealthy(OLD_A))
    .then(RemediateUnhealthy(OLD_A))
    .then(DrainProgressToDeleting(OLD_A))
    .then(CompleteDeletion(OLD_A))
    .then(CreateNewMS(NEW_B))
    .then(MarkProvisionedHealthy(NEW_B))
    .then(ScaleDownOldMS(OLD_B))
    .then(DrainProgressToDeleting(OLD_B))
    .then(CompleteDeletion(OLD_B))
}
