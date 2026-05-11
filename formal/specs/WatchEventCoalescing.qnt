module WatchEventCoalescing {

  type EventKind = Added | Modified | Deleted
  type BufferState = Empty | HasAdded | HasModified | HasDeleted

  var objectExists: bool
  var intermediateStateReached: bool
  var sideEffectApplied: bool
  var bufferState: BufferState
  var deliveredEvent: EventKind

  action init = all {
    objectExists' = false,
    intermediateStateReached' = false,
    sideEffectApplied' = false,
    bufferState' = Empty,
    deliveredEvent' = Deleted,
  }

  action EventBufferedAdd: bool = all {
    not(objectExists),
    objectExists' = true,
    bufferState' = HasAdded,
    intermediateStateReached' = intermediateStateReached,
    sideEffectApplied' = sideEffectApplied,
    deliveredEvent' = deliveredEvent,
  }

  action EventBufferedUpdate: bool = all {
    objectExists,
    not(intermediateStateReached),
    intermediateStateReached' = true,
    bufferState' = HasModified,
    objectExists' = objectExists,
    sideEffectApplied' = sideEffectApplied,
    deliveredEvent' = deliveredEvent,
  }

  action EventBufferedDelete: bool = all {
    objectExists,
    objectExists' = false,
    bufferState' = HasDeleted,
    intermediateStateReached' = intermediateStateReached,
    sideEffectApplied' = sideEffectApplied,
    deliveredEvent' = deliveredEvent,
  }

  action CoalesceUpdates: bool = all {
    bufferState == HasDeleted,
    bufferState' = HasDeleted,
    objectExists' = objectExists,
    intermediateStateReached' = intermediateStateReached,
    sideEffectApplied' = sideEffectApplied,
    deliveredEvent' = deliveredEvent,
  }

  action DeliverFinalEvent: bool = all {
    bufferState == HasDeleted,
    deliveredEvent' = Deleted,
    bufferState' = Empty,
    objectExists' = objectExists,
    intermediateStateReached' = intermediateStateReached,
    sideEffectApplied' = sideEffectApplied,
  }

  action DeliverUpdateFirst: bool = all {
    bufferState == HasModified,
    deliveredEvent' = Modified,
    bufferState' = Empty,
    sideEffectApplied' = true,
    objectExists' = objectExists,
    intermediateStateReached' = intermediateStateReached,
  }

  action ReconcileDeleteOnly: bool = all {
    deliveredEvent == Deleted,
    sideEffectApplied' = sideEffectApplied,
    objectExists' = objectExists,
    intermediateStateReached' = intermediateStateReached,
    bufferState' = bufferState,
    deliveredEvent' = deliveredEvent,
  }

  action Stutter: bool = all {
    objectExists' = objectExists,
    intermediateStateReached' = intermediateStateReached,
    sideEffectApplied' = sideEffectApplied,
    bufferState' = bufferState,
    deliveredEvent' = deliveredEvent,
  }

  action step = any {
    EventBufferedAdd,
    EventBufferedUpdate,
    EventBufferedDelete,
    CoalesceUpdates,
    DeliverFinalEvent,
    DeliverUpdateFirst,
    ReconcileDeleteOnly,
    Stutter,
  }

  action stepApalache = any {
    EventBufferedAdd,
    EventBufferedUpdate,
    EventBufferedDelete,
    DeliverFinalEvent,
  }

  val DeliveredDeleteImpliesObjectAbsent =
    deliveredEvent == Deleted and bufferState == Empty implies not(objectExists)

  val CoalescedEventKnown =
    bufferState == Empty or bufferState == HasAdded or bufferState == HasModified or bufferState == HasDeleted

  val StableSafetyInvariants = all {
    DeliveredDeleteImpliesObjectAbsent,
    CoalescedEventKnown,
  }

  val ReconcileCorrectUnderCoalescing =
    not(intermediateStateReached) or sideEffectApplied

  run updateDeliveredRun = init
    .then(EventBufferedAdd)
    .then(EventBufferedUpdate)
    .then(DeliverUpdateFirst)
    .then(EventBufferedDelete)
    .then(DeliverFinalEvent)

  run deleteOnlyAfterCoalesceRun = init
    .then(EventBufferedAdd)
    .then(EventBufferedUpdate)
    .then(EventBufferedDelete)
    .then(CoalesceUpdates)
    .then(DeliverFinalEvent)
    .then(ReconcileDeleteOnly)

  action deleteOnlyInit = all {
    objectExists' = false,
    intermediateStateReached' = true,
    sideEffectApplied' = false,
    bufferState' = Empty,
    deliveredEvent' = Deleted,
  }
}
