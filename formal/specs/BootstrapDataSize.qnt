// Copyright 2026 The Kubernetes Authors.
//
// BootstrapDataSize.qnt — issue #93 (FM-93).
//
// Cloud provider has a 16KB userData limit. Bootstrap data with
// extra files / long TLS bundle exceeds. Provider truncates
// silently; Machine boots with partial config; kubelet fails to
// register.

module BootstrapDataSize {

  pure val MACHINES: Set[int] = 1.to(2)
  pure val PROVIDER_MAX_BYTES: int = 16384
  pure val FULL_BOOTSTRAP_BYTES: int = 20480   // exceeds limit
  pure val COMPRESSED_BOOTSTRAP_BYTES: int = 12000

  var bootstrapBytes: int -> int
  var providerTruncated: int -> bool
  var kubeletRegistered: int -> bool

  action init = all {
    bootstrapBytes' = MACHINES.mapBy(_ => 0),
    providerTruncated' = MACHINES.mapBy(_ => false),
    kubeletRegistered' = MACHINES.mapBy(_ => false),
  }

  action EncodeBootstrap(m: int, bytes: int): bool = all {
    MACHINES.contains(m),
    bootstrapBytes' = bootstrapBytes.put(m, bytes),
    providerTruncated' = providerTruncated,
    kubeletRegistered' = kubeletRegistered,
  }

  action ProviderApplies(m: int): bool = all {
    MACHINES.contains(m),
    val needsTruncation = bootstrapBytes.get(m) > PROVIDER_MAX_BYTES
    val kubeletOk = not(needsTruncation)
    all {
      providerTruncated' = providerTruncated.put(m, needsTruncation),
      kubeletRegistered' = kubeletRegistered.put(m, kubeletOk),
      bootstrapBytes' = bootstrapBytes,
    }
  }

  action step = any {
    nondet m = MACHINES.oneOf(); EncodeBootstrap(m, FULL_BOOTSTRAP_BYTES),
    nondet m = MACHINES.oneOf(); EncodeBootstrap(m, COMPRESSED_BOOTSTRAP_BYTES),
    nondet m = MACHINES.oneOf(); ProviderApplies(m),
  }

  // The positive invariant: bootstrap data either fits, or the
  // controller preflight-rejects before sending to the provider
  // (modelled here as: providerTruncated must imply kubelet did
  // NOT register healthy — which means we must have caught this
  // earlier).
  val BootstrapDataFitsLimitOrPreflightRejects =
    MACHINES.forall(m =>
      bootstrapBytes.get(m) <= PROVIDER_MAX_BYTES or
      not(kubeletRegistered.get(m)))

  // Counterexample: encode 20KB, provider applies, truncates,
  // kubelet fails. The invariant holds (truncated => not registered),
  // but the OUTCOME is a stuck machine — we want to detect this
  // BEFORE provider apply.
  run silentTruncateRun = init
    .then(EncodeBootstrap(1, FULL_BOOTSTRAP_BYTES))
    .then(ProviderApplies(1))
    // providerTruncated[1] = true, kubeletRegistered[1] = false.

  // Recovery: compress before sending.
  run compressBootstrapRun = init
    .then(EncodeBootstrap(1, COMPRESSED_BOOTSTRAP_BYTES))
    .then(ProviderApplies(1))
    // providerTruncated[1] = false, kubeletRegistered[1] = true.
}
