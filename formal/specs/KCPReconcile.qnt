// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// KCPReconcile.qnt — KubeadmControlPlane reconcile loop, narrowed
// to the actions that determine whether remediation runs and what
// preflight reports when it cannot.
//
// The model represents a single KubeadmControlPlane object that
// owns a set of Machine references. For each Machine the model
// tracks whether the controller has resolved a NodeRef, whether
// it can be matched to an etcd member, and a coarse health label
// derived from the per-Machine conditions in
// MachineHealthCheck.qnt.
//
// Refines: controlplane/kubeadm/internal/controllers/{controller,
//          remediation,scale,status}.go (entry points enumerated
//          in formal/abstraction-mapping.md).
// Contract: formal/contracts/kcp-machine-contract.md
module KCPReconcile {

  // -------------------------------------------------------------
  // Domain types
  // -------------------------------------------------------------

  type MachineId = int

  // The label KCP attaches to a Machine after merging the
  // per-Machine conditions reported by MachineHealthCheck. The
  // model uses three labels because that is the resolution KCP
  // acts on; finer-grained per-condition state is handled in
  // MachineHealthCheck.qnt and wired through composition.
  type MachineHealth =
    | HealthyMachine
    | UnhealthyMachine
    | UnknownHealthMachine

  // The remediation decision the reconcile loop produces for a
  // single Machine.
  type RemediationDecision =
    | NoRemediationNeeded
    | RemediationRequested
    | RemediationAdmitted
    | RemediationBlocked
    | RemediationInFlight

  // The reason a remediation is blocked. Distinct values matter
  // because the InformativenessObligation invariant in
  // Composition.qnt distinguishes them.
  type BlockedReason =
    | QuorumWouldBeLost
    | EtcdMemberSetDoesNotMatchMachineSet
    | InsufficientReplicas
    | PreTerminateHookGateFailed
    | OtherBlock

  // -------------------------------------------------------------
  // Bounds
  // -------------------------------------------------------------

  pure val MACHINES: Set[MachineId] = 1.to(5)

  // -------------------------------------------------------------
  // State
  // -------------------------------------------------------------

  // The Machines this KCP owns.
  var machines: Set[MachineId]
  // Per-Machine NodeRef resolution: true once Machine.status.nodeRef
  // is set.
  var nodeRefSet: MachineId -> bool
  // Per-Machine health label.
  var machineHealth: MachineId -> MachineHealth
  // Per-Machine remediation decision.
  var decision: MachineId -> RemediationDecision
  // Per-Machine block reason (only populated when decision is
  // RemediationBlocked).
  var blockReason: MachineId -> BlockedReason
  // Whether preflight is currently inhibiting reconcile-driven
  // changes. The boolean is the projection of the union of
  // per-Machine block reasons that gate scale operations.
  var preflightBlocked: bool
  // Whether a Machine is already in deletion.
  var deleting: MachineId -> bool
  // Whether KCP has already committed to removing a deleting peer by
  // placing the cleanup pre-terminate annotation on it.
  var hasKCPCleanupAnnotation: MachineId -> bool
  // Admission-time verdict remembered between the remediation
  // decision reconcile and the later pre-terminate hook.
  var admissionSafe: MachineId -> bool
  // Fresh safety predicate re-evaluated at pre-terminate-hook time.
  var hookFreshSafe: MachineId -> bool

  // -------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------

  action init = all {
    machines'         = Set(1, 2, 3),
    nodeRefSet'       = Set(1, 2, 3).mapBy(_ => true),
    machineHealth'    = Set(1, 2, 3).mapBy(_ => HealthyMachine),
    decision'         = Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
    blockReason'      = Map(),
    preflightBlocked' = false,
    deleting'         = Set(1, 2, 3).mapBy(_ => false),
    hasKCPCleanupAnnotation' = Set(1, 2, 3).mapBy(_ => false),
    admissionSafe'    = Set(1, 2, 3).mapBy(_ => false),
    hookFreshSafe'    = Set(1, 2, 3).mapBy(_ => false),
  }

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------

  pure def quorumOf(n: int): int = n / 2 + 1

  // The NodeRef-projected machine set: only Machines for which
  // nodeRefSet has been resolved to true. This is the surface
  // KCP can match to etcd members.
  pure def matchableMachines(ms: Set[MachineId], nrs: MachineId -> bool): Set[MachineId] =
    ms.filter(m => nrs.keys().contains(m) and nrs.get(m))

  def condemnedPeers(ms: Set[MachineId], deletingNow: MachineId -> bool, cleanupNow: MachineId -> bool, nrs: MachineId -> bool, target: MachineId): Set[MachineId] =
    ms.filter(m =>
      m != target
        and deletingNow.get(m)
        and cleanupNow.get(m)
        and nrs.get(m))

  def hasSurvivingPeer(ms: Set[MachineId], deletingNow: MachineId -> bool, target: MachineId): bool =
    ms.exists(m => m != target and not(deletingNow.get(m)))

  def remediationPostState(ms: Set[MachineId], deletingNow: MachineId -> bool, cleanupNow: MachineId -> bool, nrs: MachineId -> bool, target: MachineId): Set[MachineId] =
    ms.exclude(Set(target)).exclude(condemnedPeers(ms, deletingNow, cleanupNow, nrs, target))

  def remediationQuorumBar(ms: Set[MachineId], deletingNow: MachineId -> bool, cleanupNow: MachineId -> bool, nrs: MachineId -> bool, target: MachineId): int =
    if (condemnedPeers(ms, deletingNow, cleanupNow, nrs, target).size() > 0
        and hasSurvivingPeer(ms, deletingNow, target))
      quorumOf(ms.size())
    else
      quorumOf(remediationPostState(ms, deletingNow, cleanupNow, nrs, target).size())

  // -------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------

  // ── AddMachine ────────────────────────────────────────────────
  // KCP's scale-up path creates a new Machine. The Machine starts
  // without a NodeRef and is implicitly UnknownHealthMachine until
  // MHC observes it.
  action AddMachine(m: MachineId): bool = all {
    not(machines.contains(m)),
    MACHINES.contains(m),
    machines'      = machines.union(Set(m)),
    nodeRefSet'    = nodeRefSet.put(m, false),
    machineHealth' = machineHealth.put(m, UnknownHealthMachine),
    decision'      = decision.put(m, NoRemediationNeeded),
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    deleting'         = deleting.put(m, false),
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation.put(m, false),
    admissionSafe'    = admissionSafe.put(m, false),
    hookFreshSafe'    = hookFreshSafe.put(m, false),
  }

  // ── ResolveNodeRef ────────────────────────────────────────────
  // The controller observes a Node corresponding to a Machine and
  // sets Machine.status.nodeRef. The model collapses the two-step
  // CAPI dance (Bootstrap → Machine controller → NodeRef set)
  // into a single transition.
  action ResolveNodeRef(m: MachineId): bool = all {
    machines.contains(m),
    not(nodeRefSet.get(m)),
    nodeRefSet' = nodeRefSet.put(m, true),
    machines'         = machines,
    machineHealth'    = machineHealth,
    decision'         = decision,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    deleting'         = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  // ── HealthChange ──────────────────────────────────────────────
  // The controller updates a Machine's coarse health label after
  // re-projecting MHC's per-condition state.
  action HealthChange(m: MachineId, h: MachineHealth): bool = all {
    machines.contains(m),
    machineHealth' = machineHealth.put(m, h),
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    decision'         = decision,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    deleting'         = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  // ── RequestRemediation ────────────────────────────────────────
  // The controller flips a Machine into RemediationRequested
  // because MachineHealthCheck has flipped the
  // MachineHealthCheckSucceeded condition to false.
  action RequestRemediation(m: MachineId): bool = all {
    machines.contains(m),
    machineHealth.get(m) == UnhealthyMachine,
    decision.get(m) == NoRemediationNeeded,
    decision' = decision.put(m, RemediationRequested),
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    deleting'         = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  // ── helpers used by EvaluateCanSafelyRemediate ────────────────

  // Local safety predicate. The action below uses these helpers
  // so the action body stays a flat conjunction.
  def isSafeToRemediate(
      ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): bool =
    remediationPostState(ms, deleting, hasKCPCleanupAnnotation, nrs, m).size()
      >= remediationQuorumBar(ms, deleting, hasKCPCleanupAnnotation, nrs, m)
      and matchableMachines(ms, nrs) == ms

  def computeBlockReason(
      ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): BlockedReason =
    if (not(remediationPostState(ms, deleting, hasKCPCleanupAnnotation, nrs, m).size()
            >= remediationQuorumBar(ms, deleting, hasKCPCleanupAnnotation, nrs, m))) QuorumWouldBeLost
    else if (matchableMachines(ms, nrs) != ms) EtcdMemberSetDoesNotMatchMachineSet
    else OtherBlock

  // ── EvaluateRemediationAdmission ───────────────────────────────
  // First call site: remediation reconcile snapshots the current
  // state and decides whether the Machine may proceed toward the
  // pre-terminate hook. This is intentionally separate from the
  // later hook-time transition so other actions may interleave.
  action EvaluateRemediationAdmission(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == RemediationRequested,
    decision' = decision.put(m,
      if (isSafeToRemediate(machines, nodeRefSet, m))
        RemediationAdmitted
      else RemediationBlocked),
    admissionSafe' = admissionSafe.put(m, isSafeToRemediate(machines, nodeRefSet, m)),
    blockReason' = if (isSafeToRemediate(machines, nodeRefSet, m))
      blockReason
    else
      blockReason.put(m, computeBlockReason(machines, nodeRefSet, m)),
    preflightBlocked' = if (isSafeToRemediate(machines, nodeRefSet, m))
      preflightBlocked
    else true,
    machines'      = machines,
    nodeRefSet'    = nodeRefSet,
    machineHealth' = machineHealth,
    deleting'      = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    hookFreshSafe' = hookFreshSafe,
  }

  // Buggy variant: hook reconcile re-reads the fresh predicate but
  // still proceeds on the earlier admission snapshot.
  action PreTerminateHookGateRecheck(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == RemediationAdmitted,
    admissionSafe.get(m),
    decision' = decision.put(m, RemediationInFlight),
    hookFreshSafe' = hookFreshSafe.put(m, isSafeToRemediate(machines, nodeRefSet, m)),
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    deleting'         = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    admissionSafe'    = admissionSafe,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
  }

  // Fixed variant: hook reconcile must use the fresh state and
  // revert/block if the predicate no longer holds.
  action PreTerminateHookGateRecheckStrict(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == RemediationAdmitted,
    decision' = decision.put(m,
      if (isSafeToRemediate(machines, nodeRefSet, m))
        RemediationInFlight
      else RemediationBlocked),
    hookFreshSafe' = hookFreshSafe.put(m, isSafeToRemediate(machines, nodeRefSet, m)),
    blockReason' = if (isSafeToRemediate(machines, nodeRefSet, m))
      blockReason
    else
      blockReason.put(m, PreTerminateHookGateFailed),
    preflightBlocked' = if (isSafeToRemediate(machines, nodeRefSet, m))
      preflightBlocked
    else true,
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    deleting'         = deleting,
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation,
    admissionSafe'    = admissionSafe,
  }

  // External etcd-membership churn or a sibling remediation can
  // invalidate the earlier admission snapshot before the hook runs.
  action ExternalMembershipChangeDrop(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == NoRemediationNeeded,
    machines'         = machines.exclude(Set(m)),
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    decision'         = decision,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    deleting'         = deleting.put(m, false),
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation.put(m, false),
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  // Mark a peer as already committed to removal by KCP. This is the
  // model-level counterpart to the production condemned-peer helper.
  action MarkCondemnedPeer(m: MachineId): bool = all {
    machines.contains(m),
    not(deleting.get(m)),
    deleting'         = deleting.put(m, true),
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation.put(m, true),
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    decision'         = decision,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  // Wind-down carve-out: a peer may already be deleting without the
  // KCP cleanup annotation while the whole cluster is being torn down.
  action MarkDeletingWithoutCleanup(m: MachineId): bool = all {
    machines.contains(m),
    not(deleting.get(m)),
    deleting'         = deleting.put(m, true),
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation.put(m, false),
    machines'         = machines,
    nodeRefSet'       = nodeRefSet,
    machineHealth'    = machineHealth,
    decision'         = decision,
    blockReason'      = blockReason,
    preflightBlocked' = preflightBlocked,
    admissionSafe'    = admissionSafe,
    hookFreshSafe'    = hookFreshSafe,
  }

  action InitFiveNode: bool = all {
    machines'         = Set(1, 2, 3, 4, 5),
    nodeRefSet'       = Set(1, 2, 3, 4, 5).mapBy(_ => true),
    machineHealth'    = Set(1, 2, 3, 4, 5).mapBy(_ => HealthyMachine),
    decision'         = Set(1, 2, 3, 4, 5).mapBy(_ => NoRemediationNeeded),
    blockReason'      = Map(),
    preflightBlocked' = false,
    deleting'         = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    hasKCPCleanupAnnotation' = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    admissionSafe'    = Set(1, 2, 3, 4, 5).mapBy(_ => false),
    hookFreshSafe'    = Set(1, 2, 3, 4, 5).mapBy(_ => false),
  }

  // ── CompleteRemediation ───────────────────────────────────────
  // The remediation succeeded; the failed Machine is gone and a
  // replacement is up. The model abstracts the replacement
  // creation away — its role here is to release preflight.
  //
  // The per-Machine maps are kept monotonic (cf. EtcdMembership
  // for the same idiom); readers gate on `machines.contains(m)`.
  // Decision flips to NoRemediationNeeded so the post-state is
  // unambiguous even though the entry remains.
  action CompleteRemediation(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == RemediationInFlight,
    machines'       = machines.exclude(Set(m)),
    decision'       = decision.put(m, NoRemediationNeeded),
    nodeRefSet'     = nodeRefSet,
    machineHealth'  = machineHealth,
    blockReason'    = blockReason,
    preflightBlocked' = false,
    deleting'         = deleting.put(m, false),
    hasKCPCleanupAnnotation' = hasKCPCleanupAnnotation.put(m, false),
    admissionSafe'    = admissionSafe.put(m, false),
    hookFreshSafe'    = hookFreshSafe.put(m, false),
  }

  // -------------------------------------------------------------
  // Step relation
  // -------------------------------------------------------------

  action step = any {
    nondet m = MACHINES.oneOf(); AddMachine(m),
    nondet m = MACHINES.oneOf(); ResolveNodeRef(m),
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      HealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateRemediationAdmission(m),
    nondet m = MACHINES.oneOf(); PreTerminateHookGateRecheck(m),
    nondet m = MACHINES.oneOf(); ExternalMembershipChangeDrop(m),
    nondet m = MACHINES.oneOf(); MarkCondemnedPeer(m),
    nondet m = MACHINES.oneOf(); MarkDeletingWithoutCleanup(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
  }

  action stepFixed = any {
    nondet m = MACHINES.oneOf(); AddMachine(m),
    nondet m = MACHINES.oneOf(); ResolveNodeRef(m),
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      HealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateRemediationAdmission(m),
    nondet m = MACHINES.oneOf(); PreTerminateHookGateRecheckStrict(m),
    nondet m = MACHINES.oneOf(); ExternalMembershipChangeDrop(m),
    nondet m = MACHINES.oneOf(); MarkCondemnedPeer(m),
    nondet m = MACHINES.oneOf(); MarkDeletingWithoutCleanup(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
  }

  action stepCondemnedPeersApalache = any {
    nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine).oneOf();
      HealthChange(m, h),
    nondet m = MACHINES.oneOf(); RequestRemediation(m),
    nondet m = MACHINES.oneOf(); EvaluateRemediationAdmission(m),
    nondet m = MACHINES.oneOf(); MarkCondemnedPeer(m),
    nondet m = MACHINES.oneOf(); MarkDeletingWithoutCleanup(m),
  }

  // -------------------------------------------------------------
  // Invariants
  // -------------------------------------------------------------

  // RemediationOnlyWhenSafe: a Machine in RemediationInFlight
  // satisfies the safety predicate at the moment of the
  // EvaluateCanSafelyRemediate transition. The guard enforces
  // this; the invariant is a doc-style cross-check that the
  // post-state matches the precondition.
  val RemediationOnlyWhenSafe =
    machines.forall(m =>
      (decision.keys().contains(m) and decision.get(m) == RemediationInFlight)
        implies (matchableMachines(machines, nodeRefSet) == machines))

  // PreflightBlocksRemediationWhenUnhealthy: if any Machine is
  // RemediationBlocked, preflight is blocked.
  val PreflightBlocksRemediationWhenUnhealthy =
    (MACHINES.exists(m =>
       decision.keys().contains(m) and decision.get(m) == RemediationBlocked))
    implies preflightBlocked

  val GateRecheckAgreesWithAdmission =
    machines.forall(m =>
      (decision.keys().contains(m) and decision.get(m) == RemediationInFlight)
        implies (hookFreshSafe.keys().contains(m) and hookFreshSafe.get(m)))

  def condemnedMachines: Set[MachineId] =
    machines.filter(m =>
      decision.keys().contains(m)
        and (decision.get(m) == RemediationAdmitted or decision.get(m) == RemediationInFlight))

  val NoConcurrentQuorumLoss =
    (machines.size() - condemnedMachines.size()) >= quorumOf(machines.size())

  val FixedVariantPreservesQuorum =
    machines.forall(m =>
      (decision.keys().contains(m) and decision.get(m) == RemediationInFlight)
        implies hookFreshSafe.get(m))

  val NoJointQuorumLossAcrossConcurrentRemediation =
    MACHINES.forall(m =>
      (decision.keys().contains(m)
        and (decision.get(m) == RemediationAdmitted or decision.get(m) == RemediationInFlight))
          implies remediationPostState(machines, deleting, hasKCPCleanupAnnotation, nodeRefSet, m).size()
            >= remediationQuorumBar(machines, deleting, hasKCPCleanupAnnotation, nodeRefSet, m))

  val AllInvariants = all {
    RemediationOnlyWhenSafe,
    PreflightBlocksRemediationWhenUnhealthy,
  }

  // -------------------------------------------------------------
  // Example runs
  // -------------------------------------------------------------

  // Happy remediation: a Machine becomes Unhealthy, KCP requests
  // remediation, the safety check passes, the Machine is
  // replaced.
  run successfulRemediation = init
    .then(HealthChange(2, UnhealthyMachine))
    .then(RequestRemediation(2))
    .then(EvaluateRemediationAdmission(2))
    .then(PreTerminateHookGateRecheck(2))
    .then(CompleteRemediation(2))

  // FM-1's shape: a fourth Machine joins the KCP, has no
  // NodeRef yet (because kubeadm-join is stuck), KCP cannot
  // match the etcd member set, remediation is blocked.
  run blockedByMatch = init
    .then(AddMachine(4))                          // joins without NodeRef
    .then(HealthChange(4, UnhealthyMachine))      // MHC flags it
    .then(RequestRemediation(4))
    .then(EvaluateRemediationAdmission(4))        // blocked: matchOk false

  // Issue #108: admission passes, another membership change lands,
  // and the later hook reconcile still proceeds based on the stale
  // admission result.
  run admissionRaceRun = init
    .then(HealthChange(1, UnhealthyMachine))
    .then(RequestRemediation(1))
    .then(EvaluateRemediationAdmission(1))
    .then(ExternalMembershipChangeDrop(3))
    .then(PreTerminateHookGateRecheck(1))

  // Fixed counterpart: the hook-time recheck blocks instead of
  // proceeding once the fresh state no longer satisfies the gate.
  run fixedAdmissionRaceRun = init
    .then(HealthChange(1, UnhealthyMachine))
    .then(RequestRemediation(1))
    .then(EvaluateRemediationAdmission(1))
    .then(ExternalMembershipChangeDrop(3))
    .then(PreTerminateHookGateRecheckStrict(1))

  // Issue #109: 3-node cluster, once one peer is condemned the next
  // remediation must be blocked by the pre-state quorum bar.
  run threeNodeCondemnedPeerBlockedRun = init
    .then(HealthChange(1, UnhealthyMachine))
    .then(RequestRemediation(1))
    .then(EvaluateRemediationAdmission(1))
    .then(MarkCondemnedPeer(1))
    .then(HealthChange(2, UnhealthyMachine))
    .then(RequestRemediation(2))
    .then(EvaluateRemediationAdmission(2))

  // 5-node cluster, one condemned peer still allows a second admission
  // because the pre-state quorum of 3 is preserved by three survivors.
  run fiveNodeCondemnedPeerAllowedRun = InitFiveNode
    .then(HealthChange(1, UnhealthyMachine))
    .then(RequestRemediation(1))
    .then(EvaluateRemediationAdmission(1))
    .then(MarkCondemnedPeer(1))
    .then(HealthChange(2, UnhealthyMachine))
    .then(RequestRemediation(2))
    .then(EvaluateRemediationAdmission(2))

  // Wind-down carve-out: all peers are deleting, so the stricter
  // pre-state quorum bar is not applied.
  run allDeletingWindDownRun = init
    .then(MarkDeletingWithoutCleanup(3))
    .then(HealthChange(1, UnhealthyMachine))
    .then(RequestRemediation(1))
    .then(EvaluateRemediationAdmission(1))

}
