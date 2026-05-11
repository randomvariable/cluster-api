module ConntrackExhaustion {

  pure val TABLE_SIZE: int = 4
  pure val SAFE_CHURN: int = 1
  pure val BURST_CHURN: int = 3

  var conntrackOccupancy: int
  var churnRate: int
  var newConnDropped: bool
  var kubeletTimedOut: bool

  action init = all {
    conntrackOccupancy' = 0,
    churnRate' = SAFE_CHURN,
    newConnDropped' = false,
    kubeletTimedOut' = false,
  }

  action RaiseChurn(rateValue: int): bool = all {
    rateValue >= 0,
    churnRate' = rateValue,
    conntrackOccupancy' = conntrackOccupancy,
    newConnDropped' = newConnDropped,
    kubeletTimedOut' = kubeletTimedOut,
  }

  action ConnEstablish: bool = all {
    conntrackOccupancy < TABLE_SIZE,
    conntrackOccupancy' = conntrackOccupancy + churnRate,
    churnRate' = churnRate,
    newConnDropped' = newConnDropped,
    kubeletTimedOut' = kubeletTimedOut,
  }

  action ConnExpire: bool = all {
    conntrackOccupancy > 0,
    conntrackOccupancy' = if (conntrackOccupancy - SAFE_CHURN >= 0) conntrackOccupancy - SAFE_CHURN else 0,
    churnRate' = churnRate,
    newConnDropped' = newConnDropped,
    kubeletTimedOut' = kubeletTimedOut,
  }

  action ConnDropOnExhaustion: bool = all {
    conntrackOccupancy >= TABLE_SIZE,
    newConnDropped' = true,
    conntrackOccupancy' = conntrackOccupancy,
    churnRate' = churnRate,
    kubeletTimedOut' = kubeletTimedOut,
  }

  action KubeletRequestTimesOut: bool = all {
    newConnDropped,
    kubeletTimedOut' = true,
    conntrackOccupancy' = conntrackOccupancy,
    churnRate' = churnRate,
    newConnDropped' = newConnDropped,
  }

  action step = any {
    nondet r = Set(SAFE_CHURN, BURST_CHURN).oneOf(); RaiseChurn(r),
    ConnEstablish,
    ConnExpire,
    ConnDropOnExhaustion,
    KubeletRequestTimesOut,
  }

  action stepApalache = any {
    RaiseChurn(BURST_CHURN),
    ConnEstablish,
    ConnDropOnExhaustion,
    KubeletRequestTimesOut,
  }

  val OccupancyBounded = conntrackOccupancy >= 0 and conntrackOccupancy <= TABLE_SIZE + BURST_CHURN
  val ExpiryNeverIncreasesOccupancy = conntrackOccupancy >= 0

  val StableSafetyInvariants = all {
    OccupancyBounded,
    ExpiryNeverIncreasesOccupancy,
  }

  val EventualConvergence = not(kubeletTimedOut)

  run boundedChurnRun = init
    .then(RaiseChurn(SAFE_CHURN))
    .then(ConnEstablish)
    .then(ConnExpire)
    .then(ConnEstablish)

  run tableFullRun = init
    .then(RaiseChurn(BURST_CHURN))
    .then(ConnEstablish)
    .then(ConnEstablish)
    .then(ConnDropOnExhaustion)
    .then(KubeletRequestTimesOut)

  action tableFullInit = all {
    conntrackOccupancy' = TABLE_SIZE,
    churnRate' = BURST_CHURN,
    newConnDropped' = true,
    kubeletTimedOut' = true,
  }
}
