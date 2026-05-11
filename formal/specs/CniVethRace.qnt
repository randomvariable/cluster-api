module CniVethRace {

  type VethState = Missing | Ready
  type ProbeState = NotRun | FailedOnce | FailedLoop

  var veth: VethState
  var containerStarted: bool
  var probeState: ProbeState
  var restartCount: int
  var cniApplied: bool

  action init = all {
    veth' = Missing,
    containerStarted' = false,
    probeState' = NotRun,
    restartCount' = 0,
    cniApplied' = false,
  }

  action ApplyCni: bool = all {
    not(cniApplied),
    cniApplied' = true,
    veth' = veth,
    containerStarted' = containerStarted,
    probeState' = probeState,
    restartCount' = restartCount,
  }

  action KubeletStartContainer: bool = all {
    not(containerStarted),
    containerStarted' = true,
    veth' = veth,
    probeState' = probeState,
    restartCount' = restartCount,
    cniApplied' = cniApplied,
  }

  action CniCreateVeth: bool = all {
    cniApplied,
    veth == Missing,
    veth' = Ready,
    containerStarted' = containerStarted,
    probeState' = probeState,
    restartCount' = restartCount,
    cniApplied' = cniApplied,
  }

  action ProbeFails: bool = all {
    containerStarted,
    veth == Missing,
    probeState' =
      if (probeState == NotRun) FailedOnce else FailedLoop,
    restartCount' = restartCount + 1,
    containerStarted' = false,
    veth' = veth,
    cniApplied' = cniApplied,
  }

  action ProbeSucceeds: bool = all {
    containerStarted,
    veth == Ready,
    probeState' = probeState,
    restartCount' = restartCount,
    containerStarted' = containerStarted,
    veth' = veth,
    cniApplied' = cniApplied,
  }

  action RestartContainer: bool = all {
    not(containerStarted),
    probeState != NotRun,
    containerStarted' = true,
    veth' = veth,
    probeState' = probeState,
    restartCount' = restartCount,
    cniApplied' = cniApplied,
  }

  action step = any {
    ApplyCni,
    KubeletStartContainer,
    CniCreateVeth,
    ProbeFails,
    ProbeSucceeds,
    RestartContainer,
  }

  action stepApalache = any {
    KubeletStartContainer,
    ProbeFails,
    RestartContainer,
    ProbeFails,
  }

  val VethRequiresCni =
    veth == Ready implies cniApplied

  val RestartLoopRequiresRepeatedProbeFailure =
    probeState == FailedLoop implies restartCount >= 2

  val StableSafetyInvariants = all {
    VethRequiresCni,
    RestartLoopRequiresRepeatedProbeFailure,
  }

  val NoContainerStartBeforeCni =
    not(containerStarted) or veth == Ready

  run cniReadyBeforeProbeRun = init
    .then(ApplyCni)
    .then(CniCreateVeth)
    .then(KubeletStartContainer)
    .then(ProbeSucceeds)

  run probeLoopBeforeVethRun = init
    .then(KubeletStartContainer)
    .then(ProbeFails)
    .then(RestartContainer)
    .then(ProbeFails)

  action probeLoopInit = all {
    veth' = Missing,
    containerStarted' = true,
    probeState' = FailedOnce,
    restartCount' = 1,
    cniApplied' = false,
  }
}
