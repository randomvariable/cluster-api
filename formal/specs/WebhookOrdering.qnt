module WebhookOrdering {

  type FieldValue = Missing | Invalid | Defaulted | Valid

  var fieldValue: FieldValue
  var validatorObserved: FieldValue
  var mutatorFired: bool
  var validatorFired: bool
  var reinvocationPending: bool
  var converged: bool

  action init = all {
    fieldValue' = Missing,
    validatorObserved' = Missing,
    mutatorFired' = false,
    validatorFired' = false,
    reinvocationPending' = false,
    converged' = false,
  }

  action SetInitialInvalid: bool = all {
    fieldValue == Missing,
    fieldValue' = Invalid,
    validatorObserved' = validatorObserved,
    mutatorFired' = mutatorFired,
    validatorFired' = validatorFired,
    reinvocationPending' = reinvocationPending,
    converged' = converged,
  }

  action ValidatingFires: bool = all {
    not(validatorFired) or reinvocationPending,
    validatorObserved' = fieldValue,
    validatorFired' = true,
    reinvocationPending' = false,
    fieldValue' = fieldValue,
    mutatorFired' = mutatorFired,
    converged' = converged,
  }

  action MutatingFiresDefault: bool = all {
    fieldValue == Missing or fieldValue == Invalid,
    fieldValue' = Defaulted,
    mutatorFired' = true,
    reinvocationPending' = validatorFired,
    validatorObserved' = validatorObserved,
    validatorFired' = validatorFired,
    converged' = false,
  }

  action MutatingFiresNormalize: bool = all {
    fieldValue == Defaulted,
    fieldValue' = Valid,
    mutatorFired' = true,
    reinvocationPending' = validatorFired,
    validatorObserved' = validatorObserved,
    validatorFired' = validatorFired,
    converged' = false,
  }

  action ReinvocationTriggered: bool = all {
    validatorFired,
    mutatorFired,
    fieldValue != validatorObserved,
    reinvocationPending' = true,
    fieldValue' = fieldValue,
    validatorObserved' = validatorObserved,
    mutatorFired' = mutatorFired,
    validatorFired' = validatorFired,
    converged' = converged,
  }

  action MarkConverged: bool = all {
    validatorFired,
    mutatorFired,
    not(reinvocationPending),
    fieldValue == Valid or fieldValue == Defaulted,
    converged' = true,
    fieldValue' = fieldValue,
    validatorObserved' = validatorObserved,
    mutatorFired' = mutatorFired,
    validatorFired' = validatorFired,
    reinvocationPending' = reinvocationPending,
  }

  action StaleValidationBug: bool = all {
    validatorFired,
    mutatorFired,
    validatorObserved != fieldValue,
    converged' = true,
    fieldValue' = fieldValue,
    validatorObserved' = validatorObserved,
    mutatorFired' = mutatorFired,
    validatorFired' = validatorFired,
    reinvocationPending' = false,
  }

  action Stutter: bool = all {
    fieldValue' = fieldValue,
    validatorObserved' = validatorObserved,
    mutatorFired' = mutatorFired,
    validatorFired' = validatorFired,
    reinvocationPending' = reinvocationPending,
    converged' = converged,
  }

  action step: bool = any {
    SetInitialInvalid,
    ValidatingFires,
    MutatingFiresDefault,
    MutatingFiresNormalize,
    ReinvocationTriggered,
    MarkConverged,
    StaleValidationBug,
    Stutter,
  }

  val ValidatorMissingObservationRequiresMissingField =
    validatorObserved == Missing implies fieldValue == Missing or not(validatorFired)

  val MutatorOnlyMovesTowardDefault =
    fieldValue == Valid implies mutatorFired

  val ObservedValueIsFinal =
    not(converged) or validatorObserved == fieldValue

  val ReinvocationConverges =
    not(reinvocationPending) or not(converged)

  val StableSafetyInvariants = all {
    MutatorOnlyMovesTowardDefault,
  }

  run convergingReinvocationRun = init
    .then(SetInitialInvalid)
    .then(ValidatingFires)
    .then(MutatingFiresDefault)
    .then(MutatingFiresNormalize)
    .then(ReinvocationTriggered)
    .then(ValidatingFires)
    .then(MarkConverged)

  run staleValidatorReadRun = init
    .then(SetInitialInvalid)
    .then(ValidatingFires)
    .then(MutatingFiresDefault)
    .then(StaleValidationBug)
}
