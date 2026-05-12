module IpamExhaustion {

  // Standalone subnet/IPAM exhaustion model for issue #58.
  //
  // Grounding:
  //   * api/ipam/v1beta2/ipaddressclaim_types.go:25-40
  //   * internal/controllers/machine/machine_controller_status.go:167-255
  //   * internal/controllers/cluster/cluster_controller_status.go
  //
  // The model keeps one subnet capacity, one currently used count, one
  // pending InfraMachine/IP claim request, and whether the exhaustion has
  // surfaced to the operator through a higher-level condition.

  pure val CAPACITY = 3

  var subnetCapacity: int
  var subnetUsed: int
  var requestPending: bool
  var infraReady: bool
  var retryCount: int
  var exhaustionSurfaced: bool

  action init = all {
    subnetCapacity' = CAPACITY,
    subnetUsed' = CAPACITY,
    requestPending' = true,
    infraReady' = false,
    retryCount' = 0,
    exhaustionSurfaced' = false,
  }

  action RequestIp: bool = all {
    requestPending,
    subnetUsed < subnetCapacity,
    subnetUsed' = subnetUsed + 1,
    requestPending' = false,
    infraReady' = true,
    retryCount' = retryCount,
    exhaustionSurfaced' = exhaustionSurfaced,
    subnetCapacity' = subnetCapacity,
  }

  action IpExhaustedRetry: bool = all {
    requestPending,
    subnetUsed >= subnetCapacity,
    subnetCapacity' = subnetCapacity,
    subnetUsed' = subnetUsed,
    requestPending' = true,
    infraReady' = false,
    retryCount' = retryCount + 1,
    exhaustionSurfaced' = exhaustionSurfaced,
  }

  action SurfaceExhaustion: bool = all {
    requestPending,
    subnetUsed >= subnetCapacity,
    subnetCapacity' = subnetCapacity,
    subnetUsed' = subnetUsed,
    requestPending' = requestPending,
    infraReady' = infraReady,
    retryCount' = retryCount,
    exhaustionSurfaced' = true,
  }

  action AddSubnetCapacity: bool = all {
    subnetCapacity' = subnetCapacity + 1,
    subnetUsed' = subnetUsed,
    requestPending' = requestPending,
    infraReady' = infraReady,
    retryCount' = retryCount,
    exhaustionSurfaced' = false,
  }

  action step = any {
    RequestIp,
    IpExhaustedRetry,
    SurfaceExhaustion,
    AddSubnetCapacity,
  }

  action stepApalache = any {
    IpExhaustedRetry,
    SurfaceExhaustion,
  }

  val UsedNeverExceedsCapacity =
    subnetUsed <= subnetCapacity

  val ExhaustionConditionNeedsFullSubnet =
    exhaustionSurfaced implies subnetUsed >= subnetCapacity

  val StableSafetyInvariants = all {
    UsedNeverExceedsCapacity,
    ExhaustionConditionNeedsFullSubnet,
  }

  val IpExhaustionEventuallySurfaced =
    exhaustionSurfaced

  val NoSilentInfiniteRetry =
    not(requestPending and subnetUsed >= subnetCapacity and retryCount >= 2 and not(exhaustionSurfaced))

  run exhaustionSurfacedRun =
    init
      .then(IpExhaustedRetry)
      .then(SurfaceExhaustion)

  run silentRetryRun =
    init
      .then(IpExhaustedRetry)
      .then(IpExhaustedRetry)

  action silentRetryInit = all {
    subnetCapacity' = CAPACITY,
    subnetUsed' = CAPACITY,
    requestPending' = true,
    infraReady' = false,
    retryCount' = 2,
    exhaustionSurfaced' = false,
  }
}
