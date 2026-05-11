module EtcdMembershipBatch {

  var voters: Set[int]
  var learners: Set[int]
  var pendingAdd: bool
  var pendingRemove: bool
  var addID: int
  var removeID: int
  var sameBatchApplied: bool

  pure def quorumOf(n: int): int = n / 2 + 1

  def memberExists(id: int): bool = voters.contains(id) or learners.contains(id)

  pure def activeMemberCount(vs: Set[int]): int = vs.size()

  action init = all {
    voters' = Set(1, 2, 3),
    learners' = Set(),
    pendingAdd' = false,
    pendingRemove' = false,
    addID' = 0,
    removeID' = 0,
    sameBatchApplied' = false,
  }

  action QueueAdd(id: int): bool = all {
    not(pendingAdd),
    not(memberExists(id)),
    pendingAdd' = true,
    addID' = id,
    voters' = voters,
    learners' = learners,
    pendingRemove' = pendingRemove,
    removeID' = removeID,
    sameBatchApplied' = sameBatchApplied,
  }

  action AddLearner(id: int): bool = all {
    pendingAdd,
    addID == id,
    not(memberExists(id)),
    learners' = learners.union(Set(id)),
    pendingAdd' = false,
    addID' = 0,
    voters' = voters,
    pendingRemove' = pendingRemove,
    removeID' = removeID,
    sameBatchApplied' = sameBatchApplied,
  }

  action PromoteLearner(id: int): bool = all {
    learners.contains(id),
    voters' = voters.union(Set(id)),
    learners' = learners.filter(x => x != id),
    pendingAdd' = pendingAdd,
    pendingRemove' = pendingRemove,
    addID' = addID,
    removeID' = removeID,
    sameBatchApplied' = sameBatchApplied,
  }

  action QueueRemove(id: int): bool = all {
    not(pendingRemove),
    voters.contains(id),
    pendingRemove' = true,
    removeID' = id,
    voters' = voters,
    learners' = learners,
    pendingAdd' = pendingAdd,
    addID' = addID,
    sameBatchApplied' = sameBatchApplied,
  }

  action RemoveMember(id: int): bool = all {
    pendingRemove,
    removeID == id,
    voters.contains(id),
    voters' = voters.filter(x => x != id),
    pendingRemove' = false,
    removeID' = 0,
    learners' = learners,
    pendingAdd' = pendingAdd,
    addID' = addID,
    sameBatchApplied' = sameBatchApplied,
  }

  // Bad batch: same reconcile both adds the learner and removes a voter
  // before the learner is promoted, creating a churny transient step the
  // serial controller path should avoid.
  action ApplySameBatchChurn(add: int, rem: int): bool = all {
    pendingAdd,
    pendingRemove,
    addID == add,
    removeID == rem,
    not(memberExists(add)),
    voters.contains(rem),
    learners' = learners.union(Set(add)),
    voters' = voters.filter(x => x != rem),
    pendingAdd' = false,
    pendingRemove' = false,
    addID' = 0,
    removeID' = 0,
    sameBatchApplied' = true,
  }

  action Stutter: bool = all {
    voters' = voters,
    learners' = learners,
    pendingAdd' = pendingAdd,
    pendingRemove' = pendingRemove,
    addID' = addID,
    removeID' = removeID,
    sameBatchApplied' = sameBatchApplied,
  }

  action step: bool = any {
    QueueAdd(4),
    AddLearner(4),
    PromoteLearner(4),
    QueueRemove(1),
    RemoveMember(1),
    ApplySameBatchChurn(4, 1),
    Stutter,
  }

  action stepApalache: bool = any {
    ApplySameBatchChurn(4, 1),
    Stutter,
  }

  val BatchRemoveRequiresExistingMember =
    not(pendingRemove) or voters.contains(removeID)

  val PromoteRequiresLearner =
    not(voters.contains(4) and learners.contains(4))

  val NoDoubleActuation =
    not(sameBatchApplied) or (not(pendingAdd) and not(pendingRemove))

  val NoSameBatchAddRemove =
    not(sameBatchApplied) and activeMemberCount(voters) >= quorumOf(voters.size())

  val StableSafetyInvariants = all {
    BatchRemoveRequiresExistingMember,
    PromoteRequiresLearner,
    NoDoubleActuation,
  }

  run serialMembershipRun = init
    .then(QueueAdd(4))
    .then(AddLearner(4))
    .then(PromoteLearner(4))
    .then(QueueRemove(1))
    .then(RemoveMember(1))

  run sameBatchChurnRun = init
    .then(QueueAdd(4))
    .then(QueueRemove(1))
    .then(ApplySameBatchChurn(4, 1))

  action sameBatchInit = all {
    voters' = Set(1, 2, 3),
    learners' = Set(),
    pendingAdd' = true,
    pendingRemove' = true,
    addID' = 4,
    removeID' = 1,
    sameBatchApplied' = false,
  }
}
