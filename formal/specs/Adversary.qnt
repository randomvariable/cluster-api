module Adversary {

  // Reusable adversarial fault-injection state for issue #100.
  // Specs can import this module and call InjectFault(kind, victim)
  // rather than hand-defining bespoke fault booleans each time.

  pure val VICTIMS: Set[int] = 1.to(3)

  pure val NOFAULT = "none"
  pure val PARTITION = "partition"
  pure val LATENCY = "latency"
  pure val CRASH = "crash"
  pure val REORDER = "reorder"
  pure val DROP = "drop"

  pure val FAULT_KINDS: Set[str] = Set(PARTITION, LATENCY, CRASH, REORDER, DROP)

  var activeFaultKind: str
  var activeVictim: int
  var faultBudget: int

  action init = all {
    activeFaultKind' = NOFAULT,
    activeVictim' = 1,
    faultBudget' = 0,
  }

  action InjectFault(kind: str, victim: int): bool = all {
    FAULT_KINDS.contains(kind),
    VICTIMS.contains(victim),
    activeFaultKind' = kind,
    activeVictim' = victim,
    faultBudget' = faultBudget + 1,
  }

  action ClearFault: bool = all {
    activeFaultKind != NOFAULT,
    activeFaultKind' = NOFAULT,
    activeVictim' = activeVictim,
    faultBudget' = faultBudget,
  }

  val ActiveKindKnown =
    activeFaultKind == NOFAULT or FAULT_KINDS.contains(activeFaultKind)

  val ActiveVictimKnown =
    VICTIMS.contains(activeVictim)

  val StableSafetyInvariants = all {
    ActiveKindKnown,
    ActiveVictimKnown,
  }
}
