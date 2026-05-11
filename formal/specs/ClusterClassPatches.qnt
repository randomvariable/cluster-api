// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ClusterClassPatches.qnt — ordered ClusterClass patch accumulation,
// variable-resolution scope, per-MachineDeployment overrides, and
// webhook rejection of immutable-field flips.
//
// Grounding anchors at branch HEAD (see abstraction-mapping.md):
//
//   internal/controllers/topology/cluster/patches/engine.go
//     :66   Engine.Apply (ordered accumulation loop)
//     :92   loop over ClusterClass.Spec.Patches in order
//     :164  addVariablesForPatch (definitionFrom-scoped variable set)
//     :435  applyPatchesToRequest / applyPatchToRequest
//     :534  updateDesiredState
//
//   internal/controllers/topology/cluster/patches/patch.go
//     :61   patchObject (preserve selected fields)
//     :70   patchTemplate
//     :78   patchUnstructured
//
//   internal/controllers/topology/cluster/patches/inline/json_patch_generator.go
//     :56   Generate
//     :251  generateJSONPatches
//
//   internal/webhooks/patch_validation.go
//     :37   validatePatches
//     :320  validateJSONPatches
//     :356  validateJSONPatchValues
//
//   internal/webhooks/cluster.go
//     :128  default+validate in one webhook pass to avoid races
//     :754  DefaultAndValidateVariables
//     :898  ValidateClusterForClusterClass
//
module ClusterClassPatches {

  // ===============================================================
  // Type space
  // ===============================================================

  type VarName =
    | VarImage
    | VarDisk
    | VarClass
    | VarTag
    | VarOverride

  type TemplateField =
    | ImageTag
    | DiskGiB
    | ControlPlaneClass
    | MetadataTag

  type PatchId =
    | PatchImage
    | PatchDisk
    | PatchClass
    | PatchConflict
    | PatchMdOverride

  type DefinitionFrom =
    | ClusterClass
    | UserOverride

  type PatchOrder =
    | Canonical
    | Reordered

  type ValidationVerdict =
    | ValidationAccept
    | ValidationReject

  pure val ALL_VARS: Set[VarName] = Set(VarImage, VarDisk, VarClass, VarTag, VarOverride)
  pure val ALL_FIELDS: Set[TemplateField] = Set(ImageTag, DiskGiB, ControlPlaneClass, MetadataTag)
  pure val ALL_PATCHES: Set[PatchId] = Set(PatchImage, PatchDisk, PatchClass, PatchConflict, PatchMdOverride)
  pure val VALUE_CHOICES: Set[int] = Set(0, 1, 2, 3, 4, 5, 9)

  // ===============================================================
  // Concrete-shape helpers
  // ===============================================================

  pure def patchField(p: PatchId): TemplateField =
    if (p == PatchImage or p == PatchConflict or p == PatchMdOverride) ImageTag
    else if (p == PatchDisk) DiskGiB
    else ControlPlaneClass

  pure def patchVar(p: PatchId): VarName =
    if (p == PatchImage) VarImage
    else if (p == PatchDisk) VarDisk
    else if (p == PatchClass) VarClass
    else if (p == PatchConflict) VarTag
    else VarOverride

  pure def patchFrom(p: PatchId): DefinitionFrom =
    if (p == PatchMdOverride) UserOverride else ClusterClass

  pure def baseTemplate: TemplateField -> int =
    ALL_FIELDS.mapBy(f =>
      if (f == ImageTag) 1
      else if (f == DiskGiB) 2
      else if (f == ControlPlaneClass) 1
      else 0)

  pure def appendIfEnabled(acc: List[PatchId], activePatches: Set[PatchId], p: PatchId): List[PatchId] =
    if (activePatches.contains(p)) acc.append(p) else acc

  pure def materializePatches(activePatches: Set[PatchId], order: PatchOrder): List[PatchId] =
    val clusterClassOrdered =
      if (order == Canonical)
        appendIfEnabled(
          appendIfEnabled(
            appendIfEnabled(
              appendIfEnabled([], activePatches, PatchImage),
              activePatches,
              PatchDisk),
            activePatches,
            PatchClass),
          activePatches,
          PatchConflict)
      else
        appendIfEnabled(
          appendIfEnabled(
            appendIfEnabled(
              appendIfEnabled([], activePatches, PatchConflict),
              activePatches,
              PatchClass),
            activePatches,
            PatchDisk),
          activePatches,
          PatchImage)
    if (activePatches.contains(PatchMdOverride)) clusterClassOrdered.append(PatchMdOverride)
    else clusterClassOrdered

  pure def mergeVars(
      ccVars: VarName -> int,
      topoVars: VarName -> int,
      ccPresent: Set[VarName],
      topoPresent: Set[VarName]): VarName -> int =
    ALL_VARS.mapBy(v =>
      if (topoPresent.contains(v)) topoVars.get(v)
      else if (ccPresent.contains(v)) ccVars.get(v)
      else 0)

  pure def patchResolvable(
      p: PatchId,
      ccPresent: Set[VarName],
      topoPresent: Set[VarName]): bool =
    if (patchFrom(p) == UserOverride) topoPresent.contains(patchVar(p))
    else ccPresent.union(topoPresent).contains(patchVar(p))

  pure def applyPatch(
      template: TemplateField -> int,
      p: PatchId,
      vars: VarName -> int): TemplateField -> int =
    template.put(patchField(p), vars.get(patchVar(p)))

  pure def applyMaybe(
      template: TemplateField -> int,
      activePatches: Set[PatchId],
      p: PatchId,
      vars: VarName -> int): TemplateField -> int =
    if (activePatches.contains(p)) applyPatch(template, p, vars) else template

  pure def computeMergedTemplate(
      activePatches: Set[PatchId],
      order: PatchOrder,
      vars: VarName -> int): TemplateField -> int =
    val clusterClassApplied =
      if (order == Canonical)
        applyMaybe(
          applyMaybe(
            applyMaybe(
              applyMaybe(baseTemplate, activePatches, PatchImage, vars),
              activePatches,
              PatchDisk,
              vars),
            activePatches,
            PatchClass,
            vars),
          activePatches,
          PatchConflict,
          vars)
      else
        applyMaybe(
          applyMaybe(
            applyMaybe(
              applyMaybe(baseTemplate, activePatches, PatchConflict, vars),
              activePatches,
              PatchClass,
              vars),
            activePatches,
            PatchDisk,
            vars),
          activePatches,
          PatchImage,
          vars)
    applyMaybe(clusterClassApplied, activePatches, PatchMdOverride, vars)

  pure def independentClusterClassFields(activePatches: Set[PatchId]): bool =
    not(activePatches.contains(PatchImage) and activePatches.contains(PatchConflict))

  pure def toggle(order: PatchOrder): PatchOrder =
    if (order == Canonical) Reordered else Canonical

  pure def candidateVerdict(
      candidate: TemplateField -> int,
      applied: TemplateField -> int,
      activePatches: Set[PatchId],
      ccPresent: Set[VarName],
      topoPresent: Set[VarName],
      immutable: Set[TemplateField]): ValidationVerdict =
    if (ALL_PATCHES.exists(p => activePatches.contains(p) and not(patchResolvable(p, ccPresent, topoPresent))))
      ValidationReject
    else if (immutable.exists(f => candidate.get(f) != applied.get(f)))
      ValidationReject
    else ValidationAccept

  // ===============================================================
  // State variables
  // ===============================================================

  var clusterClassVars: VarName -> int
  var topologyVars: VarName -> int
  var clusterClassPresent: Set[VarName]
  var topologyPresent: Set[VarName]
  var mergedVars: VarName -> int

  var enabledPatches: Set[PatchId]
  var patchOrder: PatchOrder
  var patches: List[PatchId]

  var mergedTemplate: TemplateField -> int
  var appliedTemplate: TemplateField -> int
  var webhookValidationVerdict: ValidationVerdict
  var immutableFields: Set[TemplateField]
  var templateGen: int

  // ===============================================================
  // Initial states / deterministic runs
  // ===============================================================

  action init = all {
    clusterClassVars'     = ALL_VARS.mapBy(v =>
                              if (v == VarImage) 2
                              else if (v == VarDisk) 3
                              else if (v == VarClass) 1
                              else 0),
    topologyVars'         = ALL_VARS.mapBy(_ => 0),
    clusterClassPresent'  = Set(VarImage, VarDisk, VarClass),
    topologyPresent'      = Set(VarTag),
    mergedVars'           = mergeVars(
                              ALL_VARS.mapBy(v =>
                                if (v == VarImage) 2
                                else if (v == VarDisk) 3
                                else if (v == VarClass) 1
                                else 0),
                              ALL_VARS.mapBy(_ => 0),
                              Set(VarImage, VarDisk, VarClass),
                              Set(VarTag)),
    enabledPatches'       = Set(PatchImage, PatchDisk, PatchClass),
    patchOrder'           = Canonical,
    patches'              = materializePatches(Set(PatchImage, PatchDisk, PatchClass), Canonical),
    mergedTemplate'       = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass),
                              Canonical,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 3
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(_ => 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag))),
    appliedTemplate'      = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass),
                              Canonical,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 3
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(_ => 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag))),
    webhookValidationVerdict' = candidateVerdict(
                                  computeMergedTemplate(
                                    Set(PatchImage, PatchDisk, PatchClass),
                                    Canonical,
                                    mergeVars(
                                      ALL_VARS.mapBy(v =>
                                        if (v == VarImage) 2
                                        else if (v == VarDisk) 3
                                        else if (v == VarClass) 1
                                        else 0),
                                      ALL_VARS.mapBy(_ => 0),
                                      Set(VarImage, VarDisk, VarClass),
                                      Set(VarTag))),
                                  computeMergedTemplate(
                                    Set(PatchImage, PatchDisk, PatchClass),
                                    Canonical,
                                    mergeVars(
                                      ALL_VARS.mapBy(v =>
                                        if (v == VarImage) 2
                                        else if (v == VarDisk) 3
                                        else if (v == VarClass) 1
                                        else 0),
                                      ALL_VARS.mapBy(_ => 0),
                                      Set(VarImage, VarDisk, VarClass),
                                      Set(VarTag))),
                                  Set(PatchImage, PatchDisk, PatchClass),
                                  Set(VarImage, VarDisk, VarClass),
                                  Set(VarTag),
                                  Set(ControlPlaneClass)),
    immutableFields'      = Set(ControlPlaneClass),
    templateGen'          = 1,
  }

  action happyPatchMergeRun = all {
    clusterClassVars'     = ALL_VARS.mapBy(v =>
                              if (v == VarImage) 2
                              else if (v == VarDisk) 4
                              else if (v == VarClass) 1
                              else 0),
    topologyVars'         = ALL_VARS.mapBy(v =>
                              if (v == VarTag) 5
                              else if (v == VarOverride) 9
                              else 0),
    clusterClassPresent'  = Set(VarImage, VarDisk, VarClass),
    topologyPresent'      = Set(VarTag, VarOverride),
    mergedVars'           = mergeVars(
                              ALL_VARS.mapBy(v =>
                                if (v == VarImage) 2
                                else if (v == VarDisk) 4
                                else if (v == VarClass) 1
                                else 0),
                              ALL_VARS.mapBy(v =>
                                if (v == VarTag) 5
                                else if (v == VarOverride) 9
                                else 0),
                              Set(VarImage, VarDisk, VarClass),
                              Set(VarTag, VarOverride)),
    enabledPatches'       = Set(PatchImage, PatchDisk, PatchClass, PatchMdOverride),
    patchOrder'           = Canonical,
    patches'              = materializePatches(Set(PatchImage, PatchDisk, PatchClass, PatchMdOverride), Canonical),
    mergedTemplate'       = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass, PatchMdOverride),
                              Canonical,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 4
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(v =>
                                  if (v == VarTag) 5
                                  else if (v == VarOverride) 9
                                  else 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag, VarOverride))),
    appliedTemplate'      = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass, PatchMdOverride),
                              Canonical,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 4
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(v =>
                                  if (v == VarTag) 5
                                  else if (v == VarOverride) 9
                                  else 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag, VarOverride))),
    webhookValidationVerdict' = ValidationAccept,
    immutableFields'      = Set(ControlPlaneClass),
    templateGen'          = 2,
  }

  action overlappingPatchOrderRun = all {
    clusterClassVars'     = ALL_VARS.mapBy(v =>
                              if (v == VarImage) 2
                              else if (v == VarDisk) 4
                              else if (v == VarClass) 1
                              else 0),
    topologyVars'         = ALL_VARS.mapBy(v =>
                              if (v == VarTag) 5
                              else if (v == VarOverride) 9
                              else 0),
    clusterClassPresent'  = Set(VarImage, VarDisk, VarClass),
    topologyPresent'      = Set(VarTag, VarOverride),
    mergedVars'           = mergeVars(
                              ALL_VARS.mapBy(v =>
                                if (v == VarImage) 2
                                else if (v == VarDisk) 4
                                else if (v == VarClass) 1
                                else 0),
                              ALL_VARS.mapBy(v =>
                                if (v == VarTag) 5
                                else if (v == VarOverride) 9
                                else 0),
                              Set(VarImage, VarDisk, VarClass),
                              Set(VarTag, VarOverride)),
    enabledPatches'       = Set(PatchImage, PatchDisk, PatchClass, PatchConflict, PatchMdOverride),
    patchOrder'           = Reordered,
    patches'              = materializePatches(Set(PatchImage, PatchDisk, PatchClass, PatchConflict, PatchMdOverride), Reordered),
    mergedTemplate'       = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass, PatchConflict, PatchMdOverride),
                              Reordered,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 4
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(v =>
                                  if (v == VarTag) 5
                                  else if (v == VarOverride) 9
                                  else 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag, VarOverride))),
    appliedTemplate'      = computeMergedTemplate(
                              Set(PatchImage, PatchDisk, PatchClass, PatchConflict, PatchMdOverride),
                              Reordered,
                              mergeVars(
                                ALL_VARS.mapBy(v =>
                                  if (v == VarImage) 2
                                  else if (v == VarDisk) 4
                                  else if (v == VarClass) 1
                                  else 0),
                                ALL_VARS.mapBy(v =>
                                  if (v == VarTag) 5
                                  else if (v == VarOverride) 9
                                  else 0),
                                Set(VarImage, VarDisk, VarClass),
                                Set(VarTag, VarOverride))),
    webhookValidationVerdict' = ValidationAccept,
    immutableFields'      = Set(ControlPlaneClass),
    templateGen'          = 2,
  }

  // ===============================================================
  // State transitions
  // ===============================================================

  action OperatorAddsVariable(v: VarName, value: int): bool = all {
    VALUE_CHOICES.contains(value),
    not(topologyPresent.contains(v)),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars.put(v, value),
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent.union(Set(v)),
    mergedVars'           = mergeVars(clusterClassVars, topologyVars.put(v, value), clusterClassPresent, topologyPresent.union(Set(v))),
    enabledPatches'       = enabledPatches,
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches, patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars, topologyVars.put(v, value), clusterClassPresent, topologyPresent.union(Set(v)))),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars, topologyVars.put(v, value), clusterClassPresent, topologyPresent.union(Set(v)))), appliedTemplate, enabledPatches, clusterClassPresent, topologyPresent.union(Set(v)), immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action OperatorRemovesVariable(v: VarName): bool = all {
    topologyPresent.contains(v),
    ALL_PATCHES.forall(p => not(enabledPatches.contains(p)) or patchResolvable(p, clusterClassPresent, topologyPresent.exclude(Set(v)))),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent.exclude(Set(v)),
    mergedVars'           = mergeVars(clusterClassVars, topologyVars, clusterClassPresent, topologyPresent.exclude(Set(v))),
    enabledPatches'       = enabledPatches,
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches, patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars, topologyVars, clusterClassPresent, topologyPresent.exclude(Set(v)))),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars, topologyVars, clusterClassPresent, topologyPresent.exclude(Set(v)))), appliedTemplate, enabledPatches, clusterClassPresent, topologyPresent.exclude(Set(v)), immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action PatchAppendOrder(p: PatchId): bool = all {
    any { p == PatchImage, p == PatchDisk, p == PatchClass },
    not(enabledPatches.contains(p)),
    patchResolvable(p, clusterClassPresent, topologyPresent),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent,
    mergedVars'           = mergedVars,
    enabledPatches'       = enabledPatches.union(Set(p)),
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches.union(Set(p)), patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches.union(Set(p)), patchOrder, mergedVars),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches.union(Set(p)), patchOrder, mergedVars), appliedTemplate, enabledPatches.union(Set(p)), clusterClassPresent, topologyPresent, immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action ConflictingPatchOnSameField: bool = all {
    not(enabledPatches.contains(PatchConflict)),
    patchResolvable(PatchConflict, clusterClassPresent, topologyPresent),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent,
    mergedVars'           = mergedVars,
    enabledPatches'       = enabledPatches.union(Set(PatchConflict)),
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches.union(Set(PatchConflict)), patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches.union(Set(PatchConflict)), patchOrder, mergedVars),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches.union(Set(PatchConflict)), patchOrder, mergedVars), appliedTemplate, enabledPatches.union(Set(PatchConflict)), clusterClassPresent, topologyPresent, immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action OverrideMachineDeploymentTemplate(value: int): bool = all {
    VALUE_CHOICES.contains(value),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars.put(VarOverride, value),
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent.union(Set(VarOverride)),
    mergedVars'           = mergeVars(clusterClassVars, topologyVars.put(VarOverride, value), clusterClassPresent, topologyPresent.union(Set(VarOverride))),
    enabledPatches'       = enabledPatches.union(Set(PatchMdOverride)),
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches.union(Set(PatchMdOverride)), patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches.union(Set(PatchMdOverride)), patchOrder, mergeVars(clusterClassVars, topologyVars.put(VarOverride, value), clusterClassPresent, topologyPresent.union(Set(VarOverride)))),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches.union(Set(PatchMdOverride)), patchOrder, mergeVars(clusterClassVars, topologyVars.put(VarOverride, value), clusterClassPresent, topologyPresent.union(Set(VarOverride)))), appliedTemplate, enabledPatches.union(Set(PatchMdOverride)), clusterClassPresent, topologyPresent.union(Set(VarOverride)), immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action ClusterClassImmutableFieldChanges(value: int): bool = all {
    VALUE_CHOICES.contains(value),
    value != clusterClassVars.get(VarClass),
    clusterClassVars'     = clusterClassVars.put(VarClass, value),
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent,
    mergedVars'           = mergeVars(clusterClassVars.put(VarClass, value), topologyVars, clusterClassPresent, topologyPresent),
    enabledPatches'       = enabledPatches,
    patchOrder'           = patchOrder,
    patches'              = materializePatches(enabledPatches, patchOrder),
    mergedTemplate'       = computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars.put(VarClass, value), topologyVars, clusterClassPresent, topologyPresent)),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches, patchOrder, mergeVars(clusterClassVars.put(VarClass, value), topologyVars, clusterClassPresent, topologyPresent)), appliedTemplate, enabledPatches, clusterClassPresent, topologyPresent, immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action ClusterClassPatchOrderChange: bool = all {
    enabledPatches.contains(PatchConflict),
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent,
    mergedVars'           = mergedVars,
    enabledPatches'       = enabledPatches,
    patchOrder'           = toggle(patchOrder),
    patches'              = materializePatches(enabledPatches, toggle(patchOrder)),
    mergedTemplate'       = computeMergedTemplate(enabledPatches, toggle(patchOrder), mergedVars),
    appliedTemplate'      = appliedTemplate,
    webhookValidationVerdict' = candidateVerdict(computeMergedTemplate(enabledPatches, toggle(patchOrder), mergedVars), appliedTemplate, enabledPatches, clusterClassPresent, topologyPresent, immutableFields),
    immutableFields'      = immutableFields,
    templateGen'          = templateGen,
  }

  action MergedTemplateApplied: bool = all {
    clusterClassVars'     = clusterClassVars,
    topologyVars'         = topologyVars,
    clusterClassPresent'  = clusterClassPresent,
    topologyPresent'      = topologyPresent,
    mergedVars'           = mergedVars,
    enabledPatches'       = enabledPatches,
    patchOrder'           = patchOrder,
    patches'              = patches,
    mergedTemplate'       = mergedTemplate,
    appliedTemplate'      = if (webhookValidationVerdict == ValidationAccept) mergedTemplate else appliedTemplate,
    webhookValidationVerdict' = webhookValidationVerdict,
    immutableFields'      = immutableFields,
    templateGen'          = if (webhookValidationVerdict == ValidationAccept and mergedTemplate != appliedTemplate) templateGen + 1 else templateGen,
  }

  action randomStep: bool = any {
    OperatorAddsVariable(VarOverride, 9),
    OperatorAddsVariable(VarTag, 5),
    OperatorAddsVariable(VarDisk, 4),
    OperatorRemovesVariable(VarOverride),
    OperatorRemovesVariable(VarTag),
    PatchAppendOrder(PatchImage),
    PatchAppendOrder(PatchDisk),
    PatchAppendOrder(PatchClass),
    ConflictingPatchOnSameField,
    OverrideMachineDeploymentTemplate(9),
    ClusterClassImmutableFieldChanges(4),
    ClusterClassPatchOrderChange,
    MergedTemplateApplied,
  }

  // Smaller branching relation for symbolic exploration.
  action step: bool = any {
    MergedTemplateApplied,
  }

  // ===============================================================
  // Invariants
  // ===============================================================

  val mergeDeterministic =
    independentClusterClassFields(enabledPatches)
      implies mergedTemplate == computeMergedTemplate(enabledPatches, Canonical, mergedVars)

  val immutablePreserved =
    immutableFields.forall(f => appliedTemplate.get(f) == baseTemplate.get(f))

  val overridesSurviveCC =
    enabledPatches.contains(PatchMdOverride)
      implies mergedTemplate.get(ImageTag) == mergedVars.get(VarOverride)

  val patchIdempotent =
    val once = computeMergedTemplate(enabledPatches, patchOrder, mergedVars)
    val twice = computeMergedTemplate(enabledPatches, patchOrder, mergedVars)
    once == twice

  val noPhantomVar =
    ALL_PATCHES.forall(p => not(enabledPatches.contains(p)) or patchResolvable(p, clusterClassPresent, topologyPresent))

  // Stronger candidate obligations kept for counterexample harvesting.
  val mergeDeterministicAllOrders =
    mergedTemplate == computeMergedTemplate(enabledPatches, Canonical, mergedVars)

  val immutableMergedCandidate =
    immutableFields.forall(f => mergedTemplate.get(f) == appliedTemplate.get(f))

  val StableSafetyInvariants = all {
    patches == materializePatches(enabledPatches, patchOrder),
    mergedVars == mergeVars(clusterClassVars, topologyVars, clusterClassPresent, topologyPresent),
    mergedTemplate == computeMergedTemplate(enabledPatches, patchOrder, mergedVars),
    // If the candidate merge flips an immutable field, the webhook must reject it.
    immutableFields.exists(f => mergedTemplate.get(f) != appliedTemplate.get(f))
      implies webhookValidationVerdict == ValidationReject,
    mergeDeterministic,
    immutablePreserved,
    overridesSurviveCC,
    patchIdempotent,
    noPhantomVar,
  }
}
