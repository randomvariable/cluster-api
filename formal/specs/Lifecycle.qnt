// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Lifecycle.qnt — the composed authoritative model of the
// KCP-managed control-plane lifecycle.
//
// Quint's effect system requires every alternative inside an
// `any { ... }` to operate on the same variable set. That makes
// cross-module composition through `step` action import infeasible
// in the current Quint surface. This module is therefore a single
// state machine that includes the state, actions, and invariants
// of EtcdMembership, KubeadmJoin, KCPReconcile, and
// MachineHealthCheck, plus the cross-module invariants from the
// (now-archived) Composition.qnt.
//
// The four per-module .qnt files remain in this directory for
// standalone analysis — each typechecks and simulates on its own.
// They are documentation; this file is the source of truth for
// invariant checking and convergence analysis.
//
// Refines: see formal/abstraction-mapping.md (per-action rows
//          carry forward from the per-module files unchanged).
module Lifecycle {

  // ===============================================================
  // Domain types
  // ===============================================================

  type MachineId = int
  type Term      = int

  // -- EtcdMembership --------------------------------------------

  type LearnerProgress =
    | Eligible
    | LaggingFar
    | Stuck

  type MemberHealth =
    | Healthy
    | Unhealthy
    | UnknownHealth

  // -- KubeadmJoin -----------------------------------------------

  type Phase =
    | NotStarted
    | Preflight
    | DownloadCerts
    | StaticPodManifestsWritten
    | EtcdHealthCheck
    | KubeletStart
    | KubeletTLSBootstrapped
    | KubeletManifestReady
    | NodeRegistered
    | EtcdJoinAddLearner
    | WaitForEtcdQuorum
    | KubeadmMarkControlPlane
    | KubeadmUploadConfig
    | MarkControlPlaneReady
    | JoinComplete
    | JoinFailed

  type JoinFailureReason =
    | LearnerStuckOnPromote
    | KubeletNotReady
    | PreflightCheckFailed
    | EtcdJoinAddLearnerFailed
    | DownloadCertsFailed
    | StaticPodManifestWriteFailed
    | EtcdHealthCheckFailed
    | TLSBootstrapTimeout
    | LocalNodeRegistrationFailed
    | KubeadmMarkControlPlaneFailed
    | KubeadmUploadConfigFailed
    | OtherJoinFailure

  // -- KCPReconcile ----------------------------------------------

  type MachineHealth =
    | HealthyMachine
    | UnhealthyMachine
    | UnknownHealthMachine

  type RemediationDecision =
    | NoRemediationNeeded
    | RemediationRequested
    | RemediationBlocked
    | RemediationInFlight

  type BlockedReason =
    | QuorumWouldBeLost
    | EtcdMemberSetDoesNotMatchMachineSet
    | InsufficientReplicas
    | OtherBlock

  // -- MachineHealthCheck ----------------------------------------

  type Observation =
    | ReachableHealthy
    | ReachableUnhealthy
    | UnreachableTimeout
    | UnreachableNoRoute
    | NoCorrespondingMember

  // ===============================================================
  // Bounds
  // ===============================================================

  // The model holds up to 8 MachineIds: 5-node clusters are the
  // largest topology we model, and we reserve slots for in-flight
  // scale-up replacements during upgrades and remediation.
  pure val MACHINES: Set[MachineId] = 1.to(8)
  pure val MAX_TERM: Term = 3

  // Template versions. Version 1 is the bootstrap template;
  // version 2 represents a single upgrade. MAX_TEMPLATE_VERSION
  // bounds the model.
  pure val MAX_TEMPLATE_VERSION: int = 2

  // ===============================================================
  // State
  // ===============================================================

  // -- EtcdMembership --------------------------------------------
  var members:    Set[MachineId]
  var learners:   Set[MachineId]
  var leaderAt:   Term -> MachineId
  var currentTerm: Term
  var progress:   MachineId -> LearnerProgress
  var memberHealth: MachineId -> MemberHealth

  // -- KubeadmJoin -----------------------------------------------
  var phase: MachineId -> Phase
  var failureReason: MachineId -> JoinFailureReason
  var etcdMemberRegistered: MachineId -> bool
  var kubeletReady: MachineId -> bool
  var tlsBootstrapped: MachineId -> bool
  var kubeletManifestReady: MachineId -> bool
  var nodeLocallyRegistered: MachineId -> bool
  var staticPodManifestsWritten: MachineId -> bool
  var kubeadmMarkedAsControlPlane: MachineId -> bool
  var kubeadmConfigUploaded: MachineId -> bool

  // -- KCPReconcile ----------------------------------------------
  var machines:    Set[MachineId]
  var nodeRefSet:  MachineId -> bool
  var machineHealthLabel: MachineId -> MachineHealth
  var decision:    MachineId -> RemediationDecision
  var blockReason: MachineId -> BlockedReason
  var preflightBlocked: bool
  // KCP's spec.replicas — desired control-plane size. Operator
  // changes this to scale up/down.
  var desiredReplicas: int
  // Per-Machine template version. Used by upgrade modelling.
  var template: MachineId -> int
  // KCP's spec.template version. Operator changes this to upgrade.
  var desiredTemplate: int

  // -- MachineHealthCheck ----------------------------------------
  var observation: MachineId -> Observation

  // -- Network / connectivity -----------------------------------
  // The apiserver LB proxy's health. KCP reaches the workload
  // cluster's etcd through this LB; when it's broken every MHC
  // observation flips to UnreachableTimeout.
  var lbHealthy: bool
  // CAPI's ability to reach a specific Node via the apiserver. A
  // healthy LB does not guarantee per-Node reachability — kubelet
  // can be up but unable to register, which models "etcd starts
  // but Node never joins".
  var nodeReachable: MachineId -> bool

  // -- Drain & PDB ----------------------------------------------
  // True when KCP has begun draining the Machine but kubelet drain
  // has stalled — typically because of a PodDisruptionBudget
  // violation. Sticky: only DrainTimeout (force-delete) clears it.
  // Refines `controlplane/kubeadm/internal/controllers/scale.go`
  // (`scaleDownControlPlane`) calling `internal/util/collections.HasUnhealthyMachines`
  // and the upstream `Cluster.spec.controlPlane.machineDrainTimeout`.
  var drainBlocked: MachineId -> bool
  // True when a PodDisruptionBudget refused an eviction during
  // drain. The model uses this to gate `BeginDrain` ⇒ `drainBlocked`.
  var pdbViolatedFor: MachineId -> bool

  // -- Apiserver ↔ etcd interactions ----------------------------
  // The kube-apiserver static pod's etcd backend connectivity.
  // True iff the apiserver process on this Machine can reach its
  // configured etcd backend (typically an etcd pod on the same
  // Machine via `127.0.0.1:2379`, or any peer in `--etcd-servers`).
  // Refines `staging/src/k8s.io/apiserver/pkg/storage/etcd3/preflight/checks.go::CheckEtcdServers`
  // and the etcd v3 client connection state inside
  // `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go`.
  var apiserverEtcdReachable: MachineId -> bool
  // The kube-apiserver pod's readiness. Apiserver readiness gates
  // are: storage backend reachable (apiserverEtcdReachable),
  // bootstrap secrets present, post-start hooks complete,
  // server certs valid. Refines
  // `staging/src/k8s.io/apiserver/pkg/server/healthz/healthz.go`.
  var apiserverReady: MachineId -> bool
  // Etcd auto-compaction is in progress. During compaction the
  // bbolt mmap is held; gRPC reads can spike to 10–60 s of latency
  // and Status RPCs may time out. Refines
  // `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go::StartCompactorPerEndpoint`
  // and etcd's own auto-compaction loop.
  var etcdCompactionInProgress: bool

  // -- FM-37 — Lifecycle hook skipped when CP unavailable --------
  // Refines cluster-api#8942: BeforeClusterUpgrade hook is not
  // invoked when control plane is unavailable. Operators relying on
  // the hook silently skip it during partial-outage scenarios.
  var hooksTriggered: Set[str]

  // -- FM-34 — MHC stale cluster cache --------------------------
  // The MHC controller maintains a cache-backed client for each
  // workload cluster. When the apiserver restarts (e.g. as part of
  // an upgrade), the cache holds a stale connection or returns
  // "cluster not found" briefly. While stale, MHC's `needsRemediation`
  // predicate cannot reach the workload-cluster apiserver and may
  // mis-flag a Machine as unhealthy. Refines cluster-api#12363.
  var mhcCacheStale: bool

  // -- FM-32 — Webhook rotation gap -----------------------------
  // Cert-manager rotates the CAPI webhook serving cert. For up to
  // ~90s, mutating + validating webhooks are unreachable; any KCP
  // / MHC reconcile that hits a webhook fails. Refines upstream
  // cert-manager#10522. The model gates mutation actions on
  // webhooksAvailable.
  var webhooksAvailable: bool

  // -- FM-31 — Custom Node conditions surfacing -----------------
  // Operators write custom Node conditions (e.g. via Node Problem
  // Detector) and want them to surface on Machine.status.conditions
  // without triggering MHC remediation. Refines upstream
  // cluster-api#11826. The model holds a set of condition keys per
  // Machine.
  var customCondition: MachineId -> Set[str]

  // -- containerd ↔ CRI lifecycle of static pods ----------------
  // The kubelet brings up control-plane static pods (apiserver,
  // controller-manager, scheduler, local etcd if stacked) via the
  // CRI gRPC connection to containerd at /run/containerd/containerd.sock.
  // Each container goes through three CRI lifecycle stages:
  //   1. Image pull (RuntimeService.PullImage) — refines
  //      `pkg/kubelet/kuberuntime/kuberuntime_image.go:33`
  //      (kubeGenericRuntimeManager.PullImage).
  //   2. Pod sandbox create (RuntimeService.RunPodSandbox) — refines
  //      `pkg/kubelet/kuberuntime/kuberuntime_sandbox.go:38`
  //      (kubeGenericRuntimeManager.createPodSandbox).
  //   3. Container create + start (RuntimeService.CreateContainer +
  //      StartContainer) — refines
  //      `pkg/kubelet/kuberuntime/kuberuntime_container.go:199`
  //      (kubeGenericRuntimeManager.startContainer).
  //
  // The model captures one boolean per stage per Machine. Failure
  // at any stage requires manual operator intervention (image
  // registry fix, containerd restart, fix to underlying disk/cgroups).

  // True iff the CRI runtime (containerd) is up and the CRI socket
  // /run/containerd/containerd.sock is responding to RuntimeStatus
  // RPCs. Refines kubelet's `RuntimeService.Status` probe.
  var criRuntimeReady: MachineId -> bool
  // True iff kubelet has pulled all static-pod images on this
  // Machine via CRI's PullImage. Refines
  // `pkg/kubelet/kuberuntime/kuberuntime_image.go:33`.
  var criImagesPulled: MachineId -> bool
  // True iff kubelet has called CRI's RunPodSandbox for the
  // control-plane pod sandbox on this Machine. Refines
  // `pkg/kubelet/kuberuntime/kuberuntime_sandbox.go:38`.
  var criPodSandboxRunning: MachineId -> bool
  // True iff kubelet has called CRI's CreateContainer +
  // StartContainer for every static-pod container (apiserver,
  // controller-manager, scheduler, local etcd) on this Machine.
  // Refines `pkg/kubelet/kuberuntime/kuberuntime_container.go:199`.
  var criContainersRunning: MachineId -> bool

  // ===============================================================
  // Initial state
  // ===============================================================

  // Helper — build a complete state for a given starting voter set
  // `voterSet`, with `desiredReplicas` matching, all machines on
  // template version 1, all healthy, no in-flight join. Used by the
  // topology-specific init actions below.
  //
  // Usage of `pure def` here would be ergonomic but Quint
  // requires action-shaped state initialisation, so each topology
  // duplicates the boilerplate.

  // Bootstrap: a 3-machine KCP cluster (the primary topology).
  // Machine 4 is the joining slot, retained for the existing
  // happyJoin/incidentRecovered scenarios. desiredReplicas = 3
  // and desiredTemplate = 1.
  action init = all {
    // EtcdMembership
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    // KubeadmJoin — only machine 4 has ever started kubeadm-join.
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    // KCPReconcile — three machines bootstrapped. Machine 4 not
    // yet known to KCP.
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    // MachineHealthCheck
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    // Network
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // ── Topology variants — singleNode / threeNode / fiveNode ────
  //
  // Each is a steady-state init for its respective topology with
  // no in-flight join, no faults, and one spare MachineId reserved
  // as the next scale-up / remediation slot.

  action singleNodeInit = all {
    members'      = Set(1),
    learners'     = Set(),
    leaderAt'     = Map(),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(1 -> Healthy),
    phase'                = Map(1 -> JoinComplete, 2 -> NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Map(1 -> true, 2 -> false),
    kubeletReady'         = Map(1 -> true, 2 -> false),
    tlsBootstrapped'         = Map(1 -> true, 2 -> false),
    kubeletManifestReady'         = Map(1 -> true, 2 -> false),
    nodeLocallyRegistered'         = Map(1 -> true, 2 -> false),
    staticPodManifestsWritten'         = Map(1 -> true, 2 -> false),
    kubeadmMarkedAsControlPlane'         = Map(1 -> true, 2 -> false),
    kubeadmConfigUploaded'         = Map(1 -> true, 2 -> false),
    machines'    = Set(1),
    nodeRefSet'  = Map(1 -> true),
    machineHealthLabel' = Map(1 -> HealthyMachine),
    decision'    = Map(1 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 1,
    template'        = Map(1 -> 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Map(1 -> true),
    customCondition'  = Map(1 -> Set()),
    criRuntimeReady'  = Map(1 -> true),
    criImagesPulled'  = Map(1 -> true),
    criPodSandboxRunning'  = Map(1 -> true),
    criContainersRunning'  = Map(1 -> true),
    drainBlocked'  = Map(1 -> false),
    pdbViolatedFor'  = Map(1 -> false),
    apiserverEtcdReachable'  = Map(1 -> true),
    apiserverReady'  = Map(1 -> true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // threeNodeInit duplicates `init`'s body verbatim. The natural
  // form `action threeNodeInit = init` triggers Quint error
  // QNT409 (action used both for init and for step) when running
  // TLA+ conversion. Duplicate the body to keep both names.
  action threeNodeInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    tlsBootstrapped'      = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletManifestReady' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    nodeLocallyRegistered'= Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    staticPodManifestsWritten' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmConfigUploaded'= Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition' = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady' = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled' = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning' = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning' = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked' = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor' = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable' = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady' = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  action fiveNodeInit = all {
    members'      = Set(1, 2, 3, 4, 5),
    learners'     = Set(),
    leaderAt'     = Map(),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3, 4, 5).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3, 4, 5).mapBy(_ => JoinComplete)
                              .put(6, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    kubeletReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    tlsBootstrapped'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    kubeletManifestReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4, 5).mapBy(_ => true)
                              .put(6, false),
    machines'    = Set(1, 2, 3, 4, 5),
    nodeRefSet'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3, 4, 5).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3, 4, 5).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 5,
    template'        = Set(1, 2, 3, 4, 5).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4, 5).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4, 5).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def voters(ms: Set[MachineId], ls: Set[MachineId]): Set[MachineId] =
    ms.exclude(ls)

  pure def quorumOf(n: int): int = n / 2 + 1

  pure def hasLeader(la: Term -> MachineId, t: Term): bool =
    la.keys().contains(t)

  pure def matchableMachines(ms: Set[MachineId], nrs: MachineId -> bool): Set[MachineId] =
    ms.filter(m => nrs.keys().contains(m) and nrs.get(m))

  pure def quorumPreservedAfterDelete(ms: Set[MachineId], m: MachineId): bool =
    ms.contains(m) and (ms.size() - 1) >= quorumOf(ms.size())

  pure def isSafeToRemediate(ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): bool =
    quorumPreservedAfterDelete(ms, m)
      and matchableMachines(ms, nrs) == ms

  pure def computeBlockReason(ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): BlockedReason =
    if (not(quorumPreservedAfterDelete(ms, m))) QuorumWouldBeLost
    else if (matchableMachines(ms, nrs) != ms) EtcdMemberSetDoesNotMatchMachineSet
    else OtherBlock

  // ── targetEtcdClusterHealthy ─────────────────────────────────
  //
  // Models KCP's `targetEtcdClusterHealthy` helper at
  // `controlplane/kubeadm/internal/controllers/remediation.go:692`.
  // Computes whether the etcd cluster would still have quorum
  // after a proposed transition (adding a member, removing a
  // member, both, or neither).
  //
  // Rules ported from the Go implementation:
  //
  //   * For each existing member that is NOT etcdMemberToBeDeleted,
  //     count it in the target voter set if it is not a learner,
  //     otherwise count it in the target learner set.
  //   * A non-learner is "healthy" iff `memberHealth[m] == Healthy`.
  //     A learner is treated as a learner-in-progress regardless
  //     of `progress` — KCP's check ignores etcd-side learner
  //     progress and only looks at the EtcdMemberHealthy condition.
  //   * If `addEtcdMember` is true, a new voter is added to the
  //     target. The new voter is assumed *unhealthy* unless the
  //     existing cluster size is 0 or 1 (otherwise it would be
  //     impossible to scale up from 0/1 because the new member
  //     hasn't proved itself healthy yet).
  //   * Hard refusal: if the target post-state still contains a
  //     learner, KCP refuses any further membership change. This
  //     forces serialised promotion; KCP must complete one
  //     learner-add before issuing another.
  //   * Quorum: `targetQuorum = targetVoters / 2 + 1`. Safe iff
  //     `targetVoters - unhealthyCount >= targetQuorum`.
  //
  // The MachineId 0 is the sentinel for "no member to delete";
  // 0 is not in MACHINES (which is 1.to(8)), so the exclusion is
  // a no-op in that case.
  pure val NO_MEMBER: MachineId = 0

  pure def memberIsHealthy(
      m: MachineId,
      ls: Set[MachineId],
      mh: MachineId -> MemberHealth): bool =
    not(ls.contains(m))
      and mh.keys().contains(m)
      and mh.get(m) == Healthy

  pure def targetEtcdClusterHealthy(
      ms: Set[MachineId],
      ls: Set[MachineId],
      mh: MachineId -> MemberHealth,
      addEtcdMember: bool,
      etcdMemberToBeDeleted: MachineId): bool = {
    val remainingMembers = ms.exclude(Set(etcdMemberToBeDeleted))
    val remainingLearners = ls.exclude(Set(etcdMemberToBeDeleted))
    val remainingVoters = remainingMembers.exclude(remainingLearners)
    val targetVoterCount =
      remainingVoters.size() + (if (addEtcdMember) 1 else 0)
    val targetLearnerCount = remainingLearners.size()
    val unhealthyExistingCount =
      remainingMembers.filter(m => not(memberIsHealthy(m, ls, mh))).size()
    val newMemberUnhealthy =
      if (addEtcdMember and ms.size() > 1) 1 else 0
    val unhealthyCount = unhealthyExistingCount + newMemberUnhealthy
    val targetQuorum = targetVoterCount / 2 + 1
    targetLearnerCount == 0
      and (targetVoterCount - unhealthyCount) >= targetQuorum
  }

  // ===============================================================
  // Actions — EtcdMembership
  // ===============================================================

  action ElectLeader(c: MachineId): bool = all {
    voters(members, learners).contains(c),
    not(leaderAt.keys().contains(currentTerm)),
    leaderAt' = leaderAt.put(currentTerm, c),
    members' = members, learners' = learners, currentTerm' = currentTerm,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action AdvanceTerm: bool = all {
    currentTerm < MAX_TERM,
    currentTerm' = currentTerm + 1,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action AddLearner(id: MachineId): bool = all {
    not(members.contains(id)),
    hasLeader(leaderAt, currentTerm),
    members'  = members.union(Set(id)),
    learners' = learners.union(Set(id)),
    progress' = progress.put(id, LaggingFar),
    memberHealth' = memberHealth.put(id, UnknownHealth),
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action ObserveLearnerProgress(id: MachineId, p: LearnerProgress): bool = all {
    learners.contains(id),
    // Stuck is sticky: once a learner is Stuck, only an explicit
    // recovery action can clear it. This matches the modelled
    // incident's dynamics where an underlying gRPC routing bug
    // (kubernetes-sigs reproducer) keeps the learner from
    // promoting; observation alone does not heal it.
    progress.keys().contains(id) implies progress.get(id) != Stuck,
    progress' = progress.put(id, p),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action PromoteLearner(id: MachineId): bool = all {
    learners.contains(id),
    progress.keys().contains(id),
    progress.get(id) == Eligible,
    hasLeader(leaderAt, currentTerm),
    learners' = learners.exclude(Set(id)),
    memberHealth' = memberHealth.put(id, Healthy),
    members' = members, leaderAt' = leaderAt, currentTerm' = currentTerm,
    progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action RemoveMember(id: MachineId): bool = all {
    members.contains(id),
    voters(members.exclude(Set(id)), learners.exclude(Set(id))).size() >= 1,
    hasLeader(leaderAt, currentTerm),
    leaderAt.get(currentTerm) != id,
    not(drainBlocked.keys().contains(id) and drainBlocked.get(id)),
    members'  = members.exclude(Set(id)),
    learners' = learners.exclude(Set(id)),
    progress' = progress, memberHealth' = memberHealth,
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // LeaderStepDown — the current leader steps down because its
  // observation flipped to UnreachableTimeout/Unhealthy or it was
  // removed from the cluster out-of-band. Advances the term; no
  // leader assigned at the new term until ElectLeader fires.
  // Refines the etcd-side observation that the leader's lease
  // lapses when it loses connectivity to a quorum.
  // Contract: R-LEAD-STEP-DOWN.
  action LeaderStepDown(id: MachineId): bool = all {
    hasLeader(leaderAt, currentTerm),
    leaderAt.get(currentTerm) == id,
    currentTerm < MAX_TERM,
    any {
      memberHealth.keys().contains(id) and memberHealth.get(id) == UnknownHealth,
      memberHealth.keys().contains(id) and memberHealth.get(id) == Unhealthy,
      not(members.contains(id)),
    },
    currentTerm' = currentTerm + 1,
    members' = members, learners' = learners,
    leaderAt' = leaderAt, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // TransferLeadership — KCP's pre-scale-down optimisation. Refines
  // Workload.ForwardEtcdLeadership: before removing the current
  // leader, transfer leadership to a healthy follower. Pre-conditions
  // encode etcd's MoveLeader RPC contract:
  //   * src is the current leader
  //   * dst is a current voter (not a learner)
  //   * dst is healthy enough to accept the transfer
  // Effect: advances the term and assigns dst as leader at the new
  // term. The brief no-leader window real etcd exposes during transfer
  // is exposed separately via LeaderStepDown.
  // Contract: R-LEAD-STEP-DOWN.
  action TransferLeadership(src: MachineId, dst: MachineId): bool = all {
    hasLeader(leaderAt, currentTerm),
    leaderAt.get(currentTerm) == src,
    members.contains(dst),
    not(learners.contains(dst)),
    dst != src,
    memberHealth.keys().contains(dst),
    memberHealth.get(dst) == Healthy,
    currentTerm < MAX_TERM,
    not(leaderAt.keys().contains(currentTerm + 1)),
    currentTerm' = currentTerm + 1,
    leaderAt' = leaderAt.put(currentTerm + 1, dst),
    members' = members, learners' = learners,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // MemberHealthChange — KCP refreshes its memberHealth view by
  // re-projecting observation. The action is gated so that the
  // memberHealth value matches what KCP would actually compute
  // from the latest observation:
  //
  //   * h == Healthy        ⇒ observation[id] == ReachableHealthy
  //                            (the etcd Status RPC succeeded)
  //   * h == Unhealthy      ⇒ observation[id] == ReachableUnhealthy
  //   * h == UnknownHealth  ⇒ observation[id] in {UnreachableTimeout,
  //                            UnreachableNoRoute,
  //                            NoCorrespondingMember}
  //
  // Without this gate, a free MemberHealthChange(id, Healthy) would
  // silently heal an unhealthy voter — short-circuiting the
  // FM-2 hopelessness proof. The gate forces the model to route
  // healing through Partition / HealEtcdReachability, which is the
  // honest KCP semantics: KCP's view of a member's health is a
  // projection of its observation, not an independent variable.
  action MemberHealthChange(id: MachineId, h: MemberHealth): bool = all {
    members.contains(id),
    observation.keys().contains(id),
    val o = observation.get(id)
    any {
      all { h == Healthy,        o == ReachableHealthy },
      all { h == Unhealthy,      o == ReachableUnhealthy },
      all { h == UnknownHealth,  o == UnreachableTimeout },
      all { h == UnknownHealth,  o == UnreachableNoRoute },
      all { h == UnknownHealth,  o == NoCorrespondingMember },
    },
    memberHealth' = memberHealth.put(id, h),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // Fault action — exogenous.
  action LearnerStuck(id: MachineId): bool = all {
    learners.contains(id),
    progress.keys().contains(id),
    progress' = progress.put(id, Stuck),
    memberHealth' = memberHealth.put(id, UnknownHealth),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Actions — KubeadmJoin
  // ===============================================================

  action BeginJoin(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == NotStarted,
    phase' = phase.put(m, Preflight),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action PreflightPass(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == Preflight,
    phase' = phase.put(m, DownloadCerts),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // DownloadCertsSucceeded — control-plane-prepare phase succeeded.
  // Folds the download-certs, certs (per-Machine generation),
  // kubeconfig (write CP kubeconfigs), and control-plane (static-pod
  // manifest write) sub-phases. Sets staticPodManifestsWritten.
  // Refines `cmd/kubeadm/app/cmd/phases/join/controlplaneprepare.go`.
  action DownloadCertsSucceeded(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == DownloadCerts,
    phase' = phase.put(m, StaticPodManifestsWritten),
    staticPodManifestsWritten' = staticPodManifestsWritten.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EnterEtcdHealthCheck — kubeadm-join enters check-etcd phase.
  // Refines `cmd/kubeadm/app/cmd/phases/join/checketcd.go`.
  action EnterEtcdHealthCheck(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == StaticPodManifestsWritten,
    phase' = phase.put(m, EtcdHealthCheck),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // CheckEtcdHealth — check-etcd phase succeeded; existing etcd
  // cluster is reachable and healthy from this Machine. Advances
  // to KubeletStart.
  action CheckEtcdHealth(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == EtcdHealthCheck,
    phase' = phase.put(m, KubeletStart),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // KubeletStarted — kubelet-start/start: kubeadm has written kubelet
  // config + dynamic env file (`WriteConfigToDisk`,
  // `WriteKubeletDynamicEnvFile`) and called `TryStartKubelet`. The
  // kubelet process is running with bootstrap creds; TLS bootstrap
  // not yet complete.
  // Refines `cmd/kubeadm/app/cmd/phases/join/kubelet.go:217-233`.
  action KubeletStarted(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeletStart,
    phase' = phase.put(m, KubeletTLSBootstrapped),
    kubeletReady' = kubeletReady.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // KubeletTLSBootstrap — kubelet-start/wait-bootstrap: kubelet has
  // performed the TLS Bootstrap (transforming
  // /etc/kubernetes/bootstrap-kubelet.conf into /etc/kubernetes/kubelet.conf
  // with a CA-signed client cert). Sets tlsBootstrapped and
  // kubeletManifestReady (kubelet picks up the static-pod manifests
  // it found on disk).
  // Refines `waitForTLSBootstrappedClient` at
  // `cmd/kubeadm/app/cmd/phases/join/kubelet.go:296`.
  action KubeletTLSBootstrap(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeletTLSBootstrapped,
    phase' = phase.put(m, KubeletManifestReady),
    tlsBootstrapped' = tlsBootstrapped.put(m, true),
    kubeletManifestReady' = kubeletManifestReady.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // RegisterLocalNode — kubelet performs local Node registration
  // by calling Nodes().Create() against the workload-cluster
  // apiserver, using the kubelet-config-bootstrap RBAC bundle.
  // The Node may exist before the apiserver static pod is fully
  // serving — kubelet uses the workload-cluster apiserver
  // endpoint that may already be served by other CP nodes.
  // Refines `Kubelet.registerWithAPIServer` at
  // `pkg/kubelet/kubelet_node_status.go:52` and
  // `Kubelet.tryRegisterWithAPIServer` at
  // `pkg/kubelet/kubelet_node_status.go:90`.
  action RegisterLocalNode(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeletManifestReady,
    phase' = phase.put(m, NodeRegistered),
    nodeLocallyRegistered' = nodeLocallyRegistered.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EnterEtcdAddLearner — kubeadm enters the etcd-add-learner phase
  // (control-plane-join/etcd). Pre-condition tightened (K2): the
  // local Node MUST be registered before kubeadm-join's
  // etcd-add-learner phase runs.
  // Refines `cmd/kubeadm/app/cmd/phases/join/controlplanejoin.go`.
  action EnterEtcdAddLearner(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == NodeRegistered,
    phase' = phase.put(m, EtcdJoinAddLearner),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EtcdAddLearnerSucceeded reaches into EtcdMembership to actually
  // record the new learner. Modelled as a single combined action so
  // KubeadmJoin's observable side-effect and EtcdMembership's
  // member set update are atomic — that matches kubeadm's gRPC
  // call semantics.
  action EtcdAddLearnerSucceeded(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == EtcdJoinAddLearner,
    not(members.contains(m)),
    hasLeader(leaderAt, currentTerm),
    phase' = phase.put(m, WaitForEtcdQuorum),
    etcdMemberRegistered' = etcdMemberRegistered.put(m, true),
    members'  = members.union(Set(m)),
    learners' = learners.union(Set(m)),
    progress' = progress.put(m, LaggingFar),
    memberHealth' = memberHealth.put(m, UnknownHealth),
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    failureReason' = failureReason, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EtcdQuorumReady fires after PromoteLearner — kubeadm-join
  // unblocks once is_learner flips to false on its MemberList.
  // Advances to KubeadmMarkControlPlane (recent kubeadm flow runs
  // mark-control-plane and uploadconfig phases after etcd quorum
  // is reached and before declaring the join complete).
  action EtcdQuorumReady(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == WaitForEtcdQuorum,
    not(learners.contains(m)),
    members.contains(m),
    phase' = phase.put(m, KubeadmMarkControlPlane),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // MarkAsControlPlane — control-plane-join/mark-control-plane:
  // kubeadm applies the node-role.kubernetes.io/control-plane label
  // and node-role.kubernetes.io/control-plane:NoSchedule taint to
  // the new Node.
  // Refines `cmd/kubeadm/app/phases/markcontrolplane`.
  action MarkAsControlPlane(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeadmMarkControlPlane,
    phase' = phase.put(m, KubeadmUploadConfig),
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // UploadKubeadmConfig — control-plane-join/uploadconfig: kubeadm
  // uploads the ClusterConfiguration / KubeletConfiguration to the
  // kube-system/kubeadm-config and kubelet-config ConfigMaps.
  // Refines `cmd/kubeadm/app/phases/uploadconfig`.
  action UploadKubeadmConfig(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeadmUploadConfig,
    phase' = phase.put(m, MarkControlPlaneReady),
    kubeadmConfigUploaded' = kubeadmConfigUploaded.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action MarkReady(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == MarkControlPlaneReady,
    phase' = phase.put(m, JoinComplete),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action JoinFailedAt(m: MachineId, r: JoinFailureReason): bool = all {
    phase.keys().contains(m),
    phase.get(m) != JoinComplete,
    phase.get(m) != JoinFailed,
    phase.get(m) != NotStarted,
    phase' = phase.put(m, JoinFailed),
    failureReason' = failureReason.put(m, r),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Actions — KCPReconcile
  // ===============================================================

  // AddMachine creates (or recreates) a Machine and resets every
  // per-Machine variable to its bootstrap state. The MachineId may
  // have been used previously — that models KCP recreating a
  // failed Machine with a fresh BootstrapData. This is the only
  // path back into the join workflow for a previously-failed
  // Machine.
  action AddMachine(m: MachineId): bool = all {
    not(machines.contains(m)),
    MACHINES.contains(m),
    machines'    = machines.union(Set(m)),
    nodeRefSet'  = nodeRefSet.put(m, false),
    machineHealthLabel' = machineHealthLabel.put(m, UnknownHealthMachine),
    decision'    = decision.put(m, NoRemediationNeeded),
    phase'       = phase.put(m, NotStarted),
    kubeletReady' = kubeletReady.put(m, false),
    etcdMemberRegistered' = etcdMemberRegistered.put(m, false),
    template'     = template.put(m, desiredTemplate),
    nodeReachable' = nodeReachable.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action ResolveNodeRef(m: MachineId): bool = all {
    machines.contains(m),
    nodeRefSet.keys().contains(m),
    not(nodeRefSet.get(m)),
    // The Machine controller only sets NodeRef once it observes a
    // Node in the workload-cluster apiserver. That requires:
    //   * the kubelet to have started, AND
    //   * the kubelet to be able to register with the apiserver
    //     (modelled by `nodeReachable`), AND
    //   * the apiserver LB proxy to be healthy (the Machine
    //     controller reaches the workload-cluster apiserver
    //     through it).
    kubeletReady.keys().contains(m) and kubeletReady.get(m),
    nodeReachable.keys().contains(m) and nodeReachable.get(m),
    lbHealthy,
    nodeRefSet' = nodeRefSet.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action MachineHealthChange(m: MachineId, h: MachineHealth): bool = all {
    machines.contains(m),
    machineHealthLabel' = machineHealthLabel.put(m, h),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action RequestRemediation(m: MachineId): bool = all {
    machines.contains(m),
    machineHealthLabel.keys().contains(m),
    machineHealthLabel.get(m) == UnhealthyMachine,
    decision.keys().contains(m),
    decision.get(m) == NoRemediationNeeded,
    decision' = decision.put(m, RemediationRequested),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EvaluateCanSafelyRemediate mirrors KCP's
  // `canSafelyRemediateMachine` at remediation.go:594:
  //
  //   1. matchableMachines == machines (every Machine has a
  //      NodeRef, so KCP can match Machines to etcd members by
  //      node name). The modelled scenario fails at this gate.
  //   2. targetEtcdClusterHealthy(addEtcdMember=false,
  //      etcdMemberToBeDeleted=m) — the post-remediation etcd
  //      cluster has quorum.
  action EvaluateCanSafelyRemediate(m: MachineId): bool = all {
    machines.contains(m),
    decision.keys().contains(m),
    decision.get(m) == RemediationRequested,
    decision' = decision.put(m,
      if (matchableMachines(machines, nodeRefSet) == machines
          and targetEtcdClusterHealthy(members, learners, memberHealth,
                                        false, m))
        RemediationInFlight
      else RemediationBlocked),
    blockReason' = if (matchableMachines(machines, nodeRefSet) == machines
                       and targetEtcdClusterHealthy(members, learners, memberHealth,
                                                    false, m))
      blockReason
    else
      blockReason.put(m,
        if (matchableMachines(machines, nodeRefSet) != machines)
          EtcdMemberSetDoesNotMatchMachineSet
        else QuorumWouldBeLost),
    preflightBlocked' = if (matchableMachines(machines, nodeRefSet) == machines
                            and targetEtcdClusterHealthy(members, learners, memberHealth,
                                                         false, m))
      preflightBlocked
    else true,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // CompleteRemediation is the success path: the failed machine is
  // gone from the etcd member set and from KCP's machine set. It
  // refuses to fire when removing m would drop the etcd voter set
  // below `quorumOf(machines.size() - 1)` — KCP's
  // `targetEtcdClusterHealthy` helper enforces the same gate.
  action CompleteRemediation(m: MachineId): bool = all {
    machines.contains(m),
    decision.keys().contains(m),
    decision.get(m) == RemediationInFlight,
    // Final etcd-side gate: the post-remediation cluster must
    // satisfy targetEtcdClusterHealthy. The decision was admitted
    // by EvaluateCanSafelyRemediate, but other actions (Partition,
    // MemberHealthChange) may have flipped the cluster between
    // admission and completion. Re-checking matches KCP's
    // behaviour: the canSafelyRemediate gate is re-evaluated each
    // reconcile.
    targetEtcdClusterHealthy(members, learners, memberHealth, false, m),
    machines' = machines.exclude(Set(m)),
    decision' = decision.put(m, NoRemediationNeeded),
    // Etcd-side: the member is gone too.
    members' = members.exclude(Set(m)),
    learners' = learners.exclude(Set(m)),
    preflightBlocked' = false,
    nodeRefSet' = nodeRefSet, machineHealthLabel' = machineHealthLabel,
    blockReason' = blockReason,
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Actions — MachineHealthCheck
  // ===============================================================
  //
  // MHC's `Observe` action is deliberately constrained: a random
  // walk MUST NOT be able to flip an observation back to
  // ReachableHealthy without an explicit recovery. The general
  // form `Observe(m, o)` is therefore split into:
  //
  //   * `ObserveSteadyState(m)` — re-confirms the observation
  //     consistent with the current ground-truth state (a healthy
  //     reachable member sees ReachableHealthy; an unreachable
  //     member sees UnreachableTimeout). The action does not
  //     change observation; it represents MHC polling and
  //     reaffirming.
  //
  //   * `Partition(m)` — exogenous fault: the network breaks for
  //     `m`. MHC will subsequently observe UnreachableTimeout and
  //     etcd-side health flips to UnknownHealth.
  //
  //   * `LoseEtcdMember(m)` — exogenous fault: the etcd member
  //     for `m` disappears from `MemberList`. MHC observes
  //     NoCorrespondingMember.
  //
  // The recovery action `HealEtcdReachability(m)` is the inverse
  // of `Partition(m)`.

  action Partition(m: MachineId): bool = all {
    MACHINES.contains(m),
    observation.keys().contains(m),
    observation.get(m) == ReachableHealthy,
    observation' = observation.put(m, UnreachableTimeout),
    memberHealth' = if (members.contains(m))
                      memberHealth.put(m, UnknownHealth)
                    else memberHealth,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  action LoseEtcdMember(m: MachineId): bool = all {
    MACHINES.contains(m),
    machines.contains(m),
    not(members.contains(m)),
    observation' = observation.put(m, NoCorrespondingMember),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Operator-facing lifecycle actions — scale and upgrade
  // ===============================================================

  // ChangeDesiredReplicas: the operator updates KCP's spec.replicas.
  // Allowed values are 1, 3, or 5 — even-numbered control planes
  // are not supported by KCP (no quorum benefit, two replicas can
  // tie a vote).
  action ChangeDesiredReplicas(n: int): bool = all {
    Set(1, 3, 5).contains(n),
    n != desiredReplicas,
    desiredReplicas' = n,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    template' = template, desiredTemplate' = desiredTemplate,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ScaleUpControlPlane: KCP creates a Machine because actual
  // replicas (machines.size()) is below the desired count. The
  // new Machine starts at desiredTemplate. The action is enabled
  // only when an unallocated MachineId is available AND the etcd
  // cluster's quorum tolerance can absorb the addition. The
  // quorum gate matches KCP's
  // `targetEtcdClusterHealthy(addEtcdMember=true)` check —
  // see formal/contracts/etcd-raft-contract.md and
  // controlplane/kubeadm/internal/controllers/remediation.go:692.
  //
  // Note: AddMachine remains as the lower-level action; ScaleUp
  // wraps it with the desiredReplicas guard plus the quorum gate.
  action ScaleUpControlPlane(m: MachineId): bool = all {
    not(machines.contains(m)),
    MACHINES.contains(m),
    machines.size() < desiredReplicas,
    targetEtcdClusterHealthy(members, learners, memberHealth,
                             true, NO_MEMBER),
    machines'    = machines.union(Set(m)),
    nodeRefSet'  = nodeRefSet.put(m, false),
    machineHealthLabel' = machineHealthLabel.put(m, UnknownHealthMachine),
    decision'    = decision.put(m, NoRemediationNeeded),
    phase'       = phase.put(m, NotStarted),
    kubeletReady' = kubeletReady.put(m, false),
    etcdMemberRegistered' = etcdMemberRegistered.put(m, false),
    template'     = template.put(m, desiredTemplate),
    nodeReachable' = nodeReachable.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas, desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ScaleDownControlPlane: KCP gracefully removes a healthy Machine
  // because actual replicas exceeds desired count. Distinct from
  // CompleteRemediation in that the machine is not failure-driven
  // — it is a planned removal. Gated on
  // `targetEtcdClusterHealthy(addEtcdMember=false,
  // etcdMemberToBeDeleted=m)` matching KCP's helper.
  action ScaleDownControlPlane(m: MachineId): bool = all {
    machines.contains(m),
    machines.size() > desiredReplicas,
    machineHealthLabel.keys().contains(m),
    machineHealthLabel.get(m) == HealthyMachine,
    members.contains(m),
    not(learners.contains(m)),
    targetEtcdClusterHealthy(members, learners, memberHealth,
                             false, m),
    machines' = machines.exclude(Set(m)),
    members'  = members.exclude(Set(m)),
    learners' = learners,
    decision' = decision,
    nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // InitiateUpgrade: the operator updates KCP's spec.template
  // (e.g. to a new Kubernetes version). KCP's rolling-update
  // controller subsequently scales up replacements with the new
  // template and scales down the old ones one at a time.
  action InitiateUpgrade(t: int): bool = all {
    1 <= t,
    t <= MAX_TEMPLATE_VERSION,
    t != desiredTemplate,
    desiredTemplate' = t,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Common failure-mode fault actions
  // ===============================================================

  // InvalidKubeletConfig — KubeletStarted has fired (the
  // NewKubeletStartPhase passed) but downstream the kubelet
  // detects misconfiguration and stops being Ready. Models a
  // common failure mode where TLS, CA bundle, or apiserver
  // address is wrong.
  action InvalidKubeletConfig(m: MachineId): bool = all {
    kubeletReady.keys().contains(m),
    kubeletReady.get(m),
    kubeletReady' = kubeletReady.put(m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EtcdJoinTimeout — the etcd Add Learner gRPC call timed out
  // (slow storage on the joining node, or peer-transport latency
  // above the dial timeout). Distinct from LearnerStuck which is
  // post-Add. Modelled as the joining machine's phase flipping to
  // JoinFailed with reason EtcdJoinAddLearnerFailed BEFORE the
  // learner is registered.
  action EtcdJoinTimeout(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == EtcdJoinAddLearner,
    not(etcdMemberRegistered.get(m)),
    phase'         = phase.put(m, JoinFailed),
    failureReason' = failureReason.put(m, EtcdJoinAddLearnerFailed),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // LbBroken — the apiserver LB proxy fails. KCP reaches the
  // workload-cluster apiserver through this LB, so its etcd
  // client probes fail across the board.
  action LbBroken: bool = all {
    lbHealthy,
    lbHealthy' = false,
    // Every observation flips to UnreachableTimeout because the
    // probe path is broken.
    observation' = MACHINES.filter(m => machines.contains(m))
                     .mapBy(_ => UnreachableTimeout),
    memberHealth' = MACHINES.filter(m => members.contains(m))
                      .mapBy(_ => UnknownHealth),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // NodeNeverJoins — the kubelet started, but the Node never
  // registers with the workload-cluster apiserver. CAPI cannot
  // talk to the Node directly. Models the "kubelet up but
  // apiserver unreachable from kubelet" failure.
  action NodeNeverJoins(m: MachineId): bool = all {
    nodeReachable.keys().contains(m),
    nodeReachable.get(m),
    kubeletReady.keys().contains(m),
    kubeletReady.get(m),
    not(nodeRefSet.get(m)),
    nodeReachable' = nodeReachable.put(m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Recovery actions — close the convergence loop
  // ===============================================================
  //
  // These actions model KCP behaviour that *should* exist to
  // recover from the failure modes the model otherwise exposes.
  // If the model does not converge with these actions enabled,
  // the failure mode is a KCP bug. If the model does not converge
  // even with them, but converges *only* under stronger
  // assumptions about the open system (e.g. an etcd partition
  // healing), the failure mode is exogenous.

  // HealLb — the apiserver LB proxy is restored. Modelled as
  // an exogenous recovery; the operator or infrastructure team
  // fixes the LB.
  action HealLb: bool = all {
    not(lbHealthy),
    lbHealthy' = true,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // RestoreClusterFromSnapshot — the operator's disaster-recovery
  // path. Restores etcd from a backup onto Machine m and brings
  // the cluster back up as a single-voter cluster. Required for
  // recovery from total-loss states (FM-16) where neither
  // remediation nor scale operations can fire because there are
  // no surviving voters.
  //
  // Modelled as an atomic transition: after firing, Machine m is
  // a healthy single-voter etcd cluster, leader at the current
  // term, with NodeRef resolved and observation ReachableHealthy.
  // Other Machines (if any in `machines`) are removed because
  // they are not part of the restored cluster — they would need
  // to re-join via kubeadm-join.
  //
  // This is exogenous: it requires operator action (no controller
  // can autonomously decide to restore from a snapshot because
  // the choice of snapshot is operator-policy). The action is
  // available in `step` but excluded from `stepNoRecovery`.
  //
  // Guard: m is in `machines` and `desiredReplicas == 1`. Multi-
  // node disaster recovery is a separate flow (snapshot-restore
  // followed by individual joins for the other nodes); the
  // model focuses on the single-node case which is the common
  // FM-16 path.
  action RestoreClusterFromSnapshot(m: MachineId): bool = all {
    machines.contains(m),
    desiredReplicas == 1,
    members'      = Set(m),
    learners'     = Set(),
    leaderAt'     = leaderAt.put(currentTerm, m),
    memberHealth' = Map(m -> Healthy),
    phase'        = phase.put(m, JoinComplete),
    failureReason' = Map(),
    etcdMemberRegistered' = etcdMemberRegistered.put(m, true),
    kubeletReady' = kubeletReady.put(m, true),
    machines'     = Set(m),
    nodeRefSet'   = Map(m -> true),
    machineHealthLabel' = Map(m -> HealthyMachine),
    decision'     = Map(m -> NoRemediationNeeded),
    blockReason'  = Map(),
    preflightBlocked' = false,
    template'     = Map(m -> desiredTemplate),
    observation'  = Map(m -> ReachableHealthy),
    lbHealthy'    = true,
    nodeReachable' = Map(m -> true),
    progress'     = Map(),
    currentTerm'  = currentTerm,
    desiredReplicas' = desiredReplicas,
    desiredTemplate' = desiredTemplate,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // RestoreNodeReachability — the workload-cluster apiserver
  // becomes reachable from the kubelet again, so the Node can
  // register. Exogenous recovery.
  action RestoreNodeReachability(m: MachineId): bool = all {
    nodeReachable.keys().contains(m),
    not(nodeReachable.get(m)),
    nodeReachable' = nodeReachable.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }


  // RemoveStuckLearner: KCP detects a learner stuck below the
  // promote threshold and removes the etcd member as part of
  // remediation. This is the action whose absence in the
  // modelled scenario stalled the cluster.
  action RemoveStuckLearner(m: MachineId): bool = all {
    learners.contains(m),
    progress.keys().contains(m),
    progress.get(m) == Stuck,
    voters(members.exclude(Set(m)), learners.exclude(Set(m))).size() >= 1,
    hasLeader(leaderAt, currentTerm),
    members'  = members.exclude(Set(m)),
    learners' = learners.exclude(Set(m)),
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // DeleteFailedMachine: KCP detects a JoinFailed Machine and
  // removes it from its set after also dropping any etcd member
  // that was registered. The Machine identifier becomes free to
  // be reused via AddMachine, which is the recovery loop.
  action DeleteFailedMachine(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == JoinFailed,
    machines.contains(m),
    not(members.contains(m)),  // etcd member already removed
    machines' = machines.exclude(Set(m)),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    nodeRefSet' = nodeRefSet, machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // HealEtcdReachability: an UnreachableTimeout / UnreachableNoRoute
  // observation flips back to ReachableHealthy. This is an
  // exogenous recovery — the network heals — and is required for
  // any failure mode that involves a partition.
  action HealEtcdReachability(m: MachineId): bool = all {
    MACHINES.contains(m),
    observation.keys().contains(m),
    val o = observation.get(m)
    o == UnreachableTimeout or o == UnreachableNoRoute,
    observation' = observation.put(m, ReachableHealthy),
    memberHealth' = if (members.contains(m)) memberHealth.put(m, Healthy) else memberHealth,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // Drain & PDB actions
  // ============================================================

  // BeginDrain — KCP starts draining a Machine that's been
  // RemediationInFlight. If a PodDisruptionBudget refused an
  // eviction, drainBlocked sticks; only DrainTimeout (force-delete)
  // clears it. Refines `controlplane/kubeadm/internal/controllers/scale.go`
  // (`scaleDownControlPlane`) and the Machine controller's drain
  // sequence.
  // Contract: D-DRAIN-TIMEOUT.
  action BeginDrain(m: MachineId): bool = all {
    machines.contains(m),
    decision.keys().contains(m),
    decision.get(m) == RemediationInFlight,
    drainBlocked.keys().contains(m),
    not(drainBlocked.get(m)),
    pdbViolatedFor.keys().contains(m),
    pdbViolatedFor.get(m),                            // PDB refusal triggers stuck drain
    drainBlocked' = drainBlocked.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // DrainTimeout — `nodeDrainTimeout` elapses, KCP force-deletes
  // the Machine bypassing PDB. Clears drainBlocked,
  // preflightBlocked, and advances the decision to Remediated.
  // Refines the upstream `Cluster.spec.controlPlane.machineDrainTimeout`
  // and `internal/controllers/machine/drain` package.
  // Contract: D-DRAIN-TIMEOUT.
  action DrainTimeout(m: MachineId): bool = all {
    drainBlocked.keys().contains(m),
    drainBlocked.get(m),
    decision.keys().contains(m),
    drainBlocked' = drainBlocked.put(m, false),
    decision' = decision.put(m, RemediationInFlight),  // remediation now unblocked
    preflightBlocked' = false,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    blockReason' = blockReason,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // Apiserver ↔ etcd actions
  // ============================================================

  // ApiserverEtcdConnect — kube-apiserver static pod's etcd v3
  // client reaches its configured etcd backend. Refines
  // `staging/src/k8s.io/apiserver/pkg/storage/etcd3/preflight/checks.go::CheckEtcdServers`.
  // Pre-condition: the underlying etcd member exists and the
  // network path is up (lbHealthy isn't strictly required since
  // apiserver typically talks to its local 127.0.0.1:2379).
  action ApiserverEtcdConnect(m: MachineId): bool = all {
    machines.contains(m),
    apiserverEtcdReachable.keys().contains(m),
    not(apiserverEtcdReachable.get(m)),
    members.contains(m) or members.size() > 0,        // some etcd member must exist
    apiserverEtcdReachable' = apiserverEtcdReachable.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ApiserverEtcdDisconnect — fault: apiserver's etcd connection
  // drops (etcd member crashed, network glitch, certificate
  // mismatch). Apiserver immediately fails its readiness probe
  // because the storage backend is unreachable. Refines the
  // failure path of `apiserver-pkg-storage-etcd3-store.go` ops
  // returning `rpctypes.ErrGRPCNoLeader` /
  // `rpctypes.ErrGRPCConnectFailed`.
  action ApiserverEtcdDisconnect(m: MachineId): bool = all {
    machines.contains(m),
    apiserverEtcdReachable.keys().contains(m),
    apiserverEtcdReachable.get(m),
    apiserverReady.keys().contains(m),
    apiserverEtcdReachable' = apiserverEtcdReachable.put(m, false),
    apiserverReady' = apiserverReady.put(m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ApiserverReadinessOk — kube-apiserver's readiness probe passes.
  // Refines `staging/src/k8s.io/apiserver/pkg/server/healthz/healthz.go`
  // (the readyz endpoint).
  action ApiserverReadinessOk(m: MachineId): bool = all {
    apiserverEtcdReachable.keys().contains(m),
    apiserverEtcdReachable.get(m),
    apiserverReady.keys().contains(m),
    not(apiserverReady.get(m)),
    apiserverReady' = apiserverReady.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EtcdCompactionStart — etcd auto-compaction begins. Holds the
  // bbolt mmap; gRPC reads spike to 10–60s. Refines
  // `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go::StartCompactorPerEndpoint`
  // and etcd's own auto-compaction loop. Marks all members as
  // UnknownHealth from the leader's view (mimicking FM-24's shape).
  action EtcdCompactionStart: bool = all {
    not(etcdCompactionInProgress),
    etcdCompactionInProgress' = true,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // containerd ↔ CRI lifecycle actions
  // ============================================================

  // ContainerdReady — kubelet's CRI gRPC client confirms containerd
  // is reachable and the RuntimeStatus RPC returns OK. Refines
  // kubelet's runtime probe at
  // `pkg/kubelet/kuberuntime/kuberuntime_manager.go::Status`.
  action ContainerdReady(m: MachineId): bool = all {
    machines.contains(m),
    criRuntimeReady.keys().contains(m),
    not(criRuntimeReady.get(m)),
    criRuntimeReady' = criRuntimeReady.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ContainerdCrash — fault: containerd process exits or its CRI
  // socket becomes unresponsive. All CRI lifecycle stages on this
  // Machine reset; the apiserver static pod becomes unreachable
  // because its container process is gone.
  action ContainerdCrash(m: MachineId): bool = all {
    machines.contains(m),
    criRuntimeReady.keys().contains(m),
    criRuntimeReady.get(m),
    criRuntimeReady' = criRuntimeReady.put(m, false),
    criImagesPulled' = criImagesPulled.put(m, false),
    criPodSandboxRunning' = criPodSandboxRunning.put(m, false),
    criContainersRunning' = criContainersRunning.put(m, false),
    apiserverEtcdReachable' = apiserverEtcdReachable.put(m, false),
    apiserverReady' = apiserverReady.put(m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // PullStaticPodImages — kubelet calls CRI's PullImage for the
  // apiserver, controller-manager, scheduler, and (if stacked)
  // local-etcd images. Refines
  // `pkg/kubelet/kuberuntime/kuberuntime_image.go:33::PullImage`
  // (kubeGenericRuntimeManager.PullImage).
  action PullStaticPodImages(m: MachineId): bool = all {
    machines.contains(m),
    criRuntimeReady.keys().contains(m),
    criRuntimeReady.get(m),
    criImagesPulled.keys().contains(m),
    not(criImagesPulled.get(m)),
    criImagesPulled' = criImagesPulled.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ImagePullFailed — fault: containerd cannot pull a static-pod
  // image (registry unreachable, image bad sha, auth failure).
  // Surfaces as `runtime.ErrImagePull` in
  // `pkg/kubelet/kuberuntime/kuberuntime_image.go`.
  action ImagePullFailed(m: MachineId): bool = all {
    machines.contains(m),
    criRuntimeReady.keys().contains(m),
    criRuntimeReady.get(m),
    criImagesPulled.keys().contains(m),
    not(criImagesPulled.get(m)),
    // Pull failed; criImagesPulled stays false; all downstream
    // CRI stages cannot progress. The model leaves the failure
    // observable as criImagesPulled=false until ContainerdReady
    // re-fires (e.g. operator fixes the registry).
    apiserverReady' = apiserverReady.put(m, false),
    apiserverEtcdReachable' = apiserverEtcdReachable.put(m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // CreatePodSandbox — kubelet calls CRI's RunPodSandbox to create
  // a pod sandbox (network namespace + cgroup) for the static
  // pods. Refines
  // `pkg/kubelet/kuberuntime/kuberuntime_sandbox.go:38::createPodSandbox`.
  action CreatePodSandbox(m: MachineId): bool = all {
    machines.contains(m),
    criImagesPulled.keys().contains(m),
    criImagesPulled.get(m),
    criPodSandboxRunning.keys().contains(m),
    not(criPodSandboxRunning.get(m)),
    criPodSandboxRunning' = criPodSandboxRunning.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // StartStaticPodContainers — kubelet calls CRI's CreateContainer
  // + StartContainer for every static-pod container (apiserver,
  // controller-manager, scheduler, local-etcd). Refines
  // `pkg/kubelet/kuberuntime/kuberuntime_container.go:199::startContainer`.
  action StartStaticPodContainers(m: MachineId): bool = all {
    machines.contains(m),
    criPodSandboxRunning.keys().contains(m),
    criPodSandboxRunning.get(m),
    criContainersRunning.keys().contains(m),
    not(criContainersRunning.get(m)),
    criContainersRunning' = criContainersRunning.put(m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // FM-37 — Lifecycle hook skipped under CP unavailable
  // ============================================================

  // TriggerPreUpgradeHook — adds "BeforeClusterUpgrade" to
  // hooksTriggered. The contract obligation L-HOOK-FIRES says
  // this MUST fire before any membership change driven by an
  // upgrade, regardless of control-plane availability. Refines
  // upstream cluster-api#8942.
  action TriggerPreUpgradeHook: bool = all {
    not(hooksTriggered.contains("BeforeClusterUpgrade")),
    hooksTriggered' = hooksTriggered.union(Set("BeforeClusterUpgrade")),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
  }

  // ============================================================
  // FM-34 — MHC stale cluster cache
  // ============================================================

  // MhcCacheStale — fault: MHC controller's cache-backed client
  // for the workload cluster goes stale during apiserver restart.
  // Refines cluster-api#12363.
  action MhcCacheStale: bool = all {
    not(mhcCacheStale),
    mhcCacheStale' = true,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    hooksTriggered' = hooksTriggered,
  }

  // MhcCacheRefresh — recovery: MHC controller refreshes its cache
  // for the workload cluster.
  action MhcCacheRefresh: bool = all {
    mhcCacheStale,
    mhcCacheStale' = false,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // FM-32 — Webhook rotation gap
  // ============================================================

  // WebhookRotationFault — cert-manager rotates the CAPI webhook
  // serving cert. For up to ~90s, mutating + validating webhooks
  // are unreachable. Refines cert-manager#10522.
  action WebhookRotationFault: bool = all {
    webhooksAvailable,
    webhooksAvailable' = false,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // WebhookHeal — cert-manager rotation completes; webhooks back
  // up. Recovery action.
  action WebhookHeal: bool = all {
    not(webhooksAvailable),
    webhooksAvailable' = true,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ============================================================
  // FM-31 — Custom Node conditions surfacing
  // ============================================================

  // CustomConditionObserved — operator's NPD or similar agent has
  // written a custom Node condition (e.g. "DiskPressure",
  // "MemoryPressure"). The operator wants this condition surfaced
  // on Machine.status without triggering MHC remediation. Refines
  // upstream cluster-api#11826: a "MachineSelfHealing without
  // remediation" capability that doesn't yet exist.
  // The model captures the observation by adding the key to
  // customCondition[m]; the v1beta2 condition projection is
  // expected to preserve every key (FM-31 obligation).
  action CustomConditionObserved(m: MachineId, key: str): bool = all {
    machines.contains(m),
    customCondition.keys().contains(m),
    not(customCondition.get(m).contains(key)),
    customCondition' = customCondition.put(m, customCondition.get(m).union(Set(key))),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ObservationRefresh — MHC's next reconcile picks up a fresh
  // observation. The model previously left observation[m] at its
  // init value with no transition path back to ReachableHealthy
  // when the underlying state had become healthy. This action
  // closes that gap: when the workload-side state has recovered
  // (kubelet ready, NodeRef set, apiserver reachable, etcd member
  // healthy), MHC's next observation MUST flip to ReachableHealthy.
  // Refines `internal/controllers/machinehealthcheck/machinehealthcheck_targets.go`
  // (MHC's per-target reconcile loop).
  action ObservationRefresh(m: MachineId): bool = all {
    machines.contains(m),
    nodeRefSet.keys().contains(m),
    nodeRefSet.get(m),
    members.contains(m),
    not(learners.contains(m)),
    memberHealth.keys().contains(m),
    memberHealth.get(m) == Healthy,
    apiserverReady.keys().contains(m),
    apiserverReady.get(m),
    observation.keys().contains(m),
    observation.get(m) != ReachableHealthy,
    observation' = observation.put(m, ReachableHealthy),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    etcdCompactionInProgress' = etcdCompactionInProgress,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // EtcdCompactionDone — auto-compaction completes; latency
  // returns to baseline. Recovery action.
  action EtcdCompactionDone: bool = all {
    etcdCompactionInProgress,
    etcdCompactionInProgress' = false,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    tlsBootstrapped' = tlsBootstrapped,
    kubeletManifestReady' = kubeletManifestReady,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    staticPodManifestsWritten' = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded' = kubeadmConfigUploaded,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
    drainBlocked' = drainBlocked,
    pdbViolatedFor' = pdbViolatedFor,
    apiserverEtcdReachable' = apiserverEtcdReachable,
    apiserverReady' = apiserverReady,
    criRuntimeReady' = criRuntimeReady,
    criImagesPulled' = criImagesPulled,
    criPodSandboxRunning' = criPodSandboxRunning,
    criContainersRunning' = criContainersRunning,
    customCondition' = customCondition,
    webhooksAvailable' = webhooksAvailable,
    mhcCacheStale' = mhcCacheStale,
    hooksTriggered' = hooksTriggered,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    // EtcdMembership
    nondet c = MACHINES.oneOf(); ElectLeader(c),
    AdvanceTerm,
    // ASSUMPTION (external etcd-membership management excluded):
    // Standalone `AddLearner(id)` is NOT in `step`. Etcd member-
    // add is legitimate only via the CAPI-provisioned Machine
    // lifecycle: AddMachine → BeginJoin → ... → EnterEtcdAddLearner
    // → EtcdAddLearnerSucceeded (which encodes kubeadm's direct
    // call to Cluster.MemberAddAsLearner during a CAPI-driven
    // bootstrap). External etcd managers (etcd-operator,
    // operator-driven `etcdctl member add`, externally-bootstrapped
    // etcd adopted by CAPI) are out of scope. See
    // formal/contracts/etcd-raft-contract.md §5b.
    nondet id = MACHINES.oneOf();
      nondet p = Set(Eligible, LaggingFar, Stuck).oneOf();
      ObserveLearnerProgress(id, p),
    nondet id = MACHINES.oneOf(); PromoteLearner(id),
    nondet id = MACHINES.oneOf(); RemoveMember(id),
    nondet id = MACHINES.oneOf(); LeaderStepDown(id),
    nondet src = MACHINES.oneOf();
      nondet dst = MACHINES.oneOf();
      TransferLeadership(src, dst),
    nondet id = MACHINES.oneOf();
      nondet h = Set(Healthy, Unhealthy, UnknownHealth).oneOf();
      MemberHealthChange(id, h),
    nondet id = MACHINES.oneOf(); LearnerStuck(id),
    // KubeadmJoin
    nondet m = MACHINES.oneOf(); BeginJoin(m),
    nondet m = MACHINES.oneOf(); PreflightPass(m),
    nondet m = MACHINES.oneOf(); DownloadCertsSucceeded(m),
    nondet m = MACHINES.oneOf(); EnterEtcdHealthCheck(m),
    nondet m = MACHINES.oneOf(); CheckEtcdHealth(m),
    nondet m = MACHINES.oneOf(); KubeletStarted(m),
    nondet m = MACHINES.oneOf(); KubeletTLSBootstrap(m),
    nondet m = MACHINES.oneOf(); RegisterLocalNode(m),
    nondet m = MACHINES.oneOf(); EnterEtcdAddLearner(m),
    nondet m = MACHINES.oneOf(); EtcdAddLearnerSucceeded(m),
    nondet m = MACHINES.oneOf(); EtcdQuorumReady(m),
    nondet m = MACHINES.oneOf(); MarkAsControlPlane(m),
    nondet m = MACHINES.oneOf(); UploadKubeadmConfig(m),
    nondet m = MACHINES.oneOf(); MarkReady(m),
    nondet m = MACHINES.oneOf();
      nondet r = Set(LearnerStuckOnPromote, KubeletNotReady,
                     PreflightCheckFailed, EtcdJoinAddLearnerFailed,
                     DownloadCertsFailed, StaticPodManifestWriteFailed,
                     EtcdHealthCheckFailed, TLSBootstrapTimeout,
                     LocalNodeRegistrationFailed,
                     KubeadmMarkControlPlaneFailed,
                     KubeadmUploadConfigFailed,
                     OtherJoinFailure).oneOf();
      JoinFailedAt(m, r),
    // KCPReconcile
    nondet m = MACHINES.oneOf(); AddMachine(m),
    nondet m = MACHINES.oneOf(); ResolveNodeRef(m),
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      MachineHealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateCanSafelyRemediate(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
    // MHC — exogenous faults only.
    nondet m = MACHINES.oneOf(); Partition(m),
    nondet m = MACHINES.oneOf(); LoseEtcdMember(m),
    // Lifecycle ops
    nondet n = Set(1, 3, 5).oneOf(); ChangeDesiredReplicas(n),
    nondet m = MACHINES.oneOf(); ScaleUpControlPlane(m),
    nondet m = MACHINES.oneOf(); ScaleDownControlPlane(m),
    nondet t = 1.to(MAX_TEMPLATE_VERSION).oneOf(); InitiateUpgrade(t),
    // New fault actions
    nondet m = MACHINES.oneOf(); InvalidKubeletConfig(m),
    nondet m = MACHINES.oneOf(); EtcdJoinTimeout(m),
    LbBroken,
    nondet m = MACHINES.oneOf(); NodeNeverJoins(m),
    // Drain
    nondet m = MACHINES.oneOf(); BeginDrain(m),
    nondet m = MACHINES.oneOf(); DrainTimeout(m),
    // Apiserver ↔ etcd
    nondet m = MACHINES.oneOf(); ApiserverEtcdConnect(m),
    nondet m = MACHINES.oneOf(); ApiserverEtcdDisconnect(m),
    nondet m = MACHINES.oneOf(); ApiserverReadinessOk(m),
    EtcdCompactionStart,
    EtcdCompactionDone,
    // containerd ↔ CRI lifecycle
    nondet m = MACHINES.oneOf(); ContainerdReady(m),
    nondet m = MACHINES.oneOf(); ContainerdCrash(m),
    nondet m = MACHINES.oneOf(); PullStaticPodImages(m),
    nondet m = MACHINES.oneOf(); ImagePullFailed(m),
    nondet m = MACHINES.oneOf(); CreatePodSandbox(m),
    nondet m = MACHINES.oneOf(); StartStaticPodContainers(m),
    // Recovery
    nondet m = MACHINES.oneOf(); RemoveStuckLearner(m),
    nondet m = MACHINES.oneOf(); DeleteFailedMachine(m),
    nondet m = MACHINES.oneOf(); HealEtcdReachability(m),
    HealLb,
    nondet m = MACHINES.oneOf(); RestoreNodeReachability(m),
    nondet m = MACHINES.oneOf(); RestoreClusterFromSnapshot(m),
    nondet m = MACHINES.oneOf(); ObservationRefresh(m),
    nondet m = MACHINES.oneOf();
      nondet k = Set("DiskPressure", "MemoryPressure", "NPDFault").oneOf();
      CustomConditionObserved(m, k),
    WebhookRotationFault,
    WebhookHeal,
    MhcCacheStale,
    MhcCacheRefresh,
    TriggerPreUpgradeHook,
  }

  // stepNoRecovery — same as step but with the three recovery
  // actions disabled. Used to ask "does the system converge
  // without KCP intervention?". If a scenario reaches
  // HealthyControlPlane under stepNoRecovery, the failure mode
  // is TRANSIENT or self-resolving. If it does NOT, the failure
  // mode requires explicit recovery action and is either KCP-BUG
  // (the recovery action exists but isn't wired to the controller)
  // or EXOGENOUS (the recovery action is HealEtcdReachability).
  action stepNoRecovery = any {
    nondet c = MACHINES.oneOf(); ElectLeader(c),
    AdvanceTerm,
    // AddLearner standalone removed from step — etcd member-add
    // is only legitimate via the kubeadm-join chain
    // (EtcdAddLearnerSucceeded). Free-firing AddLearner produced
    // ghost cycles in TLC ConvergenceFair (Phase 11b).
    nondet id = MACHINES.oneOf();
      nondet p = Set(Eligible, LaggingFar, Stuck).oneOf();
      ObserveLearnerProgress(id, p),
    nondet id = MACHINES.oneOf(); PromoteLearner(id),
    nondet id = MACHINES.oneOf(); RemoveMember(id),
    nondet id = MACHINES.oneOf(); LeaderStepDown(id),
    nondet src = MACHINES.oneOf();
      nondet dst = MACHINES.oneOf();
      TransferLeadership(src, dst),
    nondet id = MACHINES.oneOf();
      nondet h = Set(Healthy, Unhealthy, UnknownHealth).oneOf();
      MemberHealthChange(id, h),
    nondet id = MACHINES.oneOf(); LearnerStuck(id),
    nondet m = MACHINES.oneOf(); BeginJoin(m),
    nondet m = MACHINES.oneOf(); PreflightPass(m),
    nondet m = MACHINES.oneOf(); DownloadCertsSucceeded(m),
    nondet m = MACHINES.oneOf(); EnterEtcdHealthCheck(m),
    nondet m = MACHINES.oneOf(); CheckEtcdHealth(m),
    nondet m = MACHINES.oneOf(); KubeletStarted(m),
    nondet m = MACHINES.oneOf(); KubeletTLSBootstrap(m),
    nondet m = MACHINES.oneOf(); RegisterLocalNode(m),
    nondet m = MACHINES.oneOf(); EnterEtcdAddLearner(m),
    nondet m = MACHINES.oneOf(); EtcdAddLearnerSucceeded(m),
    nondet m = MACHINES.oneOf(); EtcdQuorumReady(m),
    nondet m = MACHINES.oneOf(); MarkAsControlPlane(m),
    nondet m = MACHINES.oneOf(); UploadKubeadmConfig(m),
    nondet m = MACHINES.oneOf(); MarkReady(m),
    nondet m = MACHINES.oneOf();
      nondet r = Set(LearnerStuckOnPromote, KubeletNotReady,
                     PreflightCheckFailed, EtcdJoinAddLearnerFailed,
                     DownloadCertsFailed, StaticPodManifestWriteFailed,
                     EtcdHealthCheckFailed, TLSBootstrapTimeout,
                     LocalNodeRegistrationFailed,
                     KubeadmMarkControlPlaneFailed,
                     KubeadmUploadConfigFailed,
                     OtherJoinFailure).oneOf();
      JoinFailedAt(m, r),
    nondet m = MACHINES.oneOf(); AddMachine(m),
    nondet m = MACHINES.oneOf(); ResolveNodeRef(m),
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      MachineHealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateCanSafelyRemediate(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
    nondet m = MACHINES.oneOf(); Partition(m),
    nondet m = MACHINES.oneOf(); LoseEtcdMember(m),
    nondet n = Set(1, 3, 5).oneOf(); ChangeDesiredReplicas(n),
    nondet m = MACHINES.oneOf(); ScaleUpControlPlane(m),
    nondet m = MACHINES.oneOf(); ScaleDownControlPlane(m),
    nondet t = 1.to(MAX_TEMPLATE_VERSION).oneOf(); InitiateUpgrade(t),
    nondet m = MACHINES.oneOf(); InvalidKubeletConfig(m),
    nondet m = MACHINES.oneOf(); EtcdJoinTimeout(m),
    LbBroken,
    nondet m = MACHINES.oneOf(); NodeNeverJoins(m),
    nondet m = MACHINES.oneOf(); BeginDrain(m),
    nondet m = MACHINES.oneOf(); ApiserverEtcdDisconnect(m),
    EtcdCompactionStart,
    nondet m = MACHINES.oneOf(); ContainerdCrash(m),
    nondet m = MACHINES.oneOf(); ImagePullFailed(m),
    WebhookRotationFault,
    MhcCacheStale,
    // No DrainTimeout, ApiserverEtcdConnect, ApiserverReadinessOk,
    // EtcdCompactionDone, ContainerdReady, PullStaticPodImages,
    // CreatePodSandbox, StartStaticPodContainers, RemoveStuckLearner,
    // DeleteFailedMachine, HealEtcdReachability, HealLb, or
    // RestoreNodeReachability.
  }

  // stepRemediation — minimal step relation that includes only
  // the actions relevant to the KCP remediation gate. Used for
  // the IncidentNeverInFlight / IncidentBlockReasonCorrect
  // exhaustive proof at small horizons; the full `step` relation
  // is intractable for TLC at max-steps>=3 because of action
  // fanout, but `stepRemediation` is bounded enough to verify.
  action stepRemediation = any {
    nondet m = MACHINES.oneOf(); ResolveNodeRef(m),
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      MachineHealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateCanSafelyRemediate(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
  }

  // ===============================================================
  // Predicates
  // ===============================================================

  // A control plane is *healthy* iff every condition below holds.
  // Topology requirement: machines.size() == desiredReplicas
  // ensures we don't accept "healthy" while a scale operation is
  // pending. desiredReplicas in {1, 3, 5} is enforced by
  // ChangeDesiredReplicas's guard.
  val HealthyControlPlane =
    // Topology
    machines.size() == desiredReplicas and
    Set(1, 3, 5).contains(desiredReplicas) and
    // KCP
    machines.forall(m =>
      nodeRefSet.keys().contains(m) and nodeRefSet.get(m)) and
    // Etcd
    voters(members, learners).size() >= quorumOf(machines.size()) and
    members == machines and
    learners == Set() and
    voters(members, learners).forall(v =>
      memberHealth.keys().contains(v) and memberHealth.get(v) == Healthy) and
    hasLeader(leaderAt, currentTerm) and
    // Remediation
    machines.forall(m =>
      decision.keys().contains(m) implies
        (decision.get(m) == NoRemediationNeeded
          or decision.get(m) == RemediationInFlight)) and
    not(machines.exists(m =>
      decision.keys().contains(m) and decision.get(m) == RemediationBlocked)) and
    not(preflightBlocked) and
    // MHC
    machines.forall(m =>
      observation.keys().contains(m) implies
        observation.get(m) == ReachableHealthy) and
    // Connectivity
    lbHealthy and
    machines.forall(m =>
      nodeReachable.keys().contains(m) and nodeReachable.get(m)) and
    // Upgrade complete — every Machine on the desired template
    machines.forall(m =>
      template.keys().contains(m) and template.get(m) == desiredTemplate)

  // ===============================================================
  // Safety invariants (true at every reachable state)
  // ===============================================================

  val LearnerCannotVote =
    learners.subseteq(members)

  val VoterSetNonEmpty =
    machines.size() == 0 or voters(members, learners).size() >= 1

  // KCP's invariant: at the moment a Machine is admitted to
  // RemediationInFlight, the matchable set equals the machine
  // set. Because that condition can be falsified by subsequent
  // AddMachine actions, we cannot state it as a *current-state*
  // invariant; instead the action's guard (in
  // EvaluateCanSafelyRemediate) is the enforcement point. The
  // invariant retained here is the weaker form: a Machine in
  // RemediationInFlight cannot itself be NodeRef-less.
  val RemediationTargetHasNodeRef =
    MACHINES.forall(m =>
      (decision.keys().contains(m) and decision.get(m) == RemediationInFlight)
        implies (nodeRefSet.keys().contains(m) and nodeRefSet.get(m)))

  val AllSafetyInvariants = all {
    LearnerCannotVote,
    VoterSetNonEmpty,
    RemediationTargetHasNodeRef,
  }

  // ===============================================================
  // Incident-witness invariants
  // ===============================================================
  //
  // The modelled scenario's defining shape is: a Machine
  // exists in `machines` without a NodeRef AND it is
  // RemediationRequested. KCP must refuse to admit it to
  // RemediationInFlight; instead it must record
  // RemediationBlocked with blockReason
  // EtcdMemberSetDoesNotMatchMachineSet.
  //
  // The two invariants below together state:
  //
  //   1. `IncidentNeverInFlight` — under the FM-1
  //      preconditions, no Machine ever holds
  //      RemediationInFlight. This is the *positive* invariant —
  //      KCP correctly refuses.
  //
  //   2. `IncidentBlockReasonCorrect` — when KCP HAS recorded a
  //      block on a no-NodeRef Machine, the reason is the
  //      matchable-set mismatch (not, say, QuorumWouldBeLost).
  //      This pins the diagnostic content of the block.

  val IncidentPrecondition =
    machines.exists(m =>
      machines.contains(m)
        and nodeRefSet.keys().contains(m)
        and not(nodeRefSet.get(m)))

  val IncidentNeverInFlight =
    IncidentPrecondition implies
      not(machines.exists(m =>
            decision.keys().contains(m)
              and decision.get(m) == RemediationInFlight
              and not(nodeRefSet.get(m))))

  val IncidentBlockReasonCorrect =
    machines.forall(m =>
      (machines.contains(m)
        and nodeRefSet.keys().contains(m)
        and not(nodeRefSet.get(m))
        and decision.keys().contains(m)
        and decision.get(m) == RemediationBlocked)
      implies
        (blockReason.keys().contains(m)
          and blockReason.get(m) == EtcdMemberSetDoesNotMatchMachineSet))

  // ===============================================================
  // Convergence (liveness) — the user's load-bearing requirement
  // ===============================================================
  //
  // The system MUST eventually reach a healthy control plane and
  // stay there. Modelled as a temporal property because it is a
  // liveness obligation.
  //
  // Quint expresses this with `temporal`. Counterexamples come
  // from loops that never reach HealthyControlPlane or that leave
  // it without returning.
  //
  // Without a fairness assumption, every state can stutter
  // indefinitely (a controller chooses to do nothing). The
  // `Convergence` form below states the unconditional liveness;
  // `ConvergenceFair` states the same conclusion under weak
  // fairness on the master step, which is the engineering
  // assumption: whenever an action is enabled, it eventually
  // fires.

  temporal Convergence = eventually(always(HealthyControlPlane))

  // ConvergenceRecurrent — recurrence form: from any reachable
  // state, HealthyControlPlane is eventually reachable. Strictly
  // weaker than `eventually(always(HealthyControlPlane))`, so a
  // verdict on this is more meaningful in the presence of
  // recurring faults. Phase 11c.
  temporal ConvergenceRecurrent = always(eventually(HealthyControlPlane))

  // ConvergenceMinimalFair — Phase 11c diagnostic. Strong-fair on
  // just ElectLeader (the single most critical action from `init`).
  // If TLC distinguishes vacuous-vs-genuine on this minimal form,
  // we can incrementally widen the fairness scope.
  temporal ConvergenceMinimalFair =
    strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars)
      implies eventually(hasLeader(leaderAt, currentTerm))

  // Phase 11d — bisecting minimal strong-fair set. The 65-conjunct
  // ConvergenceFair causes TLC's tableau to overflow ("0 branches"
  // == tautology). Smaller scopes give meaningful verdicts.

  // 8-conjunct candidate minimal set: just the actions needed to
  // (a) elect a leader, (b) drive a join to completion, (c) restore
  // health after a fault, (d) complete remediation. The intuition
  // is that all the kubeadm-join phases between PreflightPass and
  // MarkReady will progress through KubeletStarted/etc. once
  // ElectLeader and the recovery actions are strongly fair.
  temporal ConvergenceFair8 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(HealLb, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // 4-conjunct candidate (halve point): just the from-init essentials.
  temporal ConvergenceFair4 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // 8-conjunct recurrence form. Strong-fair on healing; recurrence
  // claim. After each fault, healing eventually restores
  // HealthyControlPlane.
  temporal ConvergenceRecurrentFair8 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(HealLb, allVars)
    )
      implies always(eventually(HealthyControlPlane))

  // 16-conjunct candidate (double point): if 8 tableaus to >0 branches,
  // try doubling toward the full set.
  temporal ConvergenceFair16 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet p = (Set(Eligible, LaggingFar, Stuck)).oneOf(); ObserveLearnerProgress(id, p) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet h = (Set(Healthy, Unhealthy, UnknownHealth)).oneOf(); MemberHealthChange(id, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RequestRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EvaluateCanSafelyRemediate(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(HealLb, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreNodeReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreClusterFromSnapshot(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DrainTimeout(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ObservationRefresh(m) }, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // 17-conjunct: 16-conjunct + EtcdCompactionDone. Issue #5
  // depth-bump finding: at depth 12 (was 8), TLC found a lasso
  // through `EtcdCompactionStart` because the 16-conjunct scope
  // didn't fair-schedule `EtcdCompactionDone`. The compaction
  // recovery is essential for liveness once etcdCompactionInProgress
  // becomes reachable in deeper traces.
  temporal ConvergenceFair17 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet p = (Set(Eligible, LaggingFar, Stuck)).oneOf(); ObserveLearnerProgress(id, p) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet h = (Set(Healthy, Unhealthy, UnknownHealth)).oneOf(); MemberHealthChange(id, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RequestRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EvaluateCanSafelyRemediate(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(HealLb, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreNodeReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreClusterFromSnapshot(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DrainTimeout(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ObservationRefresh(m) }, allVars) and
      strongFair(EtcdCompactionDone, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // 24-conjunct candidate. Adds the kubeadm-join chain healing
  // actions (BeginJoin..MarkReady minus the ones in 16) and the
  // KCP scale + remediation healing actions to the 16-conjunct set.
  temporal ConvergenceFair24 =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet p = (Set(Eligible, LaggingFar, Stuck)).oneOf(); ObserveLearnerProgress(id, p) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet h = (Set(Healthy, Unhealthy, UnknownHealth)).oneOf(); MemberHealthChange(id, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); BeginJoin(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); PreflightPass(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); KubeletStarted(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdAddLearnerSucceeded(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdQuorumReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); AddMachine(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RequestRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EvaluateCanSafelyRemediate(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleUpControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleDownControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(HealLb, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreNodeReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreClusterFromSnapshot(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DrainTimeout(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ObservationRefresh(m) }, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // ConvergenceFair — convergence under weak-fairness on `step`.
  // Engineering assumption: whenever any step transition is
  // enabled, it eventually fires (controllers do not stutter
  // forever). Generated by `hack/tools/quint-fairness-gen.py`.
  // See `formal/failure-modes.md` FM-9 for the verdict.
  // The varSet for fairness is the tuple of all state variables;
  // Quint compiles this to TLA+'s `<<vars>>` tuple.
  val allVars = (members, learners, leaderAt, currentTerm,
    progress, memberHealth, phase, failureReason,
    etcdMemberRegistered, kubeletReady, tlsBootstrapped,
    kubeletManifestReady, nodeLocallyRegistered,
    staticPodManifestsWritten, kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded, machines, nodeRefSet,
    machineHealthLabel, decision, blockReason, preflightBlocked,
    desiredReplicas, template, desiredTemplate, observation,
    lbHealthy, nodeReachable, drainBlocked, pdbViolatedFor,
    apiserverEtcdReachable, apiserverReady,
    etcdCompactionInProgress, criRuntimeReady, criImagesPulled,
    criPodSandboxRunning, criContainersRunning, customCondition,
    webhooksAvailable, mhcCacheStale, hooksTriggered)

  // Phase 11b: per-action fairness expansion. The earlier
  // `weakFair(step, allVars)` form admitted ghost cycles where
  // faults re-fired forever (TLC found counterexamples via
  // AddLearner→RemoveMember and MachineHealthChange flip-flops).
  // Strong-fair on healing/forward-progress; weak-fair on faults.
  // Generated by hack/tools/quint-fairness-gen.py.
  temporal ConvergenceFair =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet p = (Set(Eligible, LaggingFar, Stuck)).oneOf(); ObserveLearnerProgress(id, p) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); RemoveMember(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); LeaderStepDown(id) }, allVars) and
      strongFair(any { nondet src = (MACHINES).oneOf(); nondet dst = (MACHINES).oneOf(); TransferLeadership(src, dst) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet h = (Set(Healthy, Unhealthy, UnknownHealth)).oneOf(); MemberHealthChange(id, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); BeginJoin(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); PreflightPass(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DownloadCertsSucceeded(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EnterEtcdHealthCheck(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CheckEtcdHealth(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); KubeletStarted(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); KubeletTLSBootstrap(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RegisterLocalNode(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EnterEtcdAddLearner(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdAddLearnerSucceeded(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdQuorumReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkAsControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); UploadKubeadmConfig(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); AddMachine(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RequestRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EvaluateCanSafelyRemediate(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleUpControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleDownControlPlane(m) }, allVars) and
      strongFair(HealLb, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreNodeReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreClusterFromSnapshot(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RemoveStuckLearner(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DeleteFailedMachine(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DrainTimeout(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ApiserverEtcdConnect(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ApiserverReadinessOk(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ContainerdReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); PullStaticPodImages(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CreatePodSandbox(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); StartStaticPodContainers(m) }, allVars) and
      strongFair(TriggerPreUpgradeHook, allVars) and
      strongFair(MhcCacheRefresh, allVars) and
      strongFair(WebhookHeal, allVars) and
      strongFair(EtcdCompactionDone, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ObservationRefresh(m) }, allVars) and
      weakFair(AdvanceTerm, allVars) and
      weakFair(any { nondet id = (MACHINES).oneOf(); LearnerStuck(id) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); nondet r = (Set(LearnerStuckOnPromote, KubeletNotReady, PreflightCheckFailed, EtcdJoinAddLearnerFailed, DownloadCertsFailed, StaticPodManifestWriteFailed, EtcdHealthCheckFailed, TLSBootstrapTimeout, LocalNodeRegistrationFailed, KubeadmMarkControlPlaneFailed, KubeadmUploadConfigFailed, OtherJoinFailure)).oneOf(); JoinFailedAt(m, r) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); Partition(m) }, allVars) and
      weakFair(LbBroken, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); LoseEtcdMember(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); NodeNeverJoins(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); InvalidKubeletConfig(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); EtcdJoinTimeout(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ContainerdCrash(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ImagePullFailed(m) }, allVars) and
      weakFair(WebhookRotationFault, allVars) and
      weakFair(MhcCacheStale, allVars) and
      weakFair(EtcdCompactionStart, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ApiserverEtcdDisconnect(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); BeginDrain(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); nondet k = (Set("DiskPressure", "MemoryPressure", "NPDFault")).oneOf(); CustomConditionObserved(m, k) }, allVars) and
      weakFair(any { nondet n = (Set(1, 3, 5)).oneOf(); ChangeDesiredReplicas(n) }, allVars) and
      weakFair(any { nondet t = (1.to(MAX_TEMPLATE_VERSION)).oneOf(); InitiateUpgrade(t) }, allVars)
    )
      implies eventually(always(HealthyControlPlane))

  // ConvergenceRecurrentFair — Phase 11c. Same per-action fairness
  // assumption as ConvergenceFair but with the weaker recurrence
  // claim: HealthyControlPlane is visited infinitely often. This
  // is a meaningful liveness statement even when faults recur:
  // after each fault, healing eventually restores the cluster.
  temporal ConvergenceRecurrentFair =
    (
      strongFair(any { nondet c = (MACHINES).oneOf(); ElectLeader(c) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); PromoteLearner(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet p = (Set(Eligible, LaggingFar, Stuck)).oneOf(); ObserveLearnerProgress(id, p) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); RemoveMember(id) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); LeaderStepDown(id) }, allVars) and
      strongFair(any { nondet src = (MACHINES).oneOf(); nondet dst = (MACHINES).oneOf(); TransferLeadership(src, dst) }, allVars) and
      strongFair(any { nondet id = (MACHINES).oneOf(); nondet h = (Set(Healthy, Unhealthy, UnknownHealth)).oneOf(); MemberHealthChange(id, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); BeginJoin(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); PreflightPass(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DownloadCertsSucceeded(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EnterEtcdHealthCheck(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CheckEtcdHealth(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); KubeletStarted(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); KubeletTLSBootstrap(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RegisterLocalNode(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EnterEtcdAddLearner(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdAddLearnerSucceeded(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EtcdQuorumReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkAsControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); UploadKubeadmConfig(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); MarkReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); AddMachine(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ResolveNodeRef(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); nondet h = (Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)).oneOf(); MachineHealthChange(m, h) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RequestRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); EvaluateCanSafelyRemediate(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CompleteRemediation(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleUpControlPlane(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ScaleDownControlPlane(m) }, allVars) and
      strongFair(HealLb, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); HealEtcdReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreNodeReachability(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RestoreClusterFromSnapshot(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); RemoveStuckLearner(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DeleteFailedMachine(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); DrainTimeout(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ApiserverEtcdConnect(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ApiserverReadinessOk(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ContainerdReady(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); PullStaticPodImages(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); CreatePodSandbox(m) }, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); StartStaticPodContainers(m) }, allVars) and
      strongFair(TriggerPreUpgradeHook, allVars) and
      strongFair(MhcCacheRefresh, allVars) and
      strongFair(WebhookHeal, allVars) and
      strongFair(EtcdCompactionDone, allVars) and
      strongFair(any { nondet m = (MACHINES).oneOf(); ObservationRefresh(m) }, allVars) and
      weakFair(AdvanceTerm, allVars) and
      weakFair(any { nondet id = (MACHINES).oneOf(); LearnerStuck(id) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); nondet r = (Set(LearnerStuckOnPromote, KubeletNotReady, PreflightCheckFailed, EtcdJoinAddLearnerFailed, DownloadCertsFailed, StaticPodManifestWriteFailed, EtcdHealthCheckFailed, TLSBootstrapTimeout, LocalNodeRegistrationFailed, KubeadmMarkControlPlaneFailed, KubeadmUploadConfigFailed, OtherJoinFailure)).oneOf(); JoinFailedAt(m, r) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); Partition(m) }, allVars) and
      weakFair(LbBroken, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); LoseEtcdMember(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); NodeNeverJoins(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); InvalidKubeletConfig(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); EtcdJoinTimeout(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ContainerdCrash(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ImagePullFailed(m) }, allVars) and
      weakFair(WebhookRotationFault, allVars) and
      weakFair(MhcCacheStale, allVars) and
      weakFair(EtcdCompactionStart, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); ApiserverEtcdDisconnect(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); BeginDrain(m) }, allVars) and
      weakFair(any { nondet m = (MACHINES).oneOf(); nondet k = (Set("DiskPressure", "MemoryPressure", "NPDFault")).oneOf(); CustomConditionObserved(m, k) }, allVars) and
      weakFair(any { nondet n = (Set(1, 3, 5)).oneOf(); ChangeDesiredReplicas(n) }, allVars) and
      weakFair(any { nondet t = (1.to(MAX_TEMPLATE_VERSION)).oneOf(); InitiateUpgrade(t) }, allVars)
    )
      implies always(eventually(HealthyControlPlane))

  // ===============================================================
  // Example runs
  // ===============================================================

  // The happy path — Machine 4 joins, learner promotes, becomes a
  // healthy 4-member control plane.
  run happyJoin = init
    .then(ElectLeader(1))                                   // term 1 leader
    .then(AddMachine(4))                                    // KCP creates Machine 4
    .then(BeginJoin(4))                                     // Bootstrap signals
    .then(PreflightPass(4))                                 // → DownloadCerts
    .then(DownloadCertsSucceeded(4))                        // → StaticPodManifestsWritten
    .then(EnterEtcdHealthCheck(4))                          // → EtcdHealthCheck
    .then(CheckEtcdHealth(4))                               // → KubeletStart
    .then(KubeletStarted(4))                                // → KubeletTLSBootstrapped
    .then(KubeletTLSBootstrap(4))                           // → KubeletManifestReady
    .then(RegisterLocalNode(4))                             // → NodeRegistered
    .then(EnterEtcdAddLearner(4))                           // → EtcdJoinAddLearner
    .then(EtcdAddLearnerSucceeded(4))                       // joins as learner
    .then(ObserveLearnerProgress(4, Eligible))              // catches up
    .then(PromoteLearner(4))                                // is_learner -> false
    .then(EtcdQuorumReady(4))                               // → KubeadmMarkControlPlane
    .then(MarkAsControlPlane(4))                            // → KubeadmUploadConfig
    .then(UploadKubeadmConfig(4))                           // → MarkControlPlaneReady
    .then(MarkReady(4))                                     // → JoinComplete
    .then(ResolveNodeRef(4))                                // node registers
    .then(MachineHealthChange(4, HealthyMachine))           // KCP rolls health up

  // -------------------------------------------------------------
  // Init actions — direct state construction for TLC reachability
  // -------------------------------------------------------------
  //
  // Quint refuses `quint verify` when an action appears both in
  // an init scenario chain and in `step`. The workaround is an
  // init action that constructs the post-scenario state directly
  // by assignment, bypassing the action chain. Each init below
  // mirrors the corresponding `*Scenario` run; both forms are
  // kept because runs are easier to read while inits are TLC-
  // verifiable.

  // Bootstrapped 3-machine cluster with a leader at term 1, a
  // partitioned network from MHC's perspective. Memberset still
  // {1,2,3}; observation flipped to UnreachableTimeout for all
  // three; etcd-side health flipped to UnknownHealth.
  action partitionedClusterInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    lbHealthy'       = true,
    nodeReachable'   = Set(1, 2, 3).mapBy(_ => true),
    customCondition'   = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'   = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'   = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'   = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'   = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'   = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'   = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'   = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'   = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'   = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // 4-machine KCP set, but machine 4 is registered with KCP only
  // (no etcd member). MHC has observed NoCorrespondingMember.
  // Models FM-5: latent KCP-bug if Bootstrap is stuck.
  action noCorrespondingMemberInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                     .put(4, NoCorrespondingMember),
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    lbHealthy'       = true,
    nodeReachable'   = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'   = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'   = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'   = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'   = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'   = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'   = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'   = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // Bootstrapped 3-machine cluster with a leader, a stuck learner
  // (machine 4) registered as etcd member but progress=Stuck, and
  // a JoinFailed phase recorded with reason LearnerStuckOnPromote.
  action stuckLearnerInit = all {
    members'      = Set(1, 2, 3, 4),
    learners'     = Set(4),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(4 -> Stuck),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy)
                      .put(4, UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, JoinFailed),
    failureReason'        = Map(4 -> LearnerStuckOnPromote),
    etcdMemberRegistered' = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    lbHealthy'       = true,
    nodeReachable'   = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'   = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'   = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'   = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'   = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'   = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'   = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'   = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'   = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // FM-2 — 2-machine cluster with one Unhealthy voter
  // -------------------------------------------------------------
  //
  // This is a transient state: a 3-node cluster mid-scale-down,
  // or a 5-node cluster having lost two members in quick
  // succession. desiredReplicas is set to 3 (the steady-state
  // target the operator wants to return to), but actual
  // machines.size() = 2.
  //
  // Machine 1 is the surviving voter, healthy on every channel.
  // Machine 2 is the remaining member but its etcd Status RPC is
  // timing out: observation = UnreachableTimeout, memberHealth =
  // UnknownHealth. From KCP's view it is unhealthy and a
  // candidate for remediation.
  //
  // Under KCP's targetEtcdClusterHealthy gate:
  //   * Remediating Machine 2 needs target voter (1) - unhealthy
  //     (the new member, worst-case unhealthy because existing>1
  //     ⇒ assumed-unhealthy, plus the existing 1 stays healthy)
  //     → target after remediation = 1 voter, 0 unhealthy,
  //     quorum 1 → 1 >= 1 → ALLOWED. So remediation MIGHT fire.
  //
  // Wait — but remediation requires matchableMachines == machines
  // AND targetEtcdClusterHealthy. Both Machines have NodeRef in
  // this scenario, so matchable check passes. The transition
  // 2-machine → 1-machine etcd cluster is allowed by KCP.
  //
  // The "hopelessness" claim is therefore narrower than I first
  // wrote: from a 2-machine cluster with one unhealthy and the
  // other healthy, KCP CAN remediate. The system is not
  // hopeless — it converges to a 1-voter cluster, then scales up
  // back to 3.
  //
  // Truly hopeless: 2-machine cluster where BOTH members are
  // unhealthy. Below is that variant: machine 1 also has
  // observation = UnreachableTimeout. Under stepNoRecovery,
  // neither member can flip back to Healthy (MemberHealthChange
  // is gated on observation, observation only flips back via
  // HealEtcdReachability which is recovery-only). KCP's
  // targetEtcdClusterHealthy refuses every transition.

  action twoMachineBothUnhealthyInit = all {
    members'      = Set(1, 2),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(1 -> UnknownHealth, 2 -> UnknownHealth),
    phase'                = Map(1 -> JoinComplete, 2 -> JoinComplete,
                                3 -> NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Map(1 -> true, 2 -> true, 3 -> false),
    kubeletReady'         = Map(1 -> true, 2 -> true, 3 -> false),
    tlsBootstrapped'         = Map(1 -> true, 2 -> true, 3 -> false),
    kubeletManifestReady'         = Map(1 -> true, 2 -> true, 3 -> false),
    nodeLocallyRegistered'         = Map(1 -> true, 2 -> true, 3 -> false),
    staticPodManifestsWritten'         = Map(1 -> true, 2 -> true, 3 -> false),
    kubeadmMarkedAsControlPlane'         = Map(1 -> true, 2 -> true, 3 -> false),
    kubeadmConfigUploaded'         = Map(1 -> true, 2 -> true, 3 -> false),
    machines'    = Set(1, 2),
    nodeRefSet'  = Map(1 -> true, 2 -> true),
    machineHealthLabel' = Map(1 -> UnhealthyMachine, 2 -> UnhealthyMachine),
    decision'    = Map(1 -> NoRemediationNeeded, 2 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Map(1 -> 1, 2 -> 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> UnreachableTimeout, 2 -> UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Map(1 -> true, 2 -> true),
    customCondition'  = Map(1 -> Set(), 2 -> Set()),
    criRuntimeReady'  = Map(1 -> true, 2 -> true),
    criImagesPulled'  = Map(1 -> true, 2 -> true),
    criPodSandboxRunning'  = Map(1 -> true, 2 -> true),
    criContainersRunning'  = Map(1 -> true, 2 -> true),
    drainBlocked'  = Map(1 -> false, 2 -> false),
    pdbViolatedFor'  = Map(1 -> false, 2 -> false),
    apiserverEtcdReachable'  = Map(1 -> true, 2 -> true),
    apiserverReady'  = Map(1 -> true, 2 -> true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // Incident init — faithful reconstruction of the production
  // state at example-cluster
  // observed in the modelled scenario
  // -------------------------------------------------------------
  //
  // Mapping:
  //   Machine 1  = zwdl9 — the leader's Machine (NodeRef set,
  //                EtcdMemberHealthy=Unknown because the leader's
  //                etcd client cannot reach the workload-cluster
  //                etcd to confirm health — the gRPC routing bug
  //                described in the FM-1 spec).
  //   Machine 2, 3 = the other two control-plane Machines that
  //                completed the join and are healthy.
  //   Machine 4  = crhpt — the new joining Machine that
  //                kubadm-join started but never finished. Etcd
  //                member registered as a learner; promotion
  //                stalled (Stuck progress); kubeadm-join exited
  //                with reason LearnerStuckOnPromote. Critical
  //                detail: no NodeRef yet (the kubelet reached
  //                the apiserver but the Node never registered
  //                fully, so KCP cannot match it to the etcd
  //                member by node name).
  //
  // The model's state mirrors what KCP would observe via its
  // controllerRuntime cache. The MHC observation on Machine 1
  // (the leader) is UnreachableTimeout — that's what produces
  // the EtcdMemberHealthy=Unknown condition projection.
  action incidentInit = all {
    // Etcd-side
    members'      = Set(1, 2, 3, 4),
    learners'     = Set(4),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(4 -> Stuck),
    memberHealth' = Set(1).mapBy(_ => UnknownHealth)        // leader's Status timed out
                      .put(2, Healthy).put(3, Healthy)
                      .put(4, UnknownHealth),
    // Kubeadm-join
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, JoinFailed),
    failureReason'        = Map(4 -> LearnerStuckOnPromote),
    etcdMemberRegistered' = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    // FM-1: kubelet up, TLS-bootstrapped, manifests applied,
    // etcd-add-learner succeeded — but Node never registered and
    // mark-control-plane / uploadconfig phases never ran because
    // kubeadm-join hung at WaitForEtcdQuorum.
    tlsBootstrapped'             = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, true),
    kubeletManifestReady'        = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, true),
    nodeLocallyRegistered'       = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, false),  // FM-1 shape: Node never registered
    staticPodManifestsWritten'   = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, true),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, false),  // never reached mark-cp
    kubeadmConfigUploaded'       = Set(1, 2, 3).mapBy(_ => true)
                                     .put(4, false),  // never reached uploadconfig
    // KCP — Machine 4 is in machines but has no NodeRef
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1).mapBy(_ => UnknownHealthMachine)  // leader can't be confirmed
                            .put(2, HealthyMachine).put(3, HealthyMachine)
                            .put(4, UnhealthyMachine),                  // MHC will request remediation
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    // MHC: leader observed as UnreachableTimeout (matches
    // EtcdMemberHealthy=Unknown projection); learner has no
    // corresponding registered Node; the other two are healthy.
    observation' = Map(1 -> UnreachableTimeout,
                       2 -> ReachableHealthy,
                       3 -> ReachableHealthy,
                       4 -> NoCorrespondingMember),
    lbHealthy'      = true,    // the LB itself is fine
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // Failure-mode scenarios — keyed by the rows in
  // ../failure-modes.md
  // -------------------------------------------------------------

  // FM-1 — Stuck learner. End state: kubeadm-join failed with
  // LearnerStuckOnPromote, etcd member 4 is a Stuck learner, KCP
  // refuses to remediate (no recovery action invoked).
  run stuckLearnerScenario = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(DownloadCertsSucceeded(4))
    .then(EnterEtcdHealthCheck(4))
    .then(CheckEtcdHealth(4))
    .then(KubeletStarted(4))
    .then(KubeletTLSBootstrap(4))
    .then(RegisterLocalNode(4))
    .then(EnterEtcdAddLearner(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(LearnerStuck(4))
    .then(JoinFailedAt(4, LearnerStuckOnPromote))

  // FM-3 — Partitioned cluster: every Machine flips to
  // UnreachableTimeout via the exogenous Partition fault.
  run partitionedClusterScenario = init
    .then(ElectLeader(1))
    .then(Partition(1))
    .then(Partition(2))
    .then(Partition(3))

  // FM-4 — Promote-before-NodeRef window. End state: voter 4
  // exists in etcd but nodeRefSet[4]=false transiently.
  run nodeRefDelayScenario = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(DownloadCertsSucceeded(4))
    .then(EnterEtcdHealthCheck(4))
    .then(CheckEtcdHealth(4))
    .then(KubeletStarted(4))
    .then(KubeletTLSBootstrap(4))
    .then(RegisterLocalNode(4))
    .then(EnterEtcdAddLearner(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))
    .then(EtcdQuorumReady(4))
    .then(MarkAsControlPlane(4))
    .then(UploadKubeadmConfig(4))
    .then(MarkReady(4))
    // ResolveNodeRef not yet fired — voter without NodeRef.

  // FM-5 — MHC observation stuck on NoCorrespondingMember. KCP
  // added a Machine but kubeadm-join never started (e.g. Bootstrap
  // is broken).
  run noCorrespondingMemberScenario = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(LoseEtcdMember(4))

  // FM-6 — Etcd leader vacancy: term advances, no leader.
  run leaderVacancyScenario = init
    .then(ElectLeader(1))
    .then(AdvanceTerm)

  // FM-7 — Concurrent remediation. Two unhealthy machines, only
  // one admitted at a time (the second is RemediationBlocked
  // until the first completes).
  run cascadingRemediationScenario = init
    .then(ElectLeader(1))
    .then(MachineHealthChange(2, UnhealthyMachine))
    .then(MachineHealthChange(3, UnhealthyMachine))
    .then(RequestRemediation(2))
    .then(EvaluateCanSafelyRemediate(2))
    .then(RequestRemediation(3))

  // FM-8 — InformativenessObligation violation. The
  // DeriveCondition projection drops the upstream error chain.
  run informativenessRegressionScenario = init
    .then(Partition(2))

  // FM-10 — Stale health rollup. Etcd-side UnknownHealth coexists
  // with KCP-side HealthyMachine.
  run staleHealthRollupScenario = init
    .then(ElectLeader(1))
    .then(MemberHealthChange(2, UnknownHealth))
    .then(MachineHealthChange(2, HealthyMachine))

  // -------------------------------------------------------------
  // New failure-mode init actions and scenarios (FM-11..FM-16)
  // -------------------------------------------------------------

  // FM-11 — InvalidKubeletConfig — three-node cluster, one Machine
  // (4) joined as etcd voter (its kubelet was Ready) but a config
  // drift flips kubeletReady back to false. The Machine's NodeRef
  // is now considered stale.
  action invalidKubeletInit = all {
    members'      = Set(1, 2, 3, 4),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3, 4).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3, 4).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-12 — Etcd join times out due to slow storage. Machine 4 is
  // stuck mid-EtcdJoinAddLearner phase; its etcd member was never
  // registered (the Add Learner gRPC timed out before being
  // accepted by the leader).
  action slowStorageEtcdJoinInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, JoinFailed),
    failureReason'        = Map(4 -> EtcdJoinAddLearnerFailed),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                     .put(4, NoCorrespondingMember),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-13 / FM-14 — apiserver LB proxy broken. KCP's etcd client
  // probe path is broken; every voter's MHC observation flipped
  // to UnreachableTimeout. The cluster's internal etcd is fine —
  // KCP just cannot tell.
  action lbBrokenInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = false,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-15 — Kubelet started but Node never registers. Machine 4
  // joined etcd (voter), kubelet is Ready, but Node never
  // registered with the workload-cluster apiserver. KCP's
  // matchable check fails because nodeRefSet[4] = false.
  action nodeNeverJoinsInit = all {
    members'      = Set(1, 2, 3, 4),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3, 4).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3, 4).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-16 — Upgrade in progress: desiredTemplate has been bumped
  // to 2, the rolling-update controller scaled up Machine 4 with
  // template 2 (replacement for one of the old Machines), but the
  // join hasn't completed yet. desiredReplicas remains 3; the
  // model temporarily holds 4 machines. Convergence requires the
  // join to complete and one of the old Machines to be scaled down.
  action upgradeInFlightInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1).put(4, 2),
    desiredTemplate' = 2,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // Topology-specific scenarios
  // -------------------------------------------------------------

  // 1-node cluster losing its only voter — irrecoverable: no
  // quorum, cannot remediate. The recovery path is operator
  // intervention to rebuild from a snapshot.
  action singleNodeLostVoterInit = all {
    members'      = Set(),
    learners'     = Set(),
    leaderAt'     = Map(),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(1 -> UnknownHealth),
    phase'                = Map(1 -> JoinFailed),
    failureReason'        = Map(1 -> KubeletNotReady),
    etcdMemberRegistered' = Map(1 -> false),
    kubeletReady'         = Map(1 -> false),
    tlsBootstrapped'         = Map(1 -> false),
    kubeletManifestReady'         = Map(1 -> false),
    nodeLocallyRegistered'         = Map(1 -> false),
    staticPodManifestsWritten'         = Map(1 -> false),
    kubeadmMarkedAsControlPlane'         = Map(1 -> false),
    kubeadmConfigUploaded'         = Map(1 -> false),
    machines'    = Set(1),
    nodeRefSet'  = Map(1 -> false),
    machineHealthLabel' = Map(1 -> UnhealthyMachine),
    decision'    = Map(1 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 1,
    template'        = Map(1 -> 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Map(1 -> false),
    customCondition'  = Map(1 -> Set()),
    criRuntimeReady'  = Map(1 -> false),
    criImagesPulled'  = Map(1 -> false),
    criPodSandboxRunning'  = Map(1 -> false),
    criContainersRunning'  = Map(1 -> false),
    drainBlocked'  = Map(1 -> false),
    pdbViolatedFor'  = Map(1 -> false),
    apiserverEtcdReachable'  = Map(1 -> false),
    apiserverReady'  = Map(1 -> false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // 5-node cluster with a stuck learner being promoted — same
  // shape as stuckLearnerInit but at 5-node topology.
  action fiveNodeStuckLearnerInit = all {
    members'      = Set(1, 2, 3, 4, 5, 6),
    learners'     = Set(6),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(6 -> Stuck),
    memberHealth' = Set(1, 2, 3, 4, 5).mapBy(_ => Healthy)
                      .put(6, UnknownHealth),
    phase'                = Set(1, 2, 3, 4, 5).mapBy(_ => JoinComplete)
                              .put(6, JoinFailed),
    failureReason'        = Map(6 -> LearnerStuckOnPromote),
    etcdMemberRegistered' = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4, 5, 6),
    nodeRefSet'  = Set(1, 2, 3, 4, 5).mapBy(_ => true).put(6, false),
    machineHealthLabel' = Set(1, 2, 3, 4, 5).mapBy(_ => HealthyMachine)
                            .put(6, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4, 5, 6).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 5,
    template'        = Set(1, 2, 3, 4, 5, 6).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4, 5).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4, 5, 6).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // FM-17..FM-37 — additional failure-mode init actions
  //
  // Seeded by the upstream-issue research in
  // ../upstream-issues-research.md and the operational concerns
  // listed in ../failure-modes.md. Each init constructs the
  // post-fault state directly so it can be paired with TLC /
  // Apalache verification and with `quint run --init=<name>` for
  // sampled exploration.
  // -------------------------------------------------------------

  // FM-17 — kubeadm-join misconfiguration: the joining Machine's
  // kubelet starts with a wrong apiserver endpoint baked into
  // /etc/kubernetes/kubelet.conf. Kubelet runs but cannot
  // register a Node; etcd join never starts because kubeadm-
  // join's NewKubeletStartPhase succeeds but the subsequent
  // EtcdJoinPhase requires the kubelet to be Ready.
  action kubeadmMisconfigInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, JoinFailed),
    failureReason'        = Map(4 -> KubeletNotReady),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3, 4).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                     .put(4, NoCorrespondingMember),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false).put(4, false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-18 — concurrent scale-up + remediation race. KCP wants to
  // scale up from 3 to 5 (desiredReplicas changed); meanwhile
  // Machine 1 has flipped to UnhealthyMachine. Both ScaleUp and
  // RequestRemediation are pending. The targetEtcdClusterHealthy
  // gate must serialise: only one membership change at a time.
  action concurrentScaleAndRemediateInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(1 -> Unhealthy, 2 -> Healthy, 3 -> Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Map(1 -> UnhealthyMachine, 2 -> HealthyMachine, 3 -> HealthyMachine),
    decision'    = Map(1 -> RemediationRequested, 2 -> NoRemediationNeeded, 3 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 5,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> ReachableUnhealthy, 2 -> ReachableHealthy, 3 -> ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-19 — apiserver restart relist storm. The workload-cluster
  // apiserver restarts, all watch clients reconnect, and KCP's
  // controllers re-list every Machine / KubeadmConfig / etcd
  // member. The "restart" maps to a transient lbHealthy=false
  // followed by lbHealthy=true a short time later. Modelled as
  // an FM-13-shaped state but with all observations briefly
  // unknown rather than UnreachableTimeout.
  action apiserverRestartInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => UnknownHealthMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = false,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-20 — upgrade rollout abort mid-flight. Operator initiated
  // upgrade to template 2, KCP scaled up Machine 4 with
  // template 2. Before Machine 4 promoted, operator decided to
  // roll back: desiredTemplate flipped back to 1. Machine 4 is
  // still on template 2 and is mid-join.
  action upgradeRollbackMidFlightInit = all {
    members'      = Set(1, 2, 3, 4),
    learners'     = Set(4),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(4 -> LaggingFar),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy)
                      .put(4, UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, WaitForEtcdQuorum),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true).put(4, false),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(4, UnknownHealthMachine),
    decision'    = Set(1, 2, 3, 4).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1).put(4, 2),
    desiredTemplate' = 1,                       // ← rolled back!
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                     .put(4, NoCorrespondingMember),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-21 — five-node cluster losing two voters concurrently
  // (the largest tolerable failure). Quorum still met (3/5),
  // remediation should proceed for both.
  action fiveNodeTwoFailuresInit = all {
    members'      = Set(1, 2, 3, 4, 5),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(1 -> Healthy, 2 -> Healthy, 3 -> Healthy,
                        4 -> UnknownHealth, 5 -> UnknownHealth),
    phase'                = Set(1, 2, 3, 4, 5).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4, 5),
    nodeRefSet'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machineHealthLabel' = Map(1 -> HealthyMachine, 2 -> HealthyMachine,
                              3 -> HealthyMachine,
                              4 -> UnhealthyMachine, 5 -> UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4, 5).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 5,
    template'        = Set(1, 2, 3, 4, 5).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> ReachableHealthy, 2 -> ReachableHealthy,
                       3 -> ReachableHealthy,
                       4 -> UnreachableTimeout, 5 -> UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4, 5).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-2 replica-sweep companions (issue #27) ----------------------
  //
  // The base FM-2 init (`twoMachineBothUnhealthyInit`) covers N=2.
  // These sister inits widen the sweep across N ∈ {3, 5, 7} for the
  // same "all voters unreachable, no recovery possible" hopelessness
  // shape. N=1 is covered by `singleNodeLostVoterInit`.

  // N=3: every CP voter is UnknownHealth and unreachable. Under
  // `stepNoRecovery` the cluster cannot rejoin a healthy majority.
  action threeNodeAllUnhealthyInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => UnhealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // N=5: every CP voter unhealthy.
  action fiveNodeAllUnhealthyInit = all {
    members'      = Set(1, 2, 3, 4, 5),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3, 4, 5).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3, 4, 5).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4, 5),
    nodeRefSet'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3, 4, 5).mapBy(_ => UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4, 5).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 5,
    template'        = Set(1, 2, 3, 4, 5).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4, 5).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4, 5).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    apiserverReady'  = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // N=7: every CP voter unhealthy. Note MACHINES = 1..8 already
  // accommodates this; one slot (8) stays NotStarted.
  action sevenNodeAllUnhealthyInit = all {
    members'      = Set(1, 2, 3, 4, 5, 6, 7),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    machines'    = Set(1, 2, 3, 4, 5, 6, 7),
    nodeRefSet'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => UnhealthyMachine),
    decision'    = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 7,
    template'        = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => false),
    apiserverReady'  = Set(1, 2, 3, 4, 5, 6, 7).mapBy(_ => false),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-22 — single-node cluster scale-up race. The 1-node cluster
  // is scaling up to 3 (desiredReplicas=3, machines={1}). Machine
  // 2 added as etcd learner; before promotion the only voter
  // Machine 1 becomes unhealthy.
  action singleNodeScaleUpFailureInit = all {
    members'      = Set(1, 2),
    learners'     = Set(2),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(2 -> LaggingFar),
    memberHealth' = Map(1 -> UnknownHealth, 2 -> UnknownHealth),
    phase'                = Map(1 -> JoinComplete, 2 -> WaitForEtcdQuorum),
    failureReason'        = Map(),
    etcdMemberRegistered' = Map(1 -> true, 2 -> true),
    kubeletReady'         = Map(1 -> true, 2 -> true),
    tlsBootstrapped'         = Map(1 -> true, 2 -> true),
    kubeletManifestReady'         = Map(1 -> true, 2 -> true),
    nodeLocallyRegistered'         = Map(1 -> true, 2 -> true),
    staticPodManifestsWritten'         = Map(1 -> true, 2 -> true),
    kubeadmMarkedAsControlPlane'         = Map(1 -> true, 2 -> true),
    kubeadmConfigUploaded'         = Map(1 -> true, 2 -> true),
    machines'    = Set(1, 2),
    nodeRefSet'  = Map(1 -> true, 2 -> false),
    machineHealthLabel' = Map(1 -> UnhealthyMachine, 2 -> UnknownHealthMachine),
    decision'    = Map(1 -> NoRemediationNeeded, 2 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Map(1 -> 1, 2 -> 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> UnreachableTimeout, 2 -> NoCorrespondingMember),
    lbHealthy'      = true,
    nodeReachable'  = Map(1 -> true, 2 -> true),
    customCondition'  = Map(1 -> Set(), 2 -> Set()),
    criRuntimeReady'  = Map(1 -> true, 2 -> true),
    criImagesPulled'  = Map(1 -> true, 2 -> true),
    criPodSandboxRunning'  = Map(1 -> true, 2 -> true),
    criContainersRunning'  = Map(1 -> true, 2 -> true),
    drainBlocked'  = Map(1 -> false, 2 -> false),
    pdbViolatedFor'  = Map(1 -> false, 2 -> false),
    apiserverEtcdReachable'  = Map(1 -> true, 2 -> true),
    apiserverReady'  = Map(1 -> true, 2 -> true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-23 — Drain stuck on PDB. A Machine is being deleted
  // (CompleteRemediation pre-stage); kubelet is unreachable; PDBs
  // block eviction. Modelled as the etcdMember already removed
  // (so quorum gate was passed) but the Machine still in `machines`
  // because the drain stalls. KCP will not retry membership
  // change because the machine.deletionTimestamp is set but the
  // delete has not finalised.
  action drainStuckInit = all {
    members'      = Set(2, 3),                     // member 1 already removed
    learners'     = Set(),
    leaderAt'     = Map(1 -> 2),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Map(2 -> Healthy, 3 -> Healthy),
    phase'                = Set(2, 3).mapBy(_ => JoinComplete)
                              .put(1, JoinComplete),    // still phase=JoinComplete
    failureReason'        = Map(),
    etcdMemberRegistered' = Map(1 -> false, 2 -> true, 3 -> true),
    kubeletReady'         = Map(1 -> false, 2 -> true, 3 -> true),
    tlsBootstrapped'         = Map(1 -> false, 2 -> true, 3 -> true),
    kubeletManifestReady'         = Map(1 -> false, 2 -> true, 3 -> true),
    nodeLocallyRegistered'         = Map(1 -> false, 2 -> true, 3 -> true),
    staticPodManifestsWritten'         = Map(1 -> false, 2 -> true, 3 -> true),
    kubeadmMarkedAsControlPlane'         = Map(1 -> false, 2 -> true, 3 -> true),
    kubeadmConfigUploaded'         = Map(1 -> false, 2 -> true, 3 -> true),
    machines'    = Set(1, 2, 3),                   // 1 still in machine set, deletion stuck
    nodeRefSet'  = Map(1 -> true, 2 -> true, 3 -> true),
    machineHealthLabel' = Map(1 -> UnhealthyMachine, 2 -> HealthyMachine, 3 -> HealthyMachine),
    decision'    = Map(1 -> RemediationInFlight, 2 -> NoRemediationNeeded, 3 -> NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = true,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Map(1 -> UnreachableTimeout, 2 -> ReachableHealthy, 3 -> ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Map(1 -> false, 2 -> true, 3 -> true),
    customCondition'  = Map(1 -> Set(), 2 -> Set(), 3 -> Set()),
    criRuntimeReady'  = Map(1 -> false, 2 -> true, 3 -> true),
    criImagesPulled'  = Map(1 -> false, 2 -> true, 3 -> true),
    criPodSandboxRunning'  = Map(1 -> false, 2 -> true, 3 -> true),
    criContainersRunning'  = Map(1 -> false, 2 -> true, 3 -> true),
    drainBlocked'   = Map(1 -> true, 2 -> false, 3 -> false),
    pdbViolatedFor' = Map(1 -> true, 2 -> false, 3 -> false),
    apiserverEtcdReachable' = Map(1 -> false, 2 -> true, 3 -> true),
    apiserverReady' = Map(1 -> false, 2 -> true, 3 -> true),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-24 — etcd defrag pause. Etcd's defrag operation
  // (`etcdctl defrag`) blocks the leader for 10-60s on bbolt;
  // during that window every Status RPC times out, KCP marks
  // every member's EtcdMemberHealthy as Unknown, but nothing is
  // actually broken. Distinct from FM-3 because the cause is
  // self-imposed; recovery is the defrag finishing.
  action etcdDefragPauseInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // leaderRemovalRaceInit — Machine 1 is the current etcd leader and
  // has just flipped to UnhealthyMachine. KCP wants to remediate it,
  // which requires removing it from the etcd member set. Etcd refuses
  // to remove the current leader; KCP MUST call ForwardEtcdLeadership
  // (TransferLeadership) or wait for the leader's lease to lapse
  // (LeaderStepDown) before RemoveMember(1) can succeed.
  // 3-CP topology, Machine 4 reserved for replacement.
  action leaderRemovalRaceInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy)
                      .put(1, UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete)
                              .put(4, NotStarted),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    tlsBootstrapped'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeletManifestReady'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    nodeLocallyRegistered'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    staticPodManifestsWritten'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmMarkedAsControlPlane'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    kubeadmConfigUploaded'         = Set(1, 2, 3).mapBy(_ => true)
                              .put(4, false),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                              .put(1, UnhealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded)
                      .put(1, RemediationRequested),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                      .put(1, UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition'  = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady'  = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled'  = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning'  = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning'  = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked'  = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor'  = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable'  = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady'  = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress'  = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-37 — Lifecycle hook skipped when CP unavailable.
  // 3-CP cluster, all observation=UnreachableTimeout (CP unavailable),
  // operator just initiated upgrade (desiredTemplate=2). KCP MUST
  // fire BeforeClusterUpgrade hook before any membership change.
  // Refines cluster-api#8942.
  action lifecycleHookSkippedInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => UnknownHealth),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'      = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady' = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'= Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'= Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => UnknownHealthMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 2,                         // upgrade just initiated
    observation' = Set(1, 2, 3).mapBy(_ => UnreachableTimeout),
    lbHealthy'      = false,                      // CP unavailable
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition' = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady' = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled' = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning' = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning' = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked' = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor' = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable' = Set(1, 2, 3).mapBy(_ => false),  // apiserver down
    apiserverReady' = Set(1, 2, 3).mapBy(_ => false),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),                     // hook NOT yet fired
  }

  // FM-34 — MHC stale cluster cache.
  // 3-CP cluster healthy; workload-cluster apiserver has just
  // restarted; MHC's cache for this cluster is stale.
  // Refines cluster-api#12363.
  action mhcCacheStaleInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'      = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady' = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'= Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'= Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    lbHealthy'      = false,                          // apiserver mid-restart
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition' = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady' = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled' = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning' = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning' = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked' = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor' = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable' = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady' = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = true,
    mhcCacheStale' = true,
    hooksTriggered' = Set(),
  }

  // FM-32 — Webhook rotation gap.
  // 3-CP cluster healthy; cert-manager has just rotated the CAPI
  // webhook serving cert; webhooks unreachable for the rotation
  // window. KCP is mid-remediation (decision[1]=RemediationRequested).
  // The cluster waits for WebhookHeal; without it, no membership
  // change can complete. Refines cert-manager#10522.
  action webhookRotationInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'      = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady' = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'= Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'= Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine)
                            .put(1, UnhealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded)
                      .put(1, RemediationRequested),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy)
                      .put(1, UnreachableTimeout),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition' = Set(1, 2, 3).mapBy(_ => Set()),
    criRuntimeReady' = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled' = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning' = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning' = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked' = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor' = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable' = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady' = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = false,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // FM-31 — Custom Node conditions surfacing.
  // 3-CP cluster healthy; Machine 1 carries a custom Node condition
  // ("DiskPressure") written by an operator's NPD agent. KCP MUST
  // surface this condition on Machine.status without triggering MHC
  // remediation. Refines upstream cluster-api#11826.
  action customConditionInit = all {
    members'      = Set(1, 2, 3),
    learners'     = Set(),
    leaderAt'     = Map(1 -> 1),
    currentTerm'  = 1,
    progress'     = Map(),
    memberHealth' = Set(1, 2, 3).mapBy(_ => Healthy),
    phase'                = Set(1, 2, 3).mapBy(_ => JoinComplete),
    failureReason'        = Map(),
    etcdMemberRegistered' = Set(1, 2, 3).mapBy(_ => true),
    kubeletReady'         = Set(1, 2, 3).mapBy(_ => true),
    tlsBootstrapped'      = Set(1, 2, 3).mapBy(_ => true),
    kubeletManifestReady' = Set(1, 2, 3).mapBy(_ => true),
    nodeLocallyRegistered'= Set(1, 2, 3).mapBy(_ => true),
    staticPodManifestsWritten' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmMarkedAsControlPlane' = Set(1, 2, 3).mapBy(_ => true),
    kubeadmConfigUploaded'= Set(1, 2, 3).mapBy(_ => true),
    machines'    = Set(1, 2, 3),
    nodeRefSet'  = Set(1, 2, 3).mapBy(_ => true),
    machineHealthLabel' = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'    = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason' = Map(),
    preflightBlocked' = false,
    desiredReplicas' = 3,
    template'        = Set(1, 2, 3).mapBy(_ => 1),
    desiredTemplate' = 1,
    observation' = Set(1, 2, 3).mapBy(_ => ReachableHealthy),
    lbHealthy'      = true,
    nodeReachable'  = Set(1, 2, 3).mapBy(_ => true),
    customCondition' = Set(1, 2, 3).mapBy(_ => Set())
                         .put(1, Set("DiskPressure")),
    criRuntimeReady' = Set(1, 2, 3).mapBy(_ => true),
    criImagesPulled' = Set(1, 2, 3).mapBy(_ => true),
    criPodSandboxRunning' = Set(1, 2, 3).mapBy(_ => true),
    criContainersRunning' = Set(1, 2, 3).mapBy(_ => true),
    drainBlocked' = Set(1, 2, 3).mapBy(_ => false),
    pdbViolatedFor' = Set(1, 2, 3).mapBy(_ => false),
    apiserverEtcdReachable' = Set(1, 2, 3).mapBy(_ => true),
    apiserverReady' = Set(1, 2, 3).mapBy(_ => true),
    etcdCompactionInProgress' = false,
    webhooksAvailable' = true,
    mhcCacheStale' = false,
    hooksTriggered' = Set(),
  }

  // -------------------------------------------------------------
  // Incident proof scenario — drives the production state through
  // RequestRemediation + EvaluateCanSafelyRemediate and asserts
  // the model produces RemediationBlocked with the expected
  // blockReason. The run is deterministic; both invariants
  // (IncidentNeverInFlight and IncidentBlockReasonCorrect) hold
  // through every step.
  run incidentRemediationBlockedRun = incidentInit
    .then(RequestRemediation(4))                  // MHC flags Machine 4
    .then(EvaluateCanSafelyRemediate(4))          // KCP evaluates — must block
    // Post-state: decision[4] = RemediationBlocked,
    //             blockReason[4] = EtcdMemberSetDoesNotMatchMachineSet,
    //             preflightBlocked = true.
    .then(all { assert(decision.get(4) == RemediationBlocked),
                assert(blockReason.get(4) == EtcdMemberSetDoesNotMatchMachineSet),
                assert(preflightBlocked),
                members' = members, learners' = learners, leaderAt' = leaderAt,
                currentTerm' = currentTerm, progress' = progress,
                memberHealth' = memberHealth,
                phase' = phase, failureReason' = failureReason,
                etcdMemberRegistered' = etcdMemberRegistered,
                kubeletReady' = kubeletReady,
                tlsBootstrapped' = tlsBootstrapped,
                kubeletManifestReady' = kubeletManifestReady,
                nodeLocallyRegistered' = nodeLocallyRegistered,
                staticPodManifestsWritten' = staticPodManifestsWritten,
                kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
                kubeadmConfigUploaded' = kubeadmConfigUploaded,
                machines' = machines, nodeRefSet' = nodeRefSet,
                machineHealthLabel' = machineHealthLabel,
                decision' = decision, blockReason' = blockReason,
                preflightBlocked' = preflightBlocked,
                desiredReplicas' = desiredReplicas,
                template' = template, desiredTemplate' = desiredTemplate,
                observation' = observation,
                lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
                drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
                apiserverEtcdReachable' = apiserverEtcdReachable,
                apiserverReady' = apiserverReady,
                etcdCompactionInProgress' = etcdCompactionInProgress,
                criRuntimeReady' = criRuntimeReady,
                criImagesPulled' = criImagesPulled,
                criPodSandboxRunning' = criPodSandboxRunning,
                criContainersRunning' = criContainersRunning,
                customCondition' = customCondition,
                webhooksAvailable' = webhooksAvailable,
                mhcCacheStale' = mhcCacheStale,
                hooksTriggered' = hooksTriggered })

  // FM-1 — learner stuck at promotion. Without recovery,
  // never converges. With RemoveStuckLearner + DeleteFailedMachine,
  // converges via the recovery path.
  // Phase 11c — fairness witness. A deterministic execution that
  // exercises a fair convergence path: from `init`, elect leader,
  // join Machine 4, reach HealthyControlPlane, stay there. If the
  // `ConvergenceFair` tautology is GENUINE (not vacuous), at least
  // one such fair execution exists.
  //
  // The run reaches HealthyControlPlane=true at the final step.
  // Verified by: quint run --invariant='not(HealthyControlPlane)'
  //              --init=fairConvergenceWitnessRun --max-steps=0
  // Expected: [violation] (HealthyControlPlane reached).
  run fairConvergenceWitnessRun = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(DownloadCertsSucceeded(4))
    .then(EnterEtcdHealthCheck(4))
    .then(CheckEtcdHealth(4))
    .then(KubeletStarted(4))
    .then(KubeletTLSBootstrap(4))
    .then(RegisterLocalNode(4))
    .then(EnterEtcdAddLearner(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))
    .then(EtcdQuorumReady(4))
    .then(MarkAsControlPlane(4))
    .then(UploadKubeadmConfig(4))
    .then(MarkReady(4))
    .then(ResolveNodeRef(4))
    .then(MachineHealthChange(4, HealthyMachine))
    .then(ChangeDesiredReplicas(5))   // operator scales to 4 wait, 5 isn't 4
    // After ChangeDesiredReplicas(5), machines.size()=4 ≠ 5, so
    // HealthyControlPlane requires more provisioning; the witness
    // ends after MachineHealthChange — at that point machines={1,2,3,4},
    // desiredReplicas=3, machines.size()≠desiredReplicas. To reach
    // HealthyControlPlane we'd need to ScaleDown one machine first.
    // The simpler witness just stops at MachineHealthChange and
    // verifies machines==members==voters with leader.

  // IC-11 — Upgrade rollback mid-flight recovery.
  // Init: upgradeRollbackMidFlightInit. Machine 4 (template 2, learner)
  // exists; desiredTemplate was rolled back to 1.
  // Recovery: KCP detects template mismatch on the in-flight Machine 4,
  // aborts its join, removes Machine 4 from etcd and from the
  // machines set. The cluster settles back at 3 machines (Machines 1,
  // 2, 3) on template 1 — the pre-rollout state.
  run upgradeRollbackRecoveryRun = upgradeRollbackMidFlightInit
    .then(JoinFailedAt(4, OtherJoinFailure))         // KCP aborts the in-flight join
    .then(RemoveMember(4))                           // etcd-side cleanup (Machine 4 is a learner, not the leader)
    .then(DeleteFailedMachine(4))                    // KCP-side cleanup; cluster back to 3 machines

  run incidentRecovered = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(DownloadCertsSucceeded(4))
    .then(EnterEtcdHealthCheck(4))
    .then(CheckEtcdHealth(4))
    .then(KubeletStarted(4))
    .then(KubeletTLSBootstrap(4))
    .then(RegisterLocalNode(4))
    .then(EnterEtcdAddLearner(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(LearnerStuck(4))                                  // exogenous fault
    .then(JoinFailedAt(4, LearnerStuckOnPromote))
    .then(RemoveStuckLearner(4))                            // recovery: drop member
    .then(DeleteFailedMachine(4))                           // recovery: delete Machine
    .then(AddMachine(4))                                    // recovery: recreate Machine
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(DownloadCertsSucceeded(4))
    .then(EnterEtcdHealthCheck(4))
    .then(CheckEtcdHealth(4))
    .then(KubeletStarted(4))
    .then(KubeletTLSBootstrap(4))
    .then(RegisterLocalNode(4))
    .then(EnterEtcdAddLearner(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))
    .then(EtcdQuorumReady(4))
    .then(MarkAsControlPlane(4))
    .then(UploadKubeadmConfig(4))
    .then(MarkReady(4))
    .then(ResolveNodeRef(4))
    .then(MachineHealthChange(4, HealthyMachine))

}
