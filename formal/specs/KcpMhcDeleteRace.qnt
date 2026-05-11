module KcpMhcDeleteRace {

  // Standalone KCP + MHC concurrent-delete race model for issue #83.
  //
  // Grounding:
  //   * controlplane/kubeadm/internal/controllers/scale.go
  //   * controlplane/kubeadm/internal/controllers/helpers.go
  //   * internal/controllers/machinehealthcheck/machinehealthcheck_controller.go
  //   * formal/specs/KCPReconcile.qnt
  //   * formal/specs/MachineDeploymentRollout.qnt
  //   * formal/specs/Finalizers.qnt

  type MachineId = int

  pure val DEL_NONE = "none"
  pure val DEL_KCP = "kcp"
  pure val DEL_MHC = "mhc"
  pure val DEL_BOTH = "both"

  pure val ST_HEALTHY = "healthy"
  pure val ST_UNHEALTHY = "unhealthy"
  pure val ST_DELETING = "deleting"
  pure val ST_REMOVED = "removed"

  pure val OLD_MACHINE = 1
  pure val REPLACEMENT = 2

  var kcpSelected: MachineId -> bool
  var mhcSelected: MachineId -> bool
  var deleter: MachineId -> str
  var machineState: MachineId -> str
  var replacementCreated: bool
  var sameNodeLanding: bool
  var replacementHealthy: bool

  action init: bool = all {
    kcpSelected' = Map(OLD_MACHINE -> false, REPLACEMENT -> false),
    mhcSelected' = Map(OLD_MACHINE -> false, REPLACEMENT -> false),
    deleter' = Map(OLD_MACHINE -> DEL_NONE, REPLACEMENT -> DEL_NONE),
    machineState' = Map(OLD_MACHINE -> ST_HEALTHY, REPLACEMENT -> ST_REMOVED),
    replacementCreated' = false,
    sameNodeLanding' = false,
    replacementHealthy' = false,
  }

  action KcpPickReplacement: bool = all {
    not(kcpSelected.get(OLD_MACHINE)),
    kcpSelected' = kcpSelected.put(OLD_MACHINE, true),
    mhcSelected' = mhcSelected,
    deleter' = deleter,
    machineState' = machineState,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action CreateReplacement: bool = all {
    kcpSelected.get(OLD_MACHINE),
    not(replacementCreated),
    replacementCreated' = true,
    machineState' = machineState.put(REPLACEMENT, "healthy"),
    replacementHealthy' = true,
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    deleter' = deleter,
    sameNodeLanding' = sameNodeLanding,
  }

  action MhcFlagUnhealthyOld: bool = all {
    machineState.get(OLD_MACHINE) == ST_HEALTHY,
    mhcSelected' = mhcSelected.put(OLD_MACHINE, true),
    machineState' = machineState.put(OLD_MACHINE, ST_UNHEALTHY),
    kcpSelected' = kcpSelected,
    deleter' = deleter,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action ConcurrentDeleteOldByKcp: bool = all {
    kcpSelected.get(OLD_MACHINE),
    deleter.get(OLD_MACHINE) == DEL_NONE,
    deleter' = deleter.put(OLD_MACHINE, DEL_KCP),
    machineState' = machineState.put(OLD_MACHINE, ST_DELETING),
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action ConcurrentDeleteOldByMhc: bool = all {
    mhcSelected.get(OLD_MACHINE),
    deleter.get(OLD_MACHINE) == DEL_NONE,
    deleter' = deleter.put(OLD_MACHINE, DEL_MHC),
    machineState' = machineState.put(OLD_MACHINE, ST_DELETING),
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action ConcurrentDeleteOldByBoth: bool = all {
    kcpSelected.get(OLD_MACHINE),
    mhcSelected.get(OLD_MACHINE),
    deleter.get(OLD_MACHINE) != DEL_BOTH,
    deleter' = deleter.put(OLD_MACHINE, DEL_BOTH),
    machineState' = machineState.put(OLD_MACHINE, ST_DELETING),
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action FinalizeDeleteOld: bool = all {
    machineState.get(OLD_MACHINE) == ST_DELETING,
    machineState' = machineState.put(OLD_MACHINE, ST_REMOVED),
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    deleter' = deleter,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action ReplacementLandsSameNode: bool = all {
    replacementCreated,
    not(sameNodeLanding),
    sameNodeLanding' = true,
    kcpSelected' = kcpSelected,
    mhcSelected' = mhcSelected,
    deleter' = deleter,
    machineState' = machineState,
    replacementCreated' = replacementCreated,
    replacementHealthy' = replacementHealthy,
  }

  action MhcCannibalisesReplacement: bool = all {
    sameNodeLanding,
    replacementCreated,
    replacementHealthy,
    deleter.get(REPLACEMENT) == DEL_NONE,
    mhcSelected' = mhcSelected.put(REPLACEMENT, true),
    deleter' = deleter.put(REPLACEMENT, DEL_MHC),
    machineState' = machineState.put(REPLACEMENT, ST_DELETING),
    kcpSelected' = kcpSelected,
    replacementCreated' = replacementCreated,
    sameNodeLanding' = sameNodeLanding,
    replacementHealthy' = replacementHealthy,
  }

  action step: bool = any {
    KcpPickReplacement,
    CreateReplacement,
    MhcFlagUnhealthyOld,
    ConcurrentDeleteOldByKcp,
    ConcurrentDeleteOldByMhc,
    ConcurrentDeleteOldByBoth,
    FinalizeDeleteOld,
    ReplacementLandsSameNode,
    MhcCannibalisesReplacement,
  }

  val ReplacementDeleteNeedsUnhealthyLabel =
    deleter.get(REPLACEMENT) != DEL_MHC or sameNodeLanding

  val MhcMarksNeedSelection =
    mhcSelected.get(OLD_MACHINE) implies machineState.get(OLD_MACHINE) == ST_UNHEALTHY or machineState.get(OLD_MACHINE) == ST_DELETING or machineState.get(OLD_MACHINE) == ST_REMOVED

  val StableSafetyInvariants = all {
    ReplacementDeleteNeedsUnhealthyLabel,
    MhcMarksNeedSelection,
  }

  val NoDoubleDelete = deleter.get(OLD_MACHINE) != "both"

  val NoReplacementCannibalisation =
    not(deleter.get(REPLACEMENT) == DEL_MHC and replacementCreated)

  action stepApalache: bool = any {
    KcpPickReplacement,
    CreateReplacement,
    MhcFlagUnhealthyOld,
    ConcurrentDeleteOldByBoth,
    ReplacementLandsSameNode,
    MhcCannibalisesReplacement,
  }

  run authoritativeDeleteRun = init
    .then(KcpPickReplacement)
    .then(CreateReplacement)
    .then(ConcurrentDeleteOldByKcp)

  run concurrentDeleteRun = init
    .then(KcpPickReplacement)
    .then(MhcFlagUnhealthyOld)
    .then(ConcurrentDeleteOldByBoth)

  run replacementCannibalisedRun = init
    .then(KcpPickReplacement)
    .then(CreateReplacement)
    .then(ReplacementLandsSameNode)
    .then(MhcCannibalisesReplacement)

  action doubleDeleteInit: bool = all {
    kcpSelected' = Map(OLD_MACHINE -> true, REPLACEMENT -> false),
    mhcSelected' = Map(OLD_MACHINE -> true, REPLACEMENT -> false),
    deleter' = Map(OLD_MACHINE -> DEL_BOTH, REPLACEMENT -> DEL_NONE),
    machineState' = Map(OLD_MACHINE -> ST_DELETING, REPLACEMENT -> ST_REMOVED),
    replacementCreated' = false,
    sameNodeLanding' = false,
    replacementHealthy' = false,
  }
}
