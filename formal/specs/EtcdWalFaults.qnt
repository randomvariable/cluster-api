module EtcdWalFaults {

  pure val OK: int = 0
  pure val Corrupt: int = 1
  pure val DiskFull: int = 2

  pure def quorumOf(n: int): int = n / 2 + 1

  var members: Set[int]
  var walState: int -> int
  var crashed: int -> bool
  var alarmed: int -> bool
  var detected: int -> bool
  var remediationRequested: int -> bool

  action init = all {
    members' = Set(1, 2, 3),
    walState' = Set(1, 2, 3).mapBy(_ => OK),
    crashed' = Set(1, 2, 3).mapBy(_ => false),
    alarmed' = Set(1, 2, 3).mapBy(_ => false),
    detected' = Set(1, 2, 3).mapBy(_ => false),
    remediationRequested' = Set(1, 2, 3).mapBy(_ => false),
  }

  def healthyCount(ws: int -> int, cs: int -> bool): int =
    members.filter(m => ws.get(m) == OK and not(cs.get(m))).size()

  action WalCorrupt(m: int): bool = all {
    members.contains(m),
    walState.get(m) == OK,
    walState' = walState.put(m, Corrupt),
    members' = members,
    crashed' = crashed,
    alarmed' = alarmed,
    detected' = detected,
    remediationRequested' = remediationRequested,
  }

  action DiskFullFault(m: int): bool = all {
    members.contains(m),
    walState.get(m) == OK,
    walState' = walState.put(m, DiskFull),
    alarmed' = alarmed.put(m, true),
    members' = members,
    crashed' = crashed,
    detected' = detected,
    remediationRequested' = remediationRequested,
  }

  action MemberCrash(m: int): bool = all {
    members.contains(m),
    walState.get(m) != OK,
    crashed.get(m) == false,
    crashed' = crashed.put(m, true),
    members' = members,
    walState' = walState,
    alarmed' = alarmed,
    detected' = detected,
    remediationRequested' = remediationRequested,
  }

  action ObserveOpaqueMemberLoss(m: int): bool = all {
    members.contains(m),
    (crashed.get(m) or alarmed.get(m)),
    detected.get(m) == false,
    detected' = detected.put(m, true),
    members' = members,
    walState' = walState,
    crashed' = crashed,
    alarmed' = alarmed,
    remediationRequested' = remediationRequested,
  }

  action RequestRemediation(m: int): bool = all {
    members.contains(m),
    detected.get(m),
    remediationRequested.get(m) == false,
    remediationRequested' = remediationRequested.put(m, true),
    members' = members,
    walState' = walState,
    crashed' = crashed,
    alarmed' = alarmed,
    detected' = detected,
  }

  action Stutter: bool = all {
    members' = members,
    walState' = walState,
    crashed' = crashed,
    alarmed' = alarmed,
    detected' = detected,
    remediationRequested' = remediationRequested,
  }

  action step: bool = any {
    nondet m = members.oneOf(); WalCorrupt(m),
    nondet m = members.oneOf(); DiskFullFault(m),
    nondet m = members.oneOf(); MemberCrash(m),
    nondet m = members.oneOf(); ObserveOpaqueMemberLoss(m),
    nondet m = members.oneOf(); RequestRemediation(m),
    Stutter,
  }

  action stepApalache: bool = any {
    nondet m = members.oneOf(); WalCorrupt(m),
    nondet m = members.oneOf(); MemberCrash(m),
    Stutter,
  }

  val FaultStateImpliesNotHealthy =
    members.forall(m => walState.get(m) == OK or crashed.get(m) or alarmed.get(m))

  val RemediationRequiresDetection =
    members.forall(m => remediationRequested.get(m) implies detected.get(m))

  val KcpDetectsAndRemediates =
    members.forall(m =>
      (crashed.get(m) or alarmed.get(m)) implies
        (detected.get(m) and remediationRequested.get(m)))

  val NoSilentMemberLoss =
    healthyCount(walState, crashed) >= quorumOf(members.size()) or
      members.forall(m => not(crashed.get(m)) or detected.get(m))

  val AtMostOneOpaqueFaultFlag =
    members.forall(m => not(crashed.get(m) and alarmed.get(m)))

  val StableSafetyInvariants = all {
    RemediationRequiresDetection,
  }

  run detectedFaultRun = init
    .then(WalCorrupt(2))
    .then(MemberCrash(2))
    .then(ObserveOpaqueMemberLoss(2))
    .then(RequestRemediation(2))

  run silentCorruptionRun = init
    .then(WalCorrupt(2))
    .then(MemberCrash(2))

  action silentInit = all {
    members' = Set(1, 2, 3),
    walState' = Set(1, 2, 3).mapBy(_ => OK).put(2, Corrupt),
    crashed' = Set(1, 2, 3).mapBy(_ => false).put(2, true),
    alarmed' = Set(1, 2, 3).mapBy(_ => false),
    detected' = Set(1, 2, 3).mapBy(_ => false),
    remediationRequested' = Set(1, 2, 3).mapBy(_ => false),
  }
}
