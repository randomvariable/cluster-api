module RegistryPullBackoff {
  type RateLimit = Open | Throttled

  var registryRateLimit: RateLimit
  var pullAttempts: str -> int
  var pullBackoffUntil: str -> int
  var now: int
  var bootstrapTimeoutAt: int
  var controlPlaneInitialised: bool
  var bootstrapFailed: bool
  var imagePulled: str -> bool

  pure val API_SERVER_IMAGE: str = "kube-apiserver"
  pure val INITIAL_TIMEOUT: int = 6

  action init = all {
    registryRateLimit' = Open,
    pullAttempts' = Set(API_SERVER_IMAGE).mapBy(_ => 0),
    pullBackoffUntil' = Set(API_SERVER_IMAGE).mapBy(_ => 0),
    now' = 0,
    bootstrapTimeoutAt' = INITIAL_TIMEOUT,
    controlPlaneInitialised' = false,
    bootstrapFailed' = false,
    imagePulled' = Set(API_SERVER_IMAGE).mapBy(_ => false),
  }

  action Tick: bool = all {
    now' = now + 1,
    registryRateLimit' = registryRateLimit,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action RegistryThrottle: bool = all {
    registryRateLimit' = Throttled,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action RegistryOpen: bool = all {
    registryRateLimit' = Open,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action KubeletRetryPull(img: str): bool = all {
    not(imagePulled.get(img)),
    now >= pullBackoffUntil.get(img),
    pullAttempts' = pullAttempts.put(img, pullAttempts.get(img) + 1),
    pullBackoffUntil' = pullBackoffUntil.put(img, now + pullAttempts.get(img) + 1),
    registryRateLimit' = registryRateLimit,
    now' = now,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action PullImageSuccess(img: str): bool = all {
    registryRateLimit == Open,
    not(imagePulled.get(img)),
    now >= pullBackoffUntil.get(img),
    imagePulled' = imagePulled.put(img, true),
    registryRateLimit' = registryRateLimit,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
  }

  action MarkControlPlaneInitialised: bool = all {
    imagePulled.get(API_SERVER_IMAGE),
    not(controlPlaneInitialised),
    controlPlaneInitialised' = true,
    registryRateLimit' = registryRateLimit,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action BootstrapTimeout: bool = all {
    not(controlPlaneInitialised),
    now >= bootstrapTimeoutAt,
    bootstrapFailed' = true,
    registryRateLimit' = registryRateLimit,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    imagePulled' = imagePulled,
  }

  action Stutter: bool = all {
    registryRateLimit' = registryRateLimit,
    now' = now,
    pullAttempts' = pullAttempts,
    pullBackoffUntil' = pullBackoffUntil,
    bootstrapTimeoutAt' = bootstrapTimeoutAt,
    controlPlaneInitialised' = controlPlaneInitialised,
    bootstrapFailed' = bootstrapFailed,
    imagePulled' = imagePulled,
  }

  action step: bool = any {
    Tick,
    RegistryThrottle,
    RegistryOpen,
    KubeletRetryPull(API_SERVER_IMAGE),
    PullImageSuccess(API_SERVER_IMAGE),
    MarkControlPlaneInitialised,
    BootstrapTimeout,
    Stutter,
  }

  action stepApalache: bool = any {
    KubeletRetryPull(API_SERVER_IMAGE),
    BootstrapTimeout,
    Stutter,
  }

  action stepHappy: bool = any {
    Tick,
    RegistryThrottle,
    RegistryOpen,
    KubeletRetryPull(API_SERVER_IMAGE),
    PullImageSuccess(API_SERVER_IMAGE),
    MarkControlPlaneInitialised,
    Stutter,
  }

  val BackoffMonotone =
    pullAttempts.get(API_SERVER_IMAGE) >= 0 and pullBackoffUntil.get(API_SERVER_IMAGE) >= 0

  val FailedBootstrapNotInitialised =
    bootstrapFailed implies not(controlPlaneInitialised)

  val StableSafetyInvariants = all {
    BackoffMonotone,
  }

  val NoFalseBootstrapFailure =
    bootstrapFailed implies not(controlPlaneInitialised)

  val BootstrapTimeoutAccountsForBackoff =
    bootstrapTimeoutAt > pullBackoffUntil.get(API_SERVER_IMAGE)

  run boundedThrottleRun = init
    .then(RegistryThrottle)
    .then(KubeletRetryPull(API_SERVER_IMAGE))
    .then(Tick)
    .then(RegistryOpen)
    .then(Tick)
    .then(PullImageSuccess(API_SERVER_IMAGE))
    .then(MarkControlPlaneInitialised)

  run timeoutBeforePullClearsRun = init
    .then(RegistryThrottle)
    .then(KubeletRetryPull(API_SERVER_IMAGE))
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(BootstrapTimeout)

  action timeoutInit = all {
    registryRateLimit' = Throttled,
    pullAttempts' = Set(API_SERVER_IMAGE).mapBy(_ => 2),
    pullBackoffUntil' = Set(API_SERVER_IMAGE).mapBy(_ => INITIAL_TIMEOUT + 2),
    now' = INITIAL_TIMEOUT,
    bootstrapTimeoutAt' = INITIAL_TIMEOUT,
    controlPlaneInitialised' = false,
    bootstrapFailed' = false,
    imagePulled' = Set(API_SERVER_IMAGE).mapBy(_ => false),
  }
}
