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
  type Phase =
    | NotStarted
    | Preflight
    | KubeletStart
    | EtcdJoinAddLearner
    | WaitForEtcdQuorum
    | MarkControlPlaneReady
    | JoinComplete
    | JoinFailed

  // The reason a JoinFailed phase carries. The model retains
  // the reason because KCP's preflight projection inspects it.
  type JoinFailureReason =
    | LearnerStuckOnPromote
    | KubeletNotReady
    | PreflightCheckFailed
    | EtcdJoinAddLearnerFailed
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

  // -------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------

  action init = all {
    phase'                 = MACHINES.mapBy(_ => NotStarted),
    failureReason'         = Map(),
    etcdMemberRegistered'  = MACHINES.mapBy(_ => false),
    kubeletReady'          = MACHINES.mapBy(_ => false),
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
    failureReason'        = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    kubeletReady'         = kubeletReady,
  }

  // ── PreflightPass ─────────────────────────────────────────────
  action PreflightPass(m: MachineId): bool = all {
    phaseOf(phase, m) == Preflight,
    phase' = phase.put(m, KubeletStart),
    failureReason'        = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    kubeletReady'         = kubeletReady,
  }

  // ── KubeletStarted ────────────────────────────────────────────
  // NewKubeletStartPhase: kubelet has launched and reports Ready.
  // The model treats this as the point past which etcd-join can
  // proceed; it deliberately does not model partial kubelet
  // failures here because those are below the abstraction layer.
  action KubeletStarted(m: MachineId): bool = all {
    phaseOf(phase, m) == KubeletStart,
    phase'        = phase.put(m, EtcdJoinAddLearner),
    kubeletReady' = kubeletReady.put(m, true),
    failureReason'        = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
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
    failureReason'        = failureReason,
    kubeletReady'         = kubeletReady,
  }

  // ── EtcdQuorumReady ───────────────────────────────────────────
  // The leader has promoted the learner, the new voter is
  // contributing to quorum, and kubeadm-join unblocks.
  action EtcdQuorumReady(m: MachineId): bool = all {
    phaseOf(phase, m) == WaitForEtcdQuorum,
    phase' = phase.put(m, MarkControlPlaneReady),
    failureReason'        = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    kubeletReady'         = kubeletReady,
  }

  // ── MarkReady ─────────────────────────────────────────────────
  action MarkReady(m: MachineId): bool = all {
    phaseOf(phase, m) == MarkControlPlaneReady,
    phase' = phase.put(m, JoinComplete),
    failureReason'        = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    kubeletReady'         = kubeletReady,
  }

  // ── JoinFailedAt ──────────────────────────────────────────────
  // A failure can be recorded at any non-terminal phase. The
  // reason is captured so KCP's preflight projection can read it.
  action JoinFailedAt(m: MachineId, r: JoinFailureReason): bool = all {
    not(isTerminal(phaseOf(phase, m))),
    phaseOf(phase, m) != NotStarted,
    phase'         = phase.put(m, JoinFailed),
    failureReason' = failureReason.put(m, r),
    etcdMemberRegistered' = etcdMemberRegistered,
    kubeletReady'         = kubeletReady,
  }

  // -------------------------------------------------------------
  // Step relation
  // -------------------------------------------------------------

  action step = any {
    nondet m = MACHINES.oneOf(); BeginJoin(m),
    nondet m = MACHINES.oneOf(); PreflightPass(m),
    nondet m = MACHINES.oneOf(); KubeletStarted(m),
    nondet m = MACHINES.oneOf(); EtcdAddLearnerSucceeded(m),
    nondet m = MACHINES.oneOf(); EtcdQuorumReady(m),
    nondet m = MACHINES.oneOf(); MarkReady(m),
    nondet m = MACHINES.oneOf();
      nondet r = Set(LearnerStuckOnPromote, KubeletNotReady,
                     PreflightCheckFailed, EtcdJoinAddLearnerFailed,
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
    else if (ph == KubeletStart) 2
    else if (ph == EtcdJoinAddLearner) 3
    else if (ph == WaitForEtcdQuorum) 4
    else if (ph == MarkControlPlaneReady) 5
    else if (ph == JoinComplete) 6
    else 7  // JoinFailed

  // Once etcd registration succeeded, the kubelet must be Ready.
  // This pins the choreography KCP relies on: an etcd member
  // exists for a machine ⇒ the machine has started its kubelet,
  // and therefore (eventually) its node will register.
  val EtcdRegistrationImpliesKubeletReady =
    MACHINES.forall(m =>
      etcdMemberRegistered.get(m) implies kubeletReady.get(m))

  // A failed join with reason LearnerStuckOnPromote must have
  // previously registered an etcd member. This is the precise
  // shape of the user-reported incident.
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
    .then(KubeletStarted(2))
    .then(EtcdAddLearnerSucceeded(2))
    .then(EtcdQuorumReady(2))
    .then(MarkReady(2))

  // The incident shape: kubelet starts, etcd learner registers,
  // promotion never happens, join fails on quorum wait.
  run stuckOnQuorum = init
    .then(BeginJoin(2))
    .then(PreflightPass(2))
    .then(KubeletStarted(2))
    .then(EtcdAddLearnerSucceeded(2))
    .then(JoinFailedAt(2, LearnerStuckOnPromote))

}
