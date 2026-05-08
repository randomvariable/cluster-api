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
    | RemediationBlocked
    | RemediationInFlight

  // The reason a remediation is blocked. Distinct values matter
  // because the InformativenessObligation invariant in
  // Composition.qnt distinguishes them.
  type BlockedReason =
    | QuorumWouldBeLost
    | EtcdMemberSetDoesNotMatchMachineSet
    | InsufficientReplicas
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
  }

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------

  pure def quorumOf(n: int): int = n / 2 + 1

  // Whether deleting `m` from the current voter set preserves
  // quorum.
  pure def quorumPreservedAfterDelete(ms: Set[MachineId], m: MachineId): bool =
    ms.contains(m) and (ms.size() - 1) >= quorumOf(ms.size())

  // The NodeRef-projected machine set: only Machines for which
  // nodeRefSet has been resolved to true. This is the surface
  // KCP can match to etcd members.
  pure def matchableMachines(ms: Set[MachineId], nrs: MachineId -> bool): Set[MachineId] =
    ms.filter(m => nrs.keys().contains(m) and nrs.get(m))

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
  }

  // ── helpers used by EvaluateCanSafelyRemediate ────────────────

  // Local safety predicate. The action below uses these helpers
  // so the action body stays a flat conjunction.
  pure def isSafeToRemediate(
      ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): bool =
    quorumPreservedAfterDelete(ms, m)
      and matchableMachines(ms, nrs) == ms

  pure def computeBlockReason(
      ms: Set[MachineId], nrs: MachineId -> bool, m: MachineId): BlockedReason =
    if (not(quorumPreservedAfterDelete(ms, m))) QuorumWouldBeLost
    else if (matchableMachines(ms, nrs) != ms) EtcdMemberSetDoesNotMatchMachineSet
    else OtherBlock

  // ── EvaluateCanSafelyRemediate ────────────────────────────────
  // The reconcile loop computes whether remediation is safe and
  // either advances the decision to RemediationInFlight or pins
  // it at RemediationBlocked with a reason. The action's guard
  // encodes the same predicate as KCP's `canSafelyRemediate` Go
  // helper; the row in formal/abstraction-mapping.md fixes the
  // refinement obligation.
  action EvaluateCanSafelyRemediate(m: MachineId): bool = all {
    machines.contains(m),
    decision.get(m) == RemediationRequested,
    decision' = decision.put(m,
      if (isSafeToRemediate(machines, nodeRefSet, m))
        RemediationInFlight
      else RemediationBlocked),
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
    nondet m = MACHINES.oneOf(); EvaluateCanSafelyRemediate(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
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
    .then(EvaluateCanSafelyRemediate(2))
    .then(CompleteRemediation(2))

  // The incident shape: a fourth Machine joins the KCP, has no
  // NodeRef yet (because kubeadm-join is stuck), KCP cannot
  // match the etcd member set, remediation is blocked.
  run blockedByMatch = init
    .then(AddMachine(4))                          // joins without NodeRef
    .then(HealthChange(4, UnhealthyMachine))      // MHC flags it
    .then(RequestRemediation(4))
    .then(EvaluateCanSafelyRemediate(4))          // blocked: matchOk false

}
