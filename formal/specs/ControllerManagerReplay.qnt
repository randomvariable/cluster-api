module ControllerManagerReplay {

  // Standalone controller-manager OOM / leader-loss / replay model for issue #90.
  //
  // Grounding:
  //   * formal/specs/ControllerRuntime.qnt (leader election + replay substrate)
  //   * test/framework/cluster_proxy.go (leader-election induced restart/retry note)
  //
  // The model keeps a single reconcile effect, an in-memory completion marker,
  // the current leader replica, and a cache generation that bumps on leader
  // handoff. The bug is replaying an already-applied effect after OOM because
  // the old in-memory marker is lost with the dead leader.

  pure val REPLICA_A: int = 1
  pure val REPLICA_B: int = 2

  var leader: int
  var leaderAlive: bool
  var cacheGen: int
  var effectApplied: bool
  var effectCount: int
  var inMemoryDone: bool
  var replayedByNewLeader: bool

  action init: bool = all {
    leader' = REPLICA_A,
    leaderAlive' = true,
    cacheGen' = 1,
    effectApplied' = false,
    effectCount' = 0,
    inMemoryDone' = false,
    replayedByNewLeader' = false,
  }

  action ApplyEffectOnce: bool = all {
    leaderAlive,
    not(effectApplied),
    effectApplied' = true,
    effectCount' = 1,
    inMemoryDone' = true,
    leader' = leader,
    leaderAlive' = leaderAlive,
    cacheGen' = cacheGen,
    replayedByNewLeader' = replayedByNewLeader,
  }

  action OomKillLeader: bool = all {
    leaderAlive,
    leader' = leader,
    leaderAlive' = false,
    cacheGen' = cacheGen,
    effectApplied' = effectApplied,
    effectCount' = effectCount,
    inMemoryDone' = false,
    replayedByNewLeader' = replayedByNewLeader,
  }

  action LeaseExpiryAndFailover: bool = all {
    not(leaderAlive),
    leader' = if (leader == REPLICA_A) REPLICA_B else REPLICA_A,
    leaderAlive' = true,
    cacheGen' = cacheGen + 1,
    effectApplied' = effectApplied,
    effectCount' = effectCount,
    inMemoryDone' = false,
    replayedByNewLeader' = replayedByNewLeader,
  }

  // Safe replay path: the new leader derives from durable state that the effect already happened.
  action ReplayFromDurableState: bool = all {
    leaderAlive,
    effectApplied,
    not(inMemoryDone),
    effectApplied' = effectApplied,
    effectCount' = effectCount,
    inMemoryDone' = true,
    leader' = leader,
    leaderAlive' = leaderAlive,
    cacheGen' = cacheGen,
    replayedByNewLeader' = true,
  }

  // Bad replay path: the new leader only uses lost in-memory intent and re-applies the effect.
  action ReplayDoubleEffect: bool = all {
    leaderAlive,
    effectApplied,
    not(inMemoryDone),
    effectApplied' = true,
    effectCount' = effectCount + 1,
    inMemoryDone' = true,
    leader' = leader,
    leaderAlive' = leaderAlive,
    cacheGen' = cacheGen,
    replayedByNewLeader' = true,
  }

  action step: bool = any {
    init,
    ApplyEffectOnce,
    OomKillLeader,
    LeaseExpiryAndFailover,
    ReplayFromDurableState,
    ReplayDoubleEffect,
  }

  action stepApalache: bool = any {
    OomKillLeader,
    LeaseExpiryAndFailover,
    ReplayDoubleEffect,
  }

  val LeaderOwnsCacheGen = cacheGen >= 1

  val ReplayNeedsNewLeader =
    replayedByNewLeader implies cacheGen > 1

  val StableSafetyInvariants = all {
    LeaderOwnsCacheGen,
    ReplayNeedsNewLeader,
  }

  val RecoveryWithoutInMemoryStateAssumption =
    effectApplied and inMemoryDone and effectCount == 1

  val NoDoubleEffect =
    effectCount <= 1

  run cleanReplayRun = init
    .then(ApplyEffectOnce)
    .then(OomKillLeader)
    .then(LeaseExpiryAndFailover)
    .then(ReplayFromDurableState)

  run doubleEffectReplayRun = init
    .then(ApplyEffectOnce)
    .then(OomKillLeader)
    .then(LeaseExpiryAndFailover)
    .then(ReplayDoubleEffect)

  action doubleEffectInit: bool = all {
    leader' = REPLICA_B,
    leaderAlive' = true,
    cacheGen' = 2,
    effectApplied' = true,
    effectCount' = 1,
    inMemoryDone' = false,
    replayedByNewLeader' = false,
  }
}
