module LoadBalancerDrain {

  type TargetReg = Registered | Deregistered

  var targetReg: TargetReg
  var lbDrainProgress: int
  var apiserverAlive: bool
  var clientHung: bool

  pure val FULL_DRAIN: int = 2

  action init = all {
    targetReg' = Registered,
    lbDrainProgress' = 0,
    apiserverAlive' = true,
    clientHung' = false,
  }

  action LbDeregisterTarget: bool = all {
    targetReg == Registered,
    targetReg' = Deregistered,
    lbDrainProgress' = lbDrainProgress,
    apiserverAlive' = apiserverAlive,
    clientHung' = clientHung,
  }

  action LbDrainComplete: bool = all {
    targetReg == Deregistered,
    lbDrainProgress < FULL_DRAIN,
    lbDrainProgress' = lbDrainProgress + 1,
    targetReg' = targetReg,
    apiserverAlive' = apiserverAlive,
    clientHung' = clientHung,
  }

  action KillApiserverPod: bool = all {
    apiserverAlive,
    apiserverAlive' = false,
    targetReg' = targetReg,
    lbDrainProgress' = lbDrainProgress,
    clientHung' = clientHung,
  }

  action ClientHangsOnDereg: bool = all {
    targetReg == Deregistered,
    lbDrainProgress < FULL_DRAIN,
    not(apiserverAlive),
    clientHung' = true,
    targetReg' = targetReg,
    lbDrainProgress' = lbDrainProgress,
    apiserverAlive' = apiserverAlive,
  }

  action ClientRecovers: bool = all {
    clientHung,
    lbDrainProgress >= FULL_DRAIN or apiserverAlive,
    clientHung' = false,
    targetReg' = targetReg,
    lbDrainProgress' = lbDrainProgress,
    apiserverAlive' = apiserverAlive,
  }

  action step = any {
    LbDeregisterTarget,
    LbDrainComplete,
    KillApiserverPod,
    ClientHangsOnDereg,
    ClientRecovers,
  }

  action stepApalache = any {
    LbDeregisterTarget,
    KillApiserverPod,
    ClientHangsOnDereg,
  }

  val DrainProgressMonotone =
    lbDrainProgress >= 0 and lbDrainProgress <= FULL_DRAIN

  val HungClientNeedsDeregisteredTarget =
    clientHung implies targetReg == Deregistered

  val StableSafetyInvariants = all {
    DrainProgressMonotone,
    HungClientNeedsDeregisteredTarget,
  }

  val KcpUpgradeAccountsForLbDrain =
    apiserverAlive or lbDrainProgress >= FULL_DRAIN or not(clientHung)

  run drainBeforeKillRun = init
    .then(LbDeregisterTarget)
    .then(LbDrainComplete)
    .then(LbDrainComplete)
    .then(KillApiserverPod)

  run killBeforeDrainRun = init
    .then(LbDeregisterTarget)
    .then(KillApiserverPod)
    .then(ClientHangsOnDereg)

  action killBeforeDrainInit = all {
    targetReg' = Deregistered,
    lbDrainProgress' = 0,
    apiserverAlive' = false,
    clientHung' = true,
  }
}
