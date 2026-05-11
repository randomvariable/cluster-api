// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Finalizers.qnt — abstract finalizer-chain ordering across the core
// CAPI deletion controllers.
//
// Grounding anchors (see abstraction-mapping.md for the per-controller
// rows):
//   * internal/controllers/cluster/cluster_controller.go:330-490
//   * internal/controllers/machine/machine_controller.go:465-665
//   * internal/controllers/clusterresourceset/clusterresourceset_controller.go:220-256
//   * internal/controllers/clusterresourcesetbinding/clusterresourcesetbinding_controller.go:93-108
//   * internal/controllers/extensionconfig/extensionconfig_controller.go:215-217
//   * internal/controllers/machine/drain/drain.go

module Finalizers {

  type Obj =
    | ClusterObj
    | ControlPlaneObj
    | MachineDeploymentObj
    | MachineSetObj
    | MachineObj
    | InfraMachineObj
    | BootstrapConfigObj
    | NodeObj

  type DeleteTs =
    | TsAbsent
    | TsPresent

  type Controller =
    | ClusterCtrl
    | ControlPlaneCtrl
    | MachineDeploymentCtrl
    | MachineSetCtrl
    | MachineCtrl

  pure val OBJECTS: Set[Obj] = Set(
    ClusterObj,
    ControlPlaneObj,
    MachineDeploymentObj,
    MachineSetObj,
    MachineObj,
    InfraMachineObj,
    BootstrapConfigObj,
    NodeObj)

  pure val CONTROLLERS: Set[Controller] = Set(
    ClusterCtrl,
    ControlPlaneCtrl,
    MachineDeploymentCtrl,
    MachineSetCtrl,
    MachineCtrl)

  pure def controllerFor(o: Obj): Controller =
    if (o == ClusterObj) ClusterCtrl
    else if (o == ControlPlaneObj) ControlPlaneCtrl
    else if (o == MachineDeploymentObj) MachineDeploymentCtrl
    else if (o == MachineSetObj) MachineSetCtrl
    else MachineCtrl

  pure def ownersOf(o: Obj): Set[Obj] =
    if (o == ClusterObj) Set()
    else if (o == ControlPlaneObj or o == MachineDeploymentObj) Set(ClusterObj)
    else if (o == MachineSetObj) Set(MachineDeploymentObj)
    else if (o == MachineObj) Set(MachineSetObj)
    else Set(MachineObj)

  pure def childrenOf(o: Obj): Set[Obj] =
    if (o == ClusterObj) Set(ControlPlaneObj, MachineDeploymentObj)
    else if (o == MachineDeploymentObj) Set(MachineSetObj)
    else if (o == MachineSetObj) Set(MachineObj)
    else if (o == MachineObj) Set(InfraMachineObj, BootstrapConfigObj, NodeObj)
    else Set()

  pure def allChildrenCleared(
      o: Obj,
      alive: Obj -> bool,
      finalizerPending: Obj -> bool): bool =
    childrenOf(o).forall(c => not(alive.get(c)) or not(finalizerPending.get(c)))

  pure def ownerAcked(o: Obj, acknowledged: Obj -> bool): bool =
    ownersOf(o).forall(owner => acknowledged.get(owner))

  pure def removeAllowed(
      o: Obj,
      alive: Obj -> bool,
      deleteTs: Obj -> DeleteTs,
      finalizerPending: Obj -> bool,
      acknowledged: Obj -> bool,
      infraQuotaExceeded: bool,
      nodeDrainBlocked: bool): bool =
    if (deleteTs.get(o) != TsPresent or not(alive.get(o)) or not(finalizerPending.get(o))) false
    else if (o == ClusterObj)
      OBJECTS.forall(other => other == ClusterObj or not(alive.get(other)) or not(finalizerPending.get(other)))
    else if (o == MachineObj)
      ownerAcked(o, acknowledged) and allChildrenCleared(o, alive, finalizerPending) and not(nodeDrainBlocked)
    else if (o == InfraMachineObj)
      ownerAcked(o, acknowledged) and not(infraQuotaExceeded)
    else if (o == NodeObj)
      ownerAcked(o, acknowledged) and not(nodeDrainBlocked)
    else ownerAcked(o, acknowledged) and allChildrenCleared(o, alive, finalizerPending)

  pure def deleting(o: Obj, deleteTs: Obj -> DeleteTs): bool =
    deleteTs.get(o) == TsPresent

  var alive: Obj -> bool
  var deleteTs: Obj -> DeleteTs
  var finalizerPending: Obj -> bool
  var acknowledged: Obj -> bool
  var cacheLagDelay: Controller -> bool
  var infraQuotaExceeded: bool
  var nodeDrainBlocked: bool
  var lastRemovalTarget: Obj
  var lastRemovalApplied: bool
  var lastRemovalNoop: bool

  action init = all {
    alive'             = OBJECTS.mapBy(_ => true),
    deleteTs'          = OBJECTS.mapBy(_ => TsAbsent),
    finalizerPending'  = OBJECTS.mapBy(o => o != NodeObj),
    acknowledged'      = OBJECTS.mapBy(_ => false),
    cacheLagDelay'     = CONTROLLERS.mapBy(_ => false),
    infraQuotaExceeded' = false,
    nodeDrainBlocked'  = false,
    lastRemovalTarget' = ClusterObj,
    lastRemovalApplied' = false,
    lastRemovalNoop'   = false,
  }

  action happyCascadeRun = all {
    alive'             = OBJECTS.mapBy(_ => true),
    deleteTs'          = OBJECTS.mapBy(_ => TsPresent),
    finalizerPending'  = OBJECTS.mapBy(o => o == ClusterObj or o == MachineObj or o == InfraMachineObj or o == BootstrapConfigObj),
    acknowledged'      = OBJECTS.mapBy(o => o == ClusterObj or o == MachineDeploymentObj or o == MachineSetObj or o == MachineObj),
    cacheLagDelay'     = CONTROLLERS.mapBy(_ => false),
    infraQuotaExceeded' = false,
    nodeDrainBlocked'  = false,
    lastRemovalTarget' = MachineObj,
    lastRemovalApplied' = false,
    lastRemovalNoop'   = false,
  }

  action orphanedChildOrderingRun = all {
    alive'             = OBJECTS.mapBy(_ => true),
    deleteTs'          = OBJECTS.mapBy(_ => TsPresent),
    finalizerPending'  = OBJECTS.mapBy(o => o == MachineObj or o == InfraMachineObj or o == BootstrapConfigObj),
    acknowledged'      = OBJECTS.mapBy(o => o == ClusterObj or o == MachineDeploymentObj or o == MachineSetObj or o == MachineObj),
    cacheLagDelay'     = CONTROLLERS.mapBy(_ => false),
    infraQuotaExceeded' = false,
    nodeDrainBlocked'  = false,
    lastRemovalTarget' = MachineSetObj,
    lastRemovalApplied' = false,
    lastRemovalNoop'   = false,
  }

  action blockedDeletionRun = all {
    alive'             = OBJECTS.mapBy(_ => true),
    deleteTs'          = OBJECTS.mapBy(_ => TsPresent),
    finalizerPending'  = OBJECTS.mapBy(o => o == ClusterObj or o == MachineObj or o == InfraMachineObj or o == BootstrapConfigObj),
    acknowledged'      = OBJECTS.mapBy(_ => false),
    cacheLagDelay'     = CONTROLLERS.mapBy(_ => false),
    infraQuotaExceeded' = true,
    nodeDrainBlocked'  = true,
    lastRemovalTarget' = MachineObj,
    lastRemovalApplied' = false,
    lastRemovalNoop'   = false,
  }

  action RequestCascadeDelete(o: Obj): bool = all {
    alive.get(o),
    deleteTs.get(o) == TsAbsent,
    alive'            = alive,
    deleteTs'         = deleteTs.put(o, TsPresent),
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action AcknowledgeDelete(o: Obj): bool = all {
    alive.get(o),
    deleteTs.get(o) == TsPresent,
    not(acknowledged.get(o)),
    not(cacheLagDelay.get(controllerFor(o))),
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged.put(o, true),
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action RemoveFinalizer(o: Obj): bool = all {
    alive.get(o),
    deleteTs.get(o) == TsPresent,
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = if (removeAllowed(o, alive, deleteTs, finalizerPending, acknowledged, infraQuotaExceeded, nodeDrainBlocked))
      finalizerPending.put(o, false)
      else finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = o,
    lastRemovalApplied' = removeAllowed(o, alive, deleteTs, finalizerPending, acknowledged, infraQuotaExceeded, nodeDrainBlocked),
    lastRemovalNoop'  = not(finalizerPending.get(o)),
  }

  action GCObject(o: Obj): bool = all {
    alive.get(o),
    deleteTs.get(o) == TsPresent,
    not(finalizerPending.get(o)),
    childrenOf(o).forall(child => not(alive.get(child))),
    alive'            = alive.put(o, false),
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action InfraDeletionBlocked: bool = all {
    deleting(InfraMachineObj, deleteTs),
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = true,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action NodeDrainBlockedAction: bool = all {
    deleting(MachineObj, deleteTs) or deleting(NodeObj, deleteTs),
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = true,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action ControllerCrashMidFinalize(c: Controller): bool = all {
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay.put(c, true),
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action RecoverController(c: Controller): bool = all {
    cacheLagDelay.get(c),
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay.put(c, false),
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  // Synthetic ordering bug action for the counterexample log.
  action OwnerDeleted(o: Obj): bool = all {
    alive.get(o),
    deleteTs.get(o) == TsPresent,
    finalizerPending.get(o) == false,
    childrenOf(o).exists(child => alive.get(child) and finalizerPending.get(child)),
    alive'            = alive.put(o, false),
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action OwnerDeletedMachineSet: bool = OwnerDeleted(MachineSetObj)

  action Stutter: bool = all {
    alive'            = alive,
    deleteTs'         = deleteTs,
    finalizerPending' = finalizerPending,
    acknowledged'     = acknowledged,
    cacheLagDelay'    = cacheLagDelay,
    infraQuotaExceeded' = infraQuotaExceeded,
    nodeDrainBlocked' = nodeDrainBlocked,
    lastRemovalTarget' = lastRemovalTarget,
    lastRemovalApplied' = false,
    lastRemovalNoop'  = false,
  }

  action randomStep: bool = any {
    RequestCascadeDelete(ClusterObj),
    RequestCascadeDelete(ControlPlaneObj),
    RequestCascadeDelete(MachineDeploymentObj),
    RequestCascadeDelete(MachineSetObj),
    RequestCascadeDelete(MachineObj),
    RequestCascadeDelete(InfraMachineObj),
    RequestCascadeDelete(BootstrapConfigObj),
    RequestCascadeDelete(NodeObj),
    AcknowledgeDelete(ClusterObj),
    AcknowledgeDelete(MachineDeploymentObj),
    AcknowledgeDelete(MachineSetObj),
    AcknowledgeDelete(MachineObj),
    RemoveFinalizer(ClusterObj),
    RemoveFinalizer(ControlPlaneObj),
    RemoveFinalizer(MachineDeploymentObj),
    RemoveFinalizer(MachineSetObj),
    RemoveFinalizer(MachineObj),
    RemoveFinalizer(InfraMachineObj),
    RemoveFinalizer(BootstrapConfigObj),
    RemoveFinalizer(NodeObj),
    GCObject(ControlPlaneObj),
    GCObject(MachineDeploymentObj),
    GCObject(MachineSetObj),
    GCObject(MachineObj),
    GCObject(InfraMachineObj),
    GCObject(BootstrapConfigObj),
    GCObject(NodeObj),
    GCObject(ClusterObj),
    InfraDeletionBlocked,
    NodeDrainBlockedAction,
    ControllerCrashMidFinalize(ClusterCtrl),
    ControllerCrashMidFinalize(MachineCtrl),
    RecoverController(ClusterCtrl),
    RecoverController(MachineCtrl),
  }

  // Small symbolic relation for Apalache.
  action step: bool = any {
    RemoveFinalizer(InfraMachineObj),
    RemoveFinalizer(BootstrapConfigObj),
    RemoveFinalizer(NodeObj),
    GCObject(InfraMachineObj),
    Stutter,
  }

  val noOrphan =
    OBJECTS.forall(o =>
      ownersOf(o).size() == 0 or not(alive.get(o)) or
        ownersOf(o).exists(owner => alive.get(owner) or deleteTs.get(owner) == TsPresent))

  val cleanShutdownTerminal =
    OBJECTS.forall(o =>
      not(alive.get(o)) implies
        (deleteTs.get(o) == TsPresent and not(finalizerPending.get(o))))

  val topologicalOrder =
    not(lastRemovalApplied) or lastRemovalTarget == ClusterObj or ownerAcked(lastRemovalTarget, acknowledged)

  val idempotentRemoval =
    not(lastRemovalNoop) or not(finalizerPending.get(lastRemovalTarget))

  val StableSafetyInvariants = all {
    noOrphan,
    cleanShutdownTerminal,
    topologicalOrder,
    idempotentRemoval,
    OBJECTS.forall(o => childrenOf(o).forall(child => ownersOf(child).contains(o) or child == ControlPlaneObj or child == MachineDeploymentObj or child == MachineSetObj or child == MachineObj or child == InfraMachineObj or child == BootstrapConfigObj or child == NodeObj)),
  }

  val ownerDeletionWaitsForChildrenCandidate =
    OBJECTS.forall(o =>
      alive.get(o) or childrenOf(o).forall(child => not(alive.get(child)) or not(finalizerPending.get(child))))

  val progressFromAnyStateCandidate =
    OBJECTS.exists(o => deleteTs.get(o) == TsPresent and alive.get(o))
      implies OBJECTS.exists(o => removeAllowed(o, alive, deleteTs, finalizerPending, acknowledged, infraQuotaExceeded, nodeDrainBlocked))
}
