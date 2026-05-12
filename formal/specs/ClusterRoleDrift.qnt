module ClusterRoleDrift {

  pure val GOOD = "good"
  pure val DRIFTED = "drifted"
  pure val CAPI = "capi"
  pure val FOREIGN = "foreign"

  var rulesState: str
  var lastApplier: str
  var currentValue: int
  var lastWriterValue: int
  var conflictObserved: bool
  var forcedApply: bool
  var controller403: bool

  action init = all {
    rulesState' = GOOD,
    lastApplier' = CAPI,
    currentValue' = 3,
    lastWriterValue' = 3,
    conflictObserved' = false,
    forcedApply' = false,
    controller403' = false,
  }

  action ChartApplyRoleDrift: bool = all {
    rulesState' = DRIFTED,
    lastApplier' = FOREIGN,
    currentValue' = currentValue,
    lastWriterValue' = lastWriterValue,
    conflictObserved' = conflictObserved,
    forcedApply' = false,
    controller403' = controller403,
  }

  action CapiApply5NoForceConflict: bool = all {
    rulesState == DRIFTED,
    conflictObserved' = true,
    rulesState' = rulesState,
    lastApplier' = lastApplier,
    currentValue' = currentValue,
    lastWriterValue' = lastWriterValue,
    forcedApply' = forcedApply,
    controller403' = controller403,
  }

  action CapiApply5Force: bool = all {
    conflictObserved,
    rulesState' = GOOD,
    lastApplier' = CAPI,
    currentValue' = 5,
    lastWriterValue' = 5,
    conflictObserved' = false,
    forcedApply' = true,
    controller403' = false,
  }

  action ForeignReapplyStale3: bool = all {
    forcedApply,
    rulesState' = DRIFTED,
    lastApplier' = FOREIGN,
    currentValue' = 3,
    lastWriterValue' = 3,
    conflictObserved' = false,
    forcedApply' = false,
    controller403' = controller403,
  }

  action ControllerOperation403: bool = all {
    rulesState == DRIFTED,
    controller403' = true,
    rulesState' = rulesState,
    lastApplier' = lastApplier,
    currentValue' = currentValue,
    lastWriterValue' = lastWriterValue,
    conflictObserved' = conflictObserved,
    forcedApply' = forcedApply,
  }

  action ControllerOperationSucceeds: bool = all {
    rulesState == GOOD,
    controller403' = false,
    rulesState' = rulesState,
    lastApplier' = lastApplier,
    currentValue' = currentValue,
    lastWriterValue' = lastWriterValue,
    conflictObserved' = conflictObserved,
    forcedApply' = forcedApply,
  }

  action step: bool = any {
    ChartApplyRoleDrift,
    CapiApply5NoForceConflict,
    CapiApply5Force,
    ForeignReapplyStale3,
    ControllerOperation403,
    ControllerOperationSucceeds,
  }

  action stepApalache: bool = any {
    ChartApplyRoleDrift,
    CapiApply5NoForceConflict,
    CapiApply5Force,
    ForeignReapplyStale3,
  }

  val LastApplierKnown =
    lastApplier == CAPI or lastApplier == FOREIGN

  val RulesStateKnown =
    rulesState == GOOD or rulesState == DRIFTED

  val StableSafetyInvariants = all {
    LastApplierKnown,
    RulesStateKnown,
  }

  val CapiRoleStableUnderForeignApplier =
    rulesState == GOOD and lastApplier == CAPI and currentValue == 5 and not(controller403)

  val ForcedApplyTransfersOwnership =
    forcedApply implies (lastApplier == CAPI and currentValue == 5 and rulesState == GOOD)

  val NoSilentPermissionLossAfterDrift =
    not(controller403)

  run reassertAfterDriftRun = init
    .then(ChartApplyRoleDrift)
    .then(CapiApply5NoForceConflict)
    .then(CapiApply5Force)
    .then(ControllerOperationSucceeds)

  run drifted403Run = init
    .then(ChartApplyRoleDrift)
    .then(ControllerOperation403)

  action drifted403Init = all {
    rulesState' = DRIFTED,
    lastApplier' = FOREIGN,
    currentValue' = 3,
    lastWriterValue' = 3,
    conflictObserved' = false,
    forcedApply' = false,
    controller403' = true,
  }

  action staleRevertInit = all {
    rulesState' = DRIFTED,
    lastApplier' = FOREIGN,
    currentValue' = 3,
    lastWriterValue' = 3,
    conflictObserved' = false,
    forcedApply' = false,
    controller403' = true,
  }

  run staleManagerRevertRun = init
    .then(ChartApplyRoleDrift)
    .then(CapiApply5NoForceConflict)
    .then(CapiApply5Force)
    .then(ForeignReapplyStale3)
}
