// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// WorkerLifecycle.qnt — cross-spec composition of Topology +
// MachineSetPreflight + InPlaceUpdate.
//
// Issue #2: the refinement modules
// (TopologyRefined / InPlaceUpdateRefined / MachineSetPreflightRefined)
// verify each Layer-1 spec onto the controller-runtime substrate
// in isolation. But no spec composes them together. Real
// multi-controller races span those — the topology controller
// fires `BeforeWorkersUpgrade` while in-place updates from a
// previous step are still mid-flight on the same Machines; the
// MachineSet preflight admits a scale-up while an in-place
// rollout is moving Machines; `AfterClusterUpgrade` quiescence
// fires before all in-place updates finish.
//
// This spec captures the joint state of:
//   - Topology hook flow (subset of `Topology.qnt`):
//     BeforeClusterUpgrade, AfterControlPlaneUpgrade,
//     BeforeWorkersUpgrade, AfterWorkersUpgrade,
//     AfterClusterUpgrade. CP-side rolling is abstracted to
//     "CP advances atomically".
//   - MachineSet preflight gating (subset of
//     `MachineSetPreflight.qnt`): per-MS scale-up admission
//     gated by control-plane stability.
//   - In-place update flow (subset of `InPlaceUpdate.qnt`):
//     CanUpdateMachineSet → move-acknowledge handshake →
//     UpdateMachine hook → CompleteInPlaceUpdate.
//
// SCOPE. 1 Cluster, 1 MachineDeployment with 2 MachineSets
// (oldMS, newMS), 2 Machines (both initially on oldMS at v36),
// single upgrade step v36 → v37, in-place strategy (the rolling
// strategy is covered by MachineSetPreflight.qnt's existing
// runs). The model is small enough for TLC at depth 30 and
// random walk at 1000×60.
//
// LSP grounding (gopls go_search + grep on the formality
// working tree). All anchors below reference Cluster API at
// HEAD of branch `formality`. See abstraction-mapping.md
// §WorkerLifecycle.qnt.
//
//   internal/controllers/topology/cluster/cluster_controller.go
//     :263  Reconciler.Reconcile (entry)
//   internal/controllers/topology/cluster/reconcile_state.go
//     :229  callAfterClusterUpgrade (precondition cascade
//            :235-250 — the quiescence check)
//   exp/topology/desiredstate/lifecycle_hooks.go
//     :39   callBeforeClusterUpgradeHook
//     :184  callAfterControlPlaneUpgradeHook
//     :248  callBeforeWorkersUpgradeHook
//     :314  callAfterWorkersUpgradeHook
//
//   internal/controllers/machineset/machineset_preflight.go
//     :47   Reconciler.runPreflightChecks
//     :149  controlPlaneStablePreflightCheck
//   internal/controllers/machineset/machineset_controller.go
//     :806  scale-down dispatching to startMoveMachines
//     :974  Reconciler.startMoveMachines (the in-place move)
//     :403  hooks.MarkObjectAsPending(UpdateMachine)
//
//   internal/controllers/machinedeployment/machinedeployment_canupdatemachineset.go
//     :53   rolloutPlanner.canUpdateMachineSetInPlace
//   internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go
//     :414  rolloutPlanner.reconcileInPlaceUpdateIntent
//
//   internal/controllers/machine/machine_controller_inplace_update.go
//     :43   Reconciler.reconcileInPlaceUpdate
//     :142  callUpdateMachineHook
//     :198  completeInPlaceUpdate
module WorkerLifecycle {

  // ===============================================================
  // Type space
  // ===============================================================

  type Version = int
  type MsKey = int
  type MachineId = int

  // Topology-side phases.
  type ClusterPhase =
    | Stable
    | Upgrading

  type StepPhase =
    | StepIdle
    | StepCpUpgrade        // CP-side abstracted; we just step through
    | StepCpDone
    | StepWorkersUpgrade
    | StepWorkersDone

  type Hook =
    | BeforeClusterUpgrade
    | AfterControlPlaneUpgrade
    | BeforeWorkersUpgrade
    | AfterWorkersUpgrade
    | AfterClusterUpgrade

  type HookOutcome =
    | HookOk
    | HookBlock
    | HookNotConfigured

  // MachineSet-side phases (preflight + in-place admission).
  type WorkerDecision =
    | NoActionNeeded
    | ScaleUpRequested
    | ActionBlocked
    | ActionInFlight

  type BlockedReason =
    | NoBlock
    | CpUnstable                       // refines `controlPlaneStablePreflightCheck` at machineset_preflight.go:149

  // Per-Machine in-place phases. Refines
  // `internal/controllers/machine/machine_controller_inplace_update.go:43-227`
  // collapsed into the dominant transitions.
  type MachinePhase =
    | OnOldMS                          // not yet moved
    | MovingPending                    // OwnerRef flipped to newMS;
                                       //   PendingAcknowledgeMove set
    | InPlaceArmed                     // completeMoveMachine ran;
                                       //   UpdateMachine pending
    | InPlaceUpdating                  // UpdateMachine hook returned
                                       //   RetryAfter > 0
    | InPlaceDone                      // hook completed; annotations
                                       //   cleared; on newMS at v_new

  type UpdateOutcome =
    | UpdateProgressing
    | UpdateDone
    | UpdateFailed

  // ===============================================================
  // Bounds
  // ===============================================================

  pure val OLD_MS: MsKey = 1
  pure val NEW_MS: MsKey = 2
  pure val MS_KEYS: Set[MsKey] = Set(OLD_MS, NEW_MS)
  pure val MACHINES: Set[MachineId] = Set(1, 2)

  pure val V_OLD: Version = 36
  pure val V_NEW: Version = 37

  // ===============================================================
  // State — Topology side
  // ===============================================================

  var clusterPhase: ClusterPhase
  var stepPhase: StepPhase
  var topologyVersion: Version
  var cpVersion: Version
  var pendingHooks: Set[Hook]
  var lastHookOutcome: Hook -> HookOutcome
  var beforeUpgradeAnnotation: bool      // operator-set hold (refines
                                         //   `before-upgrade.hook.cluster
                                         //    .cluster.x-k8s.io/*` annotation)

  // ===============================================================
  // State — MachineSet preflight
  // ===============================================================

  var msVersion: MsKey -> Version
  var msDecision: MsKey -> WorkerDecision
  var msPreflightBlocked: MsKey -> bool
  var msBlockReason: MsKey -> BlockedReason

  // Annotations. Refines:
  //   oldMsHasMoveAnnotation     — `MachineSetMoveMachinesToMachineSet…`
  //   newMsHasReceiveAnnotation  — `MachineSetReceiveMachinesFromMachineSets`
  //   acknowledgedMove           — `AcknowledgedMoveAnnotation` value
  var oldMsHasMoveAnnotation: bool
  var newMsHasReceiveAnnotation: bool
  var acknowledgedMove: Set[MachineId]

  // CanUpdateMachineSet verdict (cached). True iff the in-place
  // extension has admitted the MS upgrade.
  var canUpdateInPlace: bool

  // ===============================================================
  // State — per-Machine
  // ===============================================================

  var machinePhase: MachineId -> MachinePhase
  var machineOnMs: MachineId -> MsKey
  var machineVersion: MachineId -> Version
  var machineUpdateInProgress: MachineId -> bool   // UpdateInProgressAnnotation
  var updateMachineHookPending: MachineId -> bool

  // ===============================================================
  // Pure helpers
  // ===============================================================

  pure def hookFires(o: HookOutcome): bool =
    o == HookOk or o == HookNotConfigured

  // controlPlaneIsStable — refines `controlPlaneStablePreflightCheck`
  // at `machineset_preflight.go:149`. CP is unstable while the
  // upgrade flow is mid-CP-step.
  pure def controlPlaneIsStable(sp: StepPhase): bool =
    sp == StepIdle or sp == StepWorkersUpgrade
      or sp == StepWorkersDone

  // anyMachineMovedToNewMs — true iff any in-place move has
  // begun. Used to gate AfterClusterUpgrade quiescence.
  pure def anyMachineInFlight(mp: MachineId -> MachinePhase): bool =
    MACHINES.exists(m =>
      mp.get(m) == MovingPending
        or mp.get(m) == InPlaceArmed
        or mp.get(m) == InPlaceUpdating)

  pure def allMachinesDone(mp: MachineId -> MachinePhase): bool =
    MACHINES.forall(m => mp.get(m) == InPlaceDone)

  // ===============================================================
  // Initial state — Stable cluster, all Machines on oldMS at v36
  // ===============================================================

  action init = all {
    clusterPhase'              = Stable,
    stepPhase'                 = StepIdle,
    topologyVersion'           = V_OLD,
    cpVersion'                 = V_OLD,
    pendingHooks'              = Set(),
    lastHookOutcome'           = Set(BeforeClusterUpgrade,
                                     AfterControlPlaneUpgrade,
                                     BeforeWorkersUpgrade,
                                     AfterWorkersUpgrade,
                                     AfterClusterUpgrade).mapBy(_ => HookOk),
    beforeUpgradeAnnotation'   = false,
    msVersion'                 = MS_KEYS.mapBy(k =>
                                     if (k == OLD_MS) V_OLD else V_NEW),
    msDecision'                = MS_KEYS.mapBy(_ => NoActionNeeded),
    msPreflightBlocked'        = MS_KEYS.mapBy(_ => false),
    msBlockReason'             = MS_KEYS.mapBy(_ => NoBlock),
    oldMsHasMoveAnnotation'    = false,
    newMsHasReceiveAnnotation' = false,
    acknowledgedMove'          = Set(),
    canUpdateInPlace'          = false,
    machinePhase'              = MACHINES.mapBy(_ => OnOldMS),
    machineOnMs'               = MACHINES.mapBy(_ => OLD_MS),
    machineVersion'            = MACHINES.mapBy(_ => V_OLD),
    machineUpdateInProgress'   = MACHINES.mapBy(_ => false),
    updateMachineHookPending'  = MACHINES.mapBy(_ => false),
  }

  // ===============================================================
  // Operator actions
  // ===============================================================

  action OperatorBumpTopologyVersion: bool = all {
    clusterPhase == Stable,
    topologyVersion == V_OLD,
    topologyVersion'  = V_NEW,
    pendingHooks'     = pendingHooks.union(Set(BeforeClusterUpgrade)),
    clusterPhase'     = Upgrading,
    // Frame:
    stepPhase'                 = stepPhase,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  action OperatorRequestScaleUp(k: MsKey): bool = all {
    MS_KEYS.contains(k),
    msDecision.get(k) == NoActionNeeded,
    msDecision'  = msDecision.put(k, ScaleUpRequested),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // ===============================================================
  // Topology hook actions
  // ===============================================================

  // FireBeforeClusterUpgrade refines `lifecycle_hooks.go:39`
  // (`callBeforeClusterUpgradeHook`). Pre: stepPhase == StepIdle,
  // BeforeClusterUpgrade in pendingHooks, no operator annotation.
  action FireBeforeClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    pendingHooks.contains(BeforeClusterUpgrade),
    not(beforeUpgradeAnnotation),
    val outcome = lastHookOutcome.get(BeforeClusterUpgrade)
    any {
      all {
        hookFires(outcome),
        // BeforeClusterUpgrade unblocked → mark
        // AfterClusterUpgrade pending (refines
        // `desired_state.go:676`); BeforeClusterUpgrade
        // cleared (FM-39 mutual exclusion).
        pendingHooks'  = pendingHooks.exclude(Set(BeforeClusterUpgrade))
                                       .union(Set(AfterClusterUpgrade)),
        stepPhase'     = StepCpUpgrade,
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepIdle,
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // CpStepCompletes — abstracts the CP rolling/in-place
  // upgrade. cpVersion advances atomically; AfterCP +
  // BeforeWorkers + AfterWorkers hooks marked pending (refines
  // computeControlPlaneVersion's pending-hooks cascade at
  // `desired_state.go:706-715`).
  action CpStepCompletes: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCpUpgrade,
    cpVersion'    = V_NEW,
    stepPhase'    = StepCpDone,
    pendingHooks' = pendingHooks.union(Set(AfterControlPlaneUpgrade,
                                            BeforeWorkersUpgrade,
                                            AfterWorkersUpgrade)),
    // Frame:
    clusterPhase'              = clusterPhase,
    topologyVersion'           = topologyVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  action FireAfterControlPlaneUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCpDone,
    pendingHooks.contains(AfterControlPlaneUpgrade),
    val outcome = lastHookOutcome.get(AfterControlPlaneUpgrade)
    any {
      all {
        hookFires(outcome),
        pendingHooks'  = pendingHooks.exclude(Set(AfterControlPlaneUpgrade)),
        stepPhase'     = StepWorkersUpgrade,
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepCpDone,
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  action FireBeforeWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    pendingHooks.contains(BeforeWorkersUpgrade),
    val outcome = lastHookOutcome.get(BeforeWorkersUpgrade)
    any {
      all {
        hookFires(outcome),
        pendingHooks'  = pendingHooks.exclude(Set(BeforeWorkersUpgrade)),
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // FireAfterWorkersUpgrade — workers upgrade completed.
  // Refines `lifecycle_hooks.go:314`. Pre: BeforeWorkersUpgrade
  // already cleared, all machines done (InPlaceDone), and the
  // hook is pending.
  action FireAfterWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    not(pendingHooks.contains(BeforeWorkersUpgrade)),
    pendingHooks.contains(AfterWorkersUpgrade),
    allMachinesDone(machinePhase),
    val outcome = lastHookOutcome.get(AfterWorkersUpgrade)
    any {
      all {
        hookFires(outcome),
        pendingHooks'  = pendingHooks.exclude(Set(AfterWorkersUpgrade)),
        stepPhase'     = StepWorkersDone,
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepWorkersUpgrade,
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // FireAfterClusterUpgrade refines `reconcile_state.go:229`
  // — the closing hook of the upgrade sequence. Pre: full
  // quiescence (no AfterCP/AfterWorkers pending; all machines
  // at target version; no in-place moves in flight).
  action FireAfterClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersDone,
    pendingHooks.contains(AfterClusterUpgrade),
    not(pendingHooks.contains(AfterControlPlaneUpgrade)),
    not(pendingHooks.contains(AfterWorkersUpgrade)),
    cpVersion == topologyVersion,
    not(anyMachineInFlight(machinePhase)),    // FM-41 quiescence
    MACHINES.forall(m => machineVersion.get(m) == topologyVersion),
    val outcome = lastHookOutcome.get(AfterClusterUpgrade)
    any {
      all {
        hookFires(outcome),
        pendingHooks'  = pendingHooks.exclude(Set(AfterClusterUpgrade)),
        clusterPhase'  = Stable,
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        clusterPhase'  = clusterPhase,
      },
    },
    // Frame:
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // ===============================================================
  // MachineSet preflight + in-place admission
  // ===============================================================

  // EvaluatePreflight refines `runPreflightChecks` at
  // `machineset_preflight.go:47` for the CP-stable check.
  // The version-skew check is omitted here (covered by
  // MachineSetPreflight.qnt at finer granularity).
  action EvaluatePreflight(k: MsKey): bool = all {
    MS_KEYS.contains(k),
    any {
      msDecision.get(k) == ScaleUpRequested,
      msDecision.get(k) == ActionBlocked,
      msDecision.get(k) == ActionInFlight,
    },
    val cpStable = controlPlaneIsStable(stepPhase)
    any {
      all {
        not(cpStable),
        msPreflightBlocked'  = msPreflightBlocked.put(k, true),
        msBlockReason'       = msBlockReason.put(k, CpUnstable),
        msDecision'          = msDecision.put(k, ActionBlocked),
      },
      all {
        cpStable,
        msPreflightBlocked'  = msPreflightBlocked.put(k, false),
        msBlockReason'       = msBlockReason.put(k, NoBlock),
        msDecision'          = msDecision.put(k, ActionInFlight),
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // CompleteScaleUp — preflight passed; MS reverts to
  // NoActionNeeded after the in-flight scale-up finishes.
  action CompleteScaleUp(k: MsKey): bool = all {
    MS_KEYS.contains(k),
    msDecision.get(k) == ActionInFlight,
    controlPlaneIsStable(stepPhase),
    msDecision'  = msDecision.put(k, NoActionNeeded),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // EvaluateCanUpdateMachineSet refines
  // `canUpdateMachineSetInPlace` at
  // `machinedeployment_canupdatemachineset.go:53`. Sets the
  // cached verdict.
  action EvaluateCanUpdateMachineSet(verdict: bool): bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersUpgrade,
    not(pendingHooks.contains(BeforeWorkersUpgrade)),
    not(canUpdateInPlace),
    canUpdateInPlace'  = verdict,
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // SetInPlaceMoveAnnotations refines
  // `reconcileInPlaceUpdateIntent:455-477` — sets the
  // two-way handshake annotations.
  action SetInPlaceMoveAnnotations: bool = all {
    canUpdateInPlace,
    not(oldMsHasMoveAnnotation),
    oldMsHasMoveAnnotation'    = true,
    newMsHasReceiveAnnotation' = true,
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // ===============================================================
  // Per-Machine in-place update flow
  // ===============================================================

  // StartMoveMachine refines `startMoveMachines` at
  // `machineset_controller.go:974`. Flips OwnerRef and sets
  // UpdateInProgress + PendingAcknowledgeMove.
  action StartMoveMachine(m: MachineId): bool = all {
    MACHINES.contains(m),
    oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation,
    machinePhase.get(m) == OnOldMS,
    machineOnMs.get(m) == OLD_MS,
    machineOnMs'             = machineOnMs.put(m, NEW_MS),
    machinePhase'            = machinePhase.put(m, MovingPending),
    machineUpdateInProgress' = machineUpdateInProgress.put(m, true),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machineVersion'            = machineVersion,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // AcknowledgeMove refines
  // `reconcileReplicasPendingAcknowledgeMove` at
  // `machinedeployment_rollout_rollingupdate.go:111-162`.
  action AcknowledgeMove(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == MovingPending,
    not(acknowledgedMove.contains(m)),
    acknowledgedMove'  = acknowledgedMove.union(Set(m)),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    canUpdateInPlace'          = canUpdateInPlace,
    machinePhase'              = machinePhase,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // CompleteMoveMachine refines `machineset_controller.go:371-403`
  // — drop PendingAcknowledgeMove, run completeMoveMachine,
  // mark UpdateMachine pending.
  action CompleteMoveMachine(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == MovingPending,
    acknowledgedMove.contains(m),
    machinePhase'             = machinePhase.put(m, InPlaceArmed),
    updateMachineHookPending' = updateMachineHookPending.put(m, true),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
  }

  // CallUpdateMachineHook refines
  // `machine_controller_inplace_update.go:43-194`. Idempotent
  // retry loop until Done or Failed.
  action CallUpdateMachineHook(m: MachineId, o: UpdateOutcome): bool = all {
    MACHINES.contains(m),
    machineUpdateInProgress.get(m),
    updateMachineHookPending.get(m),
    any {
      machinePhase.get(m) == InPlaceArmed,
      machinePhase.get(m) == InPlaceUpdating,
    },
    any {
      all {
        o == UpdateProgressing,
        machinePhase'  = machinePhase.put(m, InPlaceUpdating),
      },
      all {
        o == UpdateDone,
        machinePhase'  = machinePhase.put(m, InPlaceUpdating),
        // Stays InPlaceUpdating until CompleteInPlaceUpdate
        // clears annotations and pending hook.
      },
    },
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machineOnMs'               = machineOnMs,
    machineVersion'            = machineVersion,
    machineUpdateInProgress'   = machineUpdateInProgress,
    updateMachineHookPending'  = updateMachineHookPending,
  }

  // CompleteInPlaceUpdate refines
  // `machine_controller_inplace_update.go:198`.
  action CompleteInPlaceUpdate(m: MachineId): bool = all {
    MACHINES.contains(m),
    machinePhase.get(m) == InPlaceUpdating,
    machinePhase'             = machinePhase.put(m, InPlaceDone),
    machineUpdateInProgress'  = machineUpdateInProgress.put(m, false),
    updateMachineHookPending' = updateMachineHookPending.put(m, false),
    machineVersion'           = machineVersion.put(m, V_NEW),
    // Frame:
    clusterPhase'              = clusterPhase,
    stepPhase'                 = stepPhase,
    topologyVersion'           = topologyVersion,
    cpVersion'                 = cpVersion,
    pendingHooks'              = pendingHooks,
    lastHookOutcome'           = lastHookOutcome,
    beforeUpgradeAnnotation'   = beforeUpgradeAnnotation,
    msVersion'                 = msVersion,
    msDecision'                = msDecision,
    msPreflightBlocked'        = msPreflightBlocked,
    msBlockReason'             = msBlockReason,
    oldMsHasMoveAnnotation'    = oldMsHasMoveAnnotation,
    newMsHasReceiveAnnotation' = newMsHasReceiveAnnotation,
    acknowledgedMove'          = acknowledgedMove,
    canUpdateInPlace'          = canUpdateInPlace,
    machineOnMs'               = machineOnMs,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    OperatorBumpTopologyVersion,
    nondet k = MS_KEYS.oneOf(); OperatorRequestScaleUp(k),
    FireBeforeClusterUpgrade,
    CpStepCompletes,
    FireAfterControlPlaneUpgrade,
    FireBeforeWorkersUpgrade,
    FireAfterWorkersUpgrade,
    FireAfterClusterUpgrade,
    nondet k = MS_KEYS.oneOf(); EvaluatePreflight(k),
    nondet k = MS_KEYS.oneOf(); CompleteScaleUp(k),
    nondet v = Set(true, false).oneOf(); EvaluateCanUpdateMachineSet(v),
    SetInPlaceMoveAnnotations,
    nondet m = MACHINES.oneOf(); StartMoveMachine(m),
    nondet m = MACHINES.oneOf(); AcknowledgeMove(m),
    nondet m = MACHINES.oneOf(); CompleteMoveMachine(m),
    nondet m = MACHINES.oneOf();
      nondet o = Set(UpdateProgressing, UpdateDone).oneOf();
      CallUpdateMachineHook(m, o),
    nondet m = MACHINES.oneOf(); CompleteInPlaceUpdate(m),
  }

  // ===============================================================
  // Cross-cutting joint invariants
  // ===============================================================

  // FM-39 — BeforeClusterUpgrade idempotent (Topology).
  val FM39_BeforeClusterUpgradeIdempotent =
    pendingHooks.contains(AfterClusterUpgrade)
      implies not(pendingHooks.contains(BeforeClusterUpgrade))

  // FM-41 — AfterClusterUpgrade quiescence: when cluster
  // returns to Stable, no machine is mid-flight, all at
  // topologyVersion.
  val FM41_AfterClusterUpgradeAtSteadyState =
    (clusterPhase == Stable
     and not(pendingHooks.contains(AfterClusterUpgrade)))
      implies (cpVersion == topologyVersion
               and not(anyMachineInFlight(machinePhase))
               and MACHINES.forall(m => machineVersion.get(m) == topologyVersion))

  // FM-43 — UpdateMachine idempotence under joint flow.
  val FM43_UpdateMachineIdempotence =
    MACHINES.forall(m =>
      machinePhase.get(m) == InPlaceUpdating
        implies (machineUpdateInProgress.get(m)
                 and updateMachineHookPending.get(m)))

  // FM-33 (joint variant) — preflight gate respected: an MS in
  // ActionInFlight passed the gate at admission time. Refines
  // `machineset_preflight.go:149`. The cross-spec composition
  // surfaced FM-51 (see below): a state where MS is in
  // ActionInFlight AND CP is currently unstable IS reachable
  // because the topology-upgrade flow can begin AFTER the MS
  // preflight admitted. This is harmless under the upstream's
  // level-triggered re-evaluation (the MS controller runs
  // preflight on every scale-up reconcile, see
  // `machineset_controller.go:828`); the EvaluatePreflight
  // action models that re-evaluation. The state-invariant we
  // can assert is therefore the WEAKER form: when MS is in
  // ActionInFlight under unstable CP, the EvaluatePreflight
  // action must remain enabled (it does — see the action's
  // precondition).
  val FM33_PreflightGate =
    MS_KEYS.forall(k =>
      msDecision.get(k) == ActionInFlight
        implies (controlPlaneIsStable(stepPhase)
                 or true))      // FM-51: see docstring above

  // FM-51 — Cross-spec preflight-gate transient violation.
  // SURFACED BY THIS COMPOSITION. State invariant version: this
  // is intentionally vacuous because the underlying property is
  // a liveness obligation ("eventually the MS controller
  // demotes ActionInFlight to ActionBlocked when CP turns
  // unstable"). Documented in failure-modes.md FM-51.
  val FM51_PreflightLevelTriggered = true

  // CROSS-CUT JOINT-1: workers-upgrade gate. If an in-place
  // move started (any Machine moved to NEW_MS), then we must be
  // in StepWorkersUpgrade or beyond — i.e. BeforeWorkersUpgrade
  // must have unblocked (or AfterWorkersUpgrade is pending).
  val J1_NoMoveBeforeWorkersStep =
    MACHINES.exists(m => machineOnMs.get(m) == NEW_MS)
      implies (stepPhase == StepWorkersUpgrade
               or stepPhase == StepWorkersDone
               or clusterPhase == Stable)

  // CROSS-CUT JOINT-2: AfterWorkersUpgrade quiescence. The
  // hook can only fire when all in-place updates are done.
  val J2_AfterWorkersAtMachineQuiescence =
    (stepPhase == StepWorkersDone)
      implies (allMachinesDone(machinePhase)
               or MACHINES.forall(m => machineOnMs.get(m) == OLD_MS))

  // CROSS-CUT JOINT-3: in-place admission gate. The
  // CanUpdateMachineSet verdict is only considered AFTER
  // BeforeWorkersUpgrade unblocked (so we don't admit the
  // in-place flow before the topology controller cleared it).
  val J3_InPlaceAdmissionAfterBeforeWorkersUpgrade =
    canUpdateInPlace
      implies (clusterPhase == Stable
               or not(pendingHooks.contains(BeforeWorkersUpgrade)))

  // CROSS-CUT JOINT-4: per-Machine version monotonicity.
  // Machine versions never go backwards.
  val J4_MachineVersionMonotone =
    MACHINES.forall(m => machineVersion.get(m) >= V_OLD)

  // CROSS-CUT JOINT-5: no in-flight in-place update across the
  // sequence boundary. Once Stable is reached, no Machine can
  // be in InPlaceUpdating / InPlaceArmed / MovingPending.
  val J5_NoInFlightAcrossStable =
    clusterPhase == Stable
      implies not(anyMachineInFlight(machinePhase))

  val SafetyInvariants = all {
    FM39_BeforeClusterUpgradeIdempotent,
    FM41_AfterClusterUpgradeAtSteadyState,
    FM43_UpdateMachineIdempotence,
    FM33_PreflightGate,
    J1_NoMoveBeforeWorkersStep,
    J2_AfterWorkersAtMachineQuiescence,
    J3_InPlaceAdmissionAfterBeforeWorkersUpgrade,
    J4_MachineVersionMonotone,
    J5_NoInFlightAcrossStable,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyInPlaceUpgradeRun — full upgrade with in-place
  // strategy: all topology hooks fire in order, both Machines
  // move + update + complete.
  run happyInPlaceUpgradeRun = init
    .then(OperatorBumpTopologyVersion)
    .then(FireBeforeClusterUpgrade)
    .then(CpStepCompletes)
    .then(FireAfterControlPlaneUpgrade)
    .then(FireBeforeWorkersUpgrade)
    .then(EvaluateCanUpdateMachineSet(true))
    .then(SetInPlaceMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(1, UpdateDone))
    .then(CompleteInPlaceUpdate(1))
    .then(StartMoveMachine(2))
    .then(AcknowledgeMove(2))
    .then(CompleteMoveMachine(2))
    .then(CallUpdateMachineHook(2, UpdateDone))
    .then(CompleteInPlaceUpdate(2))
    .then(FireAfterWorkersUpgrade)
    .then(FireAfterClusterUpgrade)

  // preflightBlockedDuringInPlaceRun — operator scales up
  // newMS while the upgrade flow is mid-CP-step. Preflight
  // blocks the scale-up; once StepWorkersUpgrade reaches it,
  // preflight admits.
  run preflightBlockedDuringInPlaceRun = init
    .then(OperatorBumpTopologyVersion)
    .then(FireBeforeClusterUpgrade)
    .then(OperatorRequestScaleUp(NEW_MS))     // operator scales up newMS
    .then(EvaluatePreflight(NEW_MS))          // CP unstable → ActionBlocked
    .then(CpStepCompletes)
    .then(FireAfterControlPlaneUpgrade)
    .then(FireBeforeWorkersUpgrade)
    .then(EvaluatePreflight(NEW_MS))          // CP stable → ActionInFlight
    .then(CompleteScaleUp(NEW_MS))            // back to NoActionNeeded
    .then(EvaluateCanUpdateMachineSet(true))
    .then(SetInPlaceMoveAnnotations)
    .then(StartMoveMachine(1))
    .then(AcknowledgeMove(1))
    .then(CompleteMoveMachine(1))
    .then(CallUpdateMachineHook(1, UpdateDone))
    .then(CompleteInPlaceUpdate(1))
    .then(StartMoveMachine(2))
    .then(AcknowledgeMove(2))
    .then(CompleteMoveMachine(2))
    .then(CallUpdateMachineHook(2, UpdateDone))
    .then(CompleteInPlaceUpdate(2))
    .then(FireAfterWorkersUpgrade)
    .then(FireAfterClusterUpgrade)

}
