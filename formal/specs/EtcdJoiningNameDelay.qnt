module EtcdJoiningNameDelay {

  pure val ABSENT = "absent"
  pure val JOINING = "joining"
  pure val JOINED = "joined"
  pure val REMOVED = "removed"

  pure val PRESENT = "present"
  pure val PROVISIONING = "provisioning"
  pure val DELETING = "deleting"
  pure val DELETED = "deleted"

  var memberState: str
  var memberNameVisible: bool
  var machineState: str
  var infraGone: bool
  var removeAttemptedByVisibleName: bool
  var memberRemoved: bool

  action init = all {
    memberState' = ABSENT,
    memberNameVisible' = false,
    machineState' = PRESENT,
    infraGone' = false,
    removeAttemptedByVisibleName' = false,
    memberRemoved' = false,
  }

  action MemberAddReturnsJoining: bool = all {
    memberState == ABSENT,
    memberState' = JOINING,
    memberNameVisible' = false,
    machineState' = PROVISIONING,
    infraGone' = false,
    removeAttemptedByVisibleName' = false,
    memberRemoved' = false,
  }

  action PublishMemberName: bool = all {
    memberState == JOINING,
    memberState' = JOINED,
    memberNameVisible' = true,
    machineState' = machineState,
    infraGone' = infraGone,
    removeAttemptedByVisibleName' = removeAttemptedByVisibleName,
    memberRemoved' = memberRemoved,
  }

  action DeleteMachine: bool = all {
    machineState == PROVISIONING or machineState == PRESENT,
    machineState' = DELETING,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    infraGone' = infraGone,
    removeAttemptedByVisibleName' = removeAttemptedByVisibleName,
    memberRemoved' = memberRemoved,
  }

  action TeardownInfra: bool = all {
    machineState == DELETING,
    infraGone' = true,
    machineState' = DELETED,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    removeAttemptedByVisibleName' = removeAttemptedByVisibleName,
    memberRemoved' = memberRemoved,
  }

  action TryRemoveByVisibleName: bool = all {
    machineState == DELETING,
    removeAttemptedByVisibleName' = true,
    any {
      all {
        memberState == JOINED,
        memberState' = REMOVED,
        memberRemoved' = true,
        memberNameVisible' = false,
      },
      all {
        memberState == JOINING,
        memberState' = memberState,
        memberRemoved' = false,
        memberNameVisible' = memberNameVisible,
      }
    },
    machineState' = machineState,
    infraGone' = infraGone,
  }

  action RemoveMemberExplicitly: bool = all {
    memberState == JOINING or memberState == JOINED,
    memberState' = REMOVED,
    memberRemoved' = true,
    memberNameVisible' = false,
    machineState' = machineState,
    infraGone' = infraGone,
    removeAttemptedByVisibleName' = removeAttemptedByVisibleName,
  }

  action step: bool = any {
    MemberAddReturnsJoining,
    PublishMemberName,
    DeleteMachine,
    TeardownInfra,
    TryRemoveByVisibleName,
    RemoveMemberExplicitly,
  }

  action stepApalache: bool = any {
    MemberAddReturnsJoining,
    DeleteMachine,
    TeardownInfra,
    TryRemoveByVisibleName,
  }

  val JoinedImpliesNameVisible =
    memberState != JOINED or memberNameVisible

  val MachineGoneKnown =
    machineState == DELETED implies infraGone

  val StableSafetyInvariants = all {
    JoinedImpliesNameVisible,
    MachineGoneKnown,
  }

  val JoiningEventuallyJoinedOrRemoved =
    memberState != JOINING

  val NoOrphanJoiningMemberAfterMachineGone =
    not(machineState == DELETED and infraGone and memberState == JOINING)

  run joinedBeforeDeleteRun = init
    .then(MemberAddReturnsJoining)
    .then(PublishMemberName)
    .then(DeleteMachine)
    .then(TryRemoveByVisibleName)
    .then(TeardownInfra)

  run orphanJoiningRun = init
    .then(MemberAddReturnsJoining)
    .then(DeleteMachine)
    .then(TryRemoveByVisibleName)
    .then(TeardownInfra)

  action orphanJoiningInit = all {
    memberState' = JOINING,
    memberNameVisible' = false,
    machineState' = DELETED,
    infraGone' = true,
    removeAttemptedByVisibleName' = true,
    memberRemoved' = false,
  }
}
