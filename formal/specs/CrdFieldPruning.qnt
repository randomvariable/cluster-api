// Copyright 2026 The Kubernetes Authors.
//
// CrdFieldPruning.qnt — issue #78 (FM-78).
//
// CRD has `preserveUnknownFields=false` (the v1 default). A field
// formerly stored in an object but not in the current schema is
// silently pruned on the next write. Controllers that rely on the
// field break invisibly.

module CrdFieldPruning {

  pure val OBJECTS: Set[int] = 1.to(2)
  pure val ALL_FIELDS: Set[str] = Set("name", "version", "legacyField")

  var definedFields: Set[str]                  // current CRD schema
  var storedFields: int -> Set[str]            // per-object fields on disk
  var preserveUnknownFields: bool
  var controllerExpectedField: int -> Set[str] // fields the controller reads

  action init = all {
    definedFields' = Set("name", "version", "legacyField"),
    storedFields' = OBJECTS.mapBy(_ => Set("name", "version", "legacyField")),
    preserveUnknownFields' = false,
    controllerExpectedField' = OBJECTS.mapBy(_ => Set("legacyField")),
  }

  // Operator removes the legacy field from the CRD schema.
  action DropFieldFromSchema(f: str): bool = all {
    definedFields.contains(f),
    definedFields' = definedFields.exclude(Set(f)),
    storedFields' = storedFields,
    preserveUnknownFields' = preserveUnknownFields,
    controllerExpectedField' = controllerExpectedField,
  }

  // Write an object. With preserveUnknownFields=false, fields not in
  // definedFields are silently pruned from storedFields.
  action WriteObject(o: int): bool = all {
    OBJECTS.contains(o),
    val pruned = if (preserveUnknownFields)
                    storedFields.get(o)
                 else
                    storedFields.get(o).intersect(definedFields)
    all {
      storedFields' = storedFields.put(o, pruned),
      definedFields' = definedFields,
      preserveUnknownFields' = preserveUnknownFields,
      controllerExpectedField' = controllerExpectedField,
    }
  }

  action ControllerReadsField(o: int, f: str): bool = all {
    OBJECTS.contains(o),
    ALL_FIELDS.contains(f),
    controllerExpectedField' = controllerExpectedField,
    storedFields' = storedFields,
    definedFields' = definedFields,
    preserveUnknownFields' = preserveUnknownFields,
  }

  action step = any {
    nondet f = ALL_FIELDS.oneOf(); DropFieldFromSchema(f),
    nondet o = OBJECTS.oneOf(); WriteObject(o),
  }

  // The bad case: a field the controller expects is no longer in
  // storedFields. Positive invariant: every controller-expected
  // field is still in storedFields.
  val NoSilentDataLoss =
    OBJECTS.forall(o =>
      controllerExpectedField.get(o).forall(f =>
        storedFields.get(o).contains(f)))

  // Counterexample run: operator drops legacyField from schema,
  // then writes object 1, then controller reads legacyField — gone.
  run silentPruneRun = init
    .then(DropFieldFromSchema("legacyField"))
    .then(WriteObject(1))
    // storedFields[1] no longer contains legacyField; NoSilentDataLoss
    // is violated.

  // Recovery run: preserveUnknownFields=true keeps the field around.
  run preserveUnknownKeepsFieldRun = all {
    definedFields' = Set("name", "version", "legacyField"),
    storedFields' = OBJECTS.mapBy(_ => Set("name", "version", "legacyField")),
    preserveUnknownFields' = true,
    controllerExpectedField' = OBJECTS.mapBy(_ => Set("legacyField")),
  }
    .then(DropFieldFromSchema("legacyField"))
    .then(WriteObject(1))
}
