module CrossControllerCycle {

  type Reconciler = Md | Ms
  type Obj = DeploymentObj | MachineSetObj
  type QueueState = NotQueued | Ready | InFlight

  pure val RECONCILERS = Set(Md, Ms)
  pure val OBJECTS = Set(DeploymentObj, MachineSetObj)

  var queuePos: Reconciler -> QueueState
  var blockedOnPeer: Reconciler -> bool
  var peerEnqueueIssued: Reconciler -> bool
  var cacheVersion: Reconciler -> Obj -> int
  var apiVersion: Obj -> int

  action init = all {
    queuePos' = RECONCILERS.mapBy(_ => NotQueued),
    blockedOnPeer' = RECONCILERS.mapBy(_ => false),
    peerEnqueueIssued' = RECONCILERS.mapBy(_ => false),
    cacheVersion' = RECONCILERS.mapBy(_ => OBJECTS.mapBy(_ => 0)),
    apiVersion' = OBJECTS.mapBy(_ => 0),
  }

  action EnqueueMd: bool = all {
    apiVersion' = apiVersion.put(DeploymentObj, apiVersion.get(DeploymentObj) + 1),
    queuePos' = queuePos.put(Md, Ready),
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
  }

  action EnqueueMs: bool = all {
    apiVersion' = apiVersion.put(MachineSetObj, apiVersion.get(MachineSetObj) + 1),
    queuePos' = queuePos.put(Ms, Ready),
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
  }

  action StartMd: bool = all {
    queuePos.get(Md) == Ready,
    queuePos' = queuePos.put(Md, InFlight),
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
    apiVersion' = apiVersion,
  }

  action StartMs: bool = all {
    queuePos.get(Ms) == Ready,
    queuePos' = queuePos.put(Ms, InFlight),
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
    apiVersion' = apiVersion,
  }

  action CrossEnqueueMdToMs: bool = all {
    queuePos.get(Md) == InFlight,
    not(peerEnqueueIssued.get(Md)),
    queuePos' = queuePos.put(Ms, Ready),
    blockedOnPeer' = blockedOnPeer.put(Md, true),
    peerEnqueueIssued' = peerEnqueueIssued.put(Md, true),
    apiVersion' = apiVersion.put(MachineSetObj, apiVersion.get(MachineSetObj) + 1),
    cacheVersion' = cacheVersion,
  }

  // BeginCycleAtMs compresses "start Ms + enqueue Md + wait on Md's
  // observed cache update" into one step so the livelock shape is
  // reachable within Apalache depth 4.
  action BeginCycleAtMs: bool = all {
    queuePos.get(Md) == InFlight,
    blockedOnPeer.get(Md),
    queuePos.get(Ms) == Ready,
    not(peerEnqueueIssued.get(Ms)),
    queuePos' = queuePos.put(Ms, InFlight),
    blockedOnPeer' = blockedOnPeer.put(Ms, true),
    peerEnqueueIssued' = peerEnqueueIssued.put(Ms, true),
    apiVersion' = apiVersion.put(DeploymentObj, apiVersion.get(DeploymentObj) + 1),
    cacheVersion' = cacheVersion,
  }

  action CacheSyncMdOnMs: bool = all {
    cacheVersion' = cacheVersion.put(Md,
      cacheVersion.get(Md).put(MachineSetObj, apiVersion.get(MachineSetObj))),
    queuePos' = queuePos,
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    apiVersion' = apiVersion,
  }

  action CacheSyncMsOnMd: bool = all {
    cacheVersion' = cacheVersion.put(Ms,
      cacheVersion.get(Ms).put(DeploymentObj, apiVersion.get(DeploymentObj))),
    queuePos' = queuePos,
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    apiVersion' = apiVersion,
  }

  action CompleteMd: bool = all {
    queuePos.get(Md) == InFlight,
    blockedOnPeer.get(Md),
    cacheVersion.get(Md).get(MachineSetObj) == apiVersion.get(MachineSetObj),
    queuePos' = queuePos.put(Md, NotQueued),
    blockedOnPeer' = blockedOnPeer.put(Md, false),
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
    apiVersion' = apiVersion,
  }

  action CompleteMs: bool = all {
    queuePos.get(Ms) == InFlight,
    blockedOnPeer.get(Ms),
    cacheVersion.get(Ms).get(DeploymentObj) == apiVersion.get(DeploymentObj),
    queuePos' = queuePos.put(Ms, NotQueued),
    blockedOnPeer' = blockedOnPeer.put(Ms, false),
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
    apiVersion' = apiVersion,
  }

  action Stutter: bool = all {
    queuePos' = queuePos,
    blockedOnPeer' = blockedOnPeer,
    peerEnqueueIssued' = peerEnqueueIssued,
    cacheVersion' = cacheVersion,
    apiVersion' = apiVersion,
  }

  action step: bool = any {
    EnqueueMd,
    EnqueueMs,
    StartMd,
    StartMs,
    CrossEnqueueMdToMs,
    BeginCycleAtMs,
    CacheSyncMdOnMs,
    CacheSyncMsOnMd,
    CompleteMd,
    CompleteMs,
    Stutter,
  }

  def cacheStableAllowsCompletionFor(r: Reconciler): bool =
    if (r == Md)
      blockedOnPeer.get(Md) and cacheVersion.get(Md).get(MachineSetObj) == apiVersion.get(MachineSetObj)
        implies queuePos.get(Md) == InFlight or queuePos.get(Md) == NotQueued
    else
      blockedOnPeer.get(Ms) and cacheVersion.get(Ms).get(DeploymentObj) == apiVersion.get(DeploymentObj)
        implies queuePos.get(Ms) == InFlight or queuePos.get(Ms) == NotQueued

  val CacheNeverLeadsApi =
    RECONCILERS.forall(r =>
      OBJECTS.forall(o => cacheVersion.get(r).get(o) <= apiVersion.get(o)))

  val CrossEnqueuePreservesTargetQueue = all {
    peerEnqueueIssued.get(Md) implies apiVersion.get(MachineSetObj) > 0,
    peerEnqueueIssued.get(Ms) implies apiVersion.get(DeploymentObj) > 0,
  }

  val CacheStableAllowsCompletion = all {
    cacheStableAllowsCompletionFor(Md),
    cacheStableAllowsCompletionFor(Ms),
  }

  val ScenarioSafetyInvariants = all {
    CacheNeverLeadsApi,
    CrossEnqueuePreservesTargetQueue,
  }

  val NoCyclicLivelock = not(
    queuePos.get(Md) == InFlight and queuePos.get(Ms) == InFlight
      and blockedOnPeer.get(Md) and blockedOnPeer.get(Ms))

  run livelockCycleRun = init
    .then(EnqueueMd)
    .then(StartMd)
    .then(CrossEnqueueMdToMs)
    .then(BeginCycleAtMs)

  run stabilisedCycleRun = init
    .then(EnqueueMd)
    .then(StartMd)
    .then(CrossEnqueueMdToMs)
    .then(BeginCycleAtMs)
    .then(CacheSyncMdOnMs)
    .then(CacheSyncMsOnMd)
    .then(CompleteMd)
    .then(CompleteMs)
}
