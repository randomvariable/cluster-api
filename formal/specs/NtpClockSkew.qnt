// Copyright 2026 The Kubernetes Authors.
//
// NtpClockSkew.qnt — issue #63 (FM-63).
//
// Kubelet's clock drifts +5 min ahead. A new kubelet client cert
// is issued with `notBefore = issuer.wallClock`. The kubelet's TLS
// verifier reads `kubelet.wallClock = issuer.wallClock - 5min` and
// rejects the cert because `notBefore` is in the future. Kubelet
// enters a retry loop until clocks resync.
//
// Modelled state: per-node `clockSkew` (offset relative to the
// issuer's clock). The cert verification is `kubelet.wallClock
// >= cert.notBefore - skewTolerance`. The bug is when
// `skewTolerance` is too small (or zero).

module NtpClockSkew {

  pure val NODES: Set[int] = 1.to(2)
  pure val SKEW_TOLERANCE_SECS: int = 60      // typical kubelet/CA tolerance
  pure val DRIFT_BIG: int = 300               // 5-minute drift

  var clockSkew: int -> int                   // seconds ahead/behind issuer
  var certNotBeforeSecs: int -> int           // notBefore on the latest cert (issuer clock)
  var certAccepted: int -> bool

  action init = all {
    clockSkew' = NODES.mapBy(_ => 0),
    certNotBeforeSecs' = NODES.mapBy(_ => 0),
    certAccepted' = NODES.mapBy(_ => false),
  }

  action NtpDrift(node: int, delta: int): bool = all {
    NODES.contains(node),
    clockSkew' = clockSkew.put(node, clockSkew.get(node) + delta),
    certNotBeforeSecs' = certNotBeforeSecs,
    certAccepted' = certAccepted,
  }

  action IssueCert(node: int, issuerNowSecs: int): bool = all {
    NODES.contains(node),
    certNotBeforeSecs' = certNotBeforeSecs.put(node, issuerNowSecs),
    certAccepted' = certAccepted.put(node, false),    // re-verification needed
    clockSkew' = clockSkew,
  }

  // Kubelet verifies the cert. The kubelet's wall clock is
  // `issuer.wallClock + clockSkew[node]`. The check is
  // `kubelet.wallClock >= cert.notBefore - skewTolerance`.
  action KubeletVerify(node: int, issuerNowSecs: int): bool = all {
    NODES.contains(node),
    val kubeletNow = issuerNowSecs + clockSkew.get(node)
    val notBefore = certNotBeforeSecs.get(node)
    val accepted = kubeletNow >= notBefore - SKEW_TOLERANCE_SECS
    all {
      certAccepted' = certAccepted.put(node, accepted),
      clockSkew' = clockSkew,
      certNotBeforeSecs' = certNotBeforeSecs,
    }
  }

  action step = any {
    nondet n = NODES.oneOf(); NtpDrift(n, DRIFT_BIG),
    nondet n = NODES.oneOf(); NtpDrift(n, -DRIFT_BIG),
    nondet n = NODES.oneOf(); IssueCert(n, 1000),
    nondet n = NODES.oneOf(); KubeletVerify(n, 1000),
  }

  // The bad case: kubelet rejects a freshly-issued valid cert
  // because of clock skew beyond the tolerance. We assert
  // CertVerificationToleratesSkew as the positive property.
  val CertVerificationToleratesSkew =
    NODES.forall(n => certAccepted.get(n) or certNotBeforeSecs.get(n) == 0)

  // Counterexample: issue cert, then kubelet drifts back by 5 min,
  // then verify rejects.
  run kubeletRejectsAfterSkewRun = init
    .then(IssueCert(1, 1000))
    .then(NtpDrift(1, -DRIFT_BIG))
    .then(KubeletVerify(1, 1000))
    // certAccepted[1] = false; CertVerificationToleratesSkew violated.

  // Recovery: NTP resyncs the kubelet, verify accepts.
  run ntpResyncRecoveryRun = init
    .then(IssueCert(1, 1000))
    .then(NtpDrift(1, -DRIFT_BIG))
    .then(KubeletVerify(1, 1000))
    .then(NtpDrift(1, DRIFT_BIG))
    .then(KubeletVerify(1, 1000))
    // certAccepted[1] = true again.
}
