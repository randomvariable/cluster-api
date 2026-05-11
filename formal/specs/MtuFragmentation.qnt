module MtuFragmentation {
  pure val VXLAN_OVERHEAD: int = 50
  pure val UNDERLAY_MTU: int = 1500
  pure val EFFECTIVE_POD_MTU: int = UNDERLAY_MTU - VXLAN_OVERHEAD

  var linkMtu: int
  var discoveredPmtu: int
  var packetSize: int
  var dfFlag: bool
  var icmpFragNeededVisible: bool
  var packetDelivered: bool
  var snapshotTransferStarted: bool
  var snapshotTransferSucceeded: bool
  var snapshotTransferTimedOut: bool

  action init: bool = all {
    linkMtu' = EFFECTIVE_POD_MTU,
    discoveredPmtu' = UNDERLAY_MTU,
    packetSize' = 1400,
    dfFlag' = true,
    icmpFragNeededVisible' = false,
    packetDelivered' = false,
    snapshotTransferStarted' = false,
    snapshotTransferSucceeded' = false,
    snapshotTransferTimedOut' = false,
  }

  action StartSnapshotTransfer: bool = all {
    not(snapshotTransferStarted),
    snapshotTransferStarted' = true,
    packetSize' = 1490,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    dfFlag' = dfFlag,
    icmpFragNeededVisible' = icmpFragNeededVisible,
    packetDelivered' = packetDelivered,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action LargePacketSent(pktSize: int): bool = all {
    snapshotTransferStarted,
    pktSize > 0,
    packetSize' = pktSize,
    packetDelivered' = false,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    dfFlag' = dfFlag,
    icmpFragNeededVisible' = icmpFragNeededVisible,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action MtuMismatchDrop: bool = all {
    snapshotTransferStarted,
    dfFlag,
    packetSize > linkMtu,
    packetDelivered' = false,
    icmpFragNeededVisible' = true,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    packetSize' = packetSize,
    dfFlag' = dfFlag,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action IcmpFragNeededLost: bool = all {
    snapshotTransferStarted,
    dfFlag,
    packetSize > linkMtu,
    icmpFragNeededVisible,
    icmpFragNeededVisible' = false,
    packetDelivered' = false,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    packetSize' = packetSize,
    dfFlag' = dfFlag,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action LearnPathMtu: bool = all {
    snapshotTransferStarted,
    icmpFragNeededVisible,
    discoveredPmtu > linkMtu,
    discoveredPmtu' = linkMtu,
    packetSize' = linkMtu,
    // Frame
    linkMtu' = linkMtu,
    dfFlag' = dfFlag,
    icmpFragNeededVisible' = icmpFragNeededVisible,
    packetDelivered' = packetDelivered,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action DeliverPacket: bool = all {
    snapshotTransferStarted,
    packetSize <= linkMtu,
    packetDelivered' = true,
    snapshotTransferSucceeded' = true,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    packetSize' = packetSize,
    dfFlag' = dfFlag,
    icmpFragNeededVisible' = icmpFragNeededVisible,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferTimedOut' = snapshotTransferTimedOut,
  }

  action BootstrapTimeout: bool = all {
    snapshotTransferStarted,
    not(snapshotTransferSucceeded),
    snapshotTransferTimedOut' = true,
    // Frame
    linkMtu' = linkMtu,
    discoveredPmtu' = discoveredPmtu,
    packetSize' = packetSize,
    dfFlag' = dfFlag,
    icmpFragNeededVisible' = icmpFragNeededVisible,
    packetDelivered' = packetDelivered,
    snapshotTransferStarted' = snapshotTransferStarted,
    snapshotTransferSucceeded' = snapshotTransferSucceeded,
  }

  action step: bool = any {
    StartSnapshotTransfer,
    LargePacketSent(1490),
    LargePacketSent(1450),
    MtuMismatchDrop,
    IcmpFragNeededLost,
    LearnPathMtu,
    DeliverPacket,
    BootstrapTimeout,
  }

  action stepApalache: bool = any {
    StartSnapshotTransfer,
    LargePacketSent(1490),
    MtuMismatchDrop,
    IcmpFragNeededLost,
    BootstrapTimeout,
  }

  val PmtuNeverExceedsLinkMtu = discoveredPmtu >= linkMtu
  val PacketFitsImpliesDelivery =
    (snapshotTransferStarted and packetSize <= linkMtu and not(snapshotTransferTimedOut))
      implies (packetDelivered or snapshotTransferSucceeded)

  val StableSafetyInvariants = all {
    PmtuNeverExceedsLinkMtu,
  }

  val EtcdSnapshotEventuallySucceeds =
    not(snapshotTransferTimedOut) or snapshotTransferSucceeded

  val PathMtuDiscoveryConverges =
    discoveredPmtu == linkMtu and packetSize <= discoveredPmtu

  run convergedPmtuRun = init
    .then(StartSnapshotTransfer)
    .then(LargePacketSent(1490))
    .then(MtuMismatchDrop)
    .then(LearnPathMtu)
    .then(DeliverPacket)

  run silentFragDropRun = init
    .then(StartSnapshotTransfer)
    .then(LargePacketSent(1490))
    .then(MtuMismatchDrop)
    .then(IcmpFragNeededLost)
    .then(BootstrapTimeout)

  action collisionInit: bool = all {
    linkMtu' = EFFECTIVE_POD_MTU,
    discoveredPmtu' = UNDERLAY_MTU,
    packetSize' = 1490,
    dfFlag' = true,
    icmpFragNeededVisible' = false,
    packetDelivered' = false,
    snapshotTransferStarted' = true,
    snapshotTransferSucceeded' = false,
    snapshotTransferTimedOut' = false,
  }

  action silentFragInit: bool = collisionInit
}
