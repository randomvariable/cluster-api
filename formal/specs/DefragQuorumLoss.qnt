module DefragQuorumLoss {

  var voters: Set[int]
  var pausedForDefrag: Set[int]
  var glitched: Set[int]
  var defragMember: int
  var defragActive: bool

  pure def quorumOf(n: int): int = n / 2 + 1

  pure def activeVoters(vs: Set[int], paused: Set[int], down: Set[int]): int =
    vs.filter(v => not(paused.contains(v)) and not(down.contains(v))).size()

  action init = all {
    voters' = Set(1, 2, 3),
    pausedForDefrag' = Set(),
    glitched' = Set(),
    defragMember' = 0,
    defragActive' = false,
  }

  action BeginDefrag(m: int): bool = all {
    voters.contains(m),
    not(defragActive),
    defragActive' = true,
    defragMember' = m,
    pausedForDefrag' = Set(m),
    voters' = voters,
    glitched' = glitched,
  }

  action EndDefrag(m: int): bool = all {
    defragActive,
    defragMember == m,
    defragActive' = false,
    defragMember' = 0,
    pausedForDefrag' = Set(),
    voters' = voters,
    glitched' = glitched,
  }

  action MemberGlitchDuringDefrag(m: int): bool = all {
    defragActive,
    voters.contains(m),
    m != defragMember,
    glitched' = glitched.union(Set(m)),
    voters' = voters,
    pausedForDefrag' = pausedForDefrag,
    defragMember' = defragMember,
    defragActive' = defragActive,
  }

  action HealGlitch(m: int): bool = all {
    glitched.contains(m),
    glitched' = glitched.filter(x => x != m),
    voters' = voters,
    pausedForDefrag' = pausedForDefrag,
    defragMember' = defragMember,
    defragActive' = defragActive,
  }

  action Stutter: bool = all {
    voters' = voters,
    pausedForDefrag' = pausedForDefrag,
    glitched' = glitched,
    defragMember' = defragMember,
    defragActive' = defragActive,
  }

  action step: bool = any {
    nondet m = voters.oneOf(); BeginDefrag(m),
    nondet m = voters.oneOf(); EndDefrag(m),
    nondet m = voters.oneOf(); MemberGlitchDuringDefrag(m),
    nondet m = voters.oneOf(); HealGlitch(m),
    Stutter,
  }

  action stepApalache: bool = any {
    nondet m = voters.oneOf(); MemberGlitchDuringDefrag(m),
    Stutter,
  }

  val SerialDefragOrdering =
    pausedForDefrag.size() <= 1 and (defragActive implies pausedForDefrag.size() == 1)

  val SingleDefragMemberOnly =
    not(defragActive) or pausedForDefrag == Set(defragMember)

  val DefragPauseMarksMember =
    pausedForDefrag.forall(m => voters.contains(m))

  val NoQuorumLossUnderSingleMaintenanceFault =
    activeVoters(voters, pausedForDefrag, glitched) >= quorumOf(voters.size())

  val StableSafetyInvariants = all {
    SerialDefragOrdering,
    SingleDefragMemberOnly,
    DefragPauseMarksMember,
  }

  run serialDefragRun = init
    .then(BeginDefrag(1))
    .then(EndDefrag(1))

  run overlapLossRun = init
    .then(BeginDefrag(1))
    .then(MemberGlitchDuringDefrag(2))

  action overlapInit = all {
    voters' = Set(1, 2, 3),
    pausedForDefrag' = Set(1),
    glitched' = Set(),
    defragMember' = 1,
    defragActive' = true,
  }
}
