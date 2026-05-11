module WebhookSelfReference {

  type WebhookPodPhase = Ready | Restarting | Unavailable
  type FailurePolicy = Fail | Ignore
  type UpgradeProgress = NotStarted | WaitingOnAdmission | Applied | Completed

  var webhookPodPhase: WebhookPodPhase
  var failurePolicy: FailurePolicy
  var upgradeProgress: UpgradeProgress
  var invalidMutationPending: bool
  var invalidMutationApplied: bool
  var safeFallbackActive: bool

  action init = all {
    webhookPodPhase' = Ready,
    failurePolicy' = Fail,
    upgradeProgress' = NotStarted,
    invalidMutationPending' = false,
    invalidMutationApplied' = false,
    safeFallbackActive' = false,
  }

  action StartUpgrade: bool = all {
    upgradeProgress == NotStarted,
    upgradeProgress' = WaitingOnAdmission,
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action WebhookPodRestart: bool = all {
    webhookPodPhase == Ready,
    webhookPodPhase' = Restarting,
    upgradeProgress' = upgradeProgress,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action WebhookPodUnavailable: bool = all {
    webhookPodPhase == Restarting,
    webhookPodPhase' = Unavailable,
    upgradeProgress' = upgradeProgress,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action WebhookPodReadyAgain: bool = all {
    webhookPodPhase == Restarting or webhookPodPhase == Unavailable,
    webhookPodPhase' = Ready,
    upgradeProgress' = upgradeProgress,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action SetFailurePolicyIgnore: bool = all {
    failurePolicy == Fail,
    failurePolicy' = Ignore,
    webhookPodPhase' = webhookPodPhase,
    upgradeProgress' = upgradeProgress,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action ActivateSafeFallback: bool = all {
    upgradeProgress == WaitingOnAdmission,
    webhookPodPhase == Unavailable,
    safeFallbackActive' = true,
    upgradeProgress' = upgradeProgress,
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
  }

  action QueueInvalidMutation: bool = all {
    upgradeProgress == WaitingOnAdmission,
    invalidMutationPending' = true,
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    upgradeProgress' = upgradeProgress,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action UpgradeStepRequiresAdmission: bool = all {
    upgradeProgress == WaitingOnAdmission,
    (webhookPodPhase == Ready) or safeFallbackActive or failurePolicy == Ignore,
    upgradeProgress' = Applied,
    invalidMutationApplied' = invalidMutationApplied or (invalidMutationPending and failurePolicy == Ignore),
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    safeFallbackActive' = safeFallbackActive,
  }

  action CompleteUpgrade: bool = all {
    upgradeProgress == Applied,
    upgradeProgress' = Completed,
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action FailClosedDeadlock: bool = all {
    upgradeProgress == WaitingOnAdmission,
    webhookPodPhase == Unavailable,
    failurePolicy == Fail,
    not(safeFallbackActive),
    upgradeProgress' = WaitingOnAdmission,
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action Stutter: bool = all {
    webhookPodPhase' = webhookPodPhase,
    failurePolicy' = failurePolicy,
    upgradeProgress' = upgradeProgress,
    invalidMutationPending' = invalidMutationPending,
    invalidMutationApplied' = invalidMutationApplied,
    safeFallbackActive' = safeFallbackActive,
  }

  action step: bool = any {
    StartUpgrade,
    WebhookPodRestart,
    WebhookPodUnavailable,
    WebhookPodReadyAgain,
    SetFailurePolicyIgnore,
    ActivateSafeFallback,
    QueueInvalidMutation,
    UpgradeStepRequiresAdmission,
    CompleteUpgrade,
    FailClosedDeadlock,
    Stutter,
  }

  action stepApalache: bool = any {
    StartUpgrade,
    WebhookPodRestart,
    WebhookPodUnavailable,
    FailClosedDeadlock,
    Stutter,
  }

  val RestartImpliesUnavailable =
    webhookPodPhase == Restarting implies upgradeProgress != Completed

  val IgnoreWindowRequiresIgnorePolicy =
    invalidMutationApplied implies failurePolicy == Ignore

  val UpgradeProgressDespiteWebhookGap =
    upgradeProgress != WaitingOnAdmission or webhookPodPhase == Ready or safeFallbackActive or failurePolicy == Ignore

  val NoInvalidMutationDuringIgnoreWindow =
    not(invalidMutationApplied)

  val StableSafetyInvariants = all {
    IgnoreWindowRequiresIgnorePolicy,
  }

  run safeFallbackRun = init
    .then(StartUpgrade)
    .then(WebhookPodRestart)
    .then(WebhookPodUnavailable)
    .then(ActivateSafeFallback)
    .then(UpgradeStepRequiresAdmission)
    .then(CompleteUpgrade)

  run failClosedDeadlockRun = init
    .then(StartUpgrade)
    .then(WebhookPodRestart)
    .then(WebhookPodUnavailable)
    .then(FailClosedDeadlock)

  run ignoreWindowInvalidMutationRun = init
    .then(StartUpgrade)
    .then(SetFailurePolicyIgnore)
    .then(QueueInvalidMutation)
    .then(UpgradeStepRequiresAdmission)
}
