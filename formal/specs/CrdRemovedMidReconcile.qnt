// Copyright 2026 The Kubernetes Authors.
//
// CrdRemovedMidReconcile.qnt — issue #79 (FM-79).
//
// Operator deletes `cluster.cluster.x-k8s.io` CRD while
// controllers are still running. The controller's watch closes,
// reconcile sees a nil object pointer, manager panics.

module CrdRemovedMidReconcile {

  type CrdState = Installed | Deleted
  type ControllerState = Running | Panicked | GracefulShutdown

  pure val CRDS: Set[str] = Set("Cluster", "Machine", "KCP")

  var crdState: str -> CrdState
  var controllerHandlesCrdMissing: str -> bool
  var managerState: str -> ControllerState

  action init = all {
    crdState' = CRDS.mapBy(_ => Installed),
    controllerHandlesCrdMissing' = CRDS.mapBy(_ => false),
    managerState' = CRDS.mapBy(_ => Running),
  }

  action DeleteCrd(c: str): bool = all {
    CRDS.contains(c),
    crdState.get(c) == Installed,
    crdState' = crdState.put(c, Deleted),
    controllerHandlesCrdMissing' = controllerHandlesCrdMissing,
    managerState' = managerState,
  }

  action MakeControllerRobust(c: str): bool = all {
    CRDS.contains(c),
    controllerHandlesCrdMissing' = controllerHandlesCrdMissing.put(c, true),
    crdState' = crdState,
    managerState' = managerState,
  }

  action ReconcileTick(c: str): bool = all {
    CRDS.contains(c),
    managerState.get(c) == Running,
    val handles = controllerHandlesCrdMissing.get(c)
    val crd = crdState.get(c)
    val newState = if (crd == Installed) Running
                   else if (handles) GracefulShutdown
                   else Panicked
    all {
      managerState' = managerState.put(c, newState),
      crdState' = crdState,
      controllerHandlesCrdMissing' = controllerHandlesCrdMissing,
    }
  }

  action step = any {
    nondet c = CRDS.oneOf(); DeleteCrd(c),
    nondet c = CRDS.oneOf(); MakeControllerRobust(c),
    nondet c = CRDS.oneOf(); ReconcileTick(c),
  }

  // Positive invariant: no controller is in the Panicked state.
  val ControllerHandlesCrdMissing =
    CRDS.forall(c => managerState.get(c) != Panicked)

  // Counterexample run: delete the Cluster CRD with the controller
  // unprepared, the next reconcile tick panics.
  run controllerPanicsRun = init
    .then(DeleteCrd("Cluster"))
    .then(ReconcileTick("Cluster"))
    // managerState["Cluster"] = Panicked.

  // Recovery: controller has the missing-CRD guard installed first.
  run gracefulShutdownRun = init
    .then(MakeControllerRobust("Cluster"))
    .then(DeleteCrd("Cluster"))
    .then(ReconcileTick("Cluster"))
    // managerState["Cluster"] = GracefulShutdown.
}
