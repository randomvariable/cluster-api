// Copyright 2026 The Kubernetes Authors.
//
// CpProviderParity.qnt — issue #99 (FM-99).
//
// Kamaji is a managed-CP provider alternative to KCP (CP runs as
// pods on the management cluster, not as VMs). Behavioural deltas
// (no etcd-as-static-pod, no machine model, hosted apiserver) mean
// some FM properties don't map.
//
// The model is an abstract `CPProvider` interface with two
// instantiations: KCP and Kamaji. Each provider has a property
// vector; the FM properties are predicates on the vector.

module CpProviderParity {

  type Provider = KCP | Kamaji

  pure val PROVIDERS: Set[Provider] = Set(KCP, Kamaji)

  var hasStaticPodEtcd: Provider -> bool
  var hasMachineModel: Provider -> bool
  var hasHostedApiserver: Provider -> bool
  var canScaleHorizontally: Provider -> bool

  action init = all {
    hasStaticPodEtcd' = Map(KCP -> true,  Kamaji -> false),
    hasMachineModel'   = Map(KCP -> true,  Kamaji -> false),
    hasHostedApiserver' = Map(KCP -> false, Kamaji -> true),
    canScaleHorizontally' = Map(KCP -> true, Kamaji -> true),
  }

  // No actions — this is a static-model spec. The "transitions"
  // are property comparisons.
  action step = all {
    hasStaticPodEtcd' = hasStaticPodEtcd,
    hasMachineModel' = hasMachineModel,
    hasHostedApiserver' = hasHostedApiserver,
    canScaleHorizontally' = canScaleHorizontally,
  }

  // FM-2 (quorum loss) maps to providers that have an embedded etcd
  // cluster. Kamaji uses a shared/external etcd; the FM does not apply.
  val FM2_AppliesTo = PROVIDERS.filter(p => hasStaticPodEtcd.get(p))

  // FM-23 (drain stuck on PDB) maps to providers that drain
  // workloads on the CP Machine — i.e. providers with a machine
  // model. Kamaji's CP is pods; drain is the pod's lifecycle.
  val FM23_AppliesTo = PROVIDERS.filter(p => hasMachineModel.get(p))

  // FM-45 (per-key serialisation) is provider-agnostic — it's a
  // controller-runtime property.
  val FM45_AppliesTo = PROVIDERS

  // FM-48 (no CP before InfraReady) — provider-agnostic.
  val FM48_AppliesTo = PROVIDERS

  // The summary predicate: KCP and Kamaji share at least the
  // controller-runtime FMs.
  val SharedFmsAtLeastControllerRuntime =
    FM45_AppliesTo == PROVIDERS and FM48_AppliesTo == PROVIDERS

  val KamajiSkipsEtcdFms =
    not(FM2_AppliesTo.contains(Kamaji)) and not(FM23_AppliesTo.contains(Kamaji))

  val ParitySummary = SharedFmsAtLeastControllerRuntime and KamajiSkipsEtcdFms
}
