module RollbackSurgeRace {

  // Standalone rollback-during-partial-cycle surge model for issue #82.
  //
  // Grounding:
  //   * internal/controllers/machinedeployment/mdutil/util.go
  //   * internal/controllers/machinedeployment/machineset/machineset_controller_test.go
  //
  // The model keeps old-version and new-version replica counts, a desired
  // count, maxSurge, and whether an operator rollback has been requested.
  // The bug is a rollback applied mid-cycle while surge replicas still
  // exist, temporarily overproducing replicas beyond the intended bound.

  pure val NONE: str = "none"
  pure val OLD: str = "old"
  pure val NEW: str = "new"

  pure val MAX_REPLICAS: int = 8

  var desiredReplicas: int
  var maxSurge: int
  var oldReplicas: int
  var newReplicas: int
  var rollbackRequested: bool
  var drainPoint: str

  def totalReplicas: int = oldReplicas + newReplicas

  action init: bool = all {
    desiredReplicas' = 3,
    maxSurge' = 1,
    oldReplicas' = 3,
    newReplicas' = 0,
    rollbackRequested' = false,
    drainPoint' = NONE,
  }

  action StartSurge: bool = all {
    totalReplicas < desiredReplicas + maxSurge,
    newReplicas' = newReplicas + 1,
    desiredReplicas' = desiredReplicas,
    maxSurge' = maxSurge,
    oldReplicas' = oldReplicas,
    rollbackRequested' = rollbackRequested,
    drainPoint' = NEW,
  }

  action DrainOldReplica: bool = all {
    oldReplicas > 0,
    oldReplicas' = oldReplicas - 1,
    desiredReplicas' = desiredReplicas,
    maxSurge' = maxSurge,
    newReplicas' = newReplicas,
    rollbackRequested' = rollbackRequested,
    drainPoint' = OLD,
  }

  action RequestRollback: bool = all {
    rollbackRequested' = true,
    desiredReplicas' = desiredReplicas,
    maxSurge' = maxSurge,
    oldReplicas' = oldReplicas,
    newReplicas' = newReplicas,
    drainPoint' = drainPoint,
  }

  action ApplyRollbackSurge: bool = all {
    rollbackRequested,
    totalReplicas < desiredReplicas + maxSurge + 1,
    oldReplicas' = oldReplicas + 1,
    desiredReplicas' = desiredReplicas,
    maxSurge' = maxSurge,
    newReplicas' = newReplicas,
    rollbackRequested' = rollbackRequested,
    drainPoint' = OLD,
  }

  action ClearRollback: bool = all {
    rollbackRequested,
    rollbackRequested' = false,
    desiredReplicas' = desiredReplicas,
    maxSurge' = maxSurge,
    oldReplicas' = oldReplicas,
    newReplicas' = newReplicas,
    drainPoint' = drainPoint,
  }

  action step: bool = any {
    init,
    StartSurge,
    DrainOldReplica,
    RequestRollback,
    ApplyRollbackSurge,
    ClearRollback,
  }

  action stepApalache: bool = any {
    StartSurge,
    RequestRollback,
    ApplyRollbackSurge,
  }

  val OldAndNewReplicaCountsNonNegative =
    oldReplicas >= 0 and newReplicas >= 0

  val DrainPointKnown =
    drainPoint == NONE or drainPoint == OLD or drainPoint == NEW

  val StableSafetyInvariants = all {
    OldAndNewReplicaCountsNonNegative,
    DrainPointKnown,
  }

  val RollbackAppliedAfterDrainPoint =
    drainPoint == OLD and rollbackRequested == false and oldReplicas == desiredReplicas

  val NoTransientSurgeBeyondBound =
    totalReplicas <= desiredReplicas + maxSurge

  run serializedRollbackRun = init
    .then(StartSurge)
    .then(DrainOldReplica)
    .then(RequestRollback)
    .then(ApplyRollbackSurge)
    .then(ClearRollback)

  run rollbackMidCycleRun = init
    .then(StartSurge)
    .then(RequestRollback)
    .then(ApplyRollbackSurge)

  action rollbackMidCycleInit: bool = all {
    desiredReplicas' = 3,
    maxSurge' = 1,
    oldReplicas' = 3,
    newReplicas' = 1,
    rollbackRequested' = true,
    drainPoint' = NEW,
  }
}
