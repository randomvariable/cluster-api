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
    | KubeletStart
    | EtcdJoinAddLearner
    | WaitForEtcdQuorum
    | MarkControlPlaneReady
    | JoinComplete
    | JoinFailed

  type JoinFailureReason =
    | LearnerStuckOnPromote
    | KubeletNotReady
    | PreflightCheckFailed
    | EtcdJoinAddLearnerFailed
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
  }

  action threeNodeInit = init  // alias

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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action AdvanceTerm: bool = all {
    currentTerm < MAX_TERM,
    currentTerm' = currentTerm + 1,
    members' = members, learners' = learners, leaderAt' = leaderAt,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action RemoveMember(id: MachineId): bool = all {
    members.contains(id),
    voters(members.exclude(Set(id)), learners.exclude(Set(id))).size() >= 1,
    hasLeader(leaderAt, currentTerm),
    leaderAt.get(currentTerm) != id,
    members'  = members.exclude(Set(id)),
    learners' = learners.exclude(Set(id)),
    progress' = progress, memberHealth' = memberHealth,
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action PreflightPass(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == Preflight,
    phase' = phase.put(m, KubeletStart),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action KubeletStarted(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == KubeletStart,
    phase' = phase.put(m, EtcdJoinAddLearner),
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  // EtcdQuorumReady fires after PromoteLearner — kubeadm-join
  // unblocks once is_learner flips to false on its MemberList.
  action EtcdQuorumReady(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == WaitForEtcdQuorum,
    not(learners.contains(m)),
    members.contains(m),
    phase' = phase.put(m, MarkControlPlaneReady),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action MarkReady(m: MachineId): bool = all {
    phase.keys().contains(m),
    phase.get(m) == MarkControlPlaneReady,
    phase' = phase.put(m, JoinComplete),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  action MachineHealthChange(m: MachineId, h: MachineHealth): bool = all {
    machines.contains(m),
    machineHealthLabel' = machineHealthLabel.put(m, h),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered, kubeletReady' = kubeletReady,
    machines' = machines, nodeRefSet' = nodeRefSet,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    template' = template, desiredTemplate' = desiredTemplate,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
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
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy, nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate, observation' = observation,
    lbHealthy' = lbHealthy,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    nodeRefSet' = nodeRefSet, machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked, observation' = observation,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
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
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel, decision' = decision,
    blockReason' = blockReason, preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    template' = template,
    desiredTemplate' = desiredTemplate,
    lbHealthy' = lbHealthy,
    nodeReachable' = nodeReachable,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    // EtcdMembership
    nondet c = MACHINES.oneOf(); ElectLeader(c),
    AdvanceTerm,
    nondet id = MACHINES.oneOf(); AddLearner(id),
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
    nondet m = MACHINES.oneOf(); KubeletStarted(m),
    nondet m = MACHINES.oneOf(); EtcdAddLearnerSucceeded(m),
    nondet m = MACHINES.oneOf(); EtcdQuorumReady(m),
    nondet m = MACHINES.oneOf(); MarkReady(m),
    nondet m = MACHINES.oneOf();
      nondet r = Set(LearnerStuckOnPromote, KubeletNotReady,
                     PreflightCheckFailed, EtcdJoinAddLearnerFailed,
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
    // Recovery
    nondet m = MACHINES.oneOf(); RemoveStuckLearner(m),
    nondet m = MACHINES.oneOf(); DeleteFailedMachine(m),
    nondet m = MACHINES.oneOf(); HealEtcdReachability(m),
    HealLb,
    nondet m = MACHINES.oneOf(); RestoreNodeReachability(m),
    nondet m = MACHINES.oneOf(); RestoreClusterFromSnapshot(m),
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
    nondet id = MACHINES.oneOf(); AddLearner(id),
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
    nondet m = MACHINES.oneOf(); KubeletStarted(m),
    nondet m = MACHINES.oneOf(); EtcdAddLearnerSucceeded(m),
    nondet m = MACHINES.oneOf(); EtcdQuorumReady(m),
    nondet m = MACHINES.oneOf(); MarkReady(m),
    nondet m = MACHINES.oneOf();
      nondet r = Set(LearnerStuckOnPromote, KubeletNotReady,
                     PreflightCheckFailed, EtcdJoinAddLearnerFailed,
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
    // No RemoveStuckLearner, DeleteFailedMachine, HealEtcdReachability,
    // HealLb, or RestoreNodeReachability.
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

  // ConvergenceFair: convergence under fairness. The natural
  // expression
  //   `(1.to(4).map(m => Action(m).strongFair(...)).fold(...))`
  // hits a TLA+ level error: fairness operators may not appear
  // inside set-comprehensions in TLA+, and Quint's TLC backend
  // surfaces the error as
  //   `Level error in applying operator $SetOfAll`
  // The workaround is to enumerate every (action, machine-id)
  // pair as a single conjunct. Sixty conjuncts for fifteen
  // actions over four MachineIds is verbose but mechanical; if
  // the model adds a sixteenth fair action or a fifth MachineId,
  // four (or fifteen) more conjuncts must be added here.
  // Documented as future work in `formal/failure-modes.md` FM-9.
  //
  // The form below is a placeholder skeleton — full enumeration
  // is parked behind FM-9 so the rest of the model checks
  // without TLC level errors. To restore TLC verification under
  // fairness, paste in the 60 explicit `.strongFair(Set(currentTerm))`
  // conjuncts.
  // temporal ConvergenceFair = ... (see FM-9)

  // ===============================================================
  // Example runs
  // ===============================================================

  // The happy path — Machine 4 joins, learner promotes, becomes a
  // healthy 4-member control plane.
  run happyJoin = init
    .then(ElectLeader(1))                                   // term 1 leader
    .then(AddMachine(4))                                    // KCP creates Machine 4
    .then(BeginJoin(4))                                     // Bootstrap signals
    .then(PreflightPass(4))
    .then(KubeletStarted(4))
    .then(EtcdAddLearnerSucceeded(4))                       // joins as learner
    .then(ObserveLearnerProgress(4, Eligible))              // catches up
    .then(PromoteLearner(4))                                // is_learner -> false
    .then(EtcdQuorumReady(4))                               // kubeadm unblocks
    .then(MarkReady(4))                                     // join complete
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
    .then(KubeletStarted(4))
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
    .then(KubeletStarted(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))
    .then(EtcdQuorumReady(4))
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
                machines' = machines, nodeRefSet' = nodeRefSet,
                machineHealthLabel' = machineHealthLabel,
                decision' = decision, blockReason' = blockReason,
                preflightBlocked' = preflightBlocked,
                desiredReplicas' = desiredReplicas,
                template' = template, desiredTemplate' = desiredTemplate,
                observation' = observation,
                lbHealthy' = lbHealthy, nodeReachable' = nodeReachable })

  // FM-1 — learner stuck at promotion. Without recovery,
  // never converges. With RemoveStuckLearner + DeleteFailedMachine,
  // converges via the recovery path.
  run incidentRecovered = init
    .then(ElectLeader(1))
    .then(AddMachine(4))
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(KubeletStarted(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(LearnerStuck(4))                                  // exogenous fault
    .then(JoinFailedAt(4, LearnerStuckOnPromote))
    .then(RemoveStuckLearner(4))                            // recovery: drop member
    .then(DeleteFailedMachine(4))                           // recovery: delete Machine
    .then(AddMachine(4))                                    // recovery: recreate Machine
    .then(BeginJoin(4))
    .then(PreflightPass(4))
    .then(KubeletStarted(4))
    .then(EtcdAddLearnerSucceeded(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))
    .then(EtcdQuorumReady(4))
    .then(MarkReady(4))
    .then(ResolveNodeRef(4))
    .then(MachineHealthChange(4, HealthyMachine))

}
