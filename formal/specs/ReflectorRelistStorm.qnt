module ReflectorRelistStorm {

  type Reflector = KcpReflector | MdReflector

  pure val REFLECTORS = Set(KcpReflector, MdReflector)

  var apiserverRV: int
  var compactedRV: int
  var reflectorRV: Reflector -> int
  var bookmarkLatest: Reflector -> int
  var relistNeeded: Reflector -> bool
  var duplicateEventPending: bool
  var createIntentSeen: bool
  var machineCount: int

  action init = all {
    apiserverRV' = 0,
    compactedRV' = 0,
    reflectorRV' = REFLECTORS.mapBy(_ => 0),
    bookmarkLatest' = REFLECTORS.mapBy(_ => 0),
    relistNeeded' = REFLECTORS.mapBy(_ => false),
    duplicateEventPending' = false,
    createIntentSeen' = false,
    machineCount' = 0,
  }

  action ObserveCreateIntent: bool = all {
    not(createIntentSeen),
    createIntentSeen' = true,
    apiserverRV' = apiserverRV + 1,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    duplicateEventPending' = duplicateEventPending,
    machineCount' = machineCount,
    compactedRV' = compactedRV,
  }

  action CreateMachineOnce: bool = all {
    createIntentSeen,
    machineCount == 0,
    machineCount' = 1,
    apiserverRV' = apiserverRV + 1,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    duplicateEventPending' = duplicateEventPending,
    createIntentSeen' = createIntentSeen,
    compactedRV' = compactedRV,
  }

  action BookmarkDropped(r: Reflector): bool = all {
    REFLECTORS.contains(r),
    bookmarkLatest' = bookmarkLatest.put(r,
      if (apiserverRV > 0) apiserverRV - 1 else 0),
    apiserverRV' = apiserverRV,
    compactedRV' = compactedRV,
    reflectorRV' = reflectorRV,
    relistNeeded' = relistNeeded,
    duplicateEventPending' = duplicateEventPending,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action ApiserverCompact: bool = all {
    apiserverRV > 0,
    compactedRV' = apiserverRV,
    apiserverRV' = apiserverRV,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = REFLECTORS.mapBy(r => reflectorRV.get(r) < apiserverRV),
    duplicateEventPending' = duplicateEventPending,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action ReflectorRelist(r: Reflector): bool = all {
    REFLECTORS.contains(r),
    relistNeeded.get(r),
    reflectorRV' = reflectorRV.put(r, apiserverRV),
    relistNeeded' = relistNeeded.put(r, false),
    duplicateEventPending' = true,
    apiserverRV' = apiserverRV,
    compactedRV' = compactedRV,
    bookmarkLatest' = bookmarkLatest,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  // Compact helper for the depth-4 counterexample path.
  action ReflectorRelistStorm(r: Reflector): bool = all {
    REFLECTORS.contains(r),
    machineCount == 1,
    createIntentSeen,
    apiserverRV' = apiserverRV + 1,
    compactedRV' = apiserverRV + 1,
    reflectorRV' = reflectorRV.put(r, apiserverRV + 1),
    bookmarkLatest' = bookmarkLatest.put(r, if (apiserverRV > 0) apiserverRV - 1 else 0),
    relistNeeded' = REFLECTORS.mapBy(rr => false),
    duplicateEventPending' = true,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action DuplicateEventDelivered: bool = all {
    duplicateEventPending,
    duplicateEventPending' = duplicateEventPending,
    apiserverRV' = apiserverRV,
    compactedRV' = compactedRV,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action IgnoreDuplicateEvent: bool = all {
    duplicateEventPending,
    duplicateEventPending' = false,
    apiserverRV' = apiserverRV,
    compactedRV' = compactedRV,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action CreateDuplicateMachineBug: bool = all {
    duplicateEventPending,
    machineCount == 1,
    machineCount' = 2,
    duplicateEventPending' = false,
    apiserverRV' = apiserverRV + 1,
    compactedRV' = compactedRV,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    createIntentSeen' = createIntentSeen,
  }

  action Stutter: bool = all {
    apiserverRV' = apiserverRV,
    compactedRV' = compactedRV,
    reflectorRV' = reflectorRV,
    bookmarkLatest' = bookmarkLatest,
    relistNeeded' = relistNeeded,
    duplicateEventPending' = duplicateEventPending,
    createIntentSeen' = createIntentSeen,
    machineCount' = machineCount,
  }

  action step: bool = any {
    ObserveCreateIntent,
    CreateMachineOnce,
    nondet r = REFLECTORS.oneOf(); BookmarkDropped(r),
    ApiserverCompact,
    nondet r = REFLECTORS.oneOf(); ReflectorRelist(r),
    nondet r = REFLECTORS.oneOf(); ReflectorRelistStorm(r),
    DuplicateEventDelivered,
    IgnoreDuplicateEvent,
    CreateDuplicateMachineBug,
    Stutter,
  }

  val WatchStateConsistent = all {
    REFLECTORS.forall(r => reflectorRV.get(r) <= apiserverRV),
    REFLECTORS.forall(r => bookmarkLatest.get(r) <= apiserverRV),
    compactedRV <= apiserverRV,
  }

  val DuplicateDeliveryRequiresRelist =
    duplicateEventPending implies createIntentSeen

  val NoDuplicateMachineLeak = machineCount <= 1

  val StableSafetyInvariants = all {
    WatchStateConsistent,
    DuplicateDeliveryRequiresRelist,
  }

  run idempotentRelistStormRun = init
    .then(ObserveCreateIntent)
    .then(CreateMachineOnce)
    .then(ReflectorRelistStorm(KcpReflector))
    .then(IgnoreDuplicateEvent)

  run duplicateCreateRelistStormRun = init
    .then(ObserveCreateIntent)
    .then(CreateMachineOnce)
    .then(ReflectorRelistStorm(KcpReflector))
    .then(CreateDuplicateMachineBug)
}
