module SnapshotRestoreCompaction {

  var liveMembers: Set[int]
  var snapshotMembers: Set[int]
  var snapshotRev: int
  var liveRev: int
  var compactionGen: int
  var restoreInProgress: bool
  var logInconsistent: bool

  action init = all {
    liveMembers' = Set(1, 2, 3),
    snapshotMembers' = Set(1, 2, 3),
    snapshotRev' = 10,
    liveRev' = 10,
    compactionGen' = 0,
    restoreInProgress' = false,
    logInconsistent' = false,
  }

  action BeginSnapshotRestore: bool = all {
    not(restoreInProgress),
    restoreInProgress' = true,
    snapshotMembers' = liveMembers,
    snapshotRev' = liveRev,
    liveMembers' = liveMembers,
    liveRev' = liveRev,
    compactionGen' = compactionGen,
    logInconsistent' = logInconsistent,
  }

  action KcpReconcileDuringRestore: bool = all {
    restoreInProgress,
    liveMembers' = liveMembers.union(Set(4)),
    liveRev' = liveRev + 1,
    snapshotMembers' = snapshotMembers,
    snapshotRev' = snapshotRev,
    compactionGen' = compactionGen,
    restoreInProgress' = restoreInProgress,
    logInconsistent' = logInconsistent,
  }

  action CompactDuringRestore: bool = all {
    restoreInProgress,
    compactionGen' = compactionGen + 1,
    logInconsistent' = true,
    liveMembers' = liveMembers,
    snapshotMembers' = snapshotMembers,
    snapshotRev' = snapshotRev,
    liveRev' = liveRev,
    restoreInProgress' = restoreInProgress,
  }

  action CompleteRestoreCleanly: bool = all {
    restoreInProgress,
    not(logInconsistent),
    liveMembers' = snapshotMembers,
    liveRev' = snapshotRev,
    restoreInProgress' = false,
    snapshotMembers' = snapshotMembers,
    snapshotRev' = snapshotRev,
    compactionGen' = compactionGen,
    logInconsistent' = logInconsistent,
  }

  action CompleteRestoreWithRace: bool = all {
    restoreInProgress,
    logInconsistent,
    liveMembers' = snapshotMembers,
    liveRev' = snapshotRev,
    restoreInProgress' = false,
    snapshotMembers' = snapshotMembers,
    snapshotRev' = snapshotRev,
    compactionGen' = compactionGen,
    logInconsistent' = logInconsistent,
  }

  action Stutter: bool = all {
    liveMembers' = liveMembers,
    snapshotMembers' = snapshotMembers,
    snapshotRev' = snapshotRev,
    liveRev' = liveRev,
    compactionGen' = compactionGen,
    restoreInProgress' = restoreInProgress,
    logInconsistent' = logInconsistent,
  }

  action step: bool = any {
    BeginSnapshotRestore,
    KcpReconcileDuringRestore,
    CompactDuringRestore,
    CompleteRestoreCleanly,
    CompleteRestoreWithRace,
    Stutter,
  }

  action stepApalache: bool = any {
    KcpReconcileDuringRestore,
    CompactDuringRestore,
    CompleteRestoreWithRace,
    Stutter,
  }

  val RestoreFlagImpliesSnapshotPresent =
    not(restoreInProgress) or snapshotRev > 0

  val CompactionMonotone =
    compactionGen >= 0

  val MemberSetMatchesSnapshotPostRestore =
    restoreInProgress or liveMembers == snapshotMembers

  val NoLogInconsistency =
    not(logInconsistent)

  val StableSafetyInvariants = all {
    RestoreFlagImpliesSnapshotPresent,
    CompactionMonotone,
  }

  run cleanRestoreRun = init
    .then(BeginSnapshotRestore)
    .then(CompleteRestoreCleanly)

  run compactionRaceRun = init
    .then(BeginSnapshotRestore)
    .then(KcpReconcileDuringRestore)
    .then(CompactDuringRestore)
    .then(CompleteRestoreWithRace)

  action raceInit = all {
    liveMembers' = Set(1, 2, 3),
    snapshotMembers' = Set(1, 2, 3),
    snapshotRev' = 10,
    liveRev' = 10,
    compactionGen' = 0,
    restoreInProgress' = true,
    logInconsistent' = false,
  }
}
