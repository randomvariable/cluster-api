module SkipVersionUpgrade {

  // Standalone skip-version upgrade skew-bound model for issue #80.
  //
  // Grounding:
  //   * internal/controllers/machineset/machineset_preflight.go
  //   * internal/controllers/machineset/machineset_preflight_test.go
  //
  // The real system enforces Kubernetes version skew through MachineSet
  // preflight checks. This model isolates the one-minor-at-a-time safe
  // path from the explicit skip-minor counterexample.

  pure val V127: str = "v1.27"
  pure val V128: str = "v1.28"
  pure val V129: str = "v1.29"
  pure val V130: str = "v1.30"

  var currentVersion: str
  var targetVersion: str
  var preflightOk: bool
  var skippedMinor: bool
  var rolled: bool

  action init: bool = all {
    currentVersion' = V127,
    targetVersion' = V127,
    preflightOk' = true,
    skippedMinor' = false,
    rolled' = false,
  }

  action SetTargetOneMinor: bool = all {
    currentVersion == V127,
    targetVersion' = V128,
    currentVersion' = currentVersion,
    preflightOk' = true,
    skippedMinor' = false,
    rolled' = false,
  }

  action SetTargetSkipMinor: bool = all {
    currentVersion == V127,
    targetVersion' = V130,
    currentVersion' = currentVersion,
    preflightOk' = false,
    skippedMinor' = true,
    rolled' = false,
  }

  action ApplyUpgrade: bool = all {
    preflightOk,
    not(rolled),
    currentVersion' = targetVersion,
    targetVersion' = targetVersion,
    preflightOk' = preflightOk,
    skippedMinor' = skippedMinor,
    rolled' = true,
  }

  action step: bool = any {
    init,
    SetTargetOneMinor,
    SetTargetSkipMinor,
    ApplyUpgrade,
  }

  action stepApalache: bool = any {
    SetTargetSkipMinor,
  }

  val TargetVersionKnown =
    targetVersion == V127 or targetVersion == V128 or targetVersion == V129 or targetVersion == V130

  val PreflightBlocksSkippedMinor =
    skippedMinor implies not(preflightOk)

  val StableSafetyInvariants = all {
    TargetVersionKnown,
    PreflightBlocksSkippedMinor,
  }

  val UpgradeRespectsSkewBound =
    not(skippedMinor)

  run oneMinorStepRun = init
    .then(SetTargetOneMinor)
    .then(ApplyUpgrade)

  run skipMinorRun = init
    .then(SetTargetSkipMinor)

  action skipMinorInit: bool = all {
    currentVersion' = V127,
    targetVersion' = V127,
    preflightOk' = true,
    skippedMinor' = false,
    rolled' = false,
  }
}
