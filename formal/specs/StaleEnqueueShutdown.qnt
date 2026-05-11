module StaleEnqueueShutdown {

  type QueuePos = NotQueued | Ready | InFlight

  var queuePos: QueuePos
  var objectPresent: bool
  var accepting: bool
  var shuttingDown: bool
  var reconcileSawNil: bool
  var reconcileCompleted: bool
  var finalizerPresent: bool
  var finalizerOwnerPresent: bool

  action init = all {
    queuePos' = NotQueued,
    objectPresent' = true,
    accepting' = true,
    shuttingDown' = false,
    reconcileSawNil' = false,
    reconcileCompleted' = false,
    finalizerPresent' = false,
    finalizerOwnerPresent' = true,
  }

  action EnqueueObject: bool = all {
    accepting,
    queuePos == NotQueued,
    queuePos' = Ready,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action BeginReconcile: bool = all {
    accepting,
    queuePos == Ready,
    queuePos' = InFlight,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action DeleteObjectMidEnqueue: bool = all {
    queuePos == Ready or queuePos == InFlight,
    objectPresent,
    objectPresent' = false,
    queuePos' = queuePos,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action AddFinalizerIntent: bool = all {
    objectPresent,
    not(finalizerPresent),
    finalizerPresent' = true,
    queuePos' = queuePos,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action DeleteOwnerDuringFinalizerAdd: bool = all {
    finalizerPresent,
    finalizerOwnerPresent,
    finalizerOwnerPresent' = false,
    queuePos' = queuePos,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
  }

  action ManagerShutdown: bool = all {
    accepting,
    accepting' = false,
    shuttingDown' = true,
    queuePos' = queuePos,
    objectPresent' = objectPresent,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action HandleNotFound: bool = all {
    queuePos == InFlight,
    not(objectPresent),
    queuePos' = NotQueued,
    reconcileCompleted' = true,
    reconcileSawNil' = false,
    finalizerPresent' = false,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action NilReadBug: bool = all {
    queuePos == InFlight,
    not(objectPresent),
    reconcileSawNil' = true,
    queuePos' = NotQueued,
    reconcileCompleted' = false,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action CompleteReconcile: bool = all {
    queuePos == InFlight,
    objectPresent,
    queuePos' = NotQueued,
    reconcileCompleted' = true,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action CleanupOrphanedFinalizer: bool = all {
    finalizerPresent,
    not(finalizerOwnerPresent),
    finalizerPresent' = false,
    queuePos' = queuePos,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action Stutter: bool = all {
    queuePos' = queuePos,
    objectPresent' = objectPresent,
    accepting' = accepting,
    shuttingDown' = shuttingDown,
    reconcileSawNil' = reconcileSawNil,
    reconcileCompleted' = reconcileCompleted,
    finalizerPresent' = finalizerPresent,
    finalizerOwnerPresent' = finalizerOwnerPresent,
  }

  action step: bool = any {
    EnqueueObject,
    BeginReconcile,
    DeleteObjectMidEnqueue,
    AddFinalizerIntent,
    DeleteOwnerDuringFinalizerAdd,
    ManagerShutdown,
    HandleNotFound,
    NilReadBug,
    CompleteReconcile,
    CleanupOrphanedFinalizer,
    Stutter,
  }

  val ShutdownImpliesNotAccepting =
    shuttingDown implies not(accepting)

  val NilReadRequiresMissingObject =
    reconcileSawNil implies not(objectPresent)

  val NoNilReadAfterDelete =
    not(reconcileSawNil)

  val ShutdownDrainCompletes =
    shuttingDown implies (queuePos != InFlight or reconcileCompleted)

  val NoOrphanedFinalizer =
    not(finalizerPresent and not(finalizerOwnerPresent))

  val StableSafetyInvariants = all {
    ShutdownImpliesNotAccepting,
    NilReadRequiresMissingObject,
  }

  run deletedObjectHandledRun = init
    .then(EnqueueObject)
    .then(BeginReconcile)
    .then(DeleteObjectMidEnqueue)
    .then(HandleNotFound)

  run shutdownDrainRun = init
    .then(EnqueueObject)
    .then(BeginReconcile)
    .then(ManagerShutdown)
    .then(CompleteReconcile)

  run nilReadAfterDeleteRun = init
    .then(EnqueueObject)
    .then(BeginReconcile)
    .then(DeleteObjectMidEnqueue)
    .then(NilReadBug)

  run orphanedFinalizerRun = init
    .then(AddFinalizerIntent)
    .then(DeleteOwnerDuringFinalizerAdd)
}
