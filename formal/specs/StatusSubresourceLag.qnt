module StatusSubresourceLag {

  // Standalone spec/status lag model for issue #70.
  //
  // Grounding:
  //   * internal/controllers/cluster/cluster_controller_status.go
  //   * internal/controllers/machine/machine_controller_status.go
  //   * internal/controllers/machinedeployment/machinedeployment_status.go

  pure val PHASE_RUNNING: str = "Running"
  pure val PHASE_SCALING: str = "ScalingUp"

  var specGen: int
  var statusGen: int
  var desiredTemplateChanged: bool
  var statusPhase: str
  var staleDecisionTaken: bool

  action init: bool = all {
    specGen' = 1,
    statusGen' = 1,
    desiredTemplateChanged' = false,
    statusPhase' = PHASE_RUNNING,
    staleDecisionTaken' = false,
  }

  action UpdateSpecTemplate: bool = all {
    specGen' = specGen + 1,
    desiredTemplateChanged' = true,
    statusGen' = statusGen,
    statusPhase' = statusPhase,
    staleDecisionTaken' = staleDecisionTaken,
  }

  action UpdateStatusSubresource: bool = all {
    statusGen' = specGen,
    statusPhase' = if (desiredTemplateChanged) PHASE_SCALING else PHASE_RUNNING,
    specGen' = specGen,
    desiredTemplateChanged' = desiredTemplateChanged,
    staleDecisionTaken' = staleDecisionTaken,
  }

  action ControllerReadsStaleStatus: bool = all {
    desiredTemplateChanged,
    statusGen < specGen,
    statusPhase == PHASE_RUNNING,
    staleDecisionTaken' = true,
    specGen' = specGen,
    statusGen' = statusGen,
    desiredTemplateChanged' = desiredTemplateChanged,
    statusPhase' = statusPhase,
  }

  action ClearTemplateDrift: bool = all {
    statusGen == specGen,
    statusPhase == PHASE_SCALING,
    desiredTemplateChanged' = false,
    statusPhase' = PHASE_RUNNING,
    specGen' = specGen,
    statusGen' = statusGen,
    staleDecisionTaken' = staleDecisionTaken,
  }

  action step: bool = any {
    init,
    UpdateSpecTemplate,
    UpdateStatusSubresource,
    ControllerReadsStaleStatus,
    ClearTemplateDrift,
  }

  action stepApalache: bool = any {
    UpdateSpecTemplate,
    ControllerReadsStaleStatus,
  }

  val StatusNeverLeadsSpec = statusGen <= specGen

  val PhaseKnownValues =
    statusPhase == PHASE_RUNNING or statusPhase == PHASE_SCALING

  val StableSafetyInvariants = all {
    StatusNeverLeadsSpec,
    PhaseKnownValues,
  }

  val StatusEventuallyConverges =
    statusGen == specGen and not(desiredTemplateChanged) and not(staleDecisionTaken)

  val LevelTriggeredControllersTolerateLag =
    not(staleDecisionTaken)

  run convergedStatusRun = init
    .then(UpdateSpecTemplate)
    .then(UpdateStatusSubresource)
    .then(ClearTemplateDrift)

  run staleStatusDecisionRun = init
    .then(UpdateSpecTemplate)
    .then(ControllerReadsStaleStatus)

  action staleStatusInit: bool = all {
    specGen' = 2,
    statusGen' = 1,
    desiredTemplateChanged' = true,
    statusPhase' = PHASE_RUNNING,
    staleDecisionTaken' = false,
  }
}
