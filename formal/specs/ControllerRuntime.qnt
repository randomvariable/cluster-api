// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ControllerRuntime.qnt — Substrate model of sigs.k8s.io/controller-runtime.
//
// Refines the core mechanics every CAPI controller is built on
// top of: Manager, Controller (worker pool + workqueue), priority
// queue (dedup + rate-limit + ReadyAt), Reconciler result branches,
// Source/EventHandler/Predicate event pipeline, leader election,
// cache-vs-APIReader read split.
//
// SCOPE. This module is a substrate; it has no domain knowledge of
// CAPI. The CAPI specs (Topology.qnt, InPlaceUpdate.qnt,
// MachineSetPreflight.qnt) are refined onto this substrate by the
// `*Refined.qnt` companion modules — each instantiates this
// substrate with concrete keys and pins the per-key reconcile
// body to its abstract action set.
//
// VARIABLISATION. WORKERS is parametric. The default of
// `1.to(2)` exercises multi-worker concurrency without
// state-space explosion; setting it to `1.to(1)` collapses to
// single-worker semantics for fast TLC sweeps.
//
// LSP grounding (gopls go_search + grep on
// /home/naadir/go/src/sigs.k8s.io/controller-runtime). All
// anchors below reference controller-runtime working tree
// at HEAD; see abstraction-mapping.md §ControllerRuntime.qnt.
//
//   pkg/manager/manager.go
//     :54   Manager interface
//     :301  Runnable interface
//     :321  LeaderElectionRunnable interface
//
//   pkg/manager/internal.go
//     :347  controllerManager.Start
//     :613  controllerManager.initLeaderElector
//     :650  controllerManager.startLeaderElectionRunnables
//     :654  controllerManager.Elected
//     :619  LeaderCallbacks.OnStartedLeading
//     :627  LeaderCallbacks.OnStoppedLeading
//
//   pkg/internal/controller/controller.go
//     :95   Controller struct
//     :194  Controller.Reconcile (entry)
//     :235  Controller.Watch
//     :252  Controller.NeedLeaderElection
//     :275  Controller.Start (worker-pool launch)
//     :307  worker goroutine loop
//     :311  per-key serialisation comment
//     :419  processNextWorkItem
//     :461  reconcileHandler (the four-branch result discriminator)
//     :482  err != nil branch
//     :484  TerminalError branch (no requeue)
//     :487  err non-terminal → AddWithOpts(RateLimited)
//     :495  RequeueAfter > 0 branch
//     :501  Forget + AddWithOpts(After)
//     :504  Requeue (deprecated) branch
//     :508  default success → Forget
//
//   pkg/controller/priorityqueue/priorityqueue.go
//     :19   AddOpts struct
//     :39   PriorityQueue interface
//     :153  AddWithOpts
//     :197  lockedAddWithOpts (dedup merge logic)
//     :219  new-key insert
//     :239  existing-key update (priority + ReadyAt min/max)
//     :309  handleWaitingItems (timer expiry → ready)
//     :360  handleReadyItems (the per-key locked guard)
//     :391  `if w.locked.Has(item.Key) { return true }` — skip
//           items currently being processed
//     :412  Add
//     :416  AddAfter
//     :420  AddRateLimited
//     :424  GetWithPriority
//     :455  Forget (resets rate-limiter)
//     :459  NumRequeues
//     :467  Done (delete from locked set)
//
//   pkg/reconcile/reconcile.go
//     :30   Result struct
//     :42   Result.Requeue (deprecated)
//     :46   Result.RequeueAfter
//     :65   Request struct
//     :107  Reconciler interface
//     :114  TypedReconciler interface
//     :174  TerminalError
//
//   pkg/source/source.go
//     :48   Source = TypedSource[Request]
//     :58   TypedSource interface
//   pkg/handler/eventhandler.go
//     :49   EventHandler = TypedEventHandler[Object, Request]
//     :71   TypedEventHandler interface (Create/Update/Delete/Generic)
//   pkg/predicate/predicate.go
//     :33   Predicate
//     :64   TypedFuncs (default Funcs)
//     :151  ResourceVersionChangedPredicate
//     :208  GenerationChangedPredicate
//     :271  LabelChangedPredicate
//
//   pkg/cache/cache.go
//     :65   Cache interface
//     :143  Options
//   pkg/client/client.go
//     :40   Options (CacheReader / CacheUnstructured)
//     :77   CacheOptions
//     :116  New
module ControllerRuntime {

  // ===============================================================
  // Type space
  // ===============================================================

  // Reconcile request key. Refines `reconcile.Request` at
  // `pkg/reconcile/reconcile.go:65` (a NamespacedName tuple, but
  // the model treats it as an opaque comparable identifier).
  type Key = int

  // Worker identifier. Refines the per-goroutine identity in the
  // worker pool launched at `controller.go:307`.
  type Worker = int

  // Per-key queue position. Refines the `items` map +
  // `ready`/`waiting` btree split at
  // `priorityqueue.go:197-285` plus the `locked` set at
  // `:391-396`.
  type QueuePos =
    | NotInQueue          // key has no entry in items map
    | InReady             // in items + ready btree
    | InWaiting           // in items + waiting btree (ReadyAt > now)
    | InFlight            // in `locked`; either NOT in items
                          //   (Get took it out) or also re-added
                          //   while in flight — see `requeueWhileInFlight`

  // Reconciler outcome envelope. Refines the four-branch
  // discriminator at `controller.go:482-514`.
  type Outcome =
    | OutcomeSuccess        // err == nil and Result is zero
    | OutcomeRequeueAfter   // RequeueAfter > 0
    | OutcomeRequeue        // Result.Requeue (deprecated form)
    | OutcomeError          // err != nil, not terminal
    | OutcomeTerminalError  // err is reconcile.TerminalError

  // Event type emitted by a Source. Refines the four event types
  // dispatched by EventHandler at `eventhandler.go:124-180`.
  type EventType =
    | CreateEvent
    | UpdateEvent
    | DeleteEvent
    | GenericEvent

  // ===============================================================
  // Bounds
  // ===============================================================

  // KEYS: the universe of reconcile keys. The refined modules
  // pin this to their domain (e.g. one key per Cluster for the
  // Topology refinement).
  pure val KEYS: Set[Key] = 1.to(3)

  // WORKERS: the pool size. Refines `MaxConcurrentReconciles` at
  // `controller.go:46-94` (default 1, configurable). Setting to
  // `1.to(N)` for N > 1 exercises the per-key serialisation
  // guarantee at `priorityqueue.go:391`. Default `1.to(2)`
  // sweeps the multi-worker invariants without state explosion.
  pure val WORKERS: Set[Worker] = 1.to(2)

  // RATE_LIMIT_CAP: an abstract bound on rate-limiter retries
  // for invariant phrasing. The real exponential backoff is
  // unbounded; the model treats it as a count.
  pure val RATE_LIMIT_CAP: int = 5

  // ===============================================================
  // State variables
  // ===============================================================

  // Manager started. Refines `controllerManager.started` at
  // `manager/internal.go:349-353`.
  var managerStarted: bool

  // Leader-elected status. Refines the `Elected` channel at
  // `manager/internal.go:625` (closed when OnStartedLeading
  // fires).
  var leaderElected: bool

  // Whether leader-election runnables (i.e. controllers) have
  // started. Refines `startLeaderElectionRunnables` at
  // `manager/internal.go:650`.
  var leaderRunnablesStarted: bool

  // Per-key queue position.
  var queuePos: Key -> QueuePos

  // Per-key NumRequeues counter. Refines the rate-limiter state
  // tracked at `priorityqueue.go:459`. Reset to 0 by `Forget`.
  var numRequeues: Key -> int

  // Per-key "re-added while in flight" bit. Refines the upstream
  // semantics where Add(key) during InFlight inserts a fresh
  // item back into the ready btree (see `lockedAddWithOpts:219`)
  // but `handleReadyItems` skips it because the key is in
  // `locked` (`:391`). After Done removes from `locked`, the next
  // dispatch picks it up.
  var requeueWhileInFlight: Key -> bool

  // Per-worker assignment. Refines the goroutine-local item at
  // `controller.go:312` (each worker is in `processNextWorkItem`
  // for at most one key at a time).
  var workerOnKey: Worker -> Key
  // Sentinel for "worker is idle".
  pure val IDLE_KEY: Key = 0

  // Per-key last reconcile outcome. Refines the result branch
  // taken at `controller.go:482-514`.
  var lastOutcome: Key -> Outcome

  // Per-key Source state (have any events been emitted yet?).
  // Refines `Source.Start(ctx, queue)` at
  // `controller.go:298` and the informer watch firing
  // Create/Update/Delete events at `eventhandler.go:124-180`.
  var sourceStarted: bool

  // The currently-pending event for a key (a Source has emitted
  // an event but the EventHandler has not yet dispatched).
  // Set when SourceEmit fires; cleared by EnqueueViaHandler
  // (after Predicate filtering).
  var pendingEvent: Key -> Option[EventType]

  // Cache vs API server values (single integer field per key —
  // refines a generation/resourceVersion-like field). The cache
  // value is what `client.Get` returns
  // (`pkg/client/client.go:40` CacheReader path); the API server
  // value is what `client.Reader` (APIReader) returns directly.
  var apiVersion: Key -> int
  var cacheVersion: Key -> int

  // ===============================================================
  // Helpers (Option type — model uses None/Some inline below)
  // ===============================================================

  type Option[a] =
    | None
    | Some(a)

  pure def hasEvent(opt: Option[EventType]): bool =
    match opt {
      | None => false
      | Some(_) => true
    }

  // anyWorkerOnKey — refines the `w.locked.Has(item.Key)` check
  // at `priorityqueue.go:391` plus the worker-pool's per-key
  // serialisation comment at `controller.go:311`.
  pure def anyWorkerOnKey(k: Key, assignment: Worker -> Key): bool =
    WORKERS.exists(w => assignment.get(w) == k)

  // workersIdle — count of workers currently idle.
  pure def idleWorkers(assignment: Worker -> Key): Set[Worker] =
    WORKERS.filter(w => assignment.get(w) == IDLE_KEY)

  // ===============================================================
  // Initial state
  // ===============================================================

  action init = all {
    managerStarted'           = false,
    leaderElected'            = false,
    leaderRunnablesStarted'   = false,
    queuePos'                 = KEYS.mapBy(_ => NotInQueue),
    numRequeues'              = KEYS.mapBy(_ => 0),
    requeueWhileInFlight'     = KEYS.mapBy(_ => false),
    workerOnKey'              = WORKERS.mapBy(_ => IDLE_KEY),
    lastOutcome'              = KEYS.mapBy(_ => OutcomeSuccess),
    sourceStarted'            = false,
    pendingEvent'             = KEYS.mapBy(_ => None),
    apiVersion'               = KEYS.mapBy(_ => 0),
    cacheVersion'             = KEYS.mapBy(_ => 0),
  }

  // ===============================================================
  // Manager actions
  // ===============================================================

  // ManagerStart refines `controllerManager.Start` at
  // `manager/internal.go:347`. Sets `started=true` (line 353);
  // initialises the leader elector (line 371) — but does NOT yet
  // close `cm.elected` until OnStartedLeading fires.
  action ManagerStart: bool = all {
    not(managerStarted),
    managerStarted' = true,
    // Frame:
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // LeaderAcquire refines the `OnStartedLeading` callback at
  // `manager/internal.go:619-625`: sets `cm.elected` (modelled
  // by leaderElected) AND triggers
  // `cm.startLeaderElectionRunnables` (line 621).
  action LeaderAcquire: bool = all {
    managerStarted,
    not(leaderElected),
    leaderElected'            = true,
    leaderRunnablesStarted'   = true,
    sourceStarted'            = true,            // Source.Start fires
    // Frame:
    managerStarted'           = managerStarted,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // LeaderLose refines the `OnStoppedLeading` callback at
  // `manager/internal.go:627-637`. The model treats this as a
  // catastrophic error: leader-election runnables are halted
  // (workers stop pulling new items), but the `elected` bit is
  // not cleared because the upstream code returns an error
  // rather than returning to the un-elected state.
  // The model can fire this once and never re-acquire; this
  // captures the "leader election lost" failure mode.
  action LeaderLose: bool = all {
    leaderElected,
    leaderRunnablesStarted,
    leaderRunnablesStarted'   = false,
    sourceStarted'            = false,
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ===============================================================
  // API-server / cache actions
  // ===============================================================

  // ApiServerWrite refines an external write to the API server.
  // The cache is NOT immediately updated; CacheSync brings it
  // forward. Refines the staleness window between
  // `client.Update` (which goes to the API server) and the
  // informer's next watch event.
  action ApiServerWrite(k: Key): bool = all {
    KEYS.contains(k),
    apiVersion'   = apiVersion.put(k, apiVersion.get(k) + 1),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    cacheVersion'             = cacheVersion,
  }

  // CacheSync refines the informer's watch event firing —
  // `pkg/cache/cache.go:65` — that catches the cache up to
  // (some prefix of) the API server. Modelled as: cache catches
  // up by one version step. Triggers a Source event.
  action CacheSync(k: Key): bool = all {
    KEYS.contains(k),
    cacheVersion.get(k) < apiVersion.get(k),
    sourceStarted,
    cacheVersion'  = cacheVersion.put(k, cacheVersion.get(k) + 1),
    pendingEvent'  = pendingEvent.put(k, Some(UpdateEvent)),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    apiVersion'               = apiVersion,
  }

  // ===============================================================
  // Source / EventHandler / Predicate / Workqueue
  // ===============================================================

  // SourceEmitCreate refines a Source firing a Create event
  // (`eventhandler.go:124`). Pre: source has started; no event
  // already pending for this key.
  action SourceEmitCreate(k: Key): bool = all {
    KEYS.contains(k),
    sourceStarted,
    not(hasEvent(pendingEvent.get(k))),
    pendingEvent'  = pendingEvent.put(k, Some(CreateEvent)),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    queuePos'                 = queuePos,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // EnqueueViaHandler refines an EventHandler.Create/Update/...
  // dispatching the event into the workqueue
  // (`eventhandler.go:124`). The model abstracts the predicate
  // result by allowing the action to either ENQUEUE or DROP.
  // Filtering corresponds to `predicate.go:33-103` where a
  // user-supplied predicate's Update returning false short-
  // circuits the dispatch.
  action EnqueueViaHandler(k: Key, drop: bool): bool = all {
    KEYS.contains(k),
    hasEvent(pendingEvent.get(k)),
    pendingEvent'  = pendingEvent.put(k, None),
    any {
      // Predicate dropped — no enqueue.
      all {
        drop,
        queuePos'              = queuePos,
        requeueWhileInFlight'  = requeueWhileInFlight,
      },
      // Predicate passed — enqueue (deduped).
      all {
        not(drop),
        // If currently in-flight, set the requeueWhileInFlight
        // flag (refines the lockedAddWithOpts:219 path: a fresh
        // item is added to the ready btree but
        // handleReadyItems:391 will skip it until Done).
        any {
          all {
            queuePos.get(k) == InFlight,
            requeueWhileInFlight'  = requeueWhileInFlight.put(k, true),
            queuePos'              = queuePos,
          },
          // Otherwise: NotInQueue → InReady (deduped no-op if
          // already InReady or InWaiting).
          all {
            queuePos.get(k) != InFlight,
            requeueWhileInFlight'  = requeueWhileInFlight,
            queuePos'              = queuePos.put(k,
                                       if (queuePos.get(k) == NotInQueue) InReady
                                       else queuePos.get(k)),
          },
        },
      },
    },
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    numRequeues'              = numRequeues,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // EnqueueAfterTimerExpires refines `handleWaitingItems` at
  // `priorityqueue.go:309-356`: when a key's ReadyAt time
  // passes, it transitions from InWaiting to InReady.
  action EnqueueAfterTimerExpires(k: Key): bool = all {
    KEYS.contains(k),
    queuePos.get(k) == InWaiting,
    queuePos'  = queuePos.put(k, InReady),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    workerOnKey'              = workerOnKey,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ===============================================================
  // Worker dispatch
  // ===============================================================

  // ProcessNextWorkItem refines `processNextWorkItem` at
  // `controller.go:419-439`: a worker calls
  // `Queue.GetWithPriority` (`priorityqueue.go:424`); the
  // priority queue's `handleReadyItems` (`:360-409`) hands out
  // the next ready item whose key is NOT in `locked` (`:391`).
  // The worker then calls Reconcile (modelled by the next
  // ReconcileSucceed/Error/RequeueAfter action).
  action ProcessNextWorkItem(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    KEYS.contains(k),
    leaderRunnablesStarted,                       // gate at :650
    workerOnKey.get(w) == IDLE_KEY,
    queuePos.get(k) == InReady,
    not(anyWorkerOnKey(k, workerOnKey)),          // per-key serialisation (:391)
    workerOnKey'  = workerOnKey.put(w, k),
    queuePos'     = queuePos.put(k, InFlight),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    numRequeues'              = numRequeues,
    requeueWhileInFlight'     = requeueWhileInFlight,
    lastOutcome'              = lastOutcome,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ===============================================================
  // Reconcile result branches (controller.go:461-514)
  // ===============================================================

  // ReconcileSucceed refines the success branch at
  // `controller.go:508-513`. Forget (resets rate-limiter), no
  // requeue. Worker becomes idle. If a re-add happened during
  // the in-flight window, the key transitions to InReady;
  // otherwise NotInQueue.
  action ReconcileSucceed(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == k,
    queuePos.get(k) == InFlight,
    workerOnKey'         = workerOnKey.put(w, IDLE_KEY),
    numRequeues'         = numRequeues.put(k, 0),         // Forget (:512)
    queuePos'            = queuePos.put(k,
                              if (requeueWhileInFlight.get(k)) InReady
                              else NotInQueue),
    requeueWhileInFlight' = requeueWhileInFlight.put(k, false),
    lastOutcome'         = lastOutcome.put(k, OutcomeSuccess),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ReconcileRequeueAfter refines the RequeueAfter branch at
  // `controller.go:495-503`. Forget + AddWithOpts(After).
  // Re-enqueued in InWaiting state.
  action ReconcileRequeueAfter(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == k,
    queuePos.get(k) == InFlight,
    workerOnKey'         = workerOnKey.put(w, IDLE_KEY),
    numRequeues'         = numRequeues.put(k, 0),         // Forget (:501)
    queuePos'            = queuePos.put(k, InWaiting),    // AddWithOpts(After) (:502)
    requeueWhileInFlight' = requeueWhileInFlight.put(k, false),
    lastOutcome'         = lastOutcome.put(k, OutcomeRequeueAfter),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ReconcileRequeue refines the deprecated Result.Requeue
  // branch at `controller.go:504-507`. AddRateLimited → InReady
  // (or InWaiting if rate-limiter delays). Model treats it as
  // InReady with NumRequeues bumped.
  action ReconcileRequeue(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == k,
    queuePos.get(k) == InFlight,
    numRequeues.get(k) < RATE_LIMIT_CAP,
    workerOnKey'         = workerOnKey.put(w, IDLE_KEY),
    numRequeues'         = numRequeues.put(k, numRequeues.get(k) + 1),
    queuePos'            = queuePos.put(k, InWaiting),    // rate-limited
    requeueWhileInFlight' = requeueWhileInFlight.put(k, false),
    lastOutcome'         = lastOutcome.put(k, OutcomeRequeue),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ReconcileError refines the err != nil (non-terminal) branch
  // at `controller.go:483, 487-489`: AddWithOpts(RateLimited)
  // and increment requeues.
  action ReconcileError(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == k,
    queuePos.get(k) == InFlight,
    numRequeues.get(k) < RATE_LIMIT_CAP,
    workerOnKey'         = workerOnKey.put(w, IDLE_KEY),
    numRequeues'         = numRequeues.put(k, numRequeues.get(k) + 1),
    queuePos'            = queuePos.put(k, InWaiting),    // rate-limited
    requeueWhileInFlight' = requeueWhileInFlight.put(k, false),
    lastOutcome'         = lastOutcome.put(k, OutcomeError),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ReconcileTerminalError refines the terminal-error branch at
  // `controller.go:484-485`: NO requeue (the key drops out
  // entirely). The reconcileTotal "error" counter increments,
  // but the workqueue is not re-added.
  action ReconcileTerminalError(w: Worker, k: Key): bool = all {
    WORKERS.contains(w),
    workerOnKey.get(w) == k,
    queuePos.get(k) == InFlight,
    workerOnKey'         = workerOnKey.put(w, IDLE_KEY),
    queuePos'            = queuePos.put(k,
                              if (requeueWhileInFlight.get(k)) InReady
                              else NotInQueue),
    requeueWhileInFlight' = requeueWhileInFlight.put(k, false),
    lastOutcome'         = lastOutcome.put(k, OutcomeTerminalError),
    // Frame:
    managerStarted'           = managerStarted,
    leaderElected'            = leaderElected,
    leaderRunnablesStarted'   = leaderRunnablesStarted,
    numRequeues'              = numRequeues,
    sourceStarted'            = sourceStarted,
    pendingEvent'             = pendingEvent,
    apiVersion'               = apiVersion,
    cacheVersion'             = cacheVersion,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    ManagerStart,
    LeaderAcquire,
    LeaderLose,
    nondet k = KEYS.oneOf(); ApiServerWrite(k),
    nondet k = KEYS.oneOf(); CacheSync(k),
    nondet k = KEYS.oneOf(); SourceEmitCreate(k),
    nondet k = KEYS.oneOf();
      nondet d = Set(true, false).oneOf();
      EnqueueViaHandler(k, d),
    nondet k = KEYS.oneOf(); EnqueueAfterTimerExpires(k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ProcessNextWorkItem(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ReconcileSucceed(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ReconcileRequeueAfter(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ReconcileRequeue(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ReconcileError(w, k),
    nondet w = WORKERS.oneOf();
      nondet k = KEYS.oneOf();
      ReconcileTerminalError(w, k),
  }

  // ===============================================================
  // Invariants
  // ===============================================================

  // FM-45: PER-KEY SERIALISATION. At most one worker is
  // processing any given key. Refines the upstream guarantee at
  // `priorityqueue.go:391` plus `controller.go:311`. This is
  // the load-bearing safety property of multi-worker controllers
  // — if two workers reconciled the same object simultaneously,
  // the SSA / patch helpers would race.
  val FM45_PerKeySerialisation =
    KEYS.forall(k =>
      WORKERS.filter(w => workerOnKey.get(w) == k).size() <= 1)

  // FM-46: TERMINAL ERROR DOES NOT REQUEUE. Refines
  // `controller.go:484` (terminal-error branch is the only
  // err != nil path that does NOT call AddWithOpts(RateLimited)).
  // State-invariant phrasing: a key that has just received a
  // TerminalError is either NotInQueue or InReady (the latter
  // only because of a re-add during the in-flight window).
  val FM46_TerminalErrorNoRequeue =
    KEYS.forall(k =>
      lastOutcome.get(k) == OutcomeTerminalError
        and workerOnKey.keys().forall(w => workerOnKey.get(w) != k)
        implies (queuePos.get(k) == NotInQueue
                 or queuePos.get(k) == InReady))

  // FM-47: CACHE STALENESS BOUND. The cache version is at most
  // the API server version. Refines the read split at
  // `pkg/client/client.go:40` (CacheReader path) — `client.Get`
  // returns the cached value, which lags `client.Update` until
  // the next informer sync.
  val FM47_CacheBehindAPI =
    KEYS.forall(k => cacheVersion.get(k) <= apiVersion.get(k))

  // I-LE: leader-election runnables only run while we hold the
  // lock. Refines `manager/internal.go:650` (gated on the
  // OnStartedLeading callback).
  val LeaderElectionGate =
    leaderRunnablesStarted implies leaderElected

  // I-WORKER: idle workers carry the IDLE_KEY sentinel.
  val WorkerSentinelConsistency =
    WORKERS.forall(w =>
      workerOnKey.get(w) != IDLE_KEY
        implies KEYS.contains(workerOnKey.get(w))
                and queuePos.get(workerOnKey.get(w)) == InFlight)

  // I-INFLIGHT: a key in InFlight has at least one assigned
  // worker.
  val InFlightHasWorker =
    KEYS.forall(k =>
      queuePos.get(k) == InFlight
        implies anyWorkerOnKey(k, workerOnKey))

  // I-RL: rate-limiter retries are bounded.
  val RateLimitBounded =
    KEYS.forall(k => numRequeues.get(k) <= RATE_LIMIT_CAP)

  val SafetyInvariants = all {
    FM45_PerKeySerialisation,
    FM46_TerminalErrorNoRequeue,
    FM47_CacheBehindAPI,
    LeaderElectionGate,
    WorkerSentinelConsistency,
    InFlightHasWorker,
    RateLimitBounded,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyManagerStartRun — Manager starts, acquires leader,
  // launches sources, processes a single Create event.
  run happyManagerStartRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ReconcileSucceed(1, 1))

  // multiWorkerParallelRun — two keys enqueued; two workers
  // pick them up concurrently. Verifies multi-worker
  // concurrency without breaking per-key serialisation.
  run multiWorkerParallelRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(SourceEmitCreate(2))
    .then(EnqueueViaHandler(2, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ProcessNextWorkItem(2, 2))
    .then(ReconcileSucceed(1, 1))
    .then(ReconcileSucceed(2, 2))

  // dedupDuringInFlightRun — Source emits Update for key 1
  // while it's already being reconciled by worker 1. The model
  // captures the requeueWhileInFlight bit; after Done, the key
  // returns to InReady.
  run dedupDuringInFlightRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ApiServerWrite(1))
    .then(CacheSync(1))
    .then(EnqueueViaHandler(1, false))      // re-add during in-flight
    .then(ReconcileSucceed(1, 1))           // Done → InReady
    .then(ProcessNextWorkItem(1, 1))        // re-process
    .then(ReconcileSucceed(1, 1))

  // requeueAfterRun — Reconciler returns RequeueAfter; key
  // transitions to InWaiting; timer expires; key processes
  // again.
  run requeueAfterRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ReconcileRequeueAfter(1, 1))
    .then(EnqueueAfterTimerExpires(1))
    .then(ProcessNextWorkItem(1, 1))
    .then(ReconcileSucceed(1, 1))

  // terminalErrorRun — Reconciler returns TerminalError; the
  // key drops out without requeue. lastOutcome stays
  // OutcomeTerminalError.
  run terminalErrorRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ReconcileTerminalError(1, 1))

  // leaderLossRun — Manager acquires leader, processes an
  // event, then loses the lock; further dispatch is gated.
  run leaderLossRun = init
    .then(ManagerStart)
    .then(LeaderAcquire)
    .then(SourceEmitCreate(1))
    .then(EnqueueViaHandler(1, false))
    .then(ProcessNextWorkItem(1, 1))
    .then(ReconcileSucceed(1, 1))
    .then(LeaderLose)

}
