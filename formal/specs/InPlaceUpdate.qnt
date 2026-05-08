// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// InPlaceUpdate.qnt — In-place machine updates (CAEP "in-place
// updates", feature gate `InPlaceUpdates`).
//
// Refines the cross-controller choreography that turns a worker
// MachineDeployment template change into per-Machine patch calls
// to a runtime extension, instead of a rolling replacement. The
// flow involves THREE controllers (MachineDeployment, MachineSet,
// Machine) and FIVE annotations plus the pending-hooks annotation.
// The model captures the complete two-way handshake from
// MD-decides-to-in-place to UpdateMachine-hook-fires-to-completion.
//
// LSP grounding (gopls go_search + grep on the formality working
// tree). All anchors below reference Cluster API at HEAD of branch
// `formality`; see abstraction-mapping.md §InPlaceUpdate.qnt.
//
//   feature/feature.go
//     :86   InPlaceUpdates feature gate
//     :110  default Alpha / disabled
//
//   api/runtime/hooks/v1alpha1/inplaceupdate_types.go
//     :103  CanUpdateMachine hook
//     :165  CanUpdateMachineSet hook
//     :213  UpdateMachine hook
//
//   api/core/v1beta2/machine_types.go
//     :96   PendingAcknowledgeMoveAnnotation
//     :100  UpdateInProgressAnnotation
//
//   api/core/v1beta2/machineset_types.go
//     :43   MachineSetMoveMachinesToMachineSetAnnotation
//     :51   MachineSetReceiveMachinesFromMachineSetsAnnotation
//     :58   AcknowledgedMoveAnnotation
//
//   internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go
//     :111  rolloutPlanner.reconcileReplicasPendingAcknowledgeMove
//     :414  rolloutPlanner.reconcileInPlaceUpdateIntent
//     :529  rolloutPlanner.scalingOrInPlaceUpdateInProgress
//
//   internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go
//     :53   rolloutPlanner.canUpdateMachineSetInPlace
//     :120  rolloutPlanner.canExtensionsUpdateMachineSet
//
//   internal/controllers/machineset/machineset_controller.go
//     :371  PendingAcknowledgeMove → drop on AcknowledgedMove
//     :397  Reconciler.completeMoveMachine call
//     :403  hooks.MarkObjectAsPending(UpdateMachine)
//     :806  scale-down branch dispatching to startMoveMachines
//     :974  Reconciler.startMoveMachines
//
//   internal/controllers/machineset/machineset_controller.go
//     :429  Reconciler.completeMoveMachine
//
//   internal/controllers/machine/machine_controller_inplace_update.go
//     :43   Reconciler.reconcileInPlaceUpdate
//     :127  Reconciler.isInfraMachineReadyForUpdate
//     :133  Reconciler.isBootstrapConfigReadyForUpdate
//     :142  Reconciler.callUpdateMachineHook
//     :198  Reconciler.completeInPlaceUpdate
//     :230  Reconciler.removeInPlaceUpdateAnnotation
//
//   internal/util/inplace/inplace.go
//     IsUpdateInProgress (used by startMoveMachines:1017 to skip
//     machines already updating)
//
// SCOPE NOTE. The model assumes a single MachineDeployment with
// one oldMS and one newMS — the smallest topology that exercises
// the move handshake. Multi-MS scenarios (>1 oldMS) reduce to
// repeated applications of the same pattern.
module InPlaceUpdate {

  // ===============================================================
  // Type space
  // ===============================================================

  type MachineId = int

  // Per-Machine state. Refines the bookkeeping flags observed by
  // `Reconciler.reconcileInPlaceUpdate` at
  // `machine_controller_inplace_update.go:43-124`.
  type MachinePhase =
    | OnOldMS                  // owned by oldMS, no in-place flags
    | MovingPending            // OwnerRef flipped to newMS, has
                               // UpdateInProgress + PendingAck on
                               // the Machine. AcknowledgedMove not
                               // yet set on newMS.
    | MovingAcknowledged       // newMS has Machine in
                               // AcknowledgedMove; PendingAck
                               // dropped from Machine but not yet
                               // completeMoveMachine.
    | InPlaceArmed             // completeMoveMachine has run:
                               // InfraMachine + BootstrapConfig
                               // also carry UpdateInProgress;
                               // UpdateMachine hook is pending.
    | InPlaceUpdating          // UpdateMachine hook returned
                               // RetryAfter > 0 (in-progress).
    | InPlaceDone              // UpdateMachine returned ok;
                               // annotations + pending-hook
                               // cleared; Machine on newMS at new
                               // version.
    | InPlaceFailed            // UpdateMachine returned Failure or
                               // multiple-extensions detected;
                               // s.updatingReason =
                               // MachineInPlaceUpdateFailedReason.

  // Hook outcome envelope for UpdateMachine. Refines the response
  // discriminator at `inplaceupdate_types.go:198-201`:
  //   - Success + RetryAfterSeconds > 0  → in progress
  //   - Success + RetryAfterSeconds = 0  → done
  //   - Failure                          → failed
  type UpdateOutcome =
    | UpdateProgressing
    | UpdateDone
    | UpdateFailed

  // CanUpdateMachineSet planning verdict. Refines
  // `canExtensionsUpdateMachineSet` at
  // `machinedeployment_canupdatemachineset.go:120-159`.
  type CanUpdateVerdict =
    | CanUpdateUnknown    // not yet evaluated this reconcile
    | CanUpdateYes        // extension matched the desired spec
    | CanUpdateNo         // no extension can cover the change
                          // (or no extension registered: line 81)

  // ===============================================================
  // Bounds
  // ===============================================================

  pure val MACHINES: Set[MachineId] = 1.to(3)

  // ===============================================================
  // State variables
  // ===============================================================

  // Replica intent. Refines `MachineDeployment.Spec.Replicas`.
  var mdReplicas: int

  // Old / new MachineSet template versions. Refines the
  // `MachineSet.Spec.Template.Spec.Version` field.
  var oldMsVersion: int
  var newMsVersion: int

  // Per-Machine version (mutates in-place when the hook completes).
  var machineVersion: MachineId -> int

  // Per-Machine phase.
  var machinePhase: MachineId -> MachinePhase

  // Per-Machine ownership (true ⇒ owned by newMS).
  var machineOnNewMs: MachineId -> bool

  // Annotation set on each side of the handshake. Booleans rather
  // than strings because the model has only one (oldMS, newMS) pair.
  // Refines:
  //   oldMsHasMoveAnnotation   ↔
  //     `MachineSetMoveMachinesToMachineSetAnnotation` on oldMS
  //     (`machineset_types.go:43`).
  //   newMsHasReceiveAnnotation ↔
  //     `MachineSetReceiveMachinesFromMachineSetsAnnotation` on newMS
  //     (`machineset_types.go:51`).
  //   acknowledgedMove          ↔ Set of Machine IDs in
  //     `AcknowledgedMoveAnnotation` value on newMS
  //     (`machineset_types.go:58`).
  var oldMsHasMoveAnnotation: bool
  var newMsHasReceiveAnnotation: bool
  var acknowledgedMove: Set[MachineId]

  // Pending-hooks set on Machine. Refines the comma-separated
  // `runtime.cluster.x-k8s.io/pending-hooks` annotation; for this
  // model the only relevant hook is UpdateMachine.
  var updateMachineHookPending: MachineId -> bool

  // Per-Machine in-place-update annotations. The Machine
  // controller's reconcileInPlaceUpdate gate at
  // `machine_controller_inplace_update.go:94-100` requires ALL
  // three to be present. Refines the
  // `UpdateInProgressAnnotation` (`machine_types.go:100`) on each
  // of the Machine / InfraMachine / BootstrapConfig.
  var machineInProgress: MachineId -> bool
  var infraInProgress: MachineId -> bool
  var bootstrapInProgress: MachineId -> bool

  // CanUpdateMachineSet planning cache verdict. Refines the
  // `canUpdateMachineSetCache` at
  // `machinedeployment_canupdatemachineset.go:88-99`.
  var canUpdateVerdict: CanUpdateVerdict

  // Number of CanUpdateMachineSet extensions. Refines
  // `len(extensionHandlers)` at lines 76-86: 0 ⇒ fall back to
  // rolling, >1 ⇒ error.
  var canUpdateExtensionCount: int

  // Number of UpdateMachine extensions. Refines
  // `len(extensions)` at `machine_controller_inplace_update.go:152`:
  // 0 ⇒ "no extensions" error, >1 ⇒ "multiple hooks" error.
  var updateMachineExtensionCount: int

  // Last UpdateMachine outcome (cached) per Machine. Refines the
  // `hookCache` at `machine_controller_inplace_update.go:159-164`
  // and the response discriminator.
  var lastUpdateOutcome: MachineId -> UpdateOutcome

  // Feature gate. Refines `feature.Gates.Enabled(InPlaceUpdates)`
  // at `machine_controller_inplace_update.go:44` and
  // `machinedeployment_rollout_rollingupdate.go:417`.
  var inPlaceFeatureEnabled: bool

  // ===============================================================
  // Pure helpers
  // ===============================================================

  // canUpdateInPlace refines
  // `rolloutPlanner.canUpdateMachineSetInPlace` at
  // `machinedeployment_canupdatemachineset.go:53`. The Go function
  // returns false when extensionHandlers is empty (line 81). The
  // model collapses to the cached verdict.
  pure def canUpdateInPlace(v: CanUpdateVerdict): bool =
    v == CanUpdateYes

  // hookGateOpen refines the precondition cascade at
  // `machine_controller_inplace_update.go:74-99`: feature gate on,
  // UpdateInProgress on Machine, UpdateMachine hook pending, infra
  // provisioned (assumed by being on newMS), bootstrap secret OK
  // (assumed), nodeRef set (assumed by InPlaceArmed precondition),
  // and the per-object UpdateInProgress on infra+bootstrap.
  pure def hookGateOpen(
      featureOn: bool,
      mInProgress: bool,
      hookPending: bool,
      iInProgress: bool,
      bInProgress: bool): bool =
    featureOn
      and mInProgress
      and hookPending
      and iInProgress
      and bInProgress

  // ===============================================================
  // Initial state
  // ===============================================================

  // init — three Machines on oldMS at v36; operator changes the
  // MD template to v37; rollout planner has not yet evaluated.
  action init = all {
    mdReplicas'                     = 3,
    oldMsVersion'                   = 36,
    newMsVersion'                   = 37,
    machineVersion'                 = MACHINES.mapBy(_ => 36),
    machinePhase'                   = MACHINES.mapBy(_ => OnOldMS),
    machineOnNewMs'                 = MACHINES.mapBy(_ => false),
    oldMsHasMoveAnnotation'         = false,
    newMsHasReceiveAnnotation'      = false,
    acknowledgedMove'               = Set(),
    updateMachineHookPending'       = MACHINES.mapBy(_ => false),
    machineInProgress'              = MACHINES.mapBy(_ => false),
    infraInProgress'                = MACHINES.mapBy(_ => false),
    bootstrapInProgress'            = MACHINES.mapBy(_ => false),
    canUpdateVerdict'               = CanUpdateUnknown,
    canUpdateExtensionCount'        = 1,    // single extension by default
    updateMachineExtensionCount'    = 1,
    lastUpdateOutcome'              = MACHINES.mapBy(_ => UpdateProgressing),
    inPlaceFeatureEnabled'          = true,
  }

  // ===============================================================
  // MD rollout-planner actions
  // ===============================================================

  // EvaluateCanUpdateMachineSet refines
  // `rolloutPlanner.canUpdateMachineSetInPlace` at
  // `machinedeployment_canupdatemachineset.go:53` and the inner
  // call to `canExtensionsUpdateMachineSet` at line 120. The
  // verdict is cached (lines 88-99); the model picks the verdict
  // non-deterministically among CanUpdateYes/No when one extension
  // is registered, and forces CanUpdateNo when zero extensions
  // (line 81-82).
  action EvaluateCanUpdateMachineSet(v: CanUpdateVerdict): bool = all {
    inPlaceFeatureEnabled,
    oldMsVersion != newMsVersion,
    canUpdateVerdict == CanUpdateUnknown,
    any {
      // Multiple extensions → error in upstream; the model
      // surfaces this as CanUpdateNo (the planner does not
      // commit to in-place; logs the error and returns).
      all {
        canUpdateExtensionCount > 1,
        v == CanUpdateNo,
      },
      // No extension registered → fall back to rolling.
      all {
        canUpdateExtensionCount == 0,
        v == CanUpdateNo,
      },
      // Exactly one extension — extension chooses to admit or not.
      all {
        canUpdateExtensionCount == 1,
        any { v == CanUpdateYes, v == CanUpdateNo },
      },
    },
    canUpdateVerdict' = v,
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    machineInProgress'           = machineInProgress,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // SetMoveAnnotations refines the second half of
  // `reconcileInPlaceUpdateIntent` at
  // `machinedeployment_rollout_rollingupdate.go:455-477`. Sets the
  // pair of annotations on oldMS (line 459) and newMS (line 477)
  // simultaneously — the Go code does both before returning, and
  // a single rollout-planner reconcile is atomic from the model's
  // perspective.
  action SetMoveAnnotations: bool = all {
    canUpdateInPlace(canUpdateVerdict),
    not(oldMsHasMoveAnnotation),
    oldMsHasMoveAnnotation'      = true,
    newMsHasReceiveAnnotation'   = true,
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    machineInProgress'           = machineInProgress,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // AcknowledgeMove refines
  // `rolloutPlanner.reconcileReplicasPendingAcknowledgeMove` at
  // `machinedeployment_rollout_rollingupdate.go:111-162`: the
  // planner inspects newMS's machines for PendingAcknowledgeMove
  // and adds them to the AcknowledgedMoveAnnotation list (line
  // 162). Triggered for one Machine at a time in the model.
  action AcknowledgeMove(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == MovingPending,
    not(acknowledgedMove.contains(m)),
    acknowledgedMove' = acknowledgedMove.union(Set(m)),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    updateMachineHookPending'    = updateMachineHookPending,
    machineInProgress'           = machineInProgress,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // MachineSet controller actions
  // ===============================================================

  // StartMoveMachine refines `Reconciler.startMoveMachines` at
  // `machineset_controller.go:974-1091`. Per-Machine: change
  // ownership (line 1046-1052), change unique label (line 1064),
  // set UpdateInProgress + PendingAcknowledgeMove on Machine
  // (lines 1070-1071). Precondition cascade: the source MS has
  // MoveMachinesTo (line 806, here the action's guard) and the
  // target MS has ReceiveMachinesFrom (line 990, model's
  // newMsHasReceiveAnnotation). Skips machines already updating
  // (line 1017) — model encodes this by requiring OnOldMS phase.
  action StartMoveMachine(m: MachineId): bool = all {
    MACHINES.contains(m),
    oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation,                       // two-way check
    machinePhase.get(m) == OnOldMS,
    not(machineOnNewMs.get(m)),
    machineOnNewMs'           = machineOnNewMs.put(m, true),
    machinePhase'             = machinePhase.put(m, MovingPending),
    machineInProgress'        = machineInProgress.put(m, true),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // CompleteMoveMachine refines the newMS-side handshake at
  // `machineset_controller.go:371-403`:
  //   1. Drop PendingAcknowledgeMove from Machine if Machine is in
  //      AcknowledgedMove list on newMS (lines 381-386).
  //   2. Run completeMoveMachine (line 397, function at :429):
  //      writes desired InfraMachine and BootstrapConfig with
  //      UpdateInProgress (lines 458, 481).
  //   3. MarkObjectAsPending(UpdateMachine) on the Machine
  //      (line 403).
  // The model collapses these into one atomic action because
  // they happen in the same MS reconcile.
  action CompleteMoveMachine(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == MovingPending,
    acknowledgedMove.contains(m),
    machinePhase'              = machinePhase.put(m, InPlaceArmed),
    infraInProgress'           = infraInProgress.put(m, true),
    bootstrapInProgress'       = bootstrapInProgress.put(m, true),
    updateMachineHookPending'  = updateMachineHookPending.put(m, true),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    machineInProgress'           = machineInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // Machine controller actions (in-place update)
  // ===============================================================

  // CallUpdateMachineHook refines
  // `Reconciler.callUpdateMachineHook` at
  // `machine_controller_inplace_update.go:142-194`. Pre: the gate
  // at lines 74-99 (Machine UpdateInProgress + UpdateMachine
  // pending + infra/bootstrap UpdateInProgress + feature on).
  // Outcome:
  //   - 0 extensions → error (lines 152-153). Model: phase →
  //     InPlaceFailed.
  //   - >1 extensions → error (lines 155-156). Model: phase →
  //     InPlaceFailed.
  //   - RetryAfter > 0 → in progress (line 185-189). Model:
  //     phase → InPlaceUpdating, lastUpdateOutcome = UpdateProgressing.
  //   - RetryAfter = 0 → completed (line 192-193). Model: caller
  //     proceeds to completeInPlaceUpdate.
  //   - Failure → reason flipped (line 104-106). Model:
  //     UpdateFailed.
  action CallUpdateMachineHook(m: MachineId, outcome: UpdateOutcome): bool = all {
    MACHINES.contains(m),
    hookGateOpen(
      inPlaceFeatureEnabled,
      machineInProgress.get(m),
      updateMachineHookPending.get(m),
      infraInProgress.get(m),
      bootstrapInProgress.get(m)),
    any {
      machinePhase.get(m) == InPlaceArmed,
      machinePhase.get(m) == InPlaceUpdating,
    },
    any {
      // Single extension, returns Progressing → keep retrying.
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateProgressing,
        machinePhase' = machinePhase.put(m, InPlaceUpdating),
      },
      // Single extension, returns Done.
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateDone,
        machinePhase' = machinePhase.put(m, InPlaceUpdating),
        // we do NOT yet promote — completeInPlaceUpdate clears
        // annotations + pending hook (next action). Modelled
        // as advance from InPlaceArmed to InPlaceUpdating; the
        // CompleteInPlaceUpdate action consumes UpdateDone.
      },
      // Single extension, returns Failure.
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateFailed,
        machinePhase' = machinePhase.put(m, InPlaceFailed),
      },
      // Zero or >1 extensions — line 152-156 errors.
      all {
        any {
          updateMachineExtensionCount == 0,
          updateMachineExtensionCount > 1,
        },
        outcome == UpdateFailed,
        machinePhase' = machinePhase.put(m, InPlaceFailed),
      },
    },
    lastUpdateOutcome' = lastUpdateOutcome.put(m, outcome),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    machineInProgress'           = machineInProgress,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // CompleteInPlaceUpdate refines
  // `Reconciler.completeInPlaceUpdate` at
  // `machine_controller_inplace_update.go:198-227`:
  //   - Remove UpdateInProgress from Machine (line 201-203).
  //   - Remove UpdateInProgress from InfraMachine (line 208-210).
  //   - Remove UpdateInProgress from BootstrapConfig (line
  //     213-216).
  //   - hooks.MarkAsDone(UpdateMachine) on Machine (line 221).
  // Refined as one atomic action since the upstream sequence is
  // a single reconcile-suffix.
  action CompleteInPlaceUpdate(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == InPlaceUpdating,
    lastUpdateOutcome.get(m) == UpdateDone,
    machineInProgress'         = machineInProgress.put(m, false),
    infraInProgress'           = infraInProgress.put(m, false),
    bootstrapInProgress'       = bootstrapInProgress.put(m, false),
    updateMachineHookPending'  = updateMachineHookPending.put(m, false),
    machinePhase'              = machinePhase.put(m, InPlaceDone),
    machineVersion'            = machineVersion.put(m, newMsVersion),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // CleanupOrphanedHook refines the cleanup branch at
  // `machine_controller_inplace_update.go:54-66`: if the
  // UpdateInProgress annotation has been removed from the Machine
  // but the UpdateMachine hook is still pending, clean up the
  // orphaned annotation+hook.
  action CleanupOrphanedHook(m: MachineId): bool = all {
    MACHINES.contains(m),
    not(machineInProgress.get(m)),
    updateMachineHookPending.get(m),
    machinePhase.get(m) != InPlaceDone,
    updateMachineHookPending'  = updateMachineHookPending.put(m, false),
    infraInProgress'           = infraInProgress.put(m, false),
    bootstrapInProgress'       = bootstrapInProgress.put(m, false),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    machineInProgress'           = machineInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // Operator-driven faults
  // ===============================================================

  // OperatorRegisterMultipleUpdateMachineExtensions —
  // misconfiguration that the upstream code rejects at
  // `machine_controller_inplace_update.go:155-156`.
  action OperatorRegisterMultipleUpdateMachineExtensions: bool = all {
    updateMachineExtensionCount == 1,
    updateMachineExtensionCount' = 2,
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    machineInProgress'           = machineInProgress,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // OperatorRemoveUpdateInProgress — operator removes the
  // UpdateInProgress annotation from a Machine mid-update. The
  // upstream cleanup branch at
  // `machine_controller_inplace_update.go:54-66` handles this
  // ONLY when the UpdateMachine hook is already pending — i.e.
  // after `completeMoveMachine` has set the pending-hook bit
  // (`machineset_controller.go:403`). Removing the annotation in
  // an earlier state (MovingPending) is not a documented failure
  // surface; the model restricts to the post-armed states to
  // match the cleanup-branch precondition.
  action OperatorRemoveUpdateInProgress(m: MachineId): bool = all {
    MACHINES.contains(m),
    machineInProgress.get(m),
    updateMachineHookPending.get(m),
    machinePhase.get(m) != InPlaceDone,
    machineInProgress' = machineInProgress.put(m, false),
    // Frame:
    mdReplicas'                  = mdReplicas,
    oldMsVersion'                = oldMsVersion,
    newMsVersion'                = newMsVersion,
    machineVersion'              = machineVersion,
    machinePhase'                = machinePhase,
    machineOnNewMs'              = machineOnNewMs,
    oldMsHasMoveAnnotation'      = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation'   = newMsHasReceiveAnnotation,
    acknowledgedMove'            = acknowledgedMove,
    updateMachineHookPending'    = updateMachineHookPending,
    infraInProgress'             = infraInProgress,
    bootstrapInProgress'         = bootstrapInProgress,
    canUpdateVerdict'            = canUpdateVerdict,
    canUpdateExtensionCount'     = canUpdateExtensionCount,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    lastUpdateOutcome'           = lastUpdateOutcome,
    inPlaceFeatureEnabled'       = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    nondet v = Set(CanUpdateYes, CanUpdateNo).oneOf();
      EvaluateCanUpdateMachineSet(v),
    SetMoveAnnotations,
    nondet m = MACHINES.oneOf(); StartMoveMachine(m),
    nondet m = MACHINES.oneOf(); AcknowledgeMove(m),
    nondet m = MACHINES.oneOf(); CompleteMoveMachine(m),
    nondet m = MACHINES.oneOf();
      nondet o = Set(UpdateProgressing, UpdateDone, UpdateFailed).oneOf();
      CallUpdateMachineHook(m, o),
    nondet m = MACHINES.oneOf(); CompleteInPlaceUpdate(m),
    nondet m = MACHINES.oneOf(); CleanupOrphanedHook(m),
    OperatorRegisterMultipleUpdateMachineExtensions,
    nondet m = MACHINES.oneOf(); OperatorRemoveUpdateInProgress(m),
  }

  // ===============================================================
  // Liveness properties (issue #3 — beyond FM-9)
  // ===============================================================

  // allVars tuple for fairness operator. Quint compiles this to
  // TLA+'s <<vars>> tuple at the lambda level. See FM-9
  // discussion in `failure-modes.md`.
  val allVars = (mdReplicas, oldMsVersion, newMsVersion,
    machineVersion, machinePhase, machineOnNewMs,
    oldMsHasMoveAnnotation, newMsHasReceiveAnnotation,
    acknowledgedMove, updateMachineHookPending,
    machineInProgress, infraInProgress, bootstrapInProgress,
    canUpdateVerdict, canUpdateExtensionCount,
    updateMachineExtensionCount, lastUpdateOutcome,
    inPlaceFeatureEnabled)

  // Pure helper: a Machine is in a "settled" phase — either it
  // never got admitted to in-place (OnOldMS, in which case the
  // rolling fallback would handle it; rolling is not modelled
  // here), or the in-place flow completed (InPlaceDone) or
  // failed (InPlaceFailed). All three are terminal in the
  // sense that no further forward-progress transition fires
  // from them in this spec.
  pure def isSettled(p: MachinePhase): bool =
    p == OnOldMS or p == InPlaceDone or p == InPlaceFailed

  // The fairness conjunct list for the in-place forward-progress
  // path. Strong-fair on every action that, when enabled, must
  // eventually fire to advance a Machine toward a settled phase.
  // Operator misconfiguration actions
  // (OperatorRegisterMultipleUpdateMachineExtensions,
  // OperatorRemoveUpdateInProgress) are NOT in the fair set —
  // they may never fire, but if they do, the failure branch is
  // also a settled phase, so the property still holds.
  temporal ForwardProgressFair =
    strongFair(any { nondet v = Set(CanUpdateYes, CanUpdateNo).oneOf();
                     EvaluateCanUpdateMachineSet(v) }, allVars)
    and strongFair(SetMoveAnnotations, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          StartMoveMachine(m) }, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          AcknowledgeMove(m) }, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          CompleteMoveMachine(m) }, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          nondet o = Set(UpdateProgressing, UpdateDone, UpdateFailed).oneOf();
                          CallUpdateMachineHook(m, o) }, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          CompleteInPlaceUpdate(m) }, allVars)
    and strongFair(any { nondet m = MACHINES.oneOf();
                          CleanupOrphanedHook(m) }, allVars)

  // L-1 — eventually all Machines reach a settled phase.
  // Refines the upstream contract at
  // `machine_controller_inplace_update.go:43-227`: under
  // fair scheduling, no Machine stutters indefinitely
  // in MovingPending/InPlaceArmed/InPlaceUpdating.
  temporal L1_EventuallyAllMachinesSettled =
    ForwardProgressFair
    implies eventually(MACHINES.forall(m => isSettled(machinePhase.get(m))))

  // L-2 — eventually `updateMachineHookPending` is cleared for
  // every Machine that started the in-place flow. Refines the
  // post-condition of `completeInPlaceUpdate` at
  // `machine_controller_inplace_update.go:221`
  // (`hooks.MarkAsDone(UpdateMachine)`).
  temporal L2_EventuallyHookPendingCleared =
    ForwardProgressFair
    implies eventually(MACHINES.forall(m => not(updateMachineHookPending.get(m))))

  // L-3 — eventually every Machine's version is one of:
  // - oldMsVersion (if it stayed on oldMS — no admission)
  // - newMsVersion (if InPlaceDone fired)
  // - oldMsVersion (if InPlaceFailed — version doesn't flip in
  //   this spec under failure)
  // i.e. every Machine settles at a stable version.
  temporal L3_EventuallyVersionStable =
    ForwardProgressFair
    implies eventually(MACHINES.forall(m =>
      machineVersion.get(m) == oldMsVersion
      or machineVersion.get(m) == newMsVersion))

  // ===============================================================
  // Invariants
  // ===============================================================

  // I-1: Two-way handshake — newMS has Receive iff oldMS has
  // Move. Refines the discipline at
  // `machinedeployment_rollout_rollingupdate.go:455-477`: both
  // annotations are set together and removed together.
  val TwoWayHandshakeAnnotations =
    oldMsHasMoveAnnotation iff newMsHasReceiveAnnotation

  // I-2: PendingAcknowledgeMove → MovingPending. A Machine in
  // MovingPending means the move has happened but the MD
  // controller hasn't yet acknowledged. The model encodes the
  // upstream flow at `machineset_controller.go:381-392`: a
  // Machine's PendingAcknowledgeMove is only cleared when the
  // newMS acknowledges. Here: every machine in MovingPending is
  // owned by newMS (post-OwnerRef flip) AND has UpdateInProgress
  // on the Machine.
  val MovingPendingShape =
    MACHINES.forall(m =>
      machinePhase.get(m) == MovingPending
        implies (machineOnNewMs.get(m)
                 and machineInProgress.get(m)))

  // I-3: UpdateMachine hook only pending when in InPlaceArmed,
  // InPlaceUpdating, or InPlaceFailed. Refines
  // `machineset_controller.go:403` (set on completeMove) and
  // `machine_controller_inplace_update.go:221` (cleared on done).
  val UpdateMachineHookShape =
    MACHINES.forall(m =>
      updateMachineHookPending.get(m)
        implies any {
          machinePhase.get(m) == InPlaceArmed,
          machinePhase.get(m) == InPlaceUpdating,
          machinePhase.get(m) == InPlaceFailed,
        })

  // I-4: All-or-nothing UpdateInProgress trio. The Machine
  // controller's gate at
  // `machine_controller_inplace_update.go:97-99` requires Machine
  // AND Infra AND Bootstrap UpdateInProgress to be set before
  // calling the hook. The model enforces the symmetric clear on
  // CompleteInPlaceUpdate.
  val InProgressTrioConsistency =
    MACHINES.forall(m =>
      // While in InPlaceArmed/Updating: all three must be set OR
      // CleanupOrphanedHook is the next legitimate action.
      (machinePhase.get(m) == InPlaceArmed
       or machinePhase.get(m) == InPlaceUpdating)
        implies (machineInProgress.get(m)
                 and infraInProgress.get(m)
                 and bootstrapInProgress.get(m))
                or not(machineInProgress.get(m)))

  // I-5: Move-without-acknowledge race — Machine cannot be in
  // InPlaceArmed unless it was previously in AcknowledgedMove
  // (i.e. the AcknowledgedMove step ran). Refines the precondition
  // at `machineset_controller.go:381` for completeMoveMachine.
  // Captured as: InPlaceArmed implies acknowledgedMove.contains(m).
  val MoveAckBeforeArmed =
    MACHINES.forall(m =>
      (machinePhase.get(m) == InPlaceArmed
       or machinePhase.get(m) == InPlaceUpdating
       or machinePhase.get(m) == InPlaceDone)
        implies acknowledgedMove.contains(m))

  // I-6: Done implies version flipped. Refines the assignment at
  // `completeInPlaceUpdate` (effectively, the post-condition: the
  // Machine reflects the newMS template).
  val DoneImpliesVersionFlipped =
    MACHINES.forall(m =>
      machinePhase.get(m) == InPlaceDone
        implies machineVersion.get(m) == newMsVersion)

  val SafetyInvariants = all {
    TwoWayHandshakeAnnotations,
    MovingPendingShape,
    UpdateMachineHookShape,
    InProgressTrioConsistency,
    MoveAckBeforeArmed,
    DoneImpliesVersionFlipped,
  }

  // FM-42: Premature in-place admission — the rollout planner must
  // not set Move/Receive annotations until CanUpdateMachineSet
  // has returned CanUpdateYes. Refines the precondition at
  // `machinedeployment_rollout_rollingupdate.go:446-461`.
  val FM42_PrematureInPlaceAdmission =
    oldMsHasMoveAnnotation
      implies canUpdateInPlace(canUpdateVerdict)

  // FM-43: UpdateMachine idempotence — the hook may be called
  // multiple times (RetryAfter loop) without violating the
  // per-Machine pre-conditions. Refines the upstream comment at
  // `inplaceupdate_types.go:211-212` ("This hook should be
  // idempotent and can be called multiple times").
  // Surfaced as: while a Machine is in InPlaceUpdating, EITHER
  // the hook-gate is open (next retry can fire) OR the cleanup
  // branch is the next legitimate transition (machineInProgress
  // has been stripped — the upstream cleanup at
  // `machine_controller_inplace_update.go:54-66` will fire on the
  // next reconcile).
  val FM43_UpdateMachineIdempotenceGate =
    MACHINES.forall(m =>
      machinePhase.get(m) == InPlaceUpdating
        implies (hookGateOpen(
                   inPlaceFeatureEnabled,
                   machineInProgress.get(m),
                   updateMachineHookPending.get(m),
                   infraInProgress.get(m),
                   bootstrapInProgress.get(m))
                 or not(machineInProgress.get(m))))

  // FM-44: Multi-extension fast-failure — when more than one
  // UpdateMachine extension is registered, no Machine that is
  // currently mid-update (InPlaceArmed or InPlaceUpdating) can
  // make forward progress. Refines the error at
  // `machine_controller_inplace_update.go:155-156`. State-invariant
  // version restricted to in-flight phases only — Machines that
  // already completed under a single extension can stay Done
  // even if the operator later mis-registers a second extension.
  val FM44_MultiExtensionBlocksProgress =
    updateMachineExtensionCount > 1
      implies MACHINES.forall(m =>
        machinePhase.get(m) == InPlaceArmed
          implies (lastUpdateOutcome.get(m) == UpdateProgressing))

  val AllSafetyInvariants = all {
    SafetyInvariants,
    FM42_PrematureInPlaceAdmission,
    FM43_UpdateMachineIdempotenceGate,
    FM44_MultiExtensionBlocksProgress,
  }

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyInPlaceRun — full path for a single Machine: rollout
  // planner admits in-place, MS controller starts the move, MD
  // acknowledges, MS completes the move, Machine controller
  // calls UpdateMachine and completes.
  run happyInPlaceRun = init
    .then(EvaluateCanUpdateMachineSet(CanUpdateYes))
    .then(SetMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(1, UpdateDone))
    .then(CompleteInPlaceUpdate(1))

  // canUpdateNoFallbackRun — extension says "I can't" → no Move
  // annotations are set, the MD falls back to rolling (modelled
  // here as: the Machine stays on OnOldMS, no Move annotation
  // ever appears).
  run canUpdateNoFallbackRun = init
    .then(EvaluateCanUpdateMachineSet(CanUpdateNo))

  // multiExtensionRejectRun — operator registers two extensions;
  // the Machine controller rejects the call and flips to
  // InPlaceFailed.
  run multiExtensionRejectRun = init
    .then(EvaluateCanUpdateMachineSet(CanUpdateYes))
    .then(SetMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(OperatorRegisterMultipleUpdateMachineExtensions)
    .then(CallUpdateMachineHook(1, UpdateFailed))

  // updateMachineRetryLoopRun — extension reports Progressing
  // multiple times; the Machine controller keeps retrying. After
  // the third retry, returns Done.
  run updateMachineRetryLoopRun = init
    .then(EvaluateCanUpdateMachineSet(CanUpdateYes))
    .then(SetMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(1, UpdateDone))
    .then(CompleteInPlaceUpdate(1))

  // orphanedHookCleanupRun — operator strips UpdateInProgress
  // mid-flight; Machine controller cleans up the orphaned hook.
  run orphanedHookCleanupRun = init
    .then(EvaluateCanUpdateMachineSet(CanUpdateYes))
    .then(SetMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(OperatorRemoveUpdateInProgress(1))
    .then(CleanupOrphanedHook(1))

}
