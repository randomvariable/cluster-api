module BootstrapInfraReadyRace {

  // Standalone Machine readiness race model for issue #86.
  //
  // Grounding:
  //   * internal/controllers/machine/machine_controller_status.go
  //   * internal/controllers/machine/machine_controller_phases.go
  //   * bootstrap/util/configowner.go
  //
  // The Machine controller mirrors bootstrap and infrastructure readiness
  // from two independent child objects and then computes Machine readiness
  // from what it has observed. If one child flips Ready but no follow-up
  // event reaches the Machine reconcile, the observed view can remain torn.

  pure val OBS_NONE: str = "none"
  pure val OBS_BOOT: str = "bootstrap"
  pure val OBS_INFRA: str = "infra"
  pure val OBS_BOTH: str = "both"

  var bootstrapReady: bool
  var infraReady: bool
  var machineReady: bool
  var lastObserved: str
  var missingInfraEvent: bool
  var reconcileCount: int

  action init = all {
    bootstrapReady' = false,
    infraReady' = false,
    machineReady' = false,
    lastObserved' = OBS_NONE,
    missingInfraEvent' = false,
    reconcileCount' = 0,
  }

  action BootstrapFlipsReady: bool = all {
    not(bootstrapReady),
    bootstrapReady' = true,
    infraReady' = infraReady,
    machineReady' = machineReady,
    lastObserved' = lastObserved,
    missingInfraEvent' = missingInfraEvent,
    reconcileCount' = reconcileCount,
  }

  action InfraFlipsReady: bool = all {
    not(infraReady),
    bootstrapReady' = bootstrapReady,
    infraReady' = true,
    machineReady' = machineReady,
    lastObserved' = lastObserved,
    missingInfraEvent' = missingInfraEvent,
    reconcileCount' = reconcileCount,
  }

  action DropInfraEvent: bool = all {
    infraReady,
    not(missingInfraEvent),
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = machineReady,
    lastObserved' = lastObserved,
    missingInfraEvent' = true,
    reconcileCount' = reconcileCount,
  }

  action MachineReconcilePinned: bool = all {
    bootstrapReady,
    infraReady,
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = true,
    lastObserved' = OBS_BOTH,
    missingInfraEvent' = false,
    reconcileCount' = reconcileCount + 1,
  }

  action MachineReconcileBootstrapOnly: bool = all {
    bootstrapReady,
    not(infraReady) or missingInfraEvent,
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = false,
    lastObserved' = OBS_BOOT,
    missingInfraEvent' = missingInfraEvent,
    reconcileCount' = reconcileCount + 1,
  }

  action MachineReconcileInfraOnly: bool = all {
    infraReady,
    not(bootstrapReady),
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = false,
    lastObserved' = OBS_INFRA,
    missingInfraEvent' = missingInfraEvent,
    reconcileCount' = reconcileCount + 1,
  }

  action MachineReconcileNeither: bool = all {
    not(bootstrapReady),
    not(infraReady),
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = false,
    lastObserved' = OBS_NONE,
    missingInfraEvent' = missingInfraEvent,
    reconcileCount' = reconcileCount + 1,
  }

  action DeliverMissedInfraEvent: bool = all {
    missingInfraEvent,
    infraReady,
    bootstrapReady' = bootstrapReady,
    infraReady' = infraReady,
    machineReady' = machineReady,
    lastObserved' = lastObserved,
    missingInfraEvent' = false,
    reconcileCount' = reconcileCount,
  }

  action step = any {
    BootstrapFlipsReady,
    InfraFlipsReady,
    DropInfraEvent,
    MachineReconcilePinned,
    MachineReconcileBootstrapOnly,
    MachineReconcileInfraOnly,
    MachineReconcileNeither,
    DeliverMissedInfraEvent,
  }

  action stepApalache = any {
    BootstrapFlipsReady,
    InfraFlipsReady,
    DropInfraEvent,
    MachineReconcileBootstrapOnly,
  }

  val LastObservedSubsetOfTruth =
    (lastObserved == OBS_NONE)
      or (lastObserved == OBS_BOOT and bootstrapReady)
      or (lastObserved == OBS_INFRA and infraReady)
      or (lastObserved == OBS_BOTH and bootstrapReady and infraReady)

  val ReadyNeedsObservedTrue =
    machineReady implies lastObserved == OBS_BOTH

  val StableSafetyInvariants = all {
    LastObservedSubsetOfTruth,
    ReadyNeedsObservedTrue,
  }

  val MachineReadyEventuallyReflectsBoth =
    bootstrapReady and infraReady implies machineReady

  val NoStuckUnreadyDespiteBothChildrenReady =
    not(bootstrapReady and infraReady and not(machineReady))

  run bothReadyObservedRun = init
    .then(BootstrapFlipsReady)
    .then(InfraFlipsReady)
    .then(MachineReconcilePinned)

  run missingInfraEventRun = init
    .then(BootstrapFlipsReady)
    .then(MachineReconcileBootstrapOnly)
    .then(InfraFlipsReady)
    .then(DropInfraEvent)

  action missingEventInit = all {
    bootstrapReady' = true,
    infraReady' = true,
    machineReady' = false,
    lastObserved' = OBS_BOOT,
    missingInfraEvent' = true,
    reconcileCount' = 1,
  }
}
