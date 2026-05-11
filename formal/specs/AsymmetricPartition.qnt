module AsymmetricPartition {

  type Node = A | B

  var leaderA: bool
  var leaderB: bool
  var currentTerm: int
  var directedBlockAB: bool
  var directedBlockBA: bool
  var followerElectionStarted: bool
  var minorityLeaderAcceptsWrites: bool

  action init = all {
    leaderA' = true,
    leaderB' = false,
    currentTerm' = 1,
    directedBlockAB' = false,
    directedBlockBA' = false,
    followerElectionStarted' = false,
    minorityLeaderAcceptsWrites' = false,
  }

  action BlockDirectionAB: bool = all {
    directedBlockAB' = true,
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockBA' = directedBlockBA,
    followerElectionStarted' = followerElectionStarted,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action BlockDirectionBA: bool = all {
    directedBlockBA' = true,
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockAB' = directedBlockAB,
    followerElectionStarted' = followerElectionStarted,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action UnblockDirectionAB: bool = all {
    directedBlockAB,
    directedBlockAB' = false,
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockBA' = directedBlockBA,
    followerElectionStarted' = followerElectionStarted,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action UnblockDirectionBA: bool = all {
    directedBlockBA,
    directedBlockBA' = false,
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockAB' = directedBlockAB,
    followerElectionStarted' = followerElectionStarted,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action FollowerStartsElection: bool = all {
    directedBlockBA,
    not(followerElectionStarted),
    followerElectionStarted' = true,
    leaderB' = true,
    currentTerm' = currentTerm + 1,
    leaderA' = leaderA,
    directedBlockAB' = directedBlockAB,
    directedBlockBA' = directedBlockBA,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action MinorityLeaderStillAcceptsWrites: bool = all {
    leaderA,
    leaderB,
    minorityLeaderAcceptsWrites' = true,
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockAB' = directedBlockAB,
    directedBlockBA' = directedBlockBA,
    followerElectionStarted' = followerElectionStarted,
  }

  action RecoverToSingleLeader: bool = all {
    leaderA,
    leaderB,
    leaderB' = false,
    minorityLeaderAcceptsWrites' = false,
    leaderA' = leaderA,
    currentTerm' = currentTerm,
    directedBlockAB' = false,
    directedBlockBA' = false,
    followerElectionStarted' = followerElectionStarted,
  }

  action Stutter: bool = all {
    leaderA' = leaderA,
    leaderB' = leaderB,
    currentTerm' = currentTerm,
    directedBlockAB' = directedBlockAB,
    directedBlockBA' = directedBlockBA,
    followerElectionStarted' = followerElectionStarted,
    minorityLeaderAcceptsWrites' = minorityLeaderAcceptsWrites,
  }

  action step: bool = any {
    BlockDirectionAB,
    BlockDirectionBA,
    UnblockDirectionAB,
    UnblockDirectionBA,
    FollowerStartsElection,
    MinorityLeaderStillAcceptsWrites,
    RecoverToSingleLeader,
    Stutter,
  }

  action stepApalache: bool = any {
    FollowerStartsElection,
    MinorityLeaderStillAcceptsWrites,
  }

  val DirectedBlockRequiresPartition =
    directedBlockAB or directedBlockBA or not(followerElectionStarted)

  val TermAdvanceRequiresElection =
    currentTerm > 1 implies followerElectionStarted

  val NoSimultaneousLeaders =
    not(leaderA and leaderB)

  val NoStuckTermAdvance =
    not(currentTerm > 1 and not(followerElectionStarted))

  val StableSafetyInvariants = all {
    TermAdvanceRequiresElection,
    NoStuckTermAdvance,
  }

  val RecoveredToSingleLeader =
    leaderA and not(leaderB) and not(minorityLeaderAcceptsWrites)

  run dualLeaderWindowRun = init
    .then(BlockDirectionBA)
    .then(FollowerStartsElection)
    .then(MinorityLeaderStillAcceptsWrites)

  run recoveredDirectionalPartitionRun = init
    .then(BlockDirectionBA)
    .then(FollowerStartsElection)
    .then(MinorityLeaderStillAcceptsWrites)
    .then(RecoverToSingleLeader)

  action dualLeaderInit = all {
    leaderA' = true,
    leaderB' = false,
    currentTerm' = 1,
    directedBlockAB' = false,
    directedBlockBA' = true,
    followerElectionStarted' = false,
    minorityLeaderAcceptsWrites' = false,
  }
}
