module EtcdFiveNodeFailure {
  type MemberState = Healthy | Failed | Learner | Promoted

  var voters: Set[int]
  var failed: Set[int]
  var learners: Set[int]
  var promotedThisRecovery: Set[int]
  var remediationRequested: Set[int]
  var scenarioTag: str

  pure def quorumOf(n: int): int = n / 2 + 1
  pure def activeVoters(vs: Set[int], down: Set[int]): int =
    vs.filter(v => not(down.contains(v))).size()

  action init = all {
    voters' = Set(1, 2, 3, 4, 5),
    failed' = Set(),
    learners' = Set(6, 7),
    promotedThisRecovery' = Set(),
    remediationRequested' = Set(),
    scenarioTag' = "steady",
  }

  action TripleFailure(a: int, b: int, c: int, tag: str): bool = all {
    Set(a, b, c).size() == 3,
    voters.contains(a),
    voters.contains(b),
    voters.contains(c),
    failed' = failed.union(Set(a, b, c)),
    voters' = voters,
    learners' = learners,
    promotedThisRecovery' = promotedThisRecovery,
    remediationRequested' = remediationRequested,
    scenarioTag' = tag,
  }

  action RequestRemediation(m: int): bool = all {
    failed.contains(m),
    remediationRequested' = remediationRequested.union(Set(m)),
    voters' = voters,
    failed' = failed,
    learners' = learners,
    promotedThisRecovery' = promotedThisRecovery,
    scenarioTag' = scenarioTag,
  }

  action PromoteLearner(m: int): bool = all {
    learners.contains(m),
    voters' = voters.union(Set(m)),
    learners' = learners.filter(x => x != m),
    promotedThisRecovery' = promotedThisRecovery.union(Set(m)),
    failed' = failed,
    remediationRequested' = remediationRequested,
    scenarioTag' = scenarioTag,
  }

  action RecoverMember(m: int): bool = all {
    failed.contains(m),
    failed' = failed.filter(x => x != m),
    voters' = voters,
    learners' = learners,
    promotedThisRecovery' = promotedThisRecovery,
    remediationRequested' = remediationRequested.filter(x => x != m),
    scenarioTag' = scenarioTag,
  }

  action EndRecovery: bool = all {
    promotedThisRecovery' = Set(),
    voters' = voters,
    failed' = failed,
    learners' = learners,
    remediationRequested' = remediationRequested,
    scenarioTag' = "steady",
  }

  action Stutter: bool = all {
    voters' = voters,
    failed' = failed,
    learners' = learners,
    promotedThisRecovery' = promotedThisRecovery,
    remediationRequested' = remediationRequested,
    scenarioTag' = scenarioTag,
  }

  action step: bool = any {
    TripleFailure(1, 2, 3, "leader-followers"),
    TripleFailure(2, 4, 5, "symmetric"),
    nondet m = failed.oneOf(); RequestRemediation(m),
    nondet m = learners.oneOf(); PromoteLearner(m),
    nondet m = failed.oneOf(); RecoverMember(m),
    EndRecovery,
    Stutter,
  }

  action stepApalache: bool = any {
    nondet m = learners.oneOf(); PromoteLearner(m),
    Stutter,
  }

  val QuorumMathConsistent = activeVoters(voters, failed) <= voters.size()

  val PromotionRequiresLearner =
    promotedThisRecovery.forall(m => not(learners.contains(m)))

  val RemediationTargetsOriginalVoters =
    remediationRequested.forall(m => Set(1, 2, 3, 4, 5).contains(m))

  val NoDoublePromotionDuringRecovery =
    promotedThisRecovery.size() <= 1

  val RemediationBoundedPerScenario =
    failed.size() <= 3 and remediationRequested.size() <= 3

  val StableSafetyInvariants = all {
    QuorumMathConsistent,
    PromotionRequiresLearner,
    RemediationTargetsOriginalVoters,
  }

  run sequentialRecoveryRun = init
    .then(TripleFailure(2, 4, 5, "symmetric"))
    .then(RequestRemediation(2))
    .then(PromoteLearner(6))
    .then(RecoverMember(2))
    .then(EndRecovery)

  run leaderFollowersLossRun = init
    .then(TripleFailure(1, 2, 3, "leader-followers"))
    .then(PromoteLearner(6))
    .then(PromoteLearner(7))

  run symmetricTripleLossRun = init
    .then(TripleFailure(2, 4, 5, "symmetric"))
    .then(RequestRemediation(2))
    .then(RequestRemediation(4))
    .then(RequestRemediation(5))

  action leaderFollowersInit = all {
    voters' = Set(1, 2, 3, 4, 5),
    failed' = Set(1, 2, 3),
    learners' = Set(6, 7),
    promotedThisRecovery' = Set(6),
    remediationRequested' = Set(1),
    scenarioTag' = "leader-followers",
  }
}
