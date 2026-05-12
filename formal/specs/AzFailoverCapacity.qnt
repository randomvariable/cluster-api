module AzFailoverCapacity {

  // Standalone AZ-wide failure / no-capacity failover model for issue #59.
  //
  // Grounding:
  //   * controlplane/kubeadm/internal/control_plane.go:238-247
  //   * controlplane/kubeadm/internal/controllers/scale.go:46,85
  //   * controlplane/kubeadm/internal/controllers/helpers.go:160-163
  //
  // Initial picture: one control-plane machine per AZ (a,b,c). AZ a fails.
  // b has no spare capacity, c has one spare slot. The good path retargets
  // to c. The bad path stays bound to a failed or exhausted zone forever.

  pure val AZ_A = "a"
  pure val AZ_B = "b"
  pure val AZ_C = "c"
  pure val AZ_NONE = "none"

  pure val REPL_NONE = "none"
  pure val REPL_PENDING = "pending"
  pure val REPL_CREATED = "created"

  var failedAz: str
  var capacityA: int
  var capacityB: int
  var capacityC: int
  var targetAz: str
  var replacementState: str
  var alternativeAttempted: bool

  action init = all {
    failedAz' = AZ_NONE,
    capacityA' = 1,
    capacityB' = 1,
    capacityC' = 1,
    targetAz' = AZ_NONE,
    replacementState' = REPL_NONE,
    alternativeAttempted' = false,
  }

  def capacityOf(az: str): int =
    if (az == AZ_A) capacityA
    else if (az == AZ_B) capacityB
    else if (az == AZ_C) capacityC
    else 0

  action AzAFails: bool = all {
    failedAz == AZ_NONE,
    failedAz' = AZ_A,
    replacementState' = REPL_PENDING,
    // a is dark, b has no spare capacity, c has one slot
    capacityA' = 0,
    capacityB' = 0,
    capacityC' = 1,
    // frame
    targetAz' = targetAz,
    alternativeAttempted' = alternativeAttempted,
  }

  action KcpTargetsFailedAz: bool = all {
    replacementState == REPL_PENDING,
    failedAz == AZ_A,
    targetAz' = AZ_A,
    // frame
    failedAz' = failedAz,
    capacityA' = capacityA,
    capacityB' = capacityB,
    capacityC' = capacityC,
    replacementState' = replacementState,
    alternativeAttempted' = alternativeAttempted,
  }

  action KcpTargetsAlternativeAz: bool = all {
    replacementState == REPL_PENDING,
    failedAz == AZ_A,
    capacityC > 0,
    targetAz' = AZ_C,
    alternativeAttempted' = true,
    // frame
    failedAz' = failedAz,
    capacityA' = capacityA,
    capacityB' = capacityB,
    capacityC' = capacityC,
    replacementState' = replacementState,
  }

  action AzCapacityExhausted: bool = all {
    replacementState == REPL_PENDING,
    targetAz != AZ_NONE,
    capacityOf(targetAz) == 0 or targetAz == failedAz,
    // frame all state; this models a failed attempt without progress
    failedAz' = failedAz,
    capacityA' = capacityA,
    capacityB' = capacityB,
    capacityC' = capacityC,
    targetAz' = targetAz,
    replacementState' = replacementState,
    alternativeAttempted' = alternativeAttempted,
  }

  action CreateReplacement: bool = all {
    replacementState == REPL_PENDING,
    targetAz == AZ_C,
    capacityC > 0,
    replacementState' = REPL_CREATED,
    capacityC' = capacityC - 1,
    // frame
    failedAz' = failedAz,
    capacityA' = capacityA,
    capacityB' = capacityB,
    targetAz' = targetAz,
    alternativeAttempted' = alternativeAttempted,
  }

  action step = any {
    AzAFails,
    KcpTargetsFailedAz,
    KcpTargetsAlternativeAz,
    AzCapacityExhausted,
    CreateReplacement,
  }

  action stepApalache = any {
    KcpTargetsFailedAz,
    AzCapacityExhausted,
  }

  val CapacityNonNegative =
    capacityA >= 0 and capacityB >= 0 and capacityC >= 0

  val AlternativeAttemptNeedsTarget =
    alternativeAttempted implies targetAz != AZ_NONE

  val StableSafetyInvariants = all {
    CapacityNonNegative,
    AlternativeAttemptNeedsTarget,
  }

  val KcpAttemptsAlternativeAzs =
    replacementState == REPL_CREATED and targetAz == AZ_C and alternativeAttempted

  val NoIndefiniteScaleAttempt =
    not(replacementState == REPL_PENDING and (targetAz == failedAz or (targetAz != AZ_NONE and capacityOf(targetAz) == 0)) and not(alternativeAttempted))

  run alternativeAzSuccessRun =
    init
      .then(AzAFails)
      .then(KcpTargetsFailedAz)
      .then(AzCapacityExhausted)
      .then(KcpTargetsAlternativeAz)
      .then(CreateReplacement)

  run stuckOnFailedAzRun =
    init
      .then(AzAFails)
      .then(KcpTargetsFailedAz)
      .then(AzCapacityExhausted)

  action stuckFailoverInit = all {
    failedAz' = AZ_A,
    capacityA' = 0,
    capacityB' = 0,
    capacityC' = 1,
    targetAz' = AZ_A,
    replacementState' = REPL_PENDING,
    alternativeAttempted' = false,
  }
}
