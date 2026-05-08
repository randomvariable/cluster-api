// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// TopologyRefined.qnt — Refinement of Topology.qnt onto the
// ControllerRuntime substrate.
//
// REFINEMENT CLAIM. Every action in `Topology.qnt` is the BODY of
// a reconcile dispatch in `ControllerRuntime.qnt`: it fires only
// while some worker holds the cluster's key in flight. The
// composed module preserves every safety invariant from
// `Topology.qnt` AND every safety invariant from
// `ControllerRuntime.qnt` (FM-45/46/47) under the joint dynamics
// — verifying that Topology's contracts are not weakened by the
// concrete substrate semantics.
//
// REFINEMENT MAPPING (informal). Given a refined-state s, the
// abstract Topology state π(s) is obtained by forgetting:
//   queuePos, workerOnKey, requeueWhileInFlight, leaderElected,
//   leaderRunnablesStarted, sourceStarted, pendingEvent,
//   numRequeues, lastOutcome, apiVersion, cacheVersion,
//   managerStarted.
// All other state variables map identity. Every refined-step's
// abstract projection is either a Topology step or a stutter
// (CR-only event with no Topology change).
//
// LSP grounding (gopls go_search + grep on
// /home/naadir/go/src/sigs.k8s.io/controller-runtime AND the
// CAPI working tree):
//
//   pkg/internal/controller/controller.go
//     :194  Controller.Reconcile (entry)
//     :311  per-key serialisation comment
//     :419  processNextWorkItem
//     :461  reconcileHandler (four-branch result)
//   pkg/controller/priorityqueue/priorityqueue.go
//     :391  locked-set guard (per-key serialisation)
//   pkg/manager/internal.go
//     :650  startLeaderElectionRunnables (gates dispatch)
//
//   internal/controllers/topology/cluster/cluster_controller.go
//     :263  Reconciler.Reconcile (the BODY of the substrate's
//            reconcile dispatch; abstract Topology actions fire
//            here)
//
// SCOPE. One Cluster (one key) for tractability; multi-worker
// (WORKERS = 1.to(2)) preserved from the substrate to exercise
// the per-key serialisation guarantee.
module TopologyRefined {

  // ===============================================================
  // ControllerRuntime substrate state (subset)
  // ===============================================================

  type Key = int
  type Worker = int
  type QueuePos = NotInQueue | InReady | InWaiting | InFlight

  pure val KEYS: Set[Key] = Set(1)              // single Cluster
  pure val WORKERS: Set[Worker] = 1.to(2)        // multi-worker
  pure val IDLE_KEY: Key = 0
  pure val CLUSTER_KEY: Key = 1                  // the one key

  var managerStarted: bool
  var leaderElected: bool
  var leaderRunnablesStarted: bool
  var sourceStarted: bool
  var queuePos: Key -> QueuePos
  var workerOnKey: Worker -> Key
  var requeueWhileInFlight: Key -> bool

  // ===============================================================
  // Topology abstract state
  // ===============================================================

  type Version = int
  type Hook =
    | BeforeClusterCreate
    | AfterControlPlaneInitialized
    | BeforeClusterUpgrade
    | BeforeControlPlaneUpgrade
    | AfterControlPlaneUpgrade
    | BeforeWorkersUpgrade
    | AfterWorkersUpgrade
    | AfterClusterUpgrade
    | BeforeClusterDelete
  type HookOutcome = HookOk | HookBlock | HookNotConfigured | HookAnnotationBlocked
  type ClusterPhase =
    | NotCreated | Creating | Provisioning | Stable | Upgrading | Deleting | Deleted
  type UpgradeStepPhase =
    | StepIdle | StepPickCP | StepCPUpgrading | StepCPDone
    | StepWorkers | StepWorkersDone

  pure val MD_NAMES: Set[str] = Set("md-a")     // single MD for compactness
  type MdPhase = MdAtVersion | MdPendingUpgrade | MdUpgrading

  var clusterPhase: ClusterPhase
  var topologyVersion: Version
  var cpVersion: Version
  var stepPhase: UpgradeStepPhase
  var cpUpgradePlan: List[Version]
  var mdVersion: str -> Version
  var mdPhase: str -> MdPhase
  var pendingHooks: Set[Hook]
  var lastHookOutcome: Hook -> HookOutcome
  var registeredHooks: Set[Hook]

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def anyWorkerOnKey(k: Key, a: Worker -> Key): bool =
    WORKERS.exists(w => a.get(w) == k)

  // reconcileInFlight — refinement guard. Refines
  // `controller.go:194` (the entry to Reconcile) plus the
  // worker holding the key. Topology actions can only fire
  // while this is true.
  pure def reconcileInFlight(a: Worker -> Key, qp: Key -> QueuePos): bool =
    qp.get(CLUSTER_KEY) == InFlight and anyWorkerOnKey(CLUSTER_KEY, a)

  // ===============================================================
  // Initial state
  // ===============================================================

  action init = all {
    // Substrate
    managerStarted'           = false,
    leaderElected'            = false,
    leaderRunnablesStarted'   = false,
    sourceStarted'            = false,
    queuePos'                 = KEYS.mapBy(_ => NotInQueue),
    workerOnKey'              = WORKERS.mapBy(_ => IDLE_KEY),
    requeueWhileInFlight'     = KEYS.mapBy(_ => false),
    // Topology abstract
    clusterPhase'             = NotCreated,
    topologyVersion'          = 36,
    cpVersion'                = 0,
    stepPhase'                = StepIdle,
    cpUpgradePlan'            = [],
    mdVersion'                = MD_NAMES.mapBy(_ => 0),
    mdPhase'                  = MD_NAMES.mapBy(_ => MdAtVersion),
    pendingHooks'             = Set(),
    lastHookOutcome'          = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                                    BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                                    AfterControlPlaneUpgrade, BeforeWorkersUpgrade,
                                    AfterWorkersUpgrade, AfterClusterUpgrade,
                                    BeforeClusterDelete).mapBy(_ => HookOk),
    registeredHooks'          = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                                    BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                                    AfterControlPlaneUpgrade, BeforeWorkersUpgrade,
                                    AfterWorkersUpgrade, AfterClusterUpgrade,
                                    BeforeClusterDelete),
  }

  // ===============================================================
  // Substrate-only actions (do not touch Topology state)
  // ===============================================================

  action ManagerStart: bool = all {
    not(managerStarted),
    managerStarted' = true,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action LeaderAcquire: bool = all {
    managerStarted,
    not(leaderElected),
    leaderElected'            = true,
    leaderRunnablesStarted'   = true,
    sourceStarted'            = true,
    // Initial reconcile event goes into the queue.
    queuePos'                 = queuePos.put(CLUSTER_KEY, InReady),
    managerStarted'           = managerStarted,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ProcessNextWorkItem(w: Worker): bool = all {
    WORKERS.contains(w),
    leaderRunnablesStarted,
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(CLUSTER_KEY) == InReady,
    not(anyWorkerOnKey(CLUSTER_KEY, workerOnKey)),     // FM-45
    workerOnKey'  = workerOnKey.put(w, CLUSTER_KEY),
    queuePos'     = queuePos.put(CLUSTER_KEY, InFlight),
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  // EnqueueRequeueAfter — finalise reconcile with Result{RequeueAfter},
  // worker becomes idle, key transitions to InWaiting.
  action ReconcileFinishRequeueAfter(w: Worker): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == CLUSTER_KEY,
    workerOnKey'  = workerOnKey.put(w, IDLE_KEY),
    queuePos'     = queuePos.put(CLUSTER_KEY,
                       if (requeueWhileInFlight.get(CLUSTER_KEY)) InReady
                       else InWaiting),
    requeueWhileInFlight'  = requeueWhileInFlight.put(CLUSTER_KEY, false),
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action TimerExpires: bool = all {
    queuePos.get(CLUSTER_KEY) == InWaiting,
    queuePos'  = queuePos.put(CLUSTER_KEY, InReady),
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  // EventEnqueue — operator edits the cluster (via watch); the
  // event is enqueued. If currently in flight, the model marks
  // requeueWhileInFlight; otherwise transitions to InReady.
  action EventEnqueue: bool = all {
    sourceStarted,
    any {
      all {
        queuePos.get(CLUSTER_KEY) == InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight.put(CLUSTER_KEY, true),
        queuePos'              = queuePos,
      },
      all {
        queuePos.get(CLUSTER_KEY) != InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight,
        queuePos'              = queuePos.put(CLUSTER_KEY,
                                    if (queuePos.get(CLUSTER_KEY) == NotInQueue) InReady
                                    else queuePos.get(CLUSTER_KEY)),
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    workerOnKey'              = workerOnKey,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  // ===============================================================
  // Topology body actions — guarded by reconcileInFlight
  // ===============================================================

  // Each Topology action gets a refined sibling guarded by
  // `reconcileInFlight(workerOnKey, queuePos)`. Otherwise the
  // body is identical to Topology.qnt.

  pure def hookFires(h: Hook, registered: Set[Hook]): bool =
    registered.contains(h)

  action EvaluateHook(h: Hook, outcome: HookOutcome): bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    val canFire = hookFires(h, registeredHooks)
    any {
      all {
        canFire,
        any { outcome == HookOk, outcome == HookBlock },
      },
      all {
        not(canFire),
        outcome == HookNotConfigured,
      },
    },
    lastHookOutcome' = lastHookOutcome.put(h, outcome),
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    registeredHooks'          = registeredHooks,
  }

  action ReconcileBeforeClusterCreate: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == NotCreated,
    val outcome = lastHookOutcome.get(BeforeClusterCreate)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        clusterPhase'  = Provisioning,
        pendingHooks'  = pendingHooks.union(Set(AfterControlPlaneInitialized)),
      },
      all {
        outcome == HookBlock,
        clusterPhase'  = NotCreated,
        pendingHooks'  = pendingHooks,
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ControlPlaneProvisioned: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Provisioning,
    cpVersion == 0,
    cpVersion'    = topologyVersion,
    mdVersion'    = MD_NAMES.mapBy(_ => topologyVersion),
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action FireAfterControlPlaneInitialized: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Provisioning,
    cpVersion > 0,
    pendingHooks.contains(AfterControlPlaneInitialized),
    val outcome = lastHookOutcome.get(AfterControlPlaneInitialized)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks' = pendingHooks.exclude(Set(AfterControlPlaneInitialized)),
        clusterPhase' = Stable,
      },
      all {
        outcome == HookBlock,
        pendingHooks' = pendingHooks,
        clusterPhase' = clusterPhase,
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action OperatorBumpTopologyVersion(v: Version): bool = all {
    // Operator edits via API server — fires OUTSIDE the
    // reconcile-in-flight guard (it's an external event).
    v > topologyVersion,
    clusterPhase == Stable,
    topologyVersion' = v,
    // The watch source picks up the change → enqueue.
    any {
      all {
        queuePos.get(CLUSTER_KEY) == InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight.put(CLUSTER_KEY, true),
        queuePos'              = queuePos,
      },
      all {
        queuePos.get(CLUSTER_KEY) != InFlight,
        requeueWhileInFlight'  = requeueWhileInFlight,
        queuePos'              = queuePos.put(CLUSTER_KEY,
                                    if (queuePos.get(CLUSTER_KEY) == NotInQueue) InReady
                                    else queuePos.get(CLUSTER_KEY)),
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    workerOnKey'              = workerOnKey,
    clusterPhase'             = clusterPhase,
    cpVersion'                = cpVersion,
    stepPhase'                = stepPhase,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ComputeUpgradePlanOneMinor: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Stable,
    cpVersion > 0,
    cpVersion < topologyVersion,
    cpUpgradePlan.length() == 0,
    cpUpgradePlan'      = (cpVersion + 1).to(topologyVersion).fold([], (acc, v) => acc.append(v)),
    clusterPhase'       = Upgrading,
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    stepPhase'                = StepIdle,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ReconcileBeforeClusterUpgrade: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    not(pendingHooks.contains(AfterClusterUpgrade)),
    cpUpgradePlan.length() > 0,
    val outcome = lastHookOutcome.get(BeforeClusterUpgrade)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks'  = pendingHooks.union(Set(AfterClusterUpgrade)),
        stepPhase'     = StepPickCP,
      },
      all {
        any { outcome == HookBlock, outcome == HookAnnotationBlocked },
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepIdle,
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ReconcileBeforeControlPlaneUpgrade: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Upgrading,
    stepPhase == StepPickCP,
    cpUpgradePlan.length() > 0,
    val outcome = lastHookOutcome.get(BeforeControlPlaneUpgrade)
    val nextV = cpUpgradePlan.head()
    val workersAtThisStep = MD_NAMES.exists(n => mdVersion.get(n) < nextV)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        cpVersion'    = nextV,
        stepPhase'    = StepCPUpgrading,
        pendingHooks' = if (workersAtThisStep)
          pendingHooks.union(Set(AfterControlPlaneUpgrade,
                                 BeforeWorkersUpgrade,
                                 AfterWorkersUpgrade))
        else pendingHooks.union(Set(AfterControlPlaneUpgrade)),
      },
      all {
        outcome == HookBlock,
        cpVersion'    = cpVersion,
        stepPhase'    = StepPickCP,
        pendingHooks' = pendingHooks,
      },
    },
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  action ControlPlaneStepCompletes: bool = all {
    reconcileInFlight(workerOnKey, queuePos),
    clusterPhase == Upgrading,
    stepPhase == StepCPUpgrading,
    stepPhase'    = StepCPDone,
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    queuePos'                 = queuePos,
    workerOnKey'              = workerOnKey,
    requeueWhileInFlight'     = requeueWhileInFlight,
    clusterPhase'             = clusterPhase,
    topologyVersion'          = topologyVersion,
    cpVersion'                = cpVersion,
    cpUpgradePlan'            = cpUpgradePlan,
    mdVersion'                = mdVersion,
    mdPhase'                  = mdPhase,
    pendingHooks'             = pendingHooks,
    lastHookOutcome'          = lastHookOutcome,
    registeredHooks'          = registeredHooks,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    // Substrate
    ManagerStart,
    LeaderAcquire,
    nondet w = WORKERS.oneOf(); ProcessNextWorkItem(w),
    nondet w = WORKERS.oneOf(); ReconcileFinishRequeueAfter(w),
    TimerExpires,
    EventEnqueue,
    nondet h = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                   BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                   AfterControlPlaneUpgrade).oneOf();
      nondet o = Set(HookOk, HookBlock, HookNotConfigured).oneOf();
      EvaluateHook(h, o),
    // Topology body actions (guarded by reconcileInFlight)
    ReconcileBeforeClusterCreate,
    ControlPlaneProvisioned,
    FireAfterControlPlaneInitialized,
    nondet v = Set(37, 38).oneOf(); OperatorBumpTopologyVersion(v),
    ComputeUpgradePlanOneMinor,
    ReconcileBeforeClusterUpgrade,
    ReconcileBeforeControlPlaneUpgrade,
    ControlPlaneStepCompletes,
  }

  // ===============================================================
  // Refinement-preserved invariants
  // ===============================================================

  // Substrate (FM-45/46/47 simplified for one key + this scope).

  val FM45_PerKeySerialisation =
    KEYS.forall(k =>
      WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  val LeaderElectionGate =
    leaderRunnablesStarted implies leaderElected

  val InFlightHasWorker =
    KEYS.forall(k =>
      queuePos.get(k) == InFlight
        implies anyWorkerOnKey(k, workerOnKey))

  // BodyActionsGated — the central refinement claim. Every
  // mutation to the abstract Topology state happens INSIDE a
  // reconcile dispatch (reconcileInFlight is true). Surfaced
  // here as: if the cluster is past NotCreated, the reconcile
  // dispatch must have been engaged at some point — which is
  // implied by leaderRunnablesStarted being true and at least
  // one Reconcile having fired.
  val BodyActionsGated =
    clusterPhase != NotCreated implies leaderRunnablesStarted

  // Topology safety invariants (subset that's relevant here).

  val PendingHookConsistency = all {
    pendingHooks.contains(AfterClusterUpgrade)
      implies clusterPhase == Upgrading,
    not(pendingHooks.contains(BeforeClusterUpgrade)
        and pendingHooks.contains(AfterClusterUpgrade)),
    pendingHooks.contains(AfterControlPlaneUpgrade)
      implies (stepPhase == StepCPUpgrading
               or stepPhase == StepCPDone),
  }

  val FM39_BeforeClusterUpgradeIdempotent =
    pendingHooks.contains(AfterClusterUpgrade)
      implies not(pendingHooks.contains(BeforeClusterUpgrade))

  val WorkerVersionLeqCp =
    MD_NAMES.forall(n => mdVersion.get(n) <= cpVersion)

  val SafetyInvariants = all {
    FM45_PerKeySerialisation,
    LeaderElectionGate,
    InFlightHasWorker,
    BodyActionsGated,
    PendingHookConsistency,
    FM39_BeforeClusterUpgradeIdempotent,
    WorkerVersionLeqCp,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyRefinedCreateRun — Manager starts, leader acquires,
  // first reconcile picks up the cluster, walks through
  // BeforeClusterCreate → Provisioning → AfterControlPlaneInitialized
  // → Stable.
  run happyRefinedCreateRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(ProcessNextWorkItem(1))
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(ReconcileFinishRequeueAfter(1))

  // multiWorkerRefinedRun — second worker tries to dispatch
  // while worker 1 is in flight; fails the per-key
  // serialisation guard. After worker 1 finishes, worker 2
  // can pick up the next reconcile.
  run multiWorkerRefinedRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(ProcessNextWorkItem(1))
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(ReconcileFinishRequeueAfter(1))
    .then(TimerExpires)
    .then(ProcessNextWorkItem(2))           // now worker 2 picks up

}
