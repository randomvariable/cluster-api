// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// InPlaceUpdateRefined.qnt — Refinement of (a slice of)
// InPlaceUpdate.qnt onto the ControllerRuntime substrate.
//
// REFINEMENT CLAIM. The Machine controller's `reconcileInPlaceUpdate`
// at `internal/controllers/machine/machine_controller_inplace_update.go:43`
// is one BODY of the substrate's worker-pool dispatch. When
// multiple Machines are queued, multiple workers can call
// reconcileInPlaceUpdate concurrently — but the per-key
// serialisation guarantee (FM-45) ensures the same Machine is
// never reconciled by two workers at once. This is what makes
// the in-place update idempotence (FM-43) hold under
// concurrency: the hook is called repeatedly across reconciles,
// but never overlapping for the same Machine.
//
// REFINEMENT MAPPING (informal). Given a refined-state s, the
// abstract InPlaceUpdate state π(s) is obtained by forgetting
// the substrate fields. The Machine state machine
// (OnOldMS → MovingPending → MovingAcknowledged → InPlaceArmed
// → InPlaceUpdating → InPlaceDone) advances only inside a
// reconcile dispatch; OperatorRegisterMultipleUpdateMachineExtensions
// fires outside.
//
// LSP grounding (gopls go_search + grep on
// /home/naadir/go/src/sigs.k8s.io/controller-runtime AND CAPI):
//
//   pkg/internal/controller/controller.go
//     :194  Reconcile (entry); the Machine controller's
//            Reconcile fires reconcileInPlaceUpdate
//     :311  per-key serialisation comment
//   pkg/controller/priorityqueue/priorityqueue.go
//     :391  locked-set guard
//
//   internal/controllers/machine/machine_controller_inplace_update.go
//     :43   reconcileInPlaceUpdate (BODY of substrate dispatch)
//     :142  callUpdateMachineHook
//     :198  completeInPlaceUpdate
//
// SCOPE. Two Machines (MACHINES = 1.to(2)) for tractability;
// multi-worker (WORKERS = 1.to(2)) preserved.
module InPlaceUpdateRefined {

  // ===============================================================
  // Substrate state
  // ===============================================================

  type Key = int
  type Worker = int
  type QueuePos = NotInQueue | InReady | InWaiting | InFlight

  pure val MACHINES: Set[Key] = 1.to(2)        // one key per Machine
  pure val WORKERS: Set[Worker] = 1.to(2)
  pure val IDLE_KEY: Key = 0

  var managerStarted: bool
  var leaderRunnablesStarted: bool
  var queuePos: Key -> QueuePos
  var workerOnKey: Worker -> Key
  var requeueWhileInFlight: Key -> bool

  // ===============================================================
  // InPlaceUpdate abstract state
  // ===============================================================

  type MachinePhase =
    | OnOldMS | MovingPending | MovingAcknowledged
    | InPlaceArmed | InPlaceUpdating | InPlaceDone | InPlaceFailed
  type UpdateOutcome = UpdateProgressing | UpdateDone | UpdateFailed

  var newMsVersion: int
  var machineVersion: Key -> int
  var machinePhase: Key -> MachinePhase
  var machineInProgress: Key -> bool
  var infraInProgress: Key -> bool
  var bootstrapInProgress: Key -> bool
  var updateMachineHookPending: Key -> bool
  var lastUpdateOutcome: Key -> UpdateOutcome
  var updateMachineExtensionCount: int
  var inPlaceFeatureEnabled: bool

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def anyWorkerOnKey(k: Key, a: Worker -> Key): bool =
    WORKERS.exists(w => a.get(w) == k)

  pure def reconcileInFlightOn(k: Key, a: Worker -> Key, qp: Key -> QueuePos): bool =
    qp.get(k) == InFlight and anyWorkerOnKey(k, a)

  pure def hookGateOpen(
      ftOn: bool, mIP: bool, hookP: bool, iIP: bool, bIP: bool): bool =
    ftOn and mIP and hookP and iIP and bIP

  // ===============================================================
  // Initial state — both machines are armed for in-place update
  // ===============================================================

  action init = all {
    managerStarted'           = false,
    leaderRunnablesStarted'   = false,
    queuePos'                 = MACHINES.mapBy(_ => NotInQueue),
    workerOnKey'              = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'     = MACHINES.mapBy(_ => false),
    newMsVersion'             = 37,
    machineVersion'           = MACHINES.mapBy(_ => 36),
    machinePhase'             = MACHINES.mapBy(_ => InPlaceArmed),
    machineInProgress'        = MACHINES.mapBy(_ => true),
    infraInProgress'          = MACHINES.mapBy(_ => true),
    bootstrapInProgress'      = MACHINES.mapBy(_ => true),
    updateMachineHookPending' = MACHINES.mapBy(_ => true),
    lastUpdateOutcome'        = MACHINES.mapBy(_ => UpdateProgressing),
    updateMachineExtensionCount' = 1,
    inPlaceFeatureEnabled'    = true,
  }

  // ===============================================================
  // Substrate-only actions
  // ===============================================================

  action ManagerStartAndLeader: bool = all {
    not(managerStarted),
    managerStarted'           = true,
    leaderRunnablesStarted'   = true,
    // Both Machines enqueued by initial informer sync.
    queuePos'                 = MACHINES.mapBy(_ => InReady),
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machinePhase'             = machinePhase,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    lastUpdateOutcome'        = lastUpdateOutcome,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  action ProcessNextWorkItem(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    MACHINES.contains(k),
    leaderRunnablesStarted,
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(k) == InReady,
    not(anyWorkerOnKey(k, workerOnKey)),         // FM-45
    workerOnKey'  = workerOnKey.put(w, k),
    queuePos'     = queuePos.put(k, InFlight),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machinePhase'             = machinePhase,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    lastUpdateOutcome'        = lastUpdateOutcome,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  action ReconcileFinishRequeueAfter(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    MACHINES.contains(k),
    workerOnKey.get(w) == k,
    workerOnKey'  = workerOnKey.put(w, IDLE_KEY),
    queuePos'     = queuePos.put(k,
                       if (requeueWhileInFlight.get(k)) InReady
                       else InWaiting),
    requeueWhileInFlight'  = requeueWhileInFlight.put(k, false),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machinePhase'             = machinePhase,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    lastUpdateOutcome'        = lastUpdateOutcome,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  action TimerExpires(k: Key): bool = all {
    MACHINES.contains(k),
    queuePos.get(k) == InWaiting,
    queuePos'  = queuePos.put(k, InReady),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machinePhase'             = machinePhase,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    lastUpdateOutcome'        = lastUpdateOutcome,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // InPlaceUpdate body actions — guarded by reconcileInFlightOn
  // ===============================================================

  // CallUpdateMachineHook fires only inside the reconcile
  // dispatch for THAT Machine. Refines `reconcileInPlaceUpdate`
  // at `machine_controller_inplace_update.go:43`.
  action CallUpdateMachineHook(k: Key, outcome: UpdateOutcome): bool = all {
    MACHINES.contains(k),
    reconcileInFlightOn(k, workerOnKey, queuePos),
    hookGateOpen(
      inPlaceFeatureEnabled,
      machineInProgress.get(k),
      updateMachineHookPending.get(k),
      infraInProgress.get(k),
      bootstrapInProgress.get(k)),
    any {
      machinePhase.get(k) == InPlaceArmed,
      machinePhase.get(k) == InPlaceUpdating,
    },
    any {
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateProgressing,
        machinePhase' = machinePhase.put(k, InPlaceUpdating),
      },
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateDone,
        machinePhase' = machinePhase.put(k, InPlaceUpdating),
      },
      all {
        updateMachineExtensionCount == 1,
        outcome == UpdateFailed,
        machinePhase' = machinePhase.put(k, InPlaceFailed),
      },
      all {
        any {
          updateMachineExtensionCount == 0,
          updateMachineExtensionCount > 1,
        },
        outcome == UpdateFailed,
        machinePhase' = machinePhase.put(k, InPlaceFailed),
      },
    },
    lastUpdateOutcome' = lastUpdateOutcome.put(k, outcome),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  // CompleteInPlaceUpdate refines `completeInPlaceUpdate` at
  // `machine_controller_inplace_update.go:198` — fires only
  // inside the reconcile dispatch.
  action CompleteInPlaceUpdate(k: Key): bool = all {
    MACHINES.contains(k),
    reconcileInFlightOn(k, workerOnKey, queuePos),
    machinePhase.get(k) == InPlaceUpdating,
    lastUpdateOutcome.get(k) == UpdateDone,
    machineInProgress'        = machineInProgress.put(k, false),
    infraInProgress'          = infraInProgress.put(k, false),
    bootstrapInProgress'      = bootstrapInProgress.put(k, false),
    updateMachineHookPending' = updateMachineHookPending.put(k, false),
    machinePhase'             = machinePhase.put(k, InPlaceDone),
    machineVersion'           = machineVersion.put(k, newMsVersion),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    lastUpdateOutcome'        = lastUpdateOutcome,
    updateMachineExtensionCount' = updateMachineExtensionCount,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  // OperatorRegisterMultiple fires OUTSIDE reconcile (it's an
  // exogenous operator misconfiguration).
  action OperatorRegisterMultiple: bool = all {
    updateMachineExtensionCount == 1,
    updateMachineExtensionCount' = 2,
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    newMsVersion'             = newMsVersion,
    machineVersion'           = machineVersion,
    machinePhase'             = machinePhase,
    machineInProgress'        = machineInProgress,
    infraInProgress'          = infraInProgress,
    bootstrapInProgress'      = bootstrapInProgress,
    updateMachineHookPending' = updateMachineHookPending,
    lastUpdateOutcome'        = lastUpdateOutcome,
    inPlaceFeatureEnabled'    = inPlaceFeatureEnabled,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    ManagerStartAndLeader,
    nondet w = WORKERS.oneOf();
      nondet k = MACHINES.oneOf();
      ProcessNextWorkItem(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = MACHINES.oneOf();
      ReconcileFinishRequeueAfter(w, k),
    nondet k = MACHINES.oneOf(); TimerExpires(k),
    nondet k = MACHINES.oneOf();
      nondet o = Set(UpdateProgressing, UpdateDone, UpdateFailed).oneOf();
      CallUpdateMachineHook(k, o),
    nondet k = MACHINES.oneOf(); CompleteInPlaceUpdate(k),
    OperatorRegisterMultiple,
  }

  // ===============================================================
  // Refinement-preserved invariants
  // ===============================================================

  val FM45_PerKeySerialisation =
    MACHINES.forall(k =>
      WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  val InFlightHasWorker =
    MACHINES.forall(k =>
      queuePos.get(k) == InFlight
        implies anyWorkerOnKey(k, workerOnKey))

  val LeaderElectionGate =
    leaderRunnablesStarted implies managerStarted

  // FM-43 (refined) — UpdateMachine idempotence under multi-worker.
  val FM43_UpdateMachineIdempotenceGate =
    MACHINES.forall(k =>
      machinePhase.get(k) == InPlaceUpdating
        implies (hookGateOpen(
                   inPlaceFeatureEnabled,
                   machineInProgress.get(k),
                   updateMachineHookPending.get(k),
                   infraInProgress.get(k),
                   bootstrapInProgress.get(k))
                 or not(machineInProgress.get(k))))

  // FM-44 (refined) — multi-extension blocks any new admission.
  val FM44_MultiExtensionBlocksProgress =
    updateMachineExtensionCount > 1
      implies MACHINES.forall(k =>
        machinePhase.get(k) == InPlaceArmed
          implies (lastUpdateOutcome.get(k) == UpdateProgressing))

  // DoneImpliesVersionFlipped — Machine that reached Done has
  // its version aligned to newMsVersion.
  val DoneImpliesVersionFlipped =
    MACHINES.forall(k =>
      machinePhase.get(k) == InPlaceDone
        implies machineVersion.get(k) == newMsVersion)

  // BodyActionsGated — every Machine that has progressed past
  // InPlaceArmed (i.e. was reconciled) implies the controller
  // has started.
  val BodyActionsGated =
    MACHINES.forall(k =>
      (machinePhase.get(k) == InPlaceUpdating
       or machinePhase.get(k) == InPlaceDone
       or machinePhase.get(k) == InPlaceFailed)
        implies leaderRunnablesStarted)

  val SafetyInvariants = all {
    FM45_PerKeySerialisation,
    InFlightHasWorker,
    LeaderElectionGate,
    FM43_UpdateMachineIdempotenceGate,
    FM44_MultiExtensionBlocksProgress,
    DoneImpliesVersionFlipped,
    BodyActionsGated,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // multiMachineConcurrentInPlaceRun — two Machines in
  // InPlaceArmed; two workers pick them up in parallel; both
  // call UpdateMachine concurrently (different keys so no
  // serialisation conflict); both complete.
  run multiMachineConcurrentInPlaceRun = init
    .then(ManagerStartAndLeader)
    .then(ProcessNextWorkItem(1, 1))
    .then(ProcessNextWorkItem(2, 2))
    .then(CallUpdateMachineHook(1, UpdateDone))
    .then(CallUpdateMachineHook(2, UpdateDone))
    .then(CompleteInPlaceUpdate(1))
    .then(CompleteInPlaceUpdate(2))

  // perKeySerialisationRun — worker 1 picks up Machine 1;
  // worker 2 cannot pick up Machine 1 (serialised). Then
  // worker 2 picks up Machine 2.
  run perKeySerialisationRun = init
    .then(ManagerStartAndLeader)
    .then(ProcessNextWorkItem(1, 1))
    .then(ProcessNextWorkItem(2, 2))
    .then(CallUpdateMachineHook(1, UpdateProgressing))
    .then(CallUpdateMachineHook(2, UpdateProgressing))

}
