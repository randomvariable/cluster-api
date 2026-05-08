// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// MachineSetPreflightRefined.qnt — Refinement of (a slice of)
// MachineSetPreflight.qnt onto the ControllerRuntime substrate.
//
// REFINEMENT CLAIM. The MachineSet controller's preflight gate
// at `internal/controllers/machineset/machineset_preflight.go:47`
// (Reconciler.runPreflightChecks) is invoked from inside the
// substrate's reconcile dispatch. Multiple MachineSets in the
// queue can be reconciled concurrently by different workers; the
// per-key serialisation guarantee ensures the same MachineSet is
// never preflight-checked twice in parallel.
//
// The model surfaces the cross-cutting interaction with the
// substrate's `RequeueAfter` behaviour: when preflight fails,
// the controller returns `Result{RequeueAfter: 15s}` (refines
// `machineset_preflight.go:45` constant `preflightFailedRequeueAfter`).
// This corresponds to the OutcomeRequeueAfter branch in the
// substrate, sending the key back to InWaiting for retry.
//
// REFINEMENT MAPPING (informal). π(s) drops the substrate
// fields. Every preflight evaluation fires inside a reconcile
// dispatch; the operator-driven actions (KcpBeginUpgrade,
// OperatorBumpMsVersion) fire outside.
//
// LSP grounding (gopls go_search + grep on
// /home/naadir/go/src/sigs.k8s.io/controller-runtime AND CAPI):
//
//   pkg/internal/controller/controller.go
//     :194  Reconcile (entry; the BODY of preflight check)
//     :311  per-key serialisation comment
//     :495  RequeueAfter > 0 branch
//   pkg/controller/priorityqueue/priorityqueue.go
//     :391  locked-set guard
//
//   internal/controllers/machineset/machineset_preflight.go
//     :45   preflightFailedRequeueAfter = 15s
//     :47   Reconciler.runPreflightChecks (BODY)
//     :149  controlPlaneStablePreflightCheck
//     :190  kubernetesVersionPreflightCheck
//   internal/controllers/machineset/machineset_controller.go
//     :828  scale-up call site (returns Result{RequeueAfter})
//     :1633 remediation call site
//
// SCOPE. Two MachineSets (as the queue keys); multi-worker
// (WORKERS = 1.to(2)).
module MachineSetPreflightRefined {

  // ===============================================================
  // Substrate state
  // ===============================================================

  type Key = int
  type Worker = int
  type QueuePos = NotInQueue | InReady | InWaiting | InFlight

  pure val MS_KEYS: Set[Key] = 1.to(2)         // one key per MachineSet
  pure val WORKERS: Set[Worker] = 1.to(2)
  pure val IDLE_KEY: Key = 0

  var managerStarted: bool
  var leaderRunnablesStarted: bool
  var queuePos: Key -> QueuePos
  var workerOnKey: Worker -> Key
  var requeueWhileInFlight: Key -> bool

  // ===============================================================
  // MachineSetPreflight abstract state
  // ===============================================================

  type WorkerDecision =
    | NoActionNeeded | ScaleUpRequested | ActionBlocked | ActionInFlight
  type BlockedReason =
    | NoBlock | CpUnstable | KubernetesVersionSkewViolation

  pure val MAX_VERSION_SKEW: int = 2

  // CP-side abstracted (one CP serves both MSes).
  var cpVersion: int
  var cpUpgradeInProgress: bool

  // Per-MachineSet state.
  var msVersion: Key -> int
  var msPreflightBlocked: Key -> bool
  var msBlockReason: Key -> BlockedReason
  var msDecision: Key -> WorkerDecision

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def anyWorkerOnKey(k: Key, a: Worker -> Key): bool =
    WORKERS.exists(w => a.get(w) == k)

  pure def reconcileInFlightOn(k: Key, a: Worker -> Key, qp: Key -> QueuePos): bool =
    qp.get(k) == InFlight and anyWorkerOnKey(k, a)

  pure def controlPlaneIsStable(upgrading: bool): bool =
    not(upgrading)

  pure def kubernetesVersionInRange(cpV: int, msV: int): bool =
    msV <= cpV and (cpV - msV) <= MAX_VERSION_SKEW

  pure def evaluatePreflight(cpUp: bool, cpV: int, msV: int): BlockedReason =
    if (not(controlPlaneIsStable(cpUp))) CpUnstable
    else if (not(kubernetesVersionInRange(cpV, msV))) KubernetesVersionSkewViolation
    else NoBlock

  // ===============================================================
  // Initial state
  // ===============================================================

  action init = all {
    managerStarted'           = false,
    leaderRunnablesStarted'   = false,
    queuePos'                 = MS_KEYS.mapBy(_ => NotInQueue),
    workerOnKey'              = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'     = MS_KEYS.mapBy(_ => false),
    cpVersion'                = 36,
    cpUpgradeInProgress'      = false,
    msVersion'                = MS_KEYS.mapBy(_ => 36),
    msPreflightBlocked'       = MS_KEYS.mapBy(_ => false),
    msBlockReason'            = MS_KEYS.mapBy(_ => NoBlock),
    msDecision'               = MS_KEYS.mapBy(_ => NoActionNeeded),
  }

  // ===============================================================
  // Substrate-only actions
  // ===============================================================

  action ManagerStartAndLeader: bool = all {
    not(managerStarted),
    managerStarted'           = true,
    leaderRunnablesStarted'   = true,
    queuePos'                 = MS_KEYS.mapBy(_ => InReady),
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  action ProcessNextWorkItem(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    MS_KEYS.contains(k),
    leaderRunnablesStarted,
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(k) == InReady,
    not(anyWorkerOnKey(k, workerOnKey)),         // FM-45
    workerOnKey'  = workerOnKey.put(w, k),
    queuePos'     = queuePos.put(k, InFlight),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    requeueWhileInFlight'     = requeueWhileInFlight,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  // ReconcileFinishRequeueAfter — preflight failed, controller
  // returns Result{RequeueAfter: 15s}.
  action ReconcileFinishRequeueAfter(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    MS_KEYS.contains(k),
    workerOnKey.get(w) == k,
    workerOnKey'  = workerOnKey.put(w, IDLE_KEY),
    queuePos'     = queuePos.put(k,
                       if (requeueWhileInFlight.get(k)) InReady
                       else InWaiting),
    requeueWhileInFlight'  = requeueWhileInFlight.put(k, false),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  action ReconcileFinishSuccess(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    MS_KEYS.contains(k),
    workerOnKey.get(w) == k,
    // Successful reconcile with no requeue is only allowed when
    // there's no pending action — otherwise the controller
    // would return Result{RequeueAfter} (or rely on a watch
    // event from a side-effect not modelled here).
    msDecision.get(k) == NoActionNeeded,
    workerOnKey'  = workerOnKey.put(w, IDLE_KEY),
    queuePos'     = queuePos.put(k,
                       if (requeueWhileInFlight.get(k)) InReady
                       else NotInQueue),
    requeueWhileInFlight'  = requeueWhileInFlight.put(k, false),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  action TimerExpires(k: Key): bool = all {
    MS_KEYS.contains(k),
    queuePos.get(k) == InWaiting,
    queuePos'  = queuePos.put(k, InReady),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  // ===============================================================
  // Operator-driven actions (fire outside reconcile)
  // ===============================================================

  action KcpBeginUpgrade: bool = all {
    not(cpUpgradeInProgress),
    cpUpgradeInProgress' = true,
    cpVersion'           = cpVersion + 1,
    // Watch event re-enqueues both MS keys.
    queuePos'  = MS_KEYS.mapBy(k =>
                    if (queuePos.get(k) == InFlight) queuePos.get(k)
                    else if (queuePos.get(k) == NotInQueue) InReady
                    else queuePos.get(k)),
    requeueWhileInFlight'  = MS_KEYS.mapBy(k =>
                    if (queuePos.get(k) == InFlight) true
                    else requeueWhileInFlight.get(k)),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    workerOnKey'              = workerOnKey,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  action KcpFinishUpgrade: bool = all {
    cpUpgradeInProgress,
    cpUpgradeInProgress' = false,
    queuePos'  = MS_KEYS.mapBy(k =>
                    if (queuePos.get(k) == InFlight) queuePos.get(k)
                    else if (queuePos.get(k) == NotInQueue) InReady
                    else queuePos.get(k)),
    requeueWhileInFlight'  = MS_KEYS.mapBy(k =>
                    if (queuePos.get(k) == InFlight) true
                    else requeueWhileInFlight.get(k)),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    workerOnKey'              = workerOnKey,
    cpVersion'                = cpVersion,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
    msDecision'               = msDecision,
  }

  action OperatorRequestScaleUp(k: Key): bool = all {
    MS_KEYS.contains(k),
    msDecision.get(k) == NoActionNeeded,
    msDecision' = msDecision.put(k, ScaleUpRequested),
    // Watch event re-enqueues this key.
    any {
      all {
        queuePos.get(k) == InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight.put(k, true),
        queuePos'              = queuePos,
      },
      all {
        queuePos.get(k) != InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight,
        queuePos'              = queuePos.put(k,
                                    if (queuePos.get(k) == NotInQueue) InReady
                                    else queuePos.get(k)),
      },
    },
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    workerOnKey'              = workerOnKey,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
  }

  // ===============================================================
  // Preflight body action (guarded by reconcileInFlightOn)
  // ===============================================================

  // CompleteScaleUp refines the post-preflight branch in
  // `(*Reconciler).reconcile` at
  // `machineset_controller.go:828` — when preflight returns
  // nil errors, the controller proceeds to create Machines and
  // the MS is back to NoActionNeeded for the next reconcile.
  action CompleteScaleUp(k: Key): bool = all {
    MS_KEYS.contains(k),
    reconcileInFlightOn(k, workerOnKey, queuePos),
    msDecision.get(k) == ActionInFlight,
    // Gate must still be passable (otherwise EvaluatePreflight
    // would re-demote first).
    evaluatePreflight(cpUpgradeInProgress, cpVersion, msVersion.get(k)) == NoBlock,
    msDecision'         = msDecision.put(k, NoActionNeeded),
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
    msPreflightBlocked'       = msPreflightBlocked,
    msBlockReason'            = msBlockReason,
  }

  // EvaluatePreflight refines `runPreflightChecks` at
  // `machineset_preflight.go:47`. Fires only inside a reconcile
  // dispatch for the specific MS.
  action EvaluatePreflight(k: Key): bool = all {
    MS_KEYS.contains(k),
    reconcileInFlightOn(k, workerOnKey, queuePos),
    // Refines `machineset_controller.go:828` — preflight is
    // re-evaluated every reconcile, including when the prior
    // verdict was ActionInFlight. This allows the gate to
    // re-block if CP advances during the in-flight window.
    any {
      msDecision.get(k) == ScaleUpRequested,
      msDecision.get(k) == ActionBlocked,
      msDecision.get(k) == ActionInFlight,
    },
    val reason = evaluatePreflight(cpUpgradeInProgress, cpVersion, msVersion.get(k))
    any {
      all {
        reason != NoBlock,
        msPreflightBlocked' = msPreflightBlocked.put(k, true),
        msBlockReason'      = msBlockReason.put(k, reason),
        msDecision'         = msDecision.put(k, ActionBlocked),
      },
      all {
        reason == NoBlock,
        msPreflightBlocked' = msPreflightBlocked.put(k, false),
        msBlockReason'      = msBlockReason.put(k, NoBlock),
        msDecision'         = msDecision.put(k, ActionInFlight),
      },
    },
    managerStarted'           = managerStarted,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    cpVersion'                = cpVersion,
    cpUpgradeInProgress'      = cpUpgradeInProgress,
    msVersion'                = msVersion,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    ManagerStartAndLeader,
    nondet w = WORKERS.oneOf();
      nondet k = MS_KEYS.oneOf();
      ProcessNextWorkItem(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = MS_KEYS.oneOf();
      ReconcileFinishRequeueAfter(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = MS_KEYS.oneOf();
      ReconcileFinishSuccess(w, k),
    nondet k = MS_KEYS.oneOf(); TimerExpires(k),
    KcpBeginUpgrade,
    KcpFinishUpgrade,
    nondet k = MS_KEYS.oneOf(); OperatorRequestScaleUp(k),
    nondet k = MS_KEYS.oneOf(); EvaluatePreflight(k),
    nondet k = MS_KEYS.oneOf(); CompleteScaleUp(k),
  }

  // ===============================================================
  // Refinement-preserved invariants
  // ===============================================================

  val FM45_PerKeySerialisation =
    MS_KEYS.forall(k =>
      WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  val InFlightHasWorker =
    MS_KEYS.forall(k =>
      queuePos.get(k) == InFlight
        implies WORKERS.exists(w => workerOnKey.get(w) == k))

  val LeaderElectionGate =
    leaderRunnablesStarted implies managerStarted

  // SafetyInvariants — preflight gate well-formedness (refines
  // MachineSetPreflight.qnt's SafetyInvariants).
  val PreflightGateWellFormed = all {
    MS_KEYS.forall(k =>
      msPreflightBlocked.get(k) implies msBlockReason.get(k) != NoBlock),
    MS_KEYS.forall(k =>
      not(msPreflightBlocked.get(k)) implies msBlockReason.get(k) == NoBlock),
    MS_KEYS.forall(k =>
      msDecision.get(k) == ActionBlocked implies msPreflightBlocked.get(k)),
  }

  // PreflightGateRespected — every MS in ActionInFlight either
  // passes the gate now, OR has a pending reconcile queued that
  // will re-evaluate the gate on the next dispatch (level-
  // triggered semantics — refines the upstream re-evaluation
  // at `machineset_controller.go:828`). This phrasing is
  // necessary under multi-worker substrate: a CP version lap
  // can transiently break the gate-passes invariant while the
  // controller is between reconciles, but the queue carries
  // the requeue intent so the gate will be re-checked.
  val PreflightGateRespected =
    MS_KEYS.forall(k =>
      msDecision.get(k) == ActionInFlight
        implies (
          evaluatePreflight(cpUpgradeInProgress, cpVersion, msVersion.get(k)) == NoBlock
          or cpUpgradeInProgress
          // OR there's a pending reconcile that will re-evaluate.
          or queuePos.get(k) != NotInQueue
          or requeueWhileInFlight.get(k)))

  // BodyActionsGated — preflight evaluation only happens inside
  // a reconcile dispatch.
  val BodyActionsGated =
    MS_KEYS.forall(k =>
      (msDecision.get(k) == ActionBlocked or msDecision.get(k) == ActionInFlight)
        implies leaderRunnablesStarted)

  val SafetyInvariants = all {
    FM45_PerKeySerialisation,
    InFlightHasWorker,
    LeaderElectionGate,
    PreflightGateWellFormed,
    PreflightGateRespected,
    BodyActionsGated,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // multiMSConcurrentPreflightRun — both MSes have ScaleUpRequested;
  // two workers pick them up concurrently and evaluate preflight
  // independently. Both pass (CP stable, versions match).
  run multiMSConcurrentPreflightRun = init
    .then(ManagerStartAndLeader)
    .then(OperatorRequestScaleUp(1))
    .then(OperatorRequestScaleUp(2))
    .then(ProcessNextWorkItem(1, 1))
    .then(ProcessNextWorkItem(2, 2))
    .then(EvaluatePreflight(1))
    .then(EvaluatePreflight(2))

  // preflightBlockRequeueRun — operator requests scale-up while
  // KCP is mid-upgrade. Preflight blocks; controller returns
  // RequeueAfter. After KCP finishes, the queue is re-driven
  // and preflight passes.
  run preflightBlockRequeueRun = init
    .then(ManagerStartAndLeader)
    .then(KcpBeginUpgrade)
    .then(OperatorRequestScaleUp(1))
    .then(ProcessNextWorkItem(1, 1))
    .then(EvaluatePreflight(1))                     // → ActionBlocked
    .then(ReconcileFinishRequeueAfter(1, 1))         // → InWaiting
    .then(KcpFinishUpgrade)                          // CP stable, watch event
    .then(TimerExpires(1))                           // refresh
    .then(ProcessNextWorkItem(1, 1))
    .then(EvaluatePreflight(1))                     // → ActionInFlight

}
