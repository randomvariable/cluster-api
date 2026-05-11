module ClusterResourceSetTiming {

  // Standalone ClusterResourceSet timing model for issue #85.
  //
  // Grounding:
  //   * internal/controllers/clusterresourceset/clusterresourceset_controller.go:292-447
  //   * internal/controllers/clusterresourceset/clusterresourceset_scope.go:81-87
  //   * internal/controllers/topology/cluster/cluster_controller.go:354
  //
  // ClusterResourceSet `ApplyOnce` can treat control-plane init as
  // sufficient readiness even when kubelets have not joined yet. A Pod-ish
  // payload may then be applied exactly once, fail to take effect, and be
  // abandoned. `Reconcile` is the contrasting mode that retries.

  pure val APPLY_ONCE = "ApplyOnce"
  pure val RECONCILE = "Reconcile"

  var controlPlaneInitialised: bool
  var kubeletsJoined: bool
  var strategy: str
  var payloadPending: bool
  var crsApplied: bool
  var payloadEffective: bool
  var retriesOutstanding: int

  action init: bool = all {
    controlPlaneInitialised' = false,
    kubeletsJoined' = false,
    strategy' = APPLY_ONCE,
    payloadPending' = true,
    crsApplied' = false,
    payloadEffective' = false,
    retriesOutstanding' = 0,
  }

  action MarkControlPlaneInitialised: bool = all {
    not(controlPlaneInitialised),
    controlPlaneInitialised' = true,
    kubeletsJoined' = kubeletsJoined,
    strategy' = strategy,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
    payloadEffective' = payloadEffective,
    retriesOutstanding' = retriesOutstanding,
  }

  action KubeletsJoin: bool = all {
    not(kubeletsJoined),
    kubeletsJoined' = true,
    controlPlaneInitialised' = controlPlaneInitialised,
    strategy' = strategy,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
    payloadEffective' = payloadEffective,
    retriesOutstanding' = retriesOutstanding,
  }

  action UseApplyOnce: bool = all {
    strategy != APPLY_ONCE,
    strategy' = APPLY_ONCE,
    controlPlaneInitialised' = controlPlaneInitialised,
    kubeletsJoined' = kubeletsJoined,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
    payloadEffective' = payloadEffective,
    retriesOutstanding' = retriesOutstanding,
  }

  action UseReconcile: bool = all {
    strategy != RECONCILE,
    strategy' = RECONCILE,
    controlPlaneInitialised' = controlPlaneInitialised,
    kubeletsJoined' = kubeletsJoined,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
    payloadEffective' = payloadEffective,
    retriesOutstanding' = retriesOutstanding,
  }

  action CrsApplyOnInit: bool = all {
    controlPlaneInitialised,
    payloadPending,
    not(crsApplied),
    crsApplied' = true,
    payloadPending' = false,
    payloadEffective' = kubeletsJoined,
    retriesOutstanding' = if (kubeletsJoined or strategy == APPLY_ONCE) 0 else 1,
    controlPlaneInitialised' = controlPlaneInitialised,
    kubeletsJoined' = kubeletsJoined,
    strategy' = strategy,
  }

  action RequeueApplyUntilJoined: bool = all {
    strategy == RECONCILE,
    retriesOutstanding > 0,
    not(payloadEffective),
    retriesOutstanding' = retriesOutstanding + 1,
    payloadEffective' = kubeletsJoined,
    controlPlaneInitialised' = controlPlaneInitialised,
    kubeletsJoined' = kubeletsJoined,
    strategy' = strategy,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
  }

  action ObserveEffect: bool = all {
    crsApplied,
    kubeletsJoined,
    not(payloadEffective),
    payloadEffective' = true,
    retriesOutstanding' = 0,
    controlPlaneInitialised' = controlPlaneInitialised,
    kubeletsJoined' = kubeletsJoined,
    strategy' = strategy,
    payloadPending' = payloadPending,
    crsApplied' = crsApplied,
  }

  action step: bool = any {
    MarkControlPlaneInitialised,
    KubeletsJoin,
    UseApplyOnce,
    UseReconcile,
    CrsApplyOnInit,
    RequeueApplyUntilJoined,
    ObserveEffect,
  }

  val ApplyOnceRequiresPendingPayload =
    crsApplied implies not(payloadPending)

  val ReconcileRetriesUntilJoined =
    strategy == RECONCILE and crsApplied and not(payloadEffective)
      implies retriesOutstanding >= 0

  val StableSafetyInvariants = all {
    ApplyOnceRequiresPendingPayload,
    ReconcileRetriesUntilJoined,
  }

  val ApplyOnceEventuallyTakesEffect = payloadEffective

  action stepApalache: bool = any {
    CrsApplyOnInit,
    KubeletsJoin,
    ObserveEffect,
  }

  run joinsBeforeApplyRun = init
    .then(MarkControlPlaneInitialised)
    .then(KubeletsJoin)
    .then(CrsApplyOnInit)

  run applyBeforeJoinRun = init
    .then(MarkControlPlaneInitialised)
    .then(CrsApplyOnInit)

  action applyBeforeJoinInit: bool = all {
    controlPlaneInitialised' = true,
    kubeletsJoined' = false,
    strategy' = APPLY_ONCE,
    payloadPending' = false,
    crsApplied' = true,
    payloadEffective' = false,
    retriesOutstanding' = 0,
  }
}
