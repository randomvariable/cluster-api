module AutoscalerKcpSurgeRace {

  // Standalone autoscaler + KCP rollout surge race model for issue #87.
  //
  // Grounding:
  //   * api/core/v1beta1/cluster_types.go (autoscaler-managed replica hint)
  //   * internal/controllers/machinedeployment/mdutil/util.go (replicas + maxSurge)
  //   * internal/controllers/machinedeployment/machinedeployment_rollout_rollingupdate.go
  //
  // We keep three counters:
  //   autoscalerDesired: desired worker replicas from cluster-autoscaler
  //   kcpDesired:        desired worker replicas from the rollout path
  //   mdReplicas:        actual machine count currently present
  //
  // The safe regime serialises those intents. The bad regime allows both
  // scale-up sources to act before arbitration, temporarily exceeding the
  // intended replicas + surge envelope.

  pure val BASE_REPLICAS: int = 3
  pure val AUTOSCALER_TARGET: int = 8
  pure val MAX_SURGE: int = 1

  var autoscalerDesired: int
  var kcpDesired: int
  var mdReplicas: int
  var autoscalerIntent: bool
  var kcpIntent: bool
  var arbitrated: bool
  var staleAutoscalerIntent: bool

  action init: bool = all {
    autoscalerDesired' = BASE_REPLICAS,
    kcpDesired' = BASE_REPLICAS,
    mdReplicas' = BASE_REPLICAS,
    autoscalerIntent' = false,
    kcpIntent' = false,
    arbitrated' = true,
    staleAutoscalerIntent' = false,
  }

  action AutoscalerSetReplicas: bool = all {
    not(autoscalerIntent),
    autoscalerDesired' = AUTOSCALER_TARGET,
    autoscalerIntent' = true,
    staleAutoscalerIntent' = false,
    arbitrated' = false,
    kcpDesired' = kcpDesired,
    kcpIntent' = kcpIntent,
    mdReplicas' = mdReplicas,
  }

  action KcpUpgradeRoll: bool = all {
    not(kcpIntent),
    kcpDesired' = BASE_REPLICAS + MAX_SURGE,
    kcpIntent' = true,
    arbitrated' = false,
    autoscalerDesired' = autoscalerDesired,
    autoscalerIntent' = autoscalerIntent,
    staleAutoscalerIntent' = staleAutoscalerIntent,
    mdReplicas' = mdReplicas,
  }

  // Reconcile honours the autoscaler target after both intents are visible.
  action ArbitrateToAutoscaler: bool = all {
    autoscalerIntent and kcpIntent,
    autoscalerDesired == AUTOSCALER_TARGET,
    autoscalerDesired' = autoscalerDesired,
    kcpDesired' = autoscalerDesired + MAX_SURGE,
    arbitrated' = true,
    autoscalerIntent' = autoscalerIntent,
    kcpIntent' = kcpIntent,
    staleAutoscalerIntent' = staleAutoscalerIntent,
    mdReplicas' = mdReplicas,
  }

  // Bad path: rollout uses stale autoscaler state and scales on top of the
  // pre-arbitrated autoscaler increase.
  action PreserveStaleAutoscalerIntent: bool = all {
    autoscalerIntent and kcpIntent and not(arbitrated),
    staleAutoscalerIntent' = true,
    autoscalerDesired' = autoscalerDesired,
    kcpDesired' = kcpDesired,
    mdReplicas' = mdReplicas,
    autoscalerIntent' = autoscalerIntent,
    kcpIntent' = kcpIntent,
    arbitrated' = arbitrated,
  }

  action ApplyAutoscalerScale: bool = all {
    autoscalerIntent,
    mdReplicas < autoscalerDesired,
    mdReplicas' = mdReplicas + 1,
    autoscalerDesired' = autoscalerDesired,
    kcpDesired' = kcpDesired,
    autoscalerIntent' = autoscalerIntent,
    kcpIntent' = kcpIntent,
    arbitrated' = arbitrated,
    staleAutoscalerIntent' = staleAutoscalerIntent,
  }

  action ApplyRolloutSurge: bool = all {
    kcpIntent,
    mdReplicas < kcpDesired,
    mdReplicas' = mdReplicas + 1,
    autoscalerDesired' = autoscalerDesired,
    kcpDesired' = kcpDesired,
    autoscalerIntent' = autoscalerIntent,
    kcpIntent' = kcpIntent,
    arbitrated' = arbitrated,
    staleAutoscalerIntent' = staleAutoscalerIntent,
  }

  action step: bool = any {
    init,
    AutoscalerSetReplicas,
    KcpUpgradeRoll,
    ArbitrateToAutoscaler,
    PreserveStaleAutoscalerIntent,
    ApplyAutoscalerScale,
    ApplyRolloutSurge,
  }

  action stepApalache: bool = any {
    AutoscalerSetReplicas,
    KcpUpgradeRoll,
    PreserveStaleAutoscalerIntent,
    ApplyAutoscalerScale,
    ApplyRolloutSurge,
  }

  val StableSafetyInvariants = all {
    ActualReplicasWithinDomain,
    LastWriterOwnsIntent,
  }

  val ActualReplicasWithinDomain =
    mdReplicas >= BASE_REPLICAS and mdReplicas <= AUTOSCALER_TARGET + MAX_SURGE + 2

  val LastWriterOwnsIntent =
    staleAutoscalerIntent implies (autoscalerIntent and kcpIntent)

  val AutoscalerKcpArbitrated =
    arbitrated and autoscalerDesired == AUTOSCALER_TARGET and kcpDesired == AUTOSCALER_TARGET + MAX_SURGE

  val SurgeBoundUnderConcurrentScale =
    mdReplicas <= autoscalerDesired + MAX_SURGE

  run serializedScaleRollRun = init
    .then(AutoscalerSetReplicas)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(KcpUpgradeRoll)
    .then(ArbitrateToAutoscaler)
    .then(ApplyRolloutSurge)

  run concurrentScaleRollRun = init
    .then(AutoscalerSetReplicas)
    .then(KcpUpgradeRoll)
    .then(PreserveStaleAutoscalerIntent)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyAutoscalerScale)
    .then(ApplyRolloutSurge)

  action concurrentScaleInit: bool = all {
    autoscalerDesired' = AUTOSCALER_TARGET,
    kcpDesired' = BASE_REPLICAS + MAX_SURGE,
    mdReplicas' = AUTOSCALER_TARGET,
    autoscalerIntent' = true,
    kcpIntent' = true,
    arbitrated' = false,
    staleAutoscalerIntent' = true,
  }
}
