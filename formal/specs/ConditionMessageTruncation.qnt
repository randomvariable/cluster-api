module ConditionMessageTruncation {

  // Standalone condition-message truncation model for issue #72.
  //
  // Grounding:
  //   * api/core/v1beta1/condition_types.go (MaxLength=10240 in newer APIs,
  //     but several user-facing condition/message surfaces still constrain
  //     entries to 1024 bytes in older / structured fields)
  //   * internal/controllers/machine/drain/drain.go + drain_test.go
  //   * internal/controllers/topology/cluster/conditions.go
  //
  // The issue asks for the specific failure where a long wrapped error has
  // the root cause in the tail, but truncation keeps only the prefix.

  pure val MAX_BYTES: int = 1024

  var messageFullLen: int
  var messageStoredLen: int
  var rootCauseInTail: bool
  var rootCauseInStored: bool
  var companionEventHasFullMessage: bool

  action init: bool = all {
    messageFullLen' = 1200,
    messageStoredLen' = 1200,
    rootCauseInTail' = true,
    rootCauseInStored' = true,
    companionEventHasFullMessage' = false,
  }

  action EmitLongCondition: bool = all {
    messageFullLen' = 1400,
    messageStoredLen' = 1400,
    rootCauseInTail' = true,
    rootCauseInStored' = true,
    companionEventHasFullMessage' = companionEventHasFullMessage,
  }

  // Safe strategy: store only the trailing window so the root cause in the
  // tail survives truncation.
  action TruncateKeepingTail: bool = all {
    messageFullLen > MAX_BYTES,
    messageStoredLen' = MAX_BYTES,
    rootCauseInStored' = rootCauseInTail,
    messageFullLen' = messageFullLen,
    rootCauseInTail' = rootCauseInTail,
    companionEventHasFullMessage' = companionEventHasFullMessage,
  }

  // Unsafe strategy: keep only the prefix and silently drop the tail.
  action TruncateDroppingTail: bool = all {
    messageFullLen > MAX_BYTES,
    messageStoredLen' = MAX_BYTES,
    rootCauseInStored' = false,
    messageFullLen' = messageFullLen,
    rootCauseInTail' = rootCauseInTail,
    companionEventHasFullMessage' = companionEventHasFullMessage,
  }

  action EmitCompanionEvent: bool = all {
    companionEventHasFullMessage' = true,
    messageFullLen' = messageFullLen,
    messageStoredLen' = messageStoredLen,
    rootCauseInTail' = rootCauseInTail,
    rootCauseInStored' = rootCauseInStored,
  }

  action step: bool = any {
    init,
    EmitLongCondition,
    TruncateKeepingTail,
    TruncateDroppingTail,
    EmitCompanionEvent,
  }

  action stepApalache: bool = any {
    EmitLongCondition,
    TruncateDroppingTail,
  }

  val StoredLengthBounded =
    messageStoredLen <= MAX_BYTES or messageStoredLen == messageFullLen

  val CompanionEventCarriesFullMessage =
    companionEventHasFullMessage implies messageFullLen >= messageStoredLen

  val StableSafetyInvariants = all {
    StoredLengthBounded,
    CompanionEventCarriesFullMessage,
  }

  val RootCauseSurvivesTruncation =
    rootCauseInStored or companionEventHasFullMessage

  run tailPreservedRun = init
    .then(EmitLongCondition)
    .then(TruncateKeepingTail)

  run tailDroppedRun = init
    .then(EmitLongCondition)
    .then(TruncateDroppingTail)

  action tailDroppedInit: bool = all {
    messageFullLen' = 1400,
    messageStoredLen' = MAX_BYTES,
    rootCauseInTail' = true,
    rootCauseInStored' = false,
    companionEventHasFullMessage' = false,
  }
}
