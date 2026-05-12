module CrdSchemaBump {

  // Standalone CRD schema-incompatible upgrade model for issue #77.
  //
  // Grounding:
  //   * cmd/clusterctl/client/cluster/crd_migration.go
  //   * util/conversion/conversion.go
  //   * internal/controllers/clusterclass/clusterclass_controller.go

  pure val V1 = "v1"
  pure val V2 = "v2"

  var crdVersion: str
  var requiresNewField: bool
  var storedObjectVersion: str
  var storedObjectHasNewField: bool
  var migrationApplied: bool
  var validationFailed: bool
  var controllerSkipped: bool

  action init = all {
    crdVersion' = V1,
    requiresNewField' = false,
    storedObjectVersion' = V1,
    storedObjectHasNewField' = false,
    migrationApplied' = false,
    validationFailed' = false,
    controllerSkipped' = false,
  }

  action BumpCrdSchema: bool = all {
    crdVersion == V1,
    crdVersion' = V2,
    requiresNewField' = true,
    storedObjectVersion' = storedObjectVersion,
    storedObjectHasNewField' = storedObjectHasNewField,
    migrationApplied' = migrationApplied,
    validationFailed' = validationFailed,
    controllerSkipped' = controllerSkipped,
  }

  action ApplyMigration: bool = all {
    requiresNewField,
    not(storedObjectHasNewField),
    storedObjectHasNewField' = true,
    migrationApplied' = true,
    crdVersion' = crdVersion,
    requiresNewField' = requiresNewField,
    storedObjectVersion' = V2,
    validationFailed' = false,
    controllerSkipped' = false,
  }

  action ReadStoredObjectFailsValidation: bool = all {
    requiresNewField,
    not(storedObjectHasNewField),
    validationFailed' = true,
    controllerSkipped' = true,
    crdVersion' = crdVersion,
    requiresNewField' = requiresNewField,
    storedObjectVersion' = storedObjectVersion,
    storedObjectHasNewField' = storedObjectHasNewField,
    migrationApplied' = migrationApplied,
  }

  action ReadStoredObjectSucceeds: bool = all {
    not(requiresNewField) or storedObjectHasNewField,
    validationFailed' = false,
    controllerSkipped' = false,
    crdVersion' = crdVersion,
    requiresNewField' = requiresNewField,
    storedObjectVersion' = storedObjectVersion,
    storedObjectHasNewField' = storedObjectHasNewField,
    migrationApplied' = migrationApplied,
  }

  action step = any {
    BumpCrdSchema,
    ApplyMigration,
    ReadStoredObjectFailsValidation,
    ReadStoredObjectSucceeds,
  }

  action stepApalache = any {
    BumpCrdSchema,
    ReadStoredObjectFailsValidation,
  }

  val StoredObjectVersionKnown =
    storedObjectVersion == V1 or storedObjectVersion == V2

  val MigrationMaintainsValidity =
    migrationApplied implies storedObjectHasNewField

  val StableSafetyInvariants = all {
    StoredObjectVersionKnown,
    MigrationMaintainsValidity,
  }

  val MigrationPathExistsForBumpedSchema =
    requiresNewField implies migrationApplied

  val NoOrphanedStoredObjects =
    not(controllerSkipped)

  run migratedObjectRun =
    init
      .then(BumpCrdSchema)
      .then(ApplyMigration)
      .then(ReadStoredObjectSucceeds)

  run validationFailureRun =
    init
      .then(BumpCrdSchema)
      .then(ReadStoredObjectFailsValidation)

  action validationFailureInit = all {
    crdVersion' = V2,
    requiresNewField' = true,
    storedObjectVersion' = V1,
    storedObjectHasNewField' = false,
    migrationApplied' = false,
    validationFailed' = false,
    controllerSkipped' = false,
  }
}
