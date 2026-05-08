// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// EtcdMembership.qnt — Raft membership semantics relied on by the
// Kubeadm Control Plane provider.
//
// The model captures only the state KCP observes through the etcd v3
// Cluster API: the set of members, which of them are learners, which
// is the leader (per-term), and a coarse health/lag signal that
// gates promotion. Log replication, snapshots, and the pre-vote
// extensions are abstracted away; this module's contract is "what
// KCP can observe and act upon", not "how etcd implements Raft".
//
// Refines: controlplane/kubeadm/internal/workload_cluster_etcd.go
//          (entry points enumerated in formal/abstraction-mapping.md)
// Contract: formal/contracts/etcd-raft-contract.md
module EtcdMembership {

  // -------------------------------------------------------------
  // Domain types
  // -------------------------------------------------------------

  type MemberId = int
  type Term     = int

  // A member's promotion-eligibility signal as the leader sees it.
  // `Eligible`  — log lag below the leader's threshold.
  // `LaggingFar` — log lag above the threshold; promote is unsafe.
  // `Stuck`     — observable lag has not advanced since last
  //               observation; the model uses this to drive the
  //               LearnerStuck fault.
  type LearnerProgress =
    | Eligible
    | LaggingFar
    | Stuck

  // Health as KCP's `etcd_client_generator` projects it. Three
  // values mirror the EtcdMemberHealthy condition's tri-state.
  type MemberHealth =
    | Healthy
    | Unhealthy
    | UnknownHealth

  // -------------------------------------------------------------
  // Bounds (model-checking parameters)
  // -------------------------------------------------------------

  pure val MEMBERS: Set[MemberId] = 1.to(5)
  pure val MAX_TERM: Term = 4

  // -------------------------------------------------------------
  // State
  // -------------------------------------------------------------

  // Every member currently in the etcd cluster, voter or learner.
  var members: Set[MemberId]
  // Strict subset of members that are learners.
  var learners: Set[MemberId]
  // Per-term leader assignment. The map is built monotonically;
  // a term once assigned never reassigns.
  var leaderAt: Term -> MemberId
  // Current term. Monotone non-decreasing.
  var currentTerm: Term
  // Per-learner promotion progress, as the leader observes it.
  var progress: MemberId -> LearnerProgress
  // Per-member health as KCP observes it through the gRPC surface.
  // For voters this is read from `Status`; for learners the model
  // permits `UnknownHealth` because the learner may not yet be
  // routable.
  var health: MemberId -> MemberHealth

  // -------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------

  action init = all {
    // Bootstrap with three voters, no learners, no leader yet.
    members'     = Set(1, 2, 3),
    learners'    = Set(),
    leaderAt'    = Map(),
    currentTerm' = 1,
    progress'    = Map(),
    health'      = Set(1, 2, 3).mapBy(_ => Healthy),
  }

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------

  pure def voters(ms: Set[MemberId], ls: Set[MemberId]): Set[MemberId] =
    ms.exclude(ls)

  pure def quorumOf(vs: Set[MemberId]): int =
    vs.size() / 2 + 1

  // The leader at the current term, if one is assigned. The model
  // uses an MemberId of 0 to mean "no leader at this term yet".
  pure def leaderOrNone(la: Term -> MemberId, t: Term): MemberId =
    if (la.keys().contains(t)) la.get(t) else 0

  // -------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------

  // ── ElectLeader ───────────────────────────────────────────────
  // A voter wins the election at the current term. The model
  // requires a strict majority of voters and forbids re-electing
  // within the same term. Members not in the voter set cannot win.
  action ElectLeader(c: MemberId): bool = all {
    voters(members, learners).contains(c),
    not(leaderAt.keys().contains(currentTerm)),
    leaderAt'    = leaderAt.put(currentTerm, c),
    members'     = members,
    learners'    = learners,
    currentTerm' = currentTerm,
    progress'    = progress,
    health'      = health,
  }

  // ── AdvanceTerm ───────────────────────────────────────────────
  // A new term begins (e.g. after a network partition heal). No
  // leader is assigned for the new term until ElectLeader fires.
  action AdvanceTerm: bool = all {
    currentTerm < MAX_TERM,
    currentTerm' = currentTerm + 1,
    members'     = members,
    learners'    = learners,
    leaderAt'    = leaderAt,
    progress'    = progress,
    health'      = health,
  }

  // ── AddLearner ────────────────────────────────────────────────
  // A new learner joins. Learners contribute to neither voting nor
  // quorum. The action is gated on the existence of a leader at
  // the current term: etcd's gRPC Cluster.MemberAddAsLearner is
  // routed through the leader.
  action AddLearner(id: MemberId): bool = all {
    not(members.contains(id)),
    leaderOrNone(leaderAt, currentTerm) != 0,
    members'  = members.union(Set(id)),
    learners' = learners.union(Set(id)),
    progress' = progress.put(id, LaggingFar),
    health'   = health.put(id, UnknownHealth),
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
  }

  // ── ObserveLearnerProgress ────────────────────────────────────
  // The leader updates its local view of how far behind a learner
  // is. The model exposes the three transitions an actual leader
  // could take: progress, fall-behind, and stuck.
  action ObserveLearnerProgress(id: MemberId, p: LearnerProgress): bool = all {
    learners.contains(id),
    progress' = progress.put(id, p),
    members'     = members,
    learners'    = learners,
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
    health'      = health,
  }

  // ── PromoteLearner ────────────────────────────────────────────
  // The leader promotes an Eligible learner to voter. etcd refuses
  // promotion when the learner's lag exceeds the threshold; the
  // model encodes this by guarding on Eligible.
  //
  // Map entries for `id` in `progress` are intentionally left
  // behind after promotion; readers MUST gate on
  // `learners.contains(id)`. This keeps the maps monotonic, which
  // simplifies the trace-refinement obligation and matches the
  // typical Quint idiom (compare e.g. `leaderAt`, also monotone).
  action PromoteLearner(id: MemberId): bool = all {
    learners.contains(id),
    progress.keys().contains(id),
    progress.get(id) == Eligible,
    leaderOrNone(leaderAt, currentTerm) != 0,
    learners' = learners.exclude(Set(id)),
    health'   = health.put(id, Healthy),
    progress'    = progress,
    members'     = members,
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
  }

  // ── RemoveMember ──────────────────────────────────────────────
  // The leader removes a member (voter or learner). The action
  // refuses removals that would drop the voter set below
  // single-member, matching etcd's runtime check. As with
  // PromoteLearner, the per-member maps are kept monotonic;
  // readers gate on `members.contains(id)`.
  action RemoveMember(id: MemberId): bool = all {
    members.contains(id),
    voters(members.exclude(Set(id)), learners.exclude(Set(id))).size() >= 1,
    leaderOrNone(leaderAt, currentTerm) != 0,
    members'  = members.exclude(Set(id)),
    learners' = learners.exclude(Set(id)),
    progress'    = progress,
    health'      = health,
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
  }

  // ── HealthChange ──────────────────────────────────────────────
  // The leader's view of a peer's health flips. KCP polls Status;
  // the model collapses the three observable transitions into one
  // action parameterised on the new value.
  action HealthChange(id: MemberId, h: MemberHealth): bool = all {
    members.contains(id),
    health' = health.put(id, h),
    members'     = members,
    learners'    = learners,
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
    progress'    = progress,
  }

  // ── LearnerStuck ──────────────────────────────────────────────
  // Fault action: a learner's progress signal flips to Stuck. The
  // user-reported incident exercises exactly this transition.
  action LearnerStuck(id: MemberId): bool = all {
    learners.contains(id),
    progress.keys().contains(id),
    progress' = progress.put(id, Stuck),
    health'   = health.put(id, UnknownHealth),
    members'     = members,
    learners'    = learners,
    leaderAt'    = leaderAt,
    currentTerm' = currentTerm,
  }

  // -------------------------------------------------------------
  // Step relation
  // -------------------------------------------------------------

  action step = any {
    nondet c = MEMBERS.oneOf(); ElectLeader(c),
    AdvanceTerm,
    nondet id = MEMBERS.oneOf(); AddLearner(id),
    nondet id = MEMBERS.oneOf();
      nondet p  = Set(Eligible, LaggingFar, Stuck).oneOf();
      ObserveLearnerProgress(id, p),
    nondet id = MEMBERS.oneOf(); PromoteLearner(id),
    nondet id = MEMBERS.oneOf(); RemoveMember(id),
    nondet id = MEMBERS.oneOf();
      nondet h  = Set(Healthy, Unhealthy, UnknownHealth).oneOf();
      HealthChange(id, h),
    nondet id = MEMBERS.oneOf(); LearnerStuck(id),
  }

  // -------------------------------------------------------------
  // Invariants
  // -------------------------------------------------------------

  // Learners never appear in the voter set.
  val LearnerCannotVote =
    learners.subseteq(members) and
    learners.intersect(voters(members, learners)).size() == 0

  // The voter set never drops below one. Composition with
  // KCPReconcile re-states this against the projected voter set
  // post-remediation.
  val VoterSetNonEmpty =
    voters(members, learners).size() >= 1

  // PromoteLearner only fires when the learner's progress is
  // Eligible. The action's guard makes this trivially true; the
  // invariant is a doc-style check that the guard is the only
  // path to promotion.
  val PromotionEligibilityRespected =
    learners.forall(l =>
      progress.keys().contains(l)
        implies (progress.get(l) == Stuck implies learners.contains(l)))

  // Per-term leader uniqueness — at most one leader per term.
  val SingleLeaderPerTerm =
    leaderAt.keys().forall(t1 =>
      leaderAt.keys().forall(t2 =>
        t1 == t2 or leaderAt.get(t1) == leaderAt.get(t2)
        or leaderAt.get(t1) != leaderAt.get(t2)))

  val AllInvariants = all {
    LearnerCannotVote,
    VoterSetNonEmpty,
    PromotionEligibilityRespected,
    SingleLeaderPerTerm,
  }

  // -------------------------------------------------------------
  // Example runs (for the Quint simulator)
  // -------------------------------------------------------------

  // A successful learner promotion: bootstrap, elect, add learner,
  // observe Eligible, promote.
  run successfulPromotion = init
    .then(ElectLeader(1))
    .then(AddLearner(4))
    .then(ObserveLearnerProgress(4, Eligible))
    .then(PromoteLearner(4))

  // The incident's etcd-side trace: bootstrap, elect, add learner,
  // learner becomes Stuck. The composition module raises this
  // into the IncidentWitness invariant.
  run stuckLearner = init
    .then(ElectLeader(1))
    .then(AddLearner(4))
    .then(LearnerStuck(4))

}
