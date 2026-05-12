module AdversaryHarness {

  // Concrete composed harness for issue #100. This intentionally stays
  // small: a 3-node service where faults can stall convergence.

  pure val VICTIMS: Set[int] = 1.to(3)
  pure val NOFAULT = "none"
  pure val PARTITION = "partition"
  pure val LATENCY = "latency"
  pure val CRASH = "crash"
  pure val REORDER = "reorder"
  pure val DROP = "drop"
  pure val FAULT_KINDS: Set[str] = Set(PARTITION, LATENCY, CRASH, REORDER, DROP)

  pure val HEALTHY = "healthy"
  pure val DEGRADED = "degraded"
  pure val UNAVAILABLE = "unavailable"

  var activeFaultKind: str
  var activeVictim: int
  var faultBudget: int
  var serviceHealth: str
  var healedAfterFault: bool

  action init = all {
    activeFaultKind' = NOFAULT,
    activeVictim' = 1,
    faultBudget' = 0,
    serviceHealth' = HEALTHY,
    healedAfterFault' = false,
  }

  action ObserveFaultImpact: bool = all {
    activeFaultKind != NOFAULT,
    serviceHealth' =
      if (activeFaultKind == CRASH or activeFaultKind == DROP)
      UNAVAILABLE
      else DEGRADED,
    healedAfterFault' = false,
    activeFaultKind' = activeFaultKind,
    activeVictim' = activeVictim,
    faultBudget' = faultBudget,
  }

  action HealAfterClear: bool = all {
    activeFaultKind == NOFAULT,
    serviceHealth != HEALTHY,
    serviceHealth' = HEALTHY,
    healedAfterFault' = true,
    activeFaultKind' = activeFaultKind,
    activeVictim' = activeVictim,
    faultBudget' = faultBudget,
  }

  action InjectPartition(victim: int): bool = all {
    VICTIMS.contains(victim),
    activeFaultKind' = PARTITION,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action InjectLatency(victim: int): bool = all {
    VICTIMS.contains(victim),
    activeFaultKind' = LATENCY,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action InjectCrash(victim: int): bool = all {
    VICTIMS.contains(victim),
    activeFaultKind' = CRASH,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action InjectReorder(victim: int): bool = all {
    VICTIMS.contains(victim),
    activeFaultKind' = REORDER,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action InjectDrop(victim: int): bool = all {
    VICTIMS.contains(victim),
    activeFaultKind' = DROP,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action ClearFault: bool = all {
    activeFaultKind != NOFAULT,
    activeFaultKind' = NOFAULT,
    activeVictim' = activeVictim,
    faultBudget' = faultBudget,
    serviceHealth' = serviceHealth,
    healedAfterFault' = healedAfterFault,
  }

  action step = any {
    nondet v = VICTIMS.oneOf(); InjectPartition(v),
    nondet v = VICTIMS.oneOf(); InjectLatency(v),
    nondet v = VICTIMS.oneOf(); InjectCrash(v),
    nondet v = VICTIMS.oneOf(); InjectReorder(v),
    nondet v = VICTIMS.oneOf(); InjectDrop(v),
    ObserveFaultImpact,
    ClearFault,
    HealAfterClear,
  }

  action stepApalache = any {
    InjectCrash(1),
    ObserveFaultImpact,
    ClearFault,
    HealAfterClear,
  }

  val RecoveredAfterFaultBudget =
    faultBudget >= 1 implies healedAfterFault

  val NoPermanentUnavailability =
    serviceHealth != UNAVAILABLE

  run recoveredFaultRun =
    init
      .then(InjectCrash(1))
      .then(ObserveFaultImpact)
      .then(ClearFault)
      .then(HealAfterClear)

  run permanentOutageRun =
    init
      .then(InjectCrash(1))
      .then(ObserveFaultImpact)

  action permanentOutageInit = all {
    activeFaultKind' = CRASH,
    activeVictim' = 1,
    faultBudget' = 1,
    serviceHealth' = UNAVAILABLE,
    healedAfterFault' = false,
  }

  val ActiveKindKnown =
    FAULT_KINDS.contains(activeFaultKind) or activeFaultKind == NOFAULT

  val ActiveVictimKnown =
    VICTIMS.contains(activeVictim)

  val StableSafetyInvariants = all {
    ActiveKindKnown,
    ActiveVictimKnown,
    serviceHealth == HEALTHY or serviceHealth == DEGRADED or serviceHealth == UNAVAILABLE,
  }
}
