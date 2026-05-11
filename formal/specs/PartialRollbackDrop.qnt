module PartialRollbackDrop {

  pure val FIELD_ENABLED: str = "enabled"
  pure val FIELD_DISABLED: str = "disabled"
  pure val OWNER_OPERATOR: str = "operator"
  pure val OWNER_CONTROLLER: str = "controller"
  pure val OWNER_NONE: str = "none"

  var fieldValue: str
  var defaultedBy: str
  var backupOmittedField: bool
  var rollbackLoopObserved: bool

  action init = all {
    fieldValue' = FIELD_ENABLED,
    defaultedBy' = OWNER_CONTROLLER,
    backupOmittedField' = false,
    rollbackLoopObserved' = false,
  }

  action OperatorBackup: bool = all {
    backupOmittedField' = true,
    fieldValue' = fieldValue,
    defaultedBy' = defaultedBy,
    rollbackLoopObserved' = rollbackLoopObserved,
  }

  action OperatorApplyOmittedField: bool = all {
    backupOmittedField,
    fieldValue' = FIELD_DISABLED,
    defaultedBy' = OWNER_OPERATOR,
    backupOmittedField' = backupOmittedField,
    rollbackLoopObserved' = rollbackLoopObserved,
  }

  action ControllerRedefault: bool = all {
    fieldValue == FIELD_DISABLED,
    fieldValue' = FIELD_ENABLED,
    defaultedBy' = OWNER_CONTROLLER,
    backupOmittedField' = backupOmittedField,
    rollbackLoopObserved' = rollbackLoopObserved,
  }

  action ObserveRollbackLoop: bool = all {
    backupOmittedField,
    fieldValue == FIELD_ENABLED,
    defaultedBy == OWNER_CONTROLLER,
    rollbackLoopObserved' = true,
    fieldValue' = fieldValue,
    defaultedBy' = defaultedBy,
    backupOmittedField' = backupOmittedField,
  }

  action Stutter: bool = all {
    fieldValue' = fieldValue,
    defaultedBy' = defaultedBy,
    backupOmittedField' = backupOmittedField,
    rollbackLoopObserved' = rollbackLoopObserved,
  }

  action step = any {
    OperatorBackup,
    OperatorApplyOmittedField,
    ControllerRedefault,
    ObserveRollbackLoop,
    Stutter,
  }

  action stepApalache = any {
    OperatorBackup,
    OperatorApplyOmittedField,
    ControllerRedefault,
    ObserveRollbackLoop,
  }

  val DefaultedByKnown =
    defaultedBy == OWNER_OPERATOR or defaultedBy == OWNER_CONTROLLER or defaultedBy == OWNER_NONE

  val FieldValueKnown =
    fieldValue == FIELD_ENABLED or fieldValue == FIELD_DISABLED

  val StableSafetyInvariants = all {
    DefaultedByKnown,
    FieldValueKnown,
  }

  val RedefaultConverges =
    not(rollbackLoopObserved)

  val OperatorActionRecoverable =
    fieldValue == FIELD_ENABLED and defaultedBy == OWNER_CONTROLLER

  run singleRedefaultRun = init
    .then(OperatorBackup)
    .then(OperatorApplyOmittedField)
    .then(ControllerRedefault)

  run rollbackLoopRun = init
    .then(OperatorBackup)
    .then(OperatorApplyOmittedField)
    .then(ControllerRedefault)
    .then(ObserveRollbackLoop)

  action rollbackLoopInit: bool = all {
    fieldValue' = FIELD_ENABLED,
    defaultedBy' = OWNER_CONTROLLER,
    backupOmittedField' = true,
    rollbackLoopObserved' = true,
  }
}
