module OidcIssuerRotation {

  // Standalone OIDC issuer rotation model for issue #75.
  //
  // Grounding:
  //   * test/framework/autoscaler_helpers.go:596-604
  //   * test/e2e/kcp_remediations.go:709-717
  //   * controllers/clustercache/cluster_accessor_client.go
  //
  // Real controllers can hold a cached/long-lived client while the
  // projected ServiceAccount token and the apiserver's trusted OIDC key
  // set both move forward. This model focuses specifically on issuer/key
  // rotation rather than token age alone.

  pure val ISSUER_A: int = 1
  pure val ISSUER_B: int = 2
  pure val KEY_A1: int = 11
  pure val KEY_B1: int = 21

  var currentIssuer: int
  var currentKey: int
  var trustedIssuer: int
  var trustedKey: int
  var tokenIssuer: int
  var tokenKey: int
  var callInFlight: bool
  var saw401: bool
  var refreshed: bool
  var reconcileFailed: bool

  action init: bool = all {
    currentIssuer' = ISSUER_A,
    currentKey' = KEY_A1,
    trustedIssuer' = ISSUER_A,
    trustedKey' = KEY_A1,
    tokenIssuer' = ISSUER_A,
    tokenKey' = KEY_A1,
    callInFlight' = false,
    saw401' = false,
    refreshed' = false,
    reconcileFailed' = false,
  }

  action CaptureClient: bool = all {
    not(callInFlight),
    tokenIssuer' = tokenIssuer,
    tokenKey' = tokenKey,
    callInFlight' = true,
    currentIssuer' = currentIssuer,
    currentKey' = currentKey,
    trustedIssuer' = trustedIssuer,
    trustedKey' = trustedKey,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action RotateIssuerAndKey: bool = all {
    currentIssuer' = ISSUER_B,
    currentKey' = KEY_B1,
    tokenIssuer' = tokenIssuer,
    tokenKey' = tokenKey,
    callInFlight' = callInFlight,
    trustedIssuer' = trustedIssuer,
    trustedKey' = trustedKey,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action ApiserverFetchJwks: bool = all {
    trustedIssuer' = currentIssuer,
    trustedKey' = currentKey,
    tokenIssuer' = tokenIssuer,
    tokenKey' = tokenKey,
    callInFlight' = callInFlight,
    currentIssuer' = currentIssuer,
    currentKey' = currentKey,
    saw401' = saw401,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action OldTokenRejected: bool = all {
    callInFlight,
    (tokenIssuer != trustedIssuer) or (tokenKey != trustedKey),
    callInFlight' = false,
    saw401' = true,
    currentIssuer' = currentIssuer,
    currentKey' = currentKey,
    trustedIssuer' = trustedIssuer,
    trustedKey' = trustedKey,
    tokenIssuer' = tokenIssuer,
    tokenKey' = tokenKey,
    refreshed' = refreshed,
    reconcileFailed' = reconcileFailed,
  }

  action ReissueToken: bool = all {
    saw401,
    tokenIssuer' = currentIssuer,
    tokenKey' = currentKey,
    refreshed' = true,
    callInFlight' = false,
    currentIssuer' = currentIssuer,
    currentKey' = currentKey,
    trustedIssuer' = trustedIssuer,
    trustedKey' = trustedKey,
    saw401' = saw401,
    reconcileFailed' = false,
  }

  action FailWithoutReissue: bool = all {
    saw401,
    reconcileFailed' = true,
    callInFlight' = false,
    currentIssuer' = currentIssuer,
    currentKey' = currentKey,
    trustedIssuer' = trustedIssuer,
    trustedKey' = trustedKey,
    tokenIssuer' = tokenIssuer,
    tokenKey' = tokenKey,
    saw401' = saw401,
    refreshed' = refreshed,
  }

  action step: bool = any {
    init,
    CaptureClient,
    RotateIssuerAndKey,
    ApiserverFetchJwks,
    OldTokenRejected,
    ReissueToken,
    FailWithoutReissue,
  }

  action stepApalache: bool = any {
    CaptureClient,
    RotateIssuerAndKey,
    ApiserverFetchJwks,
    OldTokenRejected,
    FailWithoutReissue,
  }

  val TokenIssuerKnown =
    (tokenIssuer == ISSUER_A or tokenIssuer == ISSUER_B)
      and (trustedIssuer == ISSUER_A or trustedIssuer == ISSUER_B)

  val TokenKeyKnown =
    (tokenKey == KEY_A1 or tokenKey == KEY_B1)
      and (trustedKey == KEY_A1 or trustedKey == KEY_B1)

  val StableSafetyInvariants = all {
    TokenIssuerKnown,
    TokenKeyKnown,
  }

  val EventualReissue =
    refreshed and tokenIssuer == trustedIssuer and tokenKey == trustedKey

  val NoExtendedAuthOutage =
    not(reconcileFailed)

  run eventualReissueRun = init
    .then(CaptureClient)
    .then(RotateIssuerAndKey)
    .then(ApiserverFetchJwks)
    .then(OldTokenRejected)
    .then(ReissueToken)

  run staleIssuerFailureRun = init
    .then(CaptureClient)
    .then(RotateIssuerAndKey)
    .then(ApiserverFetchJwks)
    .then(OldTokenRejected)
    .then(FailWithoutReissue)

  action staleIssuerInit: bool = all {
    currentIssuer' = ISSUER_B,
    currentKey' = KEY_B1,
    trustedIssuer' = ISSUER_B,
    trustedKey' = KEY_B1,
    tokenIssuer' = ISSUER_A,
    tokenKey' = KEY_A1,
    callInFlight' = true,
    saw401' = false,
    refreshed' = false,
    reconcileFailed' = false,
  }
}
