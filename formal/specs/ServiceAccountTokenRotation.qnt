module ServiceAccountTokenRotation {

  // Standalone projected ServiceAccountToken rotation model for issue #73.
  //
  // Grounding:
  //   * test/framework/autoscaler_helpers.go:596-604
  //   * test/e2e/kcp_remediations.go:709-717
  //   * controllers/clustercache/cluster_accessor_client.go
  //   * controlplane/kubeadm/internal/controllers/remediation.go:656
  //
  // The real repo requests service-account tokens with TokenRequest and
  // also maintains cached/long-lived cluster clients. This model captures
  // the bad case where a reconcile captures a token, the projected volume
  // rotates later, and an API call still uses the stale token until a 401
  // forces refresh.

  pure val T0: int = 0
  pure val T58: int = 58
  pure val T62: int = 62

  var now: int
  var tokenExpiry: int
  var tokenCapturedAt: int
  var currentTokenVersion: int
  var capturedTokenVersion: int
  var callInFlight: bool
  var saw401: bool
  var refreshed: bool
  var reconcileFailed: bool

  action init: bool = all {
    now' = T0,
    tokenExpiry' = 60,
    tokenCapturedAt' = T0,
    currentTokenVersion' = 1,
    capturedTokenVersion' = 1,
    callInFlight' = false,
    saw401' = false,
    refreshed' = false,
    reconcileFailed' = false,
  }

  action CaptureClient: bool = all {
    not(callInFlight),
    tokenCapturedAt' = now,
    capturedTokenVersion' = currentTokenVersion,
    callInFlight' = true,
    now' = now,
    tokenExpiry' = tokenExpiry,
    currentTokenVersion' = currentTokenVersion,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action AdvanceToT58: bool = all {
    now < T58,
    now' = T58,
    tokenExpiry' = tokenExpiry,
    tokenCapturedAt' = tokenCapturedAt,
    currentTokenVersion' = currentTokenVersion,
    capturedTokenVersion' = capturedTokenVersion,
    callInFlight' = callInFlight,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action RotateToken: bool = all {
    now >= T58,
    currentTokenVersion' = currentTokenVersion + 1,
    tokenExpiry' = now + 60,
    now' = now,
    tokenCapturedAt' = tokenCapturedAt,
    capturedTokenVersion' = capturedTokenVersion,
    callInFlight' = callInFlight,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action AdvanceToT62: bool = all {
    now < T62,
    now' = T62,
    tokenExpiry' = tokenExpiry,
    tokenCapturedAt' = tokenCapturedAt,
    currentTokenVersion' = currentTokenVersion,
    capturedTokenVersion' = capturedTokenVersion,
    callInFlight' = callInFlight,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action Returns401: bool = all {
    callInFlight,
    capturedTokenVersion < currentTokenVersion,
    now' = now,
    tokenExpiry' = tokenExpiry,
    tokenCapturedAt' = tokenCapturedAt,
    currentTokenVersion' = currentTokenVersion,
    capturedTokenVersion' = capturedTokenVersion,
    callInFlight' = false,
    saw401' = true,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action RefreshTokenAndRetry: bool = all {
    saw401,
    capturedTokenVersion' = currentTokenVersion,
    tokenCapturedAt' = now,
    callInFlight' = false,
    refreshed' = true,
    now' = now,
    tokenExpiry' = tokenExpiry,
    currentTokenVersion' = currentTokenVersion,
    saw401' = saw401,
    reconcileFailed' = false,
  }

  action FailWithoutRefresh: bool = all {
    saw401,
    now' = now,
    tokenExpiry' = tokenExpiry,
    tokenCapturedAt' = tokenCapturedAt,
    currentTokenVersion' = currentTokenVersion,
    capturedTokenVersion' = capturedTokenVersion,
    callInFlight' = false,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = true,
  }

  action step: bool = any {
    init,
    CaptureClient,
    AdvanceToT58,
    RotateToken,
    AdvanceToT62,
    Returns401,
    RefreshTokenAndRetry,
    FailWithoutRefresh,
  }

  action stepApalache: bool = any {
    CaptureClient,
    RotateToken,
    Returns401,
    FailWithoutRefresh,
  }

  val CapturedTokenNotNewerThanCurrent =
    capturedTokenVersion <= currentTokenVersion

  val ExpiryMonotone =
    tokenExpiry >= now

  val StableSafetyInvariants = all {
    CapturedTokenNotNewerThanCurrent,
  }

  val RetryOn401WithRefreshedToken =
    refreshed and not(reconcileFailed)

  val NoSilentReconcileFailure =
    not(reconcileFailed)

  run refreshAfter401Run = init
    .then(CaptureClient)
    .then(AdvanceToT58)
    .then(RotateToken)
    .then(AdvanceToT62)
    .then(Returns401)
    .then(RefreshTokenAndRetry)

  run staleTokenFailureRun = init
    .then(CaptureClient)
    .then(AdvanceToT58)
    .then(RotateToken)
    .then(AdvanceToT62)
    .then(Returns401)
    .then(FailWithoutRefresh)

  action expiredTokenInit: bool = all {
    now' = T62,
    tokenExpiry' = 118,
    tokenCapturedAt' = T0,
    currentTokenVersion' = 2,
    capturedTokenVersion' = 1,
    callInFlight' = true,
    saw401' = false,
    refreshed' = false,
    reconcileFailed' = false,
  }
}
