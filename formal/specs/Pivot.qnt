// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Pivot.qnt — abstract clusterctl move / pivot semantics.
//
// Grounding anchors (see abstraction-mapping.md for the pinned rows):
//   * cmd/clusterctl/client/cluster/mover.go
//   * cmd/clusterctl/client/cluster/objectgraph.go
//   * cmd/clusterctl/client/cluster/ownergraph.go

module Pivot {

  type Obj =
    | ClusterClassObj
    | ClusterObj
    | MachineDeploymentObj
    | MachineSetObj
    | MachineObj

  type Side =
    | Src
    | Dst

  type PivotPhase =
    | NotStarted
    | Pausing
    | BackupPhase
    | RestorePhase
    | RemovingSrcPhase
    | Resuming
    | Complete
    | Failed

  pure val OBJECTS: Set[Obj] = Set(
    ClusterClassObj,
    ClusterObj,
    MachineDeploymentObj,
    MachineSetObj,
    MachineObj)

  pure val SIDES: Set[Side] = Set(Src, Dst)

  pure def ownersOf(o: Obj): Set[Obj] =
    if (o == ClusterClassObj or o == ClusterObj) Set()
    else if (o == MachineDeploymentObj) Set(ClusterObj)
    else if (o == MachineSetObj) Set(MachineDeploymentObj)
    else Set(MachineSetObj)

  pure def childrenOf(o: Obj): Set[Obj] =
    if (o == ClusterObj) Set(MachineDeploymentObj)
    else if (o == MachineDeploymentObj) Set(MachineSetObj)
    else if (o == MachineSetObj) Set(MachineObj)
    else Set()

  pure def needsSecret(o: Obj): bool =
    o == ClusterObj or o == MachineObj

  pure def allOnDst(dstObjects: Obj -> bool): bool =
    OBJECTS.forall(o => dstObjects.get(o))

  pure def allGoneFromSrc(srcObjects: Obj -> bool): bool =
    OBJECTS.forall(o => not(srcObjects.get(o)))

  pure def transferInFlight(pivotPhase: PivotPhase): bool =
    pivotPhase == Pausing or pivotPhase == BackupPhase or pivotPhase == RestorePhase or
      pivotPhase == RemovingSrcPhase or pivotPhase == Resuming

  pure def ownerReadyOnDst(o: Obj, dstObjects: Obj -> bool): bool =
    ownersOf(o).forall(owner => dstObjects.get(owner))

  pure def secretSafe(dstObjects: Obj -> bool, secrets: Obj -> bool, paused: Side -> bool): bool =
    paused.get(Dst) or OBJECTS.forall(o => not(dstObjects.get(o)) or not(needsSecret(o)) or secrets.get(o))

  pure def retryPossible(
      pivotPhase: PivotPhase,
      controllerCrash: bool,
      networkPartition: bool,
      cleanError: bool,
      crdInstalled: Side -> bool): bool =
    pivotPhase != Failed or controllerCrash or networkPartition or cleanError or not(crdInstalled.get(Dst))

  var srcObjects: Obj -> bool
  var dstObjects: Obj -> bool
  var paused: Side -> bool
  var ownerRefsResolved: Obj -> bool
  var srcOwnerRefsRemoved: Obj -> bool
  var finalizers: Obj -> bool
  var secrets: Obj -> bool
  var crdInstalled: Side -> bool
  var backedUp: Obj -> bool
  var pivotPhase: PivotPhase
  var controllerCrash: bool
  var networkPartition: bool
  var cleanError: bool
  var lastFinalizerRemovalTarget: Obj
  var lastFinalizerRemovalApplied: bool

  action init = all {
    srcObjects'               = OBJECTS.mapBy(_ => true),
    dstObjects'               = OBJECTS.mapBy(_ => false),
    paused'                   = SIDES.mapBy(_ => false),
    ownerRefsResolved'        = OBJECTS.mapBy(_ => false),
    srcOwnerRefsRemoved'      = OBJECTS.mapBy(_ => false),
    finalizers'               = OBJECTS.mapBy(_ => true),
    secrets'                  = OBJECTS.mapBy(_ => false),
    crdInstalled'             = SIDES.mapBy(_ => true),
    backedUp'                 = OBJECTS.mapBy(_ => false),
    pivotPhase'               = NotStarted,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = ClusterObj,
    lastFinalizerRemovalApplied' = false,
  }

  action happyPivotRun = all {
    srcObjects'               = OBJECTS.mapBy(_ => false),
    dstObjects'               = OBJECTS.mapBy(_ => true),
    paused'                   = SIDES.mapBy(_ => false),
    ownerRefsResolved'        = OBJECTS.mapBy(_ => true),
    srcOwnerRefsRemoved'      = OBJECTS.mapBy(_ => true),
    finalizers'               = OBJECTS.mapBy(_ => false),
    secrets'                  = OBJECTS.mapBy(o => needsSecret(o)),
    crdInstalled'             = SIDES.mapBy(_ => true),
    backedUp'                 = OBJECTS.mapBy(_ => true),
    pivotPhase'               = Complete,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = ClusterObj,
    lastFinalizerRemovalApplied' = false,
  }

  action blockedPivotRetryRun = all {
    srcObjects'               = OBJECTS.mapBy(_ => true),
    dstObjects'               = OBJECTS.mapBy(o => o == ClusterClassObj or o == ClusterObj),
    paused'                   = SIDES.mapBy(_ => true),
    ownerRefsResolved'        = OBJECTS.mapBy(o => o == ClusterClassObj or o == ClusterObj),
    srcOwnerRefsRemoved'      = OBJECTS.mapBy(_ => false),
    finalizers'               = OBJECTS.mapBy(_ => true),
    secrets'                  = OBJECTS.mapBy(_ => false),
    crdInstalled'             = SIDES.mapBy(_ => true),
    backedUp'                 = OBJECTS.mapBy(_ => true),
    pivotPhase'               = Failed,
    controllerCrash'          = false,
    networkPartition'         = true,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = ClusterObj,
    lastFinalizerRemovalApplied' = false,
  }

  action crashDualReconcileRun = all {
    srcObjects'               = OBJECTS.mapBy(_ => true),
    dstObjects'               = OBJECTS.mapBy(o => o == ClusterObj),
    paused'                   = SIDES.mapBy(_ => false),
    ownerRefsResolved'        = OBJECTS.mapBy(o => o == ClusterObj),
    srcOwnerRefsRemoved'      = OBJECTS.mapBy(_ => false),
    finalizers'               = OBJECTS.mapBy(_ => true),
    secrets'                  = OBJECTS.mapBy(o => o == ClusterObj),
    crdInstalled'             = SIDES.mapBy(_ => true),
    backedUp'                 = OBJECTS.mapBy(_ => true),
    pivotPhase'               = Failed,
    controllerCrash'          = true,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = ClusterObj,
    lastFinalizerRemovalApplied' = false,
  }

  action partialOrphanRun = all {
    srcObjects'               = OBJECTS.mapBy(_ => true),
    dstObjects'               = OBJECTS.mapBy(o => o == MachineObj),
    paused'                   = SIDES.mapBy(_ => true),
    ownerRefsResolved'        = OBJECTS.mapBy(_ => false),
    srcOwnerRefsRemoved'      = OBJECTS.mapBy(_ => false),
    finalizers'               = OBJECTS.mapBy(_ => true),
    secrets'                  = OBJECTS.mapBy(o => o == MachineObj),
    crdInstalled'             = SIDES.mapBy(_ => true),
    backedUp'                 = OBJECTS.mapBy(_ => true),
    pivotPhase'               = Failed,
    controllerCrash'          = false,
    networkPartition'         = true,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = ClusterObj,
    lastFinalizerRemovalApplied' = false,
  }

  action Pause: bool = all {
    pivotPhase == NotStarted,
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused.put(Src, true).put(Dst, true),
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = Pausing,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action Backup: bool = all {
    (pivotPhase == Pausing or pivotPhase == BackupPhase),
    paused.get(Src) and paused.get(Dst),
    not(networkPartition),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = OBJECTS.mapBy(_ => true),
    pivotPhase'               = BackupPhase,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action RestoreToTarget(o: Obj): bool = all {
    (pivotPhase == BackupPhase or pivotPhase == RestorePhase),
    paused.get(Src) and paused.get(Dst),
    backedUp.get(o),
    crdInstalled.get(Dst),
    not(networkPartition),
    srcObjects.get(o),
    not(dstObjects.get(o)),
    ownerReadyOnDst(o, dstObjects),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects.put(o, true),
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved.put(o, true),
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = if (needsSecret(o)) secrets.put(o, true) else secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = if (OBJECTS.forall(other => dstObjects.get(other) or other == o)) RemovingSrcPhase else RestorePhase,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action RemoveOwnerRefsOnSrc(o: Obj): bool = all {
    pivotPhase == RemovingSrcPhase,
    srcObjects.get(o),
    dstObjects.get(o),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved.put(o, true),
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = RemovingSrcPhase,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action RemoveFinalizersOnSrc(o: Obj): bool = all {
    pivotPhase == RemovingSrcPhase,
    srcObjects.get(o),
    srcOwnerRefsRemoved.get(o),
    childrenOf(o).forall(child => not(srcObjects.get(child))),
    srcObjects'               = srcObjects.put(o, false),
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers.put(o, false),
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = if (OBJECTS.forall(other => not(srcObjects.get(other)) or other == o)) Resuming else RemovingSrcPhase,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = o,
    lastFinalizerRemovalApplied' = true,
  }

  action Resume: bool = all {
    pivotPhase == Resuming,
    allGoneFromSrc(srcObjects),
    allOnDst(dstObjects),
    secretSafe(dstObjects, secrets, paused),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused.put(Src, false).put(Dst, false),
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = Complete,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action MidPivotControllerCrash: bool = all {
    transferInFlight(pivotPhase),
    paused.get(Src) and paused.get(Dst),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = Failed,
    controllerCrash'          = true,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action MidPivotNetworkPartition: bool = all {
    transferInFlight(pivotPhase),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = Failed,
    controllerCrash'          = false,
    networkPartition'         = true,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action MidPivotMissingCRD: bool = all {
    pivotPhase == BackupPhase or pivotPhase == RestorePhase,
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled.put(Dst, false),
    backedUp'                 = backedUp,
    pivotPhase'               = Failed,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action RetryMove: bool = all {
    pivotPhase == Failed,
    crdInstalled.get(Dst),
    controllerCrash or networkPartition,
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused.put(Src, true).put(Dst, true),
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = if (allOnDst(dstObjects)) RemovingSrcPhase else BackupPhase,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = false,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action ReturnCleanError: bool = all {
    pivotPhase == Failed,
    not(crdInstalled.get(Dst)),
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = Failed,
    controllerCrash'          = false,
    networkPartition'         = false,
    cleanError'               = true,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action Stutter: bool = all {
    srcObjects'               = srcObjects,
    dstObjects'               = dstObjects,
    paused'                   = paused,
    ownerRefsResolved'        = ownerRefsResolved,
    srcOwnerRefsRemoved'      = srcOwnerRefsRemoved,
    finalizers'               = finalizers,
    secrets'                  = secrets,
    crdInstalled'             = crdInstalled,
    backedUp'                 = backedUp,
    pivotPhase'               = pivotPhase,
    controllerCrash'          = controllerCrash,
    networkPartition'         = networkPartition,
    cleanError'               = cleanError,
    lastFinalizerRemovalTarget' = lastFinalizerRemovalTarget,
    lastFinalizerRemovalApplied' = false,
  }

  action randomStep: bool = any {
    Pause,
    Backup,
    RestoreToTarget(ClusterClassObj),
    RestoreToTarget(ClusterObj),
    RestoreToTarget(MachineDeploymentObj),
    RestoreToTarget(MachineSetObj),
    RestoreToTarget(MachineObj),
    RemoveOwnerRefsOnSrc(ClusterClassObj),
    RemoveOwnerRefsOnSrc(ClusterObj),
    RemoveOwnerRefsOnSrc(MachineDeploymentObj),
    RemoveOwnerRefsOnSrc(MachineSetObj),
    RemoveOwnerRefsOnSrc(MachineObj),
    RemoveFinalizersOnSrc(MachineObj),
    RemoveFinalizersOnSrc(MachineSetObj),
    RemoveFinalizersOnSrc(MachineDeploymentObj),
    RemoveFinalizersOnSrc(ClusterObj),
    RemoveFinalizersOnSrc(ClusterClassObj),
    Resume,
    MidPivotControllerCrash,
    MidPivotNetworkPartition,
    MidPivotMissingCRD,
    RetryMove,
    ReturnCleanError,
  }

  // Small symbolic relation for Apalache.
  action step: bool = any {
    Pause,
    Backup,
    RestoreToTarget(ClusterClassObj),
    RestoreToTarget(ClusterObj),
    MidPivotControllerCrash,
    MidPivotMissingCRD,
    RetryMove,
    ReturnCleanError,
    Stutter,
  }

  val objectConservation =
    pivotPhase != Complete or allOnDst(dstObjects)

  val noOrphan =
    OBJECTS.forall(o =>
      ownersOf(o).size() == 0 or not(dstObjects.get(o)) or
        (ownersOf(o).forall(owner => not(srcObjects.get(owner)) or dstObjects.get(owner)) and ownerRefsResolved.get(o)))

  val mutualExclusion =
    OBJECTS.forall(o =>
      not(srcObjects.get(o) and dstObjects.get(o) and not(paused.get(Src)) and not(paused.get(Dst))))

  val partialPivotRecoverable =
    retryPossible(pivotPhase, controllerCrash, networkPartition, cleanError, crdInstalled)

  val finalizerOrdered =
    not(lastFinalizerRemovalApplied) or
      childrenOf(lastFinalizerRemovalTarget).forall(child => not(srcObjects.get(child)) or not(finalizers.get(child)))

  val secretsCloned =
    secretSafe(dstObjects, secrets, paused)

  val StableSafetyInvariants = all {
    objectConservation,
    noOrphan,
    mutualExclusion,
    partialPivotRecoverable,
    finalizerOrdered,
    secretsCloned,
    not(transferInFlight(pivotPhase)) or (paused.get(Src) and paused.get(Dst)),
    OBJECTS.forall(o => srcOwnerRefsRemoved.get(o) implies dstObjects.get(o)),
    pivotPhase == NotStarted or paused.get(Dst) or (allGoneFromSrc(srcObjects) and allOnDst(dstObjects)),
  }

  val crashMutualExclusionCandidate =
    mutualExclusion

  val partialPivotOrphanCandidate =
    OBJECTS.forall(o => ownersOf(o).size() == 0 or not(dstObjects.get(o)) or ownersOf(o).forall(owner => dstObjects.get(owner)))
}
