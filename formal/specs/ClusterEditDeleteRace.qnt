module ClusterEditDeleteRace {

  var objectExists: bool
  var desiredSpecGen: int
  var lastWrittenGen: int
  var deleteObserved: bool
  var staleWriteAfterDelete: bool

  action init = all {
    objectExists' = true,
    desiredSpecGen' = 1,
    lastWrittenGen' = 1,
    deleteObserved' = false,
    staleWriteAfterDelete' = false,
  }

  action BeginSpecEdit: bool = all {
    objectExists,
    desiredSpecGen' = desiredSpecGen + 1,
    objectExists' = objectExists,
    lastWrittenGen' = lastWrittenGen,
    deleteObserved' = deleteObserved,
    staleWriteAfterDelete' = staleWriteAfterDelete,
  }

  action PersistSpecWrite: bool = all {
    objectExists,
    lastWrittenGen < desiredSpecGen,
    lastWrittenGen' = desiredSpecGen,
    objectExists' = objectExists,
    desiredSpecGen' = desiredSpecGen,
    deleteObserved' = deleteObserved,
    staleWriteAfterDelete' = staleWriteAfterDelete,
  }

  action DeleteCluster: bool = all {
    objectExists,
    objectExists' = false,
    deleteObserved' = true,
    desiredSpecGen' = desiredSpecGen,
    lastWrittenGen' = lastWrittenGen,
    staleWriteAfterDelete' = staleWriteAfterDelete,
  }

  action IgnoreNotFoundAfterDelete: bool = all {
    deleteObserved,
    not(objectExists),
    objectExists' = objectExists,
    desiredSpecGen' = desiredSpecGen,
    lastWrittenGen' = lastWrittenGen,
    deleteObserved' = deleteObserved,
    staleWriteAfterDelete' = staleWriteAfterDelete,
  }

  action StaleWriteAfterDelete: bool = all {
    deleteObserved,
    not(objectExists),
    lastWrittenGen < desiredSpecGen,
    lastWrittenGen' = desiredSpecGen,
    staleWriteAfterDelete' = true,
    objectExists' = objectExists,
    desiredSpecGen' = desiredSpecGen,
    deleteObserved' = deleteObserved,
  }

  action step = any {
    BeginSpecEdit,
    PersistSpecWrite,
    DeleteCluster,
    IgnoreNotFoundAfterDelete,
    StaleWriteAfterDelete,
  }

  action stepApalache = any {
    BeginSpecEdit,
    DeleteCluster,
    StaleWriteAfterDelete,
  }

  val DeleteObservedImpliesAbsent =
    deleteObserved implies not(objectExists)

  val LastWriteGenNeverExceedsIntent =
    lastWrittenGen <= desiredSpecGen

  val StableSafetyInvariants = all {
    DeleteObservedImpliesAbsent,
    LastWriteGenNeverExceedsIntent,
  }

  val DeleteCancelsFurtherWrites =
    deleteObserved and not(objectExists) and not(staleWriteAfterDelete)

  val NoWriteAfterDeleteObserved =
    not(staleWriteAfterDelete)

  run editThenDeleteRun = init
    .then(BeginSpecEdit)
    .then(PersistSpecWrite)
    .then(DeleteCluster)
    .then(IgnoreNotFoundAfterDelete)

  run deleteMidEditRun = init
    .then(BeginSpecEdit)
    .then(DeleteCluster)
    .then(StaleWriteAfterDelete)

  action deleteDuringEditInit: bool = all {
    objectExists' = false,
    desiredSpecGen' = 2,
    lastWrittenGen' = 1,
    deleteObserved' = true,
    staleWriteAfterDelete' = false,
  }
}
