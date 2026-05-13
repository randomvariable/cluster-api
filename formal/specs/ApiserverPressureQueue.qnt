// Copyright 2026 The Kubernetes Authors.
//
// ApiserverPressureQueue.qnt — issue #91 (FM-91).
//
// kube-apiserver under memory pressure rejects List calls with
// 429. Controllers back off; workqueue depth grows. CPU throttle
// on the controller pod compounds. Queue never drains; memory
// grows; controller-manager OOMs.

module ApiserverPressureQueue {

  pure val QUEUE_OOM_DEPTH: int = 100
  pure val DRAIN_RATE_NORMAL: int = 5
  pure val DRAIN_RATE_THROTTLED: int = 1
  pure val ENQUEUE_RATE: int = 3

  var apiserverMemPressure: bool
  var controllerCpuThrottle: bool
  var workqueueDepth: int
  var controllerOomed: bool

  action init = all {
    apiserverMemPressure' = false,
    controllerCpuThrottle' = false,
    workqueueDepth' = 0,
    controllerOomed' = false,
  }

  action ApiserverReturns429: bool = all {
    not(controllerOomed),
    apiserverMemPressure' = true,
    controllerCpuThrottle' = controllerCpuThrottle,
    workqueueDepth' = workqueueDepth,
    controllerOomed' = controllerOomed,
  }

  action ApiserverRecovers: bool = all {
    apiserverMemPressure,
    apiserverMemPressure' = false,
    controllerCpuThrottle' = controllerCpuThrottle,
    workqueueDepth' = workqueueDepth,
    controllerOomed' = controllerOomed,
  }

  action ControllerCpuThrottleOn: bool = all {
    controllerCpuThrottle' = true,
    apiserverMemPressure' = apiserverMemPressure,
    workqueueDepth' = workqueueDepth,
    controllerOomed' = controllerOomed,
  }

  action ControllerCpuThrottleOff: bool = all {
    controllerCpuThrottle' = false,
    apiserverMemPressure' = apiserverMemPressure,
    workqueueDepth' = workqueueDepth,
    controllerOomed' = controllerOomed,
  }

  action Reconcile: bool = all {
    not(controllerOomed),
    val drain = if (apiserverMemPressure or controllerCpuThrottle)
                  DRAIN_RATE_THROTTLED else DRAIN_RATE_NORMAL
    val net = ENQUEUE_RATE - drain
    val newDepth = if (workqueueDepth + net >= 0) workqueueDepth + net else 0
    all {
      workqueueDepth' = newDepth,
      controllerOomed' = newDepth >= QUEUE_OOM_DEPTH,
      apiserverMemPressure' = apiserverMemPressure,
      controllerCpuThrottle' = controllerCpuThrottle,
    }
  }

  action step = any {
    ApiserverReturns429,
    ApiserverRecovers,
    ControllerCpuThrottleOn,
    ControllerCpuThrottleOff,
    Reconcile,
  }

  val DegradedModeStable = not(controllerOomed)

  // Counterexample: 429 sticks + throttle sticks + repeated reconciles
  // grow the queue past the OOM threshold.
  run controllerOomsRun = init
    .then(ApiserverReturns429)
    .then(ControllerCpuThrottleOn)
    // Each Reconcile adds 2 to depth (3 enqueue - 1 drain).
    // Need 50 reconciles to reach 100. Spec covers it abstractly.
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
    // depth >= 100, controllerOomed = true.

  // Recovery: 429 clears, drain rate normalises, queue shrinks.
  run apiserverRecoversRun = init
    .then(ApiserverReturns429)
    .then(Reconcile).then(Reconcile).then(Reconcile)
    .then(ApiserverRecovers)
    .then(Reconcile).then(Reconcile).then(Reconcile).then(Reconcile)
}
