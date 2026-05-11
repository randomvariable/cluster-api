module DryRunSideEffects {

  type SideEffectsDeclaration = NoneDeclared | NoneOnDryRunDeclared | UnknownDeclared
  type ProbeProgress = Idle | DryRunQueued | WebhookInvoked | Completed

  var sideEffectsDeclaration: SideEffectsDeclaration
  var dryRunRequestPending: bool
  var webhookFired: bool
  var actualSideEffectsTriggered: bool
  var probeProgress: ProbeProgress

  action init = all {
    sideEffectsDeclaration' = NoneOnDryRunDeclared,
    dryRunRequestPending' = false,
    webhookFired' = false,
    actualSideEffectsTriggered' = false,
    probeProgress' = Idle,
  }

  action QueueDryRunRequest: bool = all {
    dryRunRequestPending' = true,
    probeProgress' = DryRunQueued,
    sideEffectsDeclaration' = sideEffectsDeclaration,
    webhookFired' = webhookFired,
    actualSideEffectsTriggered' = actualSideEffectsTriggered,
  }

  action WebhookHandlesDryRunSafely: bool = all {
    dryRunRequestPending,
    probeProgress == DryRunQueued,
    webhookFired' = true,
    actualSideEffectsTriggered' = false,
    probeProgress' = WebhookInvoked,
    sideEffectsDeclaration' = sideEffectsDeclaration,
    dryRunRequestPending' = dryRunRequestPending,
  }

  action WebhookFiresExternalCall: bool = all {
    dryRunRequestPending,
    probeProgress == DryRunQueued,
    webhookFired' = true,
    actualSideEffectsTriggered' = true,
    probeProgress' = WebhookInvoked,
    sideEffectsDeclaration' = sideEffectsDeclaration,
    dryRunRequestPending' = dryRunRequestPending,
  }

  action CompleteProbe: bool = all {
    probeProgress == WebhookInvoked,
    probeProgress' = Completed,
    sideEffectsDeclaration' = sideEffectsDeclaration,
    dryRunRequestPending' = false,
    webhookFired' = webhookFired,
    actualSideEffectsTriggered' = actualSideEffectsTriggered,
  }

  action Stutter: bool = all {
    sideEffectsDeclaration' = sideEffectsDeclaration,
    dryRunRequestPending' = dryRunRequestPending,
    webhookFired' = webhookFired,
    actualSideEffectsTriggered' = actualSideEffectsTriggered,
    probeProgress' = probeProgress,
  }

  action step: bool = any {
    QueueDryRunRequest,
    WebhookHandlesDryRunSafely,
    WebhookFiresExternalCall,
    CompleteProbe,
    Stutter,
  }

  action stepApalache: bool = WebhookFiresExternalCall

  val TriggeredSideEffectsRequireWebhookFire =
    actualSideEffectsTriggered implies webhookFired

  val DryRunRequestsTracked =
    dryRunRequestPending implies probeProgress != Idle

  val DryRunHasNoSideEffects =
    not(sideEffectsDeclaration == NoneOnDryRunDeclared and actualSideEffectsTriggered)

  val StableSafetyInvariants = all {
    TriggeredSideEffectsRequireWebhookFire,
    DryRunRequestsTracked,
  }

  run compliantDryRunProbeRun = init
    .then(QueueDryRunRequest)
    .then(WebhookHandlesDryRunSafely)
    .then(CompleteProbe)

  run violatingDryRunProbeRun = init
    .then(QueueDryRunRequest)
    .then(WebhookFiresExternalCall)

  action violatingProbeInit = all {
    sideEffectsDeclaration' = NoneOnDryRunDeclared,
    dryRunRequestPending' = true,
    webhookFired' = false,
    actualSideEffectsTriggered' = false,
    probeProgress' = DryRunQueued,
  }
}
