module KubeletPlegHang {
  type CriLatency = Fast | Slow
  type NodeReadyState = Ready | Unknown | NotReady

  var criLatency: CriLatency
  var plegLastSeen: int
  var nodeReadyDerivedFromPleg: NodeReadyState
  var mhcObservedNotReady: bool
  var remediationRequested: bool
  var replaced: bool

  pure val PLEG_THRESHOLD: int = 3

  action init = all {
    criLatency' = Fast,
    plegLastSeen' = 0,
    nodeReadyDerivedFromPleg' = Ready,
    mhcObservedNotReady' = false,
    remediationRequested' = false,
    replaced' = false,
  }

  action CriSlowdown: bool = all {
    criLatency' = Slow,
    plegLastSeen' = plegLastSeen,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    mhcObservedNotReady' = mhcObservedNotReady,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action TickPleg: bool = all {
    criLatency == Slow,
    plegLastSeen' = plegLastSeen + 1,
    criLatency' = criLatency,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    mhcObservedNotReady' = mhcObservedNotReady,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action PlegThresholdBreached: bool = all {
    criLatency == Slow,
    plegLastSeen >= PLEG_THRESHOLD,
    nodeReadyDerivedFromPleg' = NotReady,
    criLatency' = criLatency,
    plegLastSeen' = plegLastSeen,
    mhcObservedNotReady' = mhcObservedNotReady,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action MhcFiresOnNotReady: bool = all {
    nodeReadyDerivedFromPleg == NotReady,
    mhcObservedNotReady' = true,
    criLatency' = criLatency,
    plegLastSeen' = plegLastSeen,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action RequestRemediation: bool = all {
    mhcObservedNotReady,
    remediationRequested' = true,
    criLatency' = criLatency,
    plegLastSeen' = plegLastSeen,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    mhcObservedNotReady' = mhcObservedNotReady,
    replaced' = replaced,
  }

  action ReplaceMachine: bool = all {
    remediationRequested,
    replaced' = true,
    criLatency' = criLatency,
    plegLastSeen' = plegLastSeen,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    mhcObservedNotReady' = mhcObservedNotReady,
    remediationRequested' = remediationRequested,
  }

  action CriRecover: bool = all {
    criLatency == Slow,
    criLatency' = Fast,
    plegLastSeen' = 0,
    nodeReadyDerivedFromPleg' = Ready,
    mhcObservedNotReady' = false,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action Stutter: bool = all {
    criLatency' = criLatency,
    plegLastSeen' = plegLastSeen,
    nodeReadyDerivedFromPleg' = nodeReadyDerivedFromPleg,
    mhcObservedNotReady' = mhcObservedNotReady,
    remediationRequested' = remediationRequested,
    replaced' = replaced,
  }

  action step: bool = any {
    CriSlowdown,
    TickPleg,
    PlegThresholdBreached,
    MhcFiresOnNotReady,
    RequestRemediation,
    ReplaceMachine,
    CriRecover,
    Stutter,
  }

  action stepApalache: bool = any {
    PlegThresholdBreached,
    MhcFiresOnNotReady,
    RequestRemediation,
    Stutter,
  }

  val PlegThresholdRequiresSlowCri =
    plegLastSeen >= PLEG_THRESHOLD implies criLatency == Slow or nodeReadyDerivedFromPleg != Ready

  val RecoveryClearsTransientNotReady =
    criLatency == Fast implies plegLastSeen == 0 or nodeReadyDerivedFromPleg != NotReady

  val StableSafetyInvariants = all {
    PlegThresholdRequiresSlowCri,
    RecoveryClearsTransientNotReady,
  }

  val RemediationAfterStableNotReady =
    remediationRequested implies plegLastSeen >= PLEG_THRESHOLD and criLatency == Slow

  run transientRecoveryRun = init
    .then(CriSlowdown)
    .then(TickPleg)
    .then(TickPleg)
    .then(CriRecover)

  run overEagerRemediationRun = init
    .then(CriSlowdown)
    .then(TickPleg)
    .then(TickPleg)
    .then(TickPleg)
    .then(PlegThresholdBreached)
    .then(MhcFiresOnNotReady)
    .then(RequestRemediation)
    .then(CriRecover)

  action slowCriInit = all {
    criLatency' = Slow,
    plegLastSeen' = PLEG_THRESHOLD,
    nodeReadyDerivedFromPleg' = NotReady,
    mhcObservedNotReady' = true,
    remediationRequested' = false,
    replaced' = false,
  }
}
