module VolumeDetachFinalizer {

  // Standalone CSI volume-detach / finalizer-chain stall model for issue #56.
  //
  // Grounding:
  //   * internal/controllers/machine/machine_controller.go:934-1009
  //   * internal/controllers/machine/machine_controller_status.go:211,374
  //   * api/core/v1beta2/machine_types.go:614,735,739

  pure val VA_COUNT = 2

  var volumeAttachments: Set[int]
  var detachInProgress: Set[int]
  var detachStuck: Set[int]
  var operatorForced: Set[int]
  var nodeDeleting: bool
  var machineFinalizerPresent: bool
  var nodeFinalizerPresent: bool

  action init = all {
    volumeAttachments' = Set(1, 2),
    detachInProgress' = Set(),
    detachStuck' = Set(),
    operatorForced' = Set(),
    nodeDeleting' = false,
    machineFinalizerPresent' = true,
    nodeFinalizerPresent' = true,
  }

  action BeginDelete: bool = all {
    nodeDeleting' = true,
    volumeAttachments' = volumeAttachments,
    detachInProgress' = detachInProgress,
    detachStuck' = detachStuck,
    operatorForced' = operatorForced,
    machineFinalizerPresent' = machineFinalizerPresent,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action BeginDetach(v: int): bool = all {
    volumeAttachments.contains(v),
    detachInProgress' = detachInProgress.union(Set(v)),
    volumeAttachments' = volumeAttachments,
    detachStuck' = detachStuck,
    operatorForced' = operatorForced,
    nodeDeleting' = nodeDeleting,
    machineFinalizerPresent' = machineFinalizerPresent,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action DetachCompletes(v: int): bool = all {
    detachInProgress.contains(v),
    volumeAttachments' = volumeAttachments.filter(x => x != v),
    detachInProgress' = detachInProgress.filter(x => x != v),
    detachStuck' = detachStuck.filter(x => x != v),
    operatorForced' = operatorForced,
    nodeDeleting' = nodeDeleting,
    machineFinalizerPresent' = machineFinalizerPresent,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action DetachBecomesStuck(v: int): bool = all {
    detachInProgress.contains(v),
    detachStuck' = detachStuck.union(Set(v)),
    volumeAttachments' = volumeAttachments,
    detachInProgress' = detachInProgress,
    operatorForced' = operatorForced,
    nodeDeleting' = nodeDeleting,
    machineFinalizerPresent' = machineFinalizerPresent,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action OperatorForceDetach(v: int): bool = all {
    detachStuck.contains(v),
    operatorForced' = operatorForced.union(Set(v)),
    volumeAttachments' = volumeAttachments.filter(x => x != v),
    detachInProgress' = detachInProgress.filter(x => x != v),
    detachStuck' = detachStuck.filter(x => x != v),
    nodeDeleting' = nodeDeleting,
    machineFinalizerPresent' = machineFinalizerPresent,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action ClearNodeFinalizer: bool = all {
    nodeDeleting,
    volumeAttachments == Set(),
    nodeFinalizerPresent,
    nodeFinalizerPresent' = false,
    volumeAttachments' = volumeAttachments,
    detachInProgress' = detachInProgress,
    detachStuck' = detachStuck,
    operatorForced' = operatorForced,
    nodeDeleting' = nodeDeleting,
    machineFinalizerPresent' = machineFinalizerPresent,
  }

  action ClearMachineFinalizer: bool = all {
    nodeDeleting,
    not(nodeFinalizerPresent),
    machineFinalizerPresent,
    machineFinalizerPresent' = false,
    volumeAttachments' = volumeAttachments,
    detachInProgress' = detachInProgress,
    detachStuck' = detachStuck,
    operatorForced' = operatorForced,
    nodeDeleting' = nodeDeleting,
    nodeFinalizerPresent' = nodeFinalizerPresent,
  }

  action step = any {
    BeginDelete,
    nondet v = volumeAttachments.oneOf(); BeginDetach(v),
    nondet v = detachInProgress.oneOf(); DetachCompletes(v),
    nondet v = detachInProgress.oneOf(); DetachBecomesStuck(v),
    nondet v = detachStuck.oneOf(); OperatorForceDetach(v),
    ClearNodeFinalizer,
    ClearMachineFinalizer,
  }

  action stepApalache = any {
    BeginDelete,
    BeginDetach(1),
    DetachBecomesStuck(1),
  }

  val DetachRequiresInProgress =
    detachStuck.subseteq(detachInProgress)

  val MachineFinalizerNeedsPendingDetach =
    machineFinalizerPresent implies (not(nodeDeleting) or nodeFinalizerPresent or volumeAttachments != Set())

  val StableSafetyInvariants = all {
    DetachRequiresInProgress,
  }

  val OperatorEscapeHatch =
    not(machineFinalizerPresent)

  run successfulDetachRun =
    init
      .then(BeginDelete)
      .then(BeginDetach(1))
      .then(DetachCompletes(1))
      .then(BeginDetach(2))
      .then(DetachCompletes(2))
      .then(ClearNodeFinalizer)
      .then(ClearMachineFinalizer)

  run stuckDetachRun =
    init
      .then(BeginDelete)
      .then(BeginDetach(1))
      .then(DetachBecomesStuck(1))

  action stuckDetachInit = all {
    volumeAttachments' = Set(1, 2),
    detachInProgress' = Set(1),
    detachStuck' = Set(1),
    operatorForced' = Set(),
    nodeDeleting' = true,
    machineFinalizerPresent' = true,
    nodeFinalizerPresent' = true,
  }
}
