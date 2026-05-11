module NetworkPolicyMidFlight {

  type ConnMode = Closed | LongLived | CachedClient

  var netpolApplied: bool
  var existingConn: ConnMode
  var terminatedByPolicy: bool
  var controllerDetected: bool
  var controllerStalled: bool

  action init = all {
    netpolApplied' = false,
    existingConn' = LongLived,
    terminatedByPolicy' = false,
    controllerDetected' = false,
    controllerStalled' = false,
  }

  action ApplyNetpol: bool = all {
    not(netpolApplied),
    netpolApplied' = true,
    existingConn' = existingConn,
    terminatedByPolicy' = terminatedByPolicy,
    controllerDetected' = controllerDetected,
    controllerStalled' = controllerStalled,
  }

  action EnforceOnExistingConn: bool = all {
    netpolApplied,
    existingConn == LongLived,
    terminatedByPolicy' = true,
    existingConn' = Closed,
    controllerDetected' = true,
    netpolApplied' = netpolApplied,
    controllerStalled' = controllerStalled,
  }

  action EnforceOnNewOnly: bool = all {
    netpolApplied,
    existingConn == LongLived,
    controllerStalled' = true,
    existingConn' = existingConn,
    terminatedByPolicy' = terminatedByPolicy,
    controllerDetected' = controllerDetected,
    netpolApplied' = netpolApplied,
  }

  action CachedClientReconnectFails: bool = all {
    netpolApplied,
    existingConn == CachedClient,
    controllerDetected' = true,
    existingConn' = Closed,
    terminatedByPolicy' = terminatedByPolicy,
    netpolApplied' = netpolApplied,
    controllerStalled' = controllerStalled,
  }

  action ControllerRecovers: bool = all {
    controllerDetected,
    controllerStalled' = false,
    existingConn' = Closed,
    terminatedByPolicy' = terminatedByPolicy,
    controllerDetected' = controllerDetected,
    netpolApplied' = netpolApplied,
  }

  action step = any {
    ApplyNetpol,
    EnforceOnExistingConn,
    EnforceOnNewOnly,
    CachedClientReconnectFails,
    ControllerRecovers,
  }

  action stepApalache = any {
    ApplyNetpol,
    EnforceOnNewOnly,
  }

  val ExistingConnRequiresAppliedPolicy =
    existingConn == LongLived implies not(terminatedByPolicy)

  val TerminatedConnRequiresPolicy =
    terminatedByPolicy implies netpolApplied

  val StableSafetyInvariants = all {
    ExistingConnRequiresAppliedPolicy,
    TerminatedConnRequiresPolicy,
  }

  val NoSilentControllerStall =
    not(controllerStalled) or controllerDetected

  run detectedPolicyCutRun = init
    .then(ApplyNetpol)
    .then(EnforceOnExistingConn)
    .then(ControllerRecovers)

  run silentWatchSurvivesRun = init
    .then(ApplyNetpol)
    .then(EnforceOnNewOnly)

  action silentWatchInit = all {
    netpolApplied' = true,
    existingConn' = LongLived,
    terminatedByPolicy' = false,
    controllerDetected' = false,
    controllerStalled' = true,
  }
}
