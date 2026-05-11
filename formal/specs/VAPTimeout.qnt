module VAPTimeout {

  type FailurePolicy = Ignore | Fail
  type EvalDuration = Fast | Slow
  type AdmissionProgress = NotStarted | WaitingOnVAP | DeniedByFail | Applied | Healed

  var failurePolicy: FailurePolicy
  var evalDuration: EvalDuration
  var remoteParamReferenced: bool
  var invalidRequestPending: bool
  var invalidRequestApplied: bool
  var timeoutObserved: bool
  var admissionProgress: AdmissionProgress

  action init = all {
    failurePolicy' = Fail,
    evalDuration' = Fast,
    remoteParamReferenced' = false,
    invalidRequestPending' = false,
    invalidRequestApplied' = false,
    timeoutObserved' = false,
    admissionProgress' = NotStarted,
  }

  action SetFailurePolicyIgnore: bool = all {
    failurePolicy == Fail,
    failurePolicy' = Ignore,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
    admissionProgress' = admissionProgress,
  }

  action ConfigureRemoteSlowParam: bool = all {
    remoteParamReferenced' = true,
    evalDuration' = Slow,
    failurePolicy' = failurePolicy,
    invalidRequestPending' = invalidRequestPending,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
    admissionProgress' = admissionProgress,
  }

  action QueueInvalidRequest: bool = all {
    invalidRequestPending' = true,
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
    admissionProgress' = admissionProgress,
  }

  action StartAdmission: bool = all {
    admissionProgress == NotStarted,
    admissionProgress' = WaitingOnVAP,
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
  }

  action EvalTimeoutIgnore: bool = all {
    admissionProgress == WaitingOnVAP,
    evalDuration == Slow,
    remoteParamReferenced,
    failurePolicy == Ignore,
    timeoutObserved' = true,
    admissionProgress' = Applied,
    invalidRequestApplied' = invalidRequestApplied or invalidRequestPending,
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
  }

  action EvalTimeoutFail: bool = all {
    admissionProgress == WaitingOnVAP,
    evalDuration == Slow,
    remoteParamReferenced,
    failurePolicy == Fail,
    timeoutObserved' = true,
    admissionProgress' = DeniedByFail,
    invalidRequestApplied' = invalidRequestApplied,
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
  }

  action FixEvalPath: bool = all {
    evalDuration == Slow,
    evalDuration' = Fast,
    failurePolicy' = failurePolicy,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
    admissionProgress' = admissionProgress,
  }

  action EvalSucceedsWithinBound: bool = all {
    any {
      admissionProgress == WaitingOnVAP,
      admissionProgress == DeniedByFail,
    },
    evalDuration == Fast,
    admissionProgress' = Healed,
    timeoutObserved' = false,
    invalidRequestApplied' = invalidRequestApplied,
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
  }

  action Stutter: bool = all {
    failurePolicy' = failurePolicy,
    evalDuration' = evalDuration,
    remoteParamReferenced' = remoteParamReferenced,
    invalidRequestPending' = invalidRequestPending,
    invalidRequestApplied' = invalidRequestApplied,
    timeoutObserved' = timeoutObserved,
    admissionProgress' = admissionProgress,
  }

  action step: bool = any {
    SetFailurePolicyIgnore,
    ConfigureRemoteSlowParam,
    QueueInvalidRequest,
    StartAdmission,
    EvalTimeoutIgnore,
    EvalTimeoutFail,
    FixEvalPath,
    EvalSucceedsWithinBound,
    Stutter,
  }

  action stepApalache: bool = EvalTimeoutIgnore

  val InvalidAdmissionRequiresIgnore =
    invalidRequestApplied implies failurePolicy == Ignore

  val TimeoutRequiresRemoteParam =
    timeoutObserved implies remoteParamReferenced

  val IgnoreWindowDoesNotMutateInvariants =
    not(invalidRequestApplied)

  val FailWindowEventuallyHeals =
    admissionProgress == Healed

  val StableSafetyInvariants = all {
    InvalidAdmissionRequiresIgnore,
    TimeoutRequiresRemoteParam,
  }

  run ignoreWindowInvalidAdmissionRun = init
    .then(SetFailurePolicyIgnore)
    .then(ConfigureRemoteSlowParam)
    .then(QueueInvalidRequest)
    .then(StartAdmission)
    .then(EvalTimeoutIgnore)

  run failWindowHealsRun = init
    .then(ConfigureRemoteSlowParam)
    .then(QueueInvalidRequest)
    .then(StartAdmission)
    .then(EvalTimeoutFail)
    .then(FixEvalPath)
    .then(EvalSucceedsWithinBound)

  action ignoreCounterexampleInit = all {
    failurePolicy' = Ignore,
    evalDuration' = Slow,
    remoteParamReferenced' = true,
    invalidRequestPending' = true,
    invalidRequestApplied' = false,
    timeoutObserved' = false,
    admissionProgress' = WaitingOnVAP,
  }
}
