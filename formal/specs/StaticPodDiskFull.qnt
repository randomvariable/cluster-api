module StaticPodDiskFull {

  pure val LOW_WATERMARK = 10
  pure val API_SERVER = 1

  var diskFreeBytes: int
  var logRate: int
  var rotationHealthy: bool
  var diskPressure: bool
  var staticPodRunning: bool
  var crashLooping: bool
  var remediationRequested: bool

  action init = all {
    diskFreeBytes' = 100,
    logRate' = 25,
    rotationHealthy' = true,
    diskPressure' = false,
    staticPodRunning' = true,
    crashLooping' = false,
    remediationRequested' = false,
  }

  action WriteLogs: bool = all {
    staticPodRunning,
    logRate > 0,
    diskFreeBytes' = if (diskFreeBytes - logRate >= 0) diskFreeBytes - logRate else 0,
    logRate' = logRate,
    rotationHealthy' = rotationHealthy,
    diskPressure' = diskPressure,
    staticPodRunning' = staticPodRunning,
    crashLooping' = crashLooping,
    remediationRequested' = remediationRequested,
  }

  action RotationFailure: bool = all {
    rotationHealthy,
    rotationHealthy' = false,
    diskFreeBytes' = diskFreeBytes,
    logRate' = logRate,
    diskPressure' = diskPressure,
    staticPodRunning' = staticPodRunning,
    crashLooping' = crashLooping,
    remediationRequested' = remediationRequested,
  }

  action EnterDiskPressure: bool = all {
    diskFreeBytes <= LOW_WATERMARK,
    diskPressure' = true,
    diskFreeBytes' = diskFreeBytes,
    logRate' = logRate,
    rotationHealthy' = rotationHealthy,
    staticPodRunning' = staticPodRunning,
    crashLooping' = crashLooping,
    remediationRequested' = remediationRequested,
  }

  action EvictStaticPodOnDiskPressure: bool = all {
    diskPressure,
    staticPodRunning,
    staticPodRunning' = false,
    crashLooping' = true,
    diskFreeBytes' = diskFreeBytes,
    logRate' = logRate,
    rotationHealthy' = rotationHealthy,
    diskPressure' = diskPressure,
    remediationRequested' = remediationRequested,
  }

  action RecoverDisk: bool = all {
    diskPressure,
    diskFreeBytes' = 100,
    diskPressure' = false,
    rotationHealthy' = true,
    staticPodRunning' = true,
    crashLooping' = false,
    logRate' = logRate,
    remediationRequested' = remediationRequested,
  }

  action RequestRemediation: bool = all {
    crashLooping,
    remediationRequested' = true,
    diskFreeBytes' = diskFreeBytes,
    logRate' = logRate,
    rotationHealthy' = rotationHealthy,
    diskPressure' = diskPressure,
    staticPodRunning' = staticPodRunning,
    crashLooping' = crashLooping,
  }

  action step: bool = any {
    WriteLogs,
    RotationFailure,
    EnterDiskPressure,
    EvictStaticPodOnDiskPressure,
    RecoverDisk,
    RequestRemediation,
  }

  action stepApalache: bool = any {
    RotationFailure,
    WriteLogs,
    EnterDiskPressure,
    EvictStaticPodOnDiskPressure,
    RequestRemediation,
  }

  val EvictionImpliesStaticPodCrashloop =
    crashLooping implies not(staticPodRunning)

  val StableSafetyInvariants = all {
    EvictionImpliesStaticPodCrashloop,
  }

  val KcpRecognisesDiskPressureAsTransient =
    not(remediationRequested)

  run recoveredDiskRun = init
    .then(WriteLogs)
    .then(WriteLogs)
    .then(WriteLogs)
    .then(WriteLogs)
    .then(RotationFailure)
    .then(WriteLogs)
    .then(EnterDiskPressure)
    .then(EvictStaticPodOnDiskPressure)
    .then(RecoverDisk)

  run crashloopRemediationRun = init
    .then(WriteLogs)
    .then(WriteLogs)
    .then(WriteLogs)
    .then(WriteLogs)
    .then(RotationFailure)
    .then(WriteLogs)
    .then(EnterDiskPressure)
    .then(EvictStaticPodOnDiskPressure)
    .then(RequestRemediation)

  action crashloopInit = all {
    diskFreeBytes' = 0,
    logRate' = 25,
    rotationHealthy' = false,
    diskPressure' = true,
    staticPodRunning' = false,
    crashLooping' = true,
    remediationRequested' = true,
  }
}
