module ControllerLeaderSplitBrain {

  // Standalone controller-manager split-brain model for issue #94.
  //
  // Grounding:
  //   * main.go / controlplane/kubeadm/main.go leader-election flags
  //   * formal/specs/ControllerManagerReplay.qnt
  //
  // The model keeps two controller-manager replicas, their lease-ownership
  // view, one durable effect count, and one convergence bit. The bug is a
  // split-brain window where both leaders believe they own the lease and
  // both apply the same effect.

  pure val NONE: str = "none"
  pure val A: str = "a"
  pure val B: str = "b"
  pure val BOTH: str = "both"

  var leaderView: str
  var effectCount: int
  var converged: bool

  action init: bool = all {
    leaderView' = A,
    effectCount' = 0,
    converged' = false,
  }

  action LeaseSplit: bool = all {
    leaderView' = BOTH,
    effectCount' = effectCount,
    converged' = false,
  }

  action LeaseConvergeToA: bool = all {
    leaderView' = A,
    effectCount' = effectCount,
    converged' = true,
  }

  action LeaseConvergeToB: bool = all {
    leaderView' = B,
    effectCount' = effectCount,
    converged' = true,
  }

  action ApplyEffectByA: bool = all {
    leaderView == A or leaderView == BOTH,
    effectCount' = effectCount + 1,
    leaderView' = leaderView,
    converged' = converged,
  }

  action ApplyEffectByB: bool = all {
    leaderView == B or leaderView == BOTH,
    effectCount' = effectCount + 1,
    leaderView' = leaderView,
    converged' = converged,
  }

  action step: bool = any {
    init,
    LeaseSplit,
    LeaseConvergeToA,
    LeaseConvergeToB,
    ApplyEffectByA,
    ApplyEffectByB,
  }

  action stepApalache: bool = any {
    LeaseSplit,
    ApplyEffectByA,
    ApplyEffectByB,
  }

  val LeaseOwnersKnown =
    leaderView == NONE or leaderView == A or leaderView == B or leaderView == BOTH

  val ConvergedImpliesSingleLeader =
    not(converged) or leaderView == A or leaderView == B

  val StableSafetyInvariants = all {
    LeaseOwnersKnown,
    ConvergedImpliesSingleLeader,
  }

  val SingleWriterAfterConvergence = converged and effectCount == 1

  val NoDuplicateEffectAcrossLeaders = effectCount <= 1

  run leaseConvergesRun = init
    .then(ApplyEffectByA)
    .then(LeaseConvergeToA)

  run splitBrainRun = init
    .then(LeaseSplit)
    .then(ApplyEffectByA)
    .then(ApplyEffectByB)

  action splitBrainInit: bool = all {
    leaderView' = BOTH,
    effectCount' = 0,
    converged' = false,
  }
}
