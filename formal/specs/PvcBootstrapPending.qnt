module PvcBootstrapPending {

  // Standalone PVC/StorageClass bootstrap dependency model for issue #55.
  // Grounding:
  //   * internal/controllers/clusterresourceset/clusterresourceset_controller.go:292-447
  //   * internal/controllers/clusterresourceset/clusterresourceset_scope.go:81-87
  //   * util/resource/resource.go:35-39
  //   * internal/controllers/machine/machine_controller_status.go:167-255

  pure val NONE = "none"
  pure val PENDING = "pending"
  pure val BOUND = "bound"

  pure val WAITING = "waiting"
  pure val RUNNING = "running"

  var storageClassKnown: bool
  var pvcPhase: str
  var bootstrapPodPhase: str
  var csiInstalled: bool
  var bootstrapDependencySatisfied: bool

  action init = all {
    storageClassKnown' = false,
    pvcPhase' = NONE,
    bootstrapPodPhase' = WAITING,
    csiInstalled' = false,
    bootstrapDependencySatisfied' = false,
  }

  action InstallStorageClass: bool = all {
    not(storageClassKnown),
    storageClassKnown' = true,
    pvcPhase' = pvcPhase,
    bootstrapPodPhase' = bootstrapPodPhase,
    csiInstalled' = csiInstalled,
    bootstrapDependencySatisfied' = bootstrapDependencySatisfied,
  }

  action InstallCsiDriver: bool = all {
    not(csiInstalled),
    csiInstalled' = true,
    storageClassKnown' = storageClassKnown,
    pvcPhase' = pvcPhase,
    bootstrapPodPhase' = bootstrapPodPhase,
    bootstrapDependencySatisfied' = bootstrapDependencySatisfied,
  }

  action CreatePvc: bool = all {
    pvcPhase == NONE,
    pvcPhase' = PENDING,
    storageClassKnown' = storageClassKnown,
    bootstrapPodPhase' = bootstrapPodPhase,
    csiInstalled' = csiInstalled,
    bootstrapDependencySatisfied' = bootstrapDependencySatisfied,
  }

  action BindPvc: bool = all {
    pvcPhase == PENDING,
    storageClassKnown,
    csiInstalled,
    pvcPhase' = BOUND,
    storageClassKnown' = storageClassKnown,
    bootstrapPodPhase' = bootstrapPodPhase,
    csiInstalled' = csiInstalled,
    bootstrapDependencySatisfied' = bootstrapDependencySatisfied,
  }

  action StartBootstrapPod: bool = all {
    bootstrapPodPhase == WAITING,
    pvcPhase == BOUND,
    bootstrapPodPhase' = RUNNING,
    bootstrapDependencySatisfied' = true,
    storageClassKnown' = storageClassKnown,
    pvcPhase' = pvcPhase,
    csiInstalled' = csiInstalled,
  }

  action RetryPendingPvc: bool = all {
    pvcPhase == PENDING,
    pvcPhase' = pvcPhase,
    storageClassKnown' = storageClassKnown,
    bootstrapPodPhase' = bootstrapPodPhase,
    csiInstalled' = csiInstalled,
    bootstrapDependencySatisfied' = bootstrapDependencySatisfied,
  }

  action step = any {
    InstallStorageClass,
    InstallCsiDriver,
    CreatePvc,
    BindPvc,
    StartBootstrapPod,
    RetryPendingPvc,
  }

  action stepApalache = any {
    CreatePvc,
    RetryPendingPvc,
    InstallCsiDriver,
    BindPvc,
    StartBootstrapPod,
  }

  val BoundImpliesStorageClassKnown =
    pvcPhase == BOUND implies storageClassKnown

  val PvcPhaseKnown =
    pvcPhase == NONE or pvcPhase == PENDING or pvcPhase == BOUND

  val StableSafetyInvariants = all {
    BoundImpliesStorageClassKnown,
    PvcPhaseKnown,
  }

  val BootstrapDependencyOrdering =
    bootstrapDependencySatisfied implies (csiInstalled and storageClassKnown and pvcPhase == BOUND and bootstrapPodPhase == RUNNING)

  run storageReadyFirstRun =
    init
      .then(InstallStorageClass)
      .then(InstallCsiDriver)
      .then(CreatePvc)
      .then(BindPvc)
      .then(StartBootstrapPod)

  run missingStorageClassRun =
    init
      .then(CreatePvc)
      .then(RetryPendingPvc)
      .then(RetryPendingPvc)

  action missingStorageClassInit = all {
    storageClassKnown' = false,
    pvcPhase' = PENDING,
    bootstrapPodPhase' = WAITING,
    csiInstalled' = false,
    bootstrapDependencySatisfied' = false,
  }
}
