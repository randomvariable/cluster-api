// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// KubeadmJoin.qnt — phase sequencing of `kubeadm join
// --control-plane` from the perspective of a single joining
// machine. The model collapses kubeadm's internal phases into the
// granularity that affects KCP's observability: when the kubelet
// has started, when the new etcd member has been registered as a
// learner, when quorum has been re-established post-promotion,
// when the node has registered with the apiserver.
//
// The model deliberately does not represent every kubeadm phase.
// Phases below the abstraction line (preflight subroutines, cert
// generation) are folded into the surrounding observable phase.
//
// Refines: cmd/kubeadm/app/cmd/join.go (upstream kubernetes), as
//          observed by CAPI through Bootstrap and Machine status.
// Contract: formal/contracts/kubeadm-etcd-contract.md
module KubeadmJoin {

  // -------------------------------------------------------------
  // Phases
  // -------------------------------------------------------------

  // The observable phase a joining machine occupies. The phase
  // lattice is total: phases advance monotonically until either
  // JoinComplete or JoinFailed terminates the run.
  //
  // The phase set covers every kubeadm-join sub-phase whose failure
  // requires manual operator intervention — kubeadm exits with an
  // error, KCP records JoinFailed with the specific reason, and a
  // human must run kubeadm reset + remediation before the Machine
  // can re-attempt the join.
  //
  // Phase set (kubeadm-join sub-phase ordering, recent K8s):
  //   NotStarted             — Bootstrap controller has not signalled join.
  //   Preflight              — kubeadm join preflight (kernel modules, ports, runtime).
  //   DownloadCerts          — control-plane-prepare/download-certs: copies the
  //                            shared CP certs (CA, etcd CA, FrontProxyCA, sa) from
  //                            the kubeadm-certs Secret on the existing CP.
  //   StaticPodManifestsWritten
  //                          — control-plane-prepare/control-plane: writes the
  //                            apiserver/controller-manager/scheduler/local-etcd
  //                            static-pod manifests to /etc/kubernetes/manifests.
  //                            (kubeconfig/cert sub-phases are folded in here.)
  //   EtcdHealthCheck        — check-etcd: verifies the existing etcd cluster is
  //                            reachable + healthy from this Machine before joining.
  //   KubeletStart           — kubelet-start/start: kubeadm has written kubelet
  //                            config + dynamic env file, kubelet has been started.
  //   KubeletTLSBootstrapped — kubelet-start/wait-bootstrap: kubelet's TLS bootstrap
  //                            has produced /etc/kubernetes/kubelet.conf using a
  //                            client cert signed by the workload-cluster CA.
  //   KubeletManifestReady   — kubelet has applied the static-pod manifests for
  //                            apiserver/controller-manager/scheduler/etcd and
  //                            reports them as Pending or Running locally.
  //   NodeRegistered         — kubelet has performed local Node registration:
  //                            workload-cluster Node object exists for this
  //                            machine via the kubelet-config-bootstrap RBAC
  //                            bundle. May complete BEFORE the apiserver static
  //                            pod is fully serving — KCP's NodeRef resolution
  //                            can pick up this Node even while the new
  //                            apiserver is still warming up. A kubelet that
  //                            fails local registration leaves the cluster with
  //                            an etcd voter that has no Node — exactly the FM-1
  //                            / FM-14 shape.
  //   EtcdJoinAddLearner     — control-plane-join/etcd: kubeadm has called
  //                            Cluster.MemberAddAsLearner against the existing
  //                            etcd cluster.
  //   WaitForEtcdQuorum      — kubeadm waits for the new etcd voter to be
  //                            promoted by the leader (90% match-progress).
  //                            FM-1's hang point.
  //   KubeadmMarkControlPlane
  //                          — control-plane-join/mark-control-plane: kubeadm
  //                            applies the `node-role.kubernetes.io/control-plane`
  //                            label and `node-role.kubernetes.io/control-plane:NoSchedule`
  //                            taint to the new Node.
  //   KubeadmUploadConfig    — control-plane-join/uploadconfig: kubeadm uploads
  //                            the ClusterConfiguration / KubeletConfiguration to
  //                            the kube-system/kubeadm-config and kubelet-config
  //                            ConfigMaps. Required so future joins read the same
  //                            config; failure leaves the cluster in an
  //                            inconsistent state.
  //   MarkControlPlaneReady  — kubeadm-join exits successfully; KCP-side observes
  //                            and prepares to advance to JoinComplete.
  //   JoinComplete           — final terminal: KCP marks the Machine ready.
  //   JoinFailed             — terminal failure; failureReason carries the phase
  //                            that failed.
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

  // The reason a JoinFailed phase carries. The model retains
  // the reason because KCP's preflight projection inspects it.
  // Each enum corresponds to a kubeadm-join sub-phase whose
  // failure requires manual operator intervention.
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

  // -------------------------------------------------------------
  // Domain types
  // -------------------------------------------------------------

  type MachineId = int

  // -------------------------------------------------------------
  // Bounds
  // -------------------------------------------------------------

  pure val MACHINES: Set[MachineId] = 1.to(5)

  // -------------------------------------------------------------
  // State
  // -------------------------------------------------------------

  // Per-machine current phase.
  var phase: MachineId -> Phase
  // Per-machine failure reason (only populated when phase is JoinFailed).
  var failureReason: MachineId -> JoinFailureReason
  // Whether kubeadm-join has registered an etcd member for the
  // machine. The etcd member id is allocated by EtcdMembership;
  // this flag records the side-effect that KCP can observe.
  var etcdMemberRegistered: MachineId -> bool
  // Whether the kubelet has reached Ready. The composition module
  // wires this back to Machine.NodeRef.
  var kubeletReady: MachineId -> bool
  // Whether the kubelet TLS bootstrap has completed
  // (/etc/kubernetes/kubelet.conf produced via the
  // bootstrap-kubelet token). Distinct from kubeletReady because
  // kubelet can be running as a systemd process while still in
  // bootstrap-pending state.
  var tlsBootstrapped: MachineId -> bool
  // Whether kubelet has applied the static-pod manifests for the
  // control-plane components (apiserver, controller-manager,
  // scheduler, local etcd). Distinct from kubeletReady because
  // kubelet can be Ready as a process but its static pods can
  // still be pending image-pull or container-create.
  var kubeletManifestReady: MachineId -> bool
  // Whether kubelet has performed local Node registration: the
  // workload-cluster Node object exists for this machine. Recent
  // K8s versions can register the Node before the apiserver static
  // pod is fully ready — the NodeRef appears, but `is apiserver
  // serving` is independent.
  var nodeLocallyRegistered: MachineId -> bool
  // Whether kubeadm has written the static-pod manifests to disk
  // (control-plane-prepare/control-plane phase). Precondition for
  // kubeletManifestReady.
  var staticPodManifestsWritten: MachineId -> bool
  // Whether kubeadm has applied the
  // node-role.kubernetes.io/control-plane label and
  // control-plane:NoSchedule taint to the Node
  // (control-plane-join/mark-control-plane phase).
  var kubeadmMarkedAsControlPlane: MachineId -> bool
  // Whether kubeadm has uploaded the ClusterConfiguration /
  // KubeletConfiguration to the kube-system/kubeadm-config and
  // kubelet-config ConfigMaps (control-plane-join/uploadconfig
  // phase). Required for future joins to read the same config.
  var kubeadmConfigUploaded: MachineId -> bool

  // -------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------

  action init = all {
    phase'                       = MACHINES.mapBy(_ => NotStarted),
    failureReason'               = Map(),
    etcdMemberRegistered'        = MACHINES.mapBy(_ => false),
    kubeletReady'                = MACHINES.mapBy(_ => false),
    tlsBootstrapped'             = MACHINES.mapBy(_ => false),
    kubeletManifestReady'        = MACHINES.mapBy(_ => false),
    nodeLocallyRegistered'       = MACHINES.mapBy(_ => false),
    staticPodManifestsWritten'   = MACHINES.mapBy(_ => false),
    kubeadmMarkedAsControlPlane' = MACHINES.mapBy(_ => false),
    kubeadmConfigUploaded'       = MACHINES.mapBy(_ => false),
  }

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------

  pure def phaseOf(p: MachineId -> Phase, m: MachineId): Phase =
    p.get(m)

  pure def isTerminal(ph: Phase): bool =
    ph == JoinComplete or ph == JoinFailed

  // -------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------

  // ── BeginJoin ─────────────────────────────────────────────────
  // The Bootstrap controller signals the machine to begin.
  action BeginJoin(m: MachineId): bool = all {
    phaseOf(phase, m) == NotStarted,
    phase' = phase.put(m, Preflight),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── PreflightPass ─────────────────────────────────────────────
  // kubeadm's preflight checks succeeded. Advances to
  // DownloadCerts (control-plane-prepare phase entry).
  action PreflightPass(m: MachineId): bool = all {
    phaseOf(phase, m) == Preflight,
    phase' = phase.put(m, DownloadCerts),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── DownloadCertsSucceeded ────────────────────────────────────
  // control-plane-prepare phase succeeded — the download-certs,
  // certs (per-Machine generation), kubeconfig (write CP
  // kubeconfigs), and control-plane (static-pod manifest write)
  // sub-phases all completed. Sets `staticPodManifestsWritten`.
  // Refines `cmd/kubeadm/app/cmd/phases/join/controlplaneprepare.go`.
  // Contract: K2.
  action DownloadCertsSucceeded(m: MachineId): bool = all {
    phaseOf(phase, m) == DownloadCerts,
    phase'                       = phase.put(m, StaticPodManifestsWritten),
    staticPodManifestsWritten'   = staticPodManifestsWritten.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── EnterEtcdHealthCheck ──────────────────────────────────────
  // kubeadm-join's check-etcd phase begins. Refines
  // `cmd/kubeadm/app/cmd/phases/join/checketcd.go`.
  action EnterEtcdHealthCheck(m: MachineId): bool = all {
    phaseOf(phase, m) == StaticPodManifestsWritten,
    phase'                       = phase.put(m, EtcdHealthCheck),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── CheckEtcdHealth ───────────────────────────────────────────
  // check-etcd phase succeeded — the existing etcd cluster is
  // reachable and healthy from this Machine. Advances to
  // KubeletStart.
  action CheckEtcdHealth(m: MachineId): bool = all {
    phaseOf(phase, m) == EtcdHealthCheck,
    phase'                       = phase.put(m, KubeletStart),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── KubeletStarted ────────────────────────────────────────────
  // kubelet-start/start: kubeadm has written the kubelet config
  // (kubeletphase.WriteConfigToDisk) plus the dynamic env file
  // (kubeletphase.WriteKubeletDynamicEnvFile) and called
  // TryStartKubelet. The kubelet process is running with bootstrap
  // credentials but has not yet completed TLS bootstrap.
  // Refines `cmd/kubeadm/app/cmd/phases/join/kubelet.go:233`.
  // Contract: K2.
  action KubeletStarted(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeletStart,
    phase'                = phase.put(m, KubeletTLSBootstrapped),
    kubeletReady'         = kubeletReady.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── KubeletTLSBootstrap ───────────────────────────────────────
  // kubelet-start/wait-bootstrap: kubelet has performed the TLS
  // Bootstrap (transforming /etc/kubernetes/bootstrap-kubelet.conf
  // into /etc/kubernetes/kubelet.conf with a CA-signed client
  // cert). Sets `tlsBootstrapped` and `kubeletManifestReady` (the
  // kubelet picks up the static-pod manifests it found on disk).
  // Refines `waitForTLSBootstrappedClient` at
  // `cmd/kubeadm/app/cmd/phases/join/kubelet.go:296`.
  // Contract: K2.
  action KubeletTLSBootstrap(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeletTLSBootstrapped,
    phase'                = phase.put(m, KubeletManifestReady),
    tlsBootstrapped'      = tlsBootstrapped.put(m, true),
    kubeletManifestReady' = kubeletManifestReady.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── RegisterLocalNode ─────────────────────────────────────────
  // Recent K8s kubelets perform local Node registration shortly
  // after kubelet start: kubelet creates a Node object in the
  // workload cluster API directly (using the kubelet-config-bootstrap
  // RBAC bundle), independent of whether the apiserver static pod
  // is fully serving. The Node may show up before the apiserver is
  // fully Ready; KCP's NodeRef resolution can find this Node and
  // attach it to a Machine while the apiserver is still warming up.
  //
  // Conversely, a kubelet that fails local registration leaves the
  // cluster with an etcd voter that has no Node — exactly the
  // FM-1 / FM-14 shape.
  //
  // Refines `Kubelet.registerWithAPIServer` at
  // `pkg/kubelet/kubelet_node_status.go:52`.
  // Contract: K2.
  action RegisterLocalNode(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeletManifestReady,
    phase'                 = phase.put(m, NodeRegistered),
    nodeLocallyRegistered' = nodeLocallyRegistered.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── EnterEtcdAddLearner ───────────────────────────────────────
  // kubeadm starts the etcd-add-learner phase
  // (control-plane-join/etcd). Pre-condition tightened (K2): the
  // local Node must be registered before kubeadm-join's
  // etcd-add-learner phase runs — kubeadm orders these phases this
  // way in recent versions, and KCP's controller relies on the
  // ordering for matchable-set checks.
  action EnterEtcdAddLearner(m: MachineId): bool = all {
    phaseOf(phase, m) == NodeRegistered,
    phase'                = phase.put(m, EtcdJoinAddLearner),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── EtcdAddLearnerSucceeded ───────────────────────────────────
  // The joining machine has called Cluster.MemberAddAsLearner on
  // the existing etcd cluster. The action only records the
  // side-effect; the actual membership change is in
  // EtcdMembership.AddLearner and the composition module wires
  // the two together.
  action EtcdAddLearnerSucceeded(m: MachineId): bool = all {
    phaseOf(phase, m) == EtcdJoinAddLearner,
    phase'                = phase.put(m, WaitForEtcdQuorum),
    etcdMemberRegistered' = etcdMemberRegistered.put(m, true),
    failureReason'               = failureReason,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── EtcdQuorumReady ───────────────────────────────────────────
  // The leader has promoted the learner, the new voter is
  // contributing to quorum, and kubeadm-join unblocks. Advances
  // to KubeadmMarkControlPlane.
  action EtcdQuorumReady(m: MachineId): bool = all {
    phaseOf(phase, m) == WaitForEtcdQuorum,
    phase' = phase.put(m, KubeadmMarkControlPlane),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── MarkAsControlPlane ────────────────────────────────────────
  // control-plane-join/mark-control-plane: kubeadm applies the
  // node-role.kubernetes.io/control-plane label and the
  // control-plane:NoSchedule taint to the new Node. Refines
  // `cmd/kubeadm/app/phases/markcontrolplane`.
  action MarkAsControlPlane(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeadmMarkControlPlane,
    phase'                       = phase.put(m, KubeadmUploadConfig),
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── UploadKubeadmConfig ───────────────────────────────────────
  // control-plane-join/uploadconfig: kubeadm uploads the
  // ClusterConfiguration / KubeletConfiguration to the
  // kube-system/kubeadm-config and kubelet-config ConfigMaps.
  // Refines `cmd/kubeadm/app/phases/uploadconfig`.
  action UploadKubeadmConfig(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeadmUploadConfig,
    phase'                 = phase.put(m, MarkControlPlaneReady),
    kubeadmConfigUploaded' = kubeadmConfigUploaded.put(m, true),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
  }

  // ── MarkReady ─────────────────────────────────────────────────
  action MarkReady(m: MachineId): bool = all {
    phaseOf(phase, m) == MarkControlPlaneReady,
    phase' = phase.put(m, JoinComplete),
    failureReason'               = failureReason,
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // ── JoinFailedAt ──────────────────────────────────────────────
  // A failure can be recorded at any non-terminal phase. The
  // reason is captured so KCP's preflight projection can read it.
  action JoinFailedAt(m: MachineId, r: JoinFailureReason): bool = all {
    not(isTerminal(phaseOf(phase, m))),
    phaseOf(phase, m) != NotStarted,
    phase'         = phase.put(m, JoinFailed),
    failureReason' = failureReason.put(m, r),
    etcdMemberRegistered'        = etcdMemberRegistered,
    kubeletReady'                = kubeletReady,
    tlsBootstrapped'             = tlsBootstrapped,
    kubeletManifestReady'        = kubeletManifestReady,
    nodeLocallyRegistered'       = nodeLocallyRegistered,
    staticPodManifestsWritten'   = staticPodManifestsWritten,
    kubeadmMarkedAsControlPlane' = kubeadmMarkedAsControlPlane,
    kubeadmConfigUploaded'       = kubeadmConfigUploaded,
  }

  // -------------------------------------------------------------
  // Step relation
  // -------------------------------------------------------------

  action step = any {
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
  }

  // -------------------------------------------------------------
  // Invariants
  // -------------------------------------------------------------

  // Phase advancement is monotonic until terminal. Every phase
  // change goes from a strictly earlier phase to a later one or
  // to JoinFailed.
  pure def phaseIndex(ph: Phase): int =
    if (ph == NotStarted) 0
    else if (ph == Preflight) 1
    else if (ph == DownloadCerts) 2
    else if (ph == StaticPodManifestsWritten) 3
    else if (ph == EtcdHealthCheck) 4
    else if (ph == KubeletStart) 5
    else if (ph == KubeletTLSBootstrapped) 6
    else if (ph == KubeletManifestReady) 7
    else if (ph == NodeRegistered) 8
    else if (ph == EtcdJoinAddLearner) 9
    else if (ph == WaitForEtcdQuorum) 10
    else if (ph == KubeadmMarkControlPlane) 11
    else if (ph == KubeadmUploadConfig) 12
    else if (ph == MarkControlPlaneReady) 13
    else if (ph == JoinComplete) 14
    else 15  // JoinFailed

  // Once etcd registration succeeded, the kubelet must be Ready.
  // This pins the choreography KCP relies on: an etcd member
  // exists for a machine ⇒ the machine has started its kubelet,
  // and therefore (eventually) its node will register.
  val EtcdRegistrationImpliesKubeletReady =
    MACHINES.forall(m =>
      etcdMemberRegistered.get(m) implies kubeletReady.get(m))

  // A failed join with reason LearnerStuckOnPromote must have
  // previously registered an etcd member. This is the precise
  // shape of the modelled scenario.
  val StuckLearnerImpliesEtcdRegistered =
    MACHINES.forall(m =>
      (phase.get(m) == JoinFailed
        and failureReason.keys().contains(m)
        and failureReason.get(m) == LearnerStuckOnPromote)
      implies etcdMemberRegistered.get(m))

  val AllInvariants = all {
    EtcdRegistrationImpliesKubeletReady,
    StuckLearnerImpliesEtcdRegistered,
  }

  // -------------------------------------------------------------
  // Example runs
  // -------------------------------------------------------------

  // The happy path through every phase.
  run happyJoin = init
    .then(BeginJoin(2))
    .then(PreflightPass(2))
    .then(DownloadCertsSucceeded(2))
    .then(EnterEtcdHealthCheck(2))
    .then(CheckEtcdHealth(2))
    .then(KubeletStarted(2))
    .then(KubeletTLSBootstrap(2))
    .then(RegisterLocalNode(2))
    .then(EnterEtcdAddLearner(2))
    .then(EtcdAddLearnerSucceeded(2))
    .then(EtcdQuorumReady(2))
    .then(MarkAsControlPlane(2))
    .then(UploadKubeadmConfig(2))
    .then(MarkReady(2))

  // FM-1's shape: kubelet starts, etcd learner registers,
  // promotion never happens, join fails on quorum wait.
  run stuckOnQuorum = init
    .then(BeginJoin(2))
    .then(PreflightPass(2))
    .then(DownloadCertsSucceeded(2))
    .then(EnterEtcdHealthCheck(2))
    .then(CheckEtcdHealth(2))
    .then(KubeletStarted(2))
    .then(KubeletTLSBootstrap(2))
    .then(RegisterLocalNode(2))
    .then(EnterEtcdAddLearner(2))
    .then(EtcdAddLearnerSucceeded(2))
    .then(JoinFailedAt(2, LearnerStuckOnPromote))

}
