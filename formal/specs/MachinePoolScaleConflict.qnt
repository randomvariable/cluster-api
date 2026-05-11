module MachinePoolScaleConflict {

  // Standalone MachinePool provider-managed scale vs CAPI desired scale model for issue #89.
  //
  // Grounding:
  //   * exp/topology/desiredstate/desired_state.go:1337-1415 (MachinePool desired spec.replicas)
  //   * api/core/v1beta1/cluster_types.go:733,921 (external autoscaler ownership hint)
  //
  // The model keeps one MachinePool desired replica count (`mpSpecReplicas`),
  // one provider-managed actual count (`providerActual`), and one coarse
  // `lastReconcile` owner marker. The bug is oscillation: CAPI keeps forcing
  // spec intent while the provider/autoscaler keeps forcing actual scale.

  pure val OWNER_NONE: str = "none"
  pure val OWNER_CAPI: str = "capi"
  pure val OWNER_PROVIDER: str = "provider"

  var mpSpecReplicas: int
  var providerActual: int
  var lastReconcile: str
  var providerOwnsScale: bool
  var converged: bool
  var oscillated: bool

  action init: bool = all {
    mpSpecReplicas' = 3,
    providerActual' = 3,
    lastReconcile' = OWNER_NONE,
    providerOwnsScale' = false,
    converged' = false,
    oscillated' = false,
  }

  action CapiSetReplicas(n: int): bool = all {
    n >= 0,
    mpSpecReplicas' = n,
    providerActual' = providerActual,
    lastReconcile' = OWNER_CAPI,
    providerOwnsScale' = providerOwnsScale,
    converged' = false,
    oscillated' = if (lastReconcile == OWNER_PROVIDER) true else oscillated,
  }

  action ProviderRebalance(n: int): bool = all {
    n >= 0,
    mpSpecReplicas' = mpSpecReplicas,
    providerActual' = n,
    lastReconcile' = OWNER_PROVIDER,
    providerOwnsScale' = providerOwnsScale,
    converged' = false,
    oscillated' = if (lastReconcile == OWNER_CAPI) true else oscillated,
  }

  // Safe regime: both sides have agreed the provider owns scale and CAPI stops forcing spec.
  action AdoptProviderAsSourceOfTruth: bool = all {
    providerOwnsScale,
    mpSpecReplicas' = providerActual,
    providerActual' = providerActual,
    lastReconcile' = OWNER_CAPI,
    providerOwnsScale' = providerOwnsScale,
    converged' = true,
    oscillated' = false,
  }

  action MarkProviderOwnsScale: bool = all {
    providerOwnsScale' = true,
    mpSpecReplicas' = mpSpecReplicas,
    providerActual' = providerActual,
    lastReconcile' = lastReconcile,
    converged' = converged,
    oscillated' = oscillated,
  }

  action step: bool = any {
    init,
    CapiSetReplicas(3),
    CapiSetReplicas(5),
    ProviderRebalance(3),
    ProviderRebalance(5),
    ProviderRebalance(8),
    MarkProviderOwnsScale,
    AdoptProviderAsSourceOfTruth,
  }

  action stepApalache: bool = any {
    CapiSetReplicas(5),
    ProviderRebalance(8),
  }

  val ProviderActualNonNegative = providerActual >= 0

  val LastReconcileIsKnown =
    lastReconcile == OWNER_NONE or lastReconcile == OWNER_CAPI or lastReconcile == OWNER_PROVIDER

  val StableSafetyInvariants = all {
    ProviderActualNonNegative,
    LastReconcileIsKnown,
  }

  val EventualConvergence = converged and mpSpecReplicas == providerActual

  val NoOscillation = not(oscillated)

  run arbitratedScaleRun = init
    .then(MarkProviderOwnsScale)
    .then(ProviderRebalance(8))
    .then(AdoptProviderAsSourceOfTruth)

  run oscillationRun = init
    .then(CapiSetReplicas(5))
    .then(ProviderRebalance(8))

  action oscillationInit: bool = all {
    mpSpecReplicas' = 5,
    providerActual' = 8,
    lastReconcile' = OWNER_PROVIDER,
    providerOwnsScale' = false,
    converged' = false,
    oscillated' = true,
  }
}
