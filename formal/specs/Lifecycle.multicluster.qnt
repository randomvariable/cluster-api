// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Lifecycle.multicluster.qnt — per-cluster expansion of the KCP
// lifecycle for FM-35 verification.
//
// SCOPE. This is a focused per-cluster spec rather than a 1:1
// mirror of Lifecycle.qnt. It includes the KCP lifecycle actions
// that are required to verify FM-35 (self-hosted upgrade
// deadlock) end-to-end:
//
//   - Etcd membership (ElectLeader, AddLearner, PromoteLearner,
//     RemoveMember, LeaderStepDown, MemberHealthChange).
//   - Kubeadm join (BeginJoin → MarkReady, collapsed phases).
//   - KCP reconcile (AddMachine, DeleteFailedMachine,
//     ResolveNodeRef, MachineHealthChange).
//   - Remediation (RequestRemediation, EvaluateCanSafelyRemediate,
//     CompleteRemediation).
//   - Drain (BeginDrain, DrainTimeout).
//   - Self-hosted-specific (KcpHostPause, KcpHostUnpause,
//     KcpReconcileResume).
//
// What's NOT here (verified in single-cluster Lifecycle.qnt):
//   - Per-step kubeadm phases beyond Begin → Done collapse
//     (the FM-35 deadlock doesn't depend on which kubeadm phase
//     fires).
//   - Containerd/CRI lifecycle, apiserver↔etcd modelling,
//     webhook rotation, custom Node conditions, MHC cache,
//     lifecycle hooks. Each is verified single-cluster and is
//     orthogonal to the FM-35 dynamics.
//
// VERIFICATION. The model bounds CLUSTERS = Set(0, 1) by default.
// Self-hosted scenarios use mgmtCluster[0]=0 (cluster 0 manages
// itself). Dual-cluster scenarios use mgmtCluster[1]=0 (cluster 0
// manages cluster 1).
//
// Refines: controlplane/kubeadm/internal/controllers/ for the
// KCP reconciler; the self-hosted dependency on
// `kcpReconcileEnabled` refines the KCP pod's host-Node availability.
module LifecycleMultiCluster {

  // ===============================================================
  // Domain types
  // ===============================================================

  type MachineId = int
  type Term      = int
  type ClusterId = int

  type LearnerProgress = | Eligible | LaggingFar | Stuck
  type MemberHealth    = | Healthy | Unhealthy | UnknownHealth

  // Kubeadm phases collapsed for FM-35 focus. The deadlock isn't
  // a function of which kubeadm sub-phase fires, only whether
  // the join completes.
  type Phase =
    | NotStarted
    | Joining          // collapsed from Preflight..MarkControlPlaneReady
    | JoinComplete
    | JoinFailed

  type JoinFailureReason =
    | LearnerStuckOnPromote
    | KubeletNotReady
    | OtherJoinFailure

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

  type Observation =
    | ReachableHealthy
    | UnreachableTimeout
    | NoCorrespondingMember

  // ===============================================================
  // Bounds
  // ===============================================================

  // 4 machines per cluster — enough for 3-CP plus a join slot.
  pure val MACHINES: Set[MachineId] = 1.to(4)
  pure val MAX_TERM: Term = 3
  pure val MAX_TEMPLATE_VERSION: int = 2

  // CLUSTERS — parameterised. Default Set(0, 1).
  pure val CLUSTERS: Set[ClusterId] = Set(0, 1)
  pure val MGMT_CLUSTER: ClusterId  = 0

  // ===============================================================
  // State (per-cluster)
  // ===============================================================

  // Etcd
  var members:      ClusterId -> Set[MachineId]
  var learners:     ClusterId -> Set[MachineId]
  var leaderAt:     ClusterId -> (Term -> MachineId)
  var currentTerm:  ClusterId -> Term
  var progress:     ClusterId -> (MachineId -> LearnerProgress)
  var memberHealth: ClusterId -> (MachineId -> MemberHealth)

  // Kubeadm join
  var phase:                  ClusterId -> (MachineId -> Phase)
  var failureReason:          ClusterId -> (MachineId -> JoinFailureReason)
  var etcdMemberRegistered:   ClusterId -> (MachineId -> bool)
  var nodeLocallyRegistered:  ClusterId -> (MachineId -> bool)

  // KCP reconcile
  var machines:           ClusterId -> Set[MachineId]
  var nodeRefSet:         ClusterId -> (MachineId -> bool)
  var machineHealthLabel: ClusterId -> (MachineId -> MachineHealth)
  var decision:           ClusterId -> (MachineId -> RemediationDecision)
  var blockReason:        ClusterId -> (MachineId -> BlockedReason)
  var preflightBlocked:   ClusterId -> bool
  var desiredReplicas:    ClusterId -> int
  var template:           ClusterId -> (MachineId -> int)
  var desiredTemplate:    ClusterId -> int

  // MHC
  var observation: ClusterId -> (MachineId -> Observation)

  // Drain & PDB
  var drainBlocked:   ClusterId -> (MachineId -> bool)
  var pdbViolatedFor: ClusterId -> (MachineId -> bool)

  // Multi-cluster self-hosted state
  // For each cluster c, mgmtCluster[c] is the cluster whose KCP
  // manages it. Self-hosted ⇔ mgmtCluster[c] = c.
  var mgmtCluster: ClusterId -> ClusterId
  // KCP-on-cluster-c is reconciling iff kcpReconcileEnabled[c].
  // Flips false when KCP's host Node is paused / drained.
  var kcpReconcileEnabled: ClusterId -> bool
  // Subset of CLUSTERS that exists in the current scenario.
  var activeClusters: Set[ClusterId]
  // For each mgmt cluster, the Machine that hosts the KCP
  // reconciler pod. KCP's reconciliation depends on this Machine
  // being unpaused.
  var kcpHost: ClusterId -> MachineId

  // ===============================================================
  // Helpers
  // ===============================================================

  pure def voters(ms: Set[MachineId], ls: Set[MachineId]): Set[MachineId] =
    ms.exclude(ls)

  pure def quorumOf(n: int): int = n / 2 + 1

  pure def hasLeader(la: Term -> MachineId, t: Term): bool =
    la.keys().contains(t)

  // Can KCP-on-mgmtCluster[c] reconcile cluster c?
  pure def canReconcile(
      m: ClusterId -> ClusterId,
      e: ClusterId -> bool,
      c: ClusterId): bool =
    e.get(m.get(c))

  // ===============================================================
  // Initial state — single-cluster default (cluster 0 only)
  // ===============================================================

  // init — 3-CP cluster 0 healthy, cluster 1 inactive. No leader
  // yet (ElectLeader will fire to bring the cluster to healthy).
  action init = all {
    members'      = Map(0 -> Set(1, 2, 3),
                        1 -> Set()),
    learners'     = Map(0 -> Set(),
                        1 -> Set()),
    leaderAt'     = Map(0 -> Map(),
                        1 -> Map()),
    currentTerm'  = Map(0 -> 1, 1 -> 1),
    progress'     = Map(0 -> Map(), 1 -> Map()),
    memberHealth' = Map(0 -> Set(1, 2, 3).mapBy(_ => Healthy),
                        1 -> Map()),
    phase'                 = Map(0 -> Set(1, 2, 3).mapBy(_ => JoinComplete)
                                       .put(4, NotStarted),
                                 1 -> MACHINES.mapBy(_ => NotStarted)),
    failureReason'         = Map(0 -> Map(), 1 -> Map()),
    etcdMemberRegistered'  = Map(0 -> Set(1, 2, 3).mapBy(_ => true).put(4, false),
                                 1 -> MACHINES.mapBy(_ => false)),
    nodeLocallyRegistered' = Map(0 -> Set(1, 2, 3).mapBy(_ => true).put(4, false),
                                 1 -> MACHINES.mapBy(_ => false)),
    machines'              = Map(0 -> Set(1, 2, 3), 1 -> Set()),
    nodeRefSet'            = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> Map()),
    machineHealthLabel'    = Map(0 -> Set(1, 2, 3).mapBy(_ => HealthyMachine),
                                 1 -> Map()),
    decision'              = Map(0 -> Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
                                 1 -> Map()),
    blockReason'           = Map(0 -> Map(), 1 -> Map()),
    preflightBlocked'      = Map(0 -> false, 1 -> false),
    desiredReplicas'       = Map(0 -> 3, 1 -> 0),
    template'              = Map(0 -> Set(1, 2, 3).mapBy(_ => 1), 1 -> Map()),
    desiredTemplate'       = Map(0 -> 1, 1 -> 1),
    observation'           = Map(0 -> Set(1, 2, 3).mapBy(_ => ReachableHealthy),
                                 1 -> Map()),
    drainBlocked'          = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    pdbViolatedFor'        = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    mgmtCluster'           = Map(0 -> 0, 1 -> 0),  // not self-hosted
    kcpReconcileEnabled'   = Map(0 -> true, 1 -> true),
    activeClusters'        = Set(0),
    kcpHost'               = Map(0 -> 1, 1 -> 1),
  }

  // ===============================================================
  // Helper actions for state-var updates per cluster
  // ===============================================================

  // putMap helpers — Quint type-parameter syntax doesn't apply
  // here; expand per-type. These save the boilerplate
  // `m.put(c, m.get(c).put(k, v))` for each per-cluster, per-machine
  // state variable.
  pure def putBool(
      outer: ClusterId -> (MachineId -> bool),
      cl: ClusterId, k: MachineId, v: bool): ClusterId -> (MachineId -> bool) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putPhase(
      outer: ClusterId -> (MachineId -> Phase),
      cl: ClusterId, k: MachineId, v: Phase): ClusterId -> (MachineId -> Phase) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putMemberHealth(
      outer: ClusterId -> (MachineId -> MemberHealth),
      cl: ClusterId, k: MachineId, v: MemberHealth): ClusterId -> (MachineId -> MemberHealth) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putMachineHealth(
      outer: ClusterId -> (MachineId -> MachineHealth),
      cl: ClusterId, k: MachineId, v: MachineHealth): ClusterId -> (MachineId -> MachineHealth) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putRemediation(
      outer: ClusterId -> (MachineId -> RemediationDecision),
      cl: ClusterId, k: MachineId, v: RemediationDecision): ClusterId -> (MachineId -> RemediationDecision) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putProgress(
      outer: ClusterId -> (MachineId -> LearnerProgress),
      cl: ClusterId, k: MachineId, v: LearnerProgress): ClusterId -> (MachineId -> LearnerProgress) =
    outer.put(cl, outer.get(cl).put(k, v))

  pure def putInt(
      outer: ClusterId -> (MachineId -> int),
      cl: ClusterId, k: MachineId, v: int): ClusterId -> (MachineId -> int) =
    outer.put(cl, outer.get(cl).put(k, v))

  // ===============================================================
  // Etcd membership actions (per-cluster)
  // ===============================================================

  action ElectLeader(cl: ClusterId, c: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    voters(members.get(cl), learners.get(cl)).contains(c),
    not(hasLeader(leaderAt.get(cl), currentTerm.get(cl))),
    leaderAt' = leaderAt.put(cl, leaderAt.get(cl).put(currentTerm.get(cl), c)),
    members' = members, learners' = learners,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action AdvanceTerm(cl: ClusterId): bool = all {
    cl.in(activeClusters),
    currentTerm.get(cl) < MAX_TERM,
    currentTerm' = currentTerm.put(cl, currentTerm.get(cl) + 1),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action AddLearner(cl: ClusterId, id: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    not(members.get(cl).contains(id)),
    hasLeader(leaderAt.get(cl), currentTerm.get(cl)),
    members'  = members.put(cl, members.get(cl).union(Set(id))),
    learners' = learners.put(cl, learners.get(cl).union(Set(id))),
    progress' = putProgress(progress, cl, id, LaggingFar),
    memberHealth' = putMemberHealth(memberHealth, cl, id, UnknownHealth),
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action PromoteLearner(cl: ClusterId, id: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    learners.get(cl).contains(id),
    progress.get(cl).keys().contains(id),
    progress.get(cl).get(id) == Eligible,
    hasLeader(leaderAt.get(cl), currentTerm.get(cl)),
    learners' = learners.put(cl, learners.get(cl).exclude(Set(id))),
    memberHealth' = putMemberHealth(memberHealth, cl, id, Healthy),
    members' = members, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action RemoveMember(cl: ClusterId, id: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    members.get(cl).contains(id),
    voters(members.get(cl).exclude(Set(id)),
           learners.get(cl).exclude(Set(id))).size() >= 1,
    hasLeader(leaderAt.get(cl), currentTerm.get(cl)),
    leaderAt.get(cl).get(currentTerm.get(cl)) != id,  // R-LEAD-STEP-DOWN
    not(drainBlocked.get(cl).keys().contains(id) and  // D-DRAIN-TIMEOUT
        drainBlocked.get(cl).get(id)),
    members' = members.put(cl, members.get(cl).exclude(Set(id))),
    learners' = learners.put(cl, learners.get(cl).exclude(Set(id))),
    leaderAt' = leaderAt, currentTerm' = currentTerm,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action LeaderStepDown(cl: ClusterId, id: MachineId): bool = all {
    cl.in(activeClusters),
    hasLeader(leaderAt.get(cl), currentTerm.get(cl)),
    leaderAt.get(cl).get(currentTerm.get(cl)) == id,
    currentTerm.get(cl) < MAX_TERM,
    any {
      memberHealth.get(cl).keys().contains(id) and
      memberHealth.get(cl).get(id) == UnknownHealth,
      memberHealth.get(cl).keys().contains(id) and
      memberHealth.get(cl).get(id) == Unhealthy,
      not(members.get(cl).contains(id)),
    },
    currentTerm' = currentTerm.put(cl, currentTerm.get(cl) + 1),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    progress' = progress, memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action MemberHealthChange(
      cl: ClusterId, id: MachineId, h: MemberHealth): bool = all {
    cl.in(activeClusters),
    members.get(cl).contains(id),
    observation.get(cl).keys().contains(id),
    val o = observation.get(cl).get(id)
    any {
      all { h == Healthy,        o == ReachableHealthy },
      all { h == UnknownHealth,  o == UnreachableTimeout },
      all { h == UnknownHealth,  o == NoCorrespondingMember },
    },
    memberHealth' = putMemberHealth(memberHealth, cl, id, h),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // ===============================================================
  // Kubeadm join (collapsed) and KCP reconcile actions
  // ===============================================================

  // BeginJoin — KCP creates the Machine, Bootstrap delivers
  // cloud-init, kubeadm-join runs. Collapsed: NotStarted → Joining.
  action BeginJoin(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    machines.get(cl).contains(m),
    phase.get(cl).get(m) == NotStarted,
    phase' = putPhase(phase, cl, m, Joining),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // CompleteJoin — kubeadm-join succeeded; etcd member registered;
  // local Node registered; phase advances to JoinComplete.
  action CompleteJoin(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    phase.get(cl).get(m) == Joining,
    not(learners.get(cl).contains(m)),  // already promoted
    members.get(cl).contains(m),         // is a voter
    phase'                 = putPhase(phase, cl, m, JoinComplete),
    etcdMemberRegistered'  = putBool(etcdMemberRegistered, cl, m, true),
    nodeLocallyRegistered' = putBool(nodeLocallyRegistered, cl, m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    failureReason' = failureReason,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action AddMachine(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    not(machines.get(cl).contains(m)),
    MACHINES.contains(m),
    machines'              = machines.put(cl, machines.get(cl).union(Set(m))),
    nodeRefSet'            = putBool(nodeRefSet, cl, m, false),
    machineHealthLabel'    = putMachineHealth(machineHealthLabel, cl, m, UnknownHealthMachine),
    decision'              = putRemediation(decision, cl, m, NoRemediationNeeded),
    phase'                 = putPhase(phase, cl, m, NotStarted),
    etcdMemberRegistered'  = putBool(etcdMemberRegistered, cl, m, false),
    nodeLocallyRegistered' = putBool(nodeLocallyRegistered, cl, m, false),
    template'              = putInt(template, cl, m, desiredTemplate.get(cl)),
    drainBlocked'          = putBool(drainBlocked, cl, m, false),
    pdbViolatedFor'        = putBool(pdbViolatedFor, cl, m, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    failureReason' = failureReason,
    blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action ResolveNodeRef(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    machines.get(cl).contains(m),
    nodeRefSet.get(cl).keys().contains(m),
    not(nodeRefSet.get(cl).get(m)),
    nodeLocallyRegistered.get(cl).keys().contains(m),
    nodeLocallyRegistered.get(cl).get(m),
    nodeRefSet' = putBool(nodeRefSet, cl, m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action MachineHealthChange(
      cl: ClusterId, m: MachineId, h: MachineHealth): bool = all {
    cl.in(activeClusters),
    machines.get(cl).contains(m),
    machineHealthLabel' = putMachineHealth(machineHealthLabel, cl, m, h),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action DeleteFailedMachine(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    phase.get(cl).keys().contains(m),
    phase.get(cl).get(m) == JoinFailed,
    machines.get(cl).contains(m),
    not(members.get(cl).contains(m)),
    machines' = machines.put(cl, machines.get(cl).exclude(Set(m))),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // ===============================================================
  // Drain
  // ===============================================================

  action BeginDrain(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    machines.get(cl).contains(m),
    decision.get(cl).keys().contains(m),
    decision.get(cl).get(m) == RemediationInFlight,
    drainBlocked.get(cl).keys().contains(m),
    not(drainBlocked.get(cl).get(m)),
    pdbViolatedFor.get(cl).keys().contains(m),
    pdbViolatedFor.get(cl).get(m),
    drainBlocked' = putBool(drainBlocked, cl, m, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  action DrainTimeout(cl: ClusterId, m: MachineId): bool = all {
    cl.in(activeClusters),
    canReconcile(mgmtCluster, kcpReconcileEnabled, cl),
    drainBlocked.get(cl).keys().contains(m),
    drainBlocked.get(cl).get(m),
    decision.get(cl).keys().contains(m),
    drainBlocked'     = putBool(drainBlocked, cl, m, false),
    decision'         = putRemediation(decision, cl, m, RemediationInFlight),
    preflightBlocked' = preflightBlocked.put(cl, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    blockReason' = blockReason,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // ===============================================================
  // Operator actions
  // ===============================================================

  // OperatorBumpTemplate — operator changes desiredTemplate (e.g.
  // KubeadmControlPlane.spec.kubernetesVersion bump). Triggers a
  // rolling upgrade.
  action OperatorBumpTemplate(cl: ClusterId, t: int): bool = all {
    cl.in(activeClusters),
    1.to(MAX_TEMPLATE_VERSION).contains(t),
    t != desiredTemplate.get(cl),
    desiredTemplate' = desiredTemplate.put(cl, t),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    kcpReconcileEnabled' = kcpReconcileEnabled,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // ===============================================================
  // Self-hosted-specific actions (FM-35 deadlock entry / recovery)
  // ===============================================================

  // KcpHostPause — fault: the Machine hosting KCP's reconciler pod
  // is paused (drain in progress, host shutdown, etc.). KCP can't
  // reconcile until the pod fails over.
  // Refines the operational case where KCP rolls its own host
  // during a self-hosted upgrade.
  action KcpHostPause(cl: ClusterId): bool = all {
    cl.in(activeClusters),
    kcpReconcileEnabled.get(cl),
    // The mgmt-cluster's kcpHost Machine is in its machines set.
    machines.get(mgmtCluster.get(cl)).contains(kcpHost.get(mgmtCluster.get(cl))),
    kcpReconcileEnabled' = kcpReconcileEnabled.put(cl, false),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    activeClusters' = activeClusters, kcpHost' = kcpHost,
  }

  // KcpReconcileResume — recovery: operator manually fails over
  // the KCP reconciler pod to a healthy non-paused Machine. Refines
  // `kubectl delete pod -n kcp-system kcp-controller-...` which
  // forces a Deployment-driven re-schedule.
  action KcpReconcileResume(cl: ClusterId, newHost: MachineId): bool = all {
    cl.in(activeClusters),
    not(kcpReconcileEnabled.get(cl)),
    machines.get(mgmtCluster.get(cl)).contains(newHost),
    newHost != kcpHost.get(mgmtCluster.get(cl)),
    machineHealthLabel.get(mgmtCluster.get(cl)).keys().contains(newHost),
    machineHealthLabel.get(mgmtCluster.get(cl)).get(newHost) == HealthyMachine,
    kcpHost' = kcpHost.put(mgmtCluster.get(cl), newHost),
    kcpReconcileEnabled' = kcpReconcileEnabled.put(cl, true),
    members' = members, learners' = learners, leaderAt' = leaderAt,
    currentTerm' = currentTerm, progress' = progress,
    memberHealth' = memberHealth,
    phase' = phase, failureReason' = failureReason,
    etcdMemberRegistered' = etcdMemberRegistered,
    nodeLocallyRegistered' = nodeLocallyRegistered,
    machines' = machines, nodeRefSet' = nodeRefSet,
    machineHealthLabel' = machineHealthLabel,
    decision' = decision, blockReason' = blockReason,
    preflightBlocked' = preflightBlocked,
    desiredReplicas' = desiredReplicas, template' = template,
    desiredTemplate' = desiredTemplate,
    observation' = observation,
    drainBlocked' = drainBlocked, pdbViolatedFor' = pdbViolatedFor,
    mgmtCluster' = mgmtCluster,
    activeClusters' = activeClusters,
  }

  // ===============================================================
  // Step relations
  // ===============================================================

  action step = any {
    nondet cl = activeClusters.oneOf(); nondet c = MACHINES.oneOf();
      ElectLeader(cl, c),
    nondet cl = activeClusters.oneOf(); AdvanceTerm(cl),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      AddLearner(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      PromoteLearner(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      RemoveMember(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      LeaderStepDown(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      nondet h = Set(Healthy, Unhealthy, UnknownHealth).oneOf();
      MemberHealthChange(cl, id, h),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      BeginJoin(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      CompleteJoin(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      AddMachine(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      ResolveNodeRef(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      MachineHealthChange(cl, m, h),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      DeleteFailedMachine(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      BeginDrain(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      DrainTimeout(cl, m),
    nondet cl = activeClusters.oneOf(); KcpHostPause(cl),
    nondet cl = activeClusters.oneOf(); nondet h = MACHINES.oneOf();
      KcpReconcileResume(cl, h),
    nondet cl = activeClusters.oneOf();
      nondet t = 1.to(MAX_TEMPLATE_VERSION).oneOf();
      OperatorBumpTemplate(cl, t),
  }

  // stepNoRecovery — KcpReconcileResume and DrainTimeout disabled.
  // Used for hopelessness proofs.
  action stepNoRecovery = any {
    nondet cl = activeClusters.oneOf(); nondet c = MACHINES.oneOf();
      ElectLeader(cl, c),
    nondet cl = activeClusters.oneOf(); AdvanceTerm(cl),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      AddLearner(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      PromoteLearner(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      RemoveMember(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      LeaderStepDown(cl, id),
    nondet cl = activeClusters.oneOf(); nondet id = MACHINES.oneOf();
      nondet h = Set(Healthy, Unhealthy, UnknownHealth).oneOf();
      MemberHealthChange(cl, id, h),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      BeginJoin(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      CompleteJoin(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      AddMachine(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      ResolveNodeRef(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      nondet h = Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine).oneOf();
      MachineHealthChange(cl, m, h),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      DeleteFailedMachine(cl, m),
    nondet cl = activeClusters.oneOf(); nondet m = MACHINES.oneOf();
      BeginDrain(cl, m),
    nondet cl = activeClusters.oneOf(); KcpHostPause(cl),
    nondet cl = activeClusters.oneOf();
      nondet t = 1.to(MAX_TEMPLATE_VERSION).oneOf();
      OperatorBumpTemplate(cl, t),
  }

  // ===============================================================
  // Predicates
  // ===============================================================

  // HealthyControlPlane(cl): same shape as Lifecycle.qnt's
  // HealthyControlPlane but per-cluster.
  pure def HealthyControlPlane(
      desiredReplicas_: int,
      machines_: Set[MachineId],
      nodeRefSet_: MachineId -> bool,
      members_: Set[MachineId],
      learners_: Set[MachineId],
      memberHealth_: MachineId -> MemberHealth,
      leaderAt_: Term -> MachineId,
      currentTerm_: Term,
      decision_: MachineId -> RemediationDecision,
      preflightBlocked_: bool,
      observation_: MachineId -> Observation,
      template_: MachineId -> int,
      desiredTemplate_: int): bool =
    machines_.size() == desiredReplicas_ and
    Set(1, 3, 5).contains(desiredReplicas_) and
    machines_.forall(m =>
      nodeRefSet_.keys().contains(m) and nodeRefSet_.get(m)) and
    voters(members_, learners_).size() >= quorumOf(machines_.size()) and
    members_ == machines_ and
    learners_ == Set() and
    voters(members_, learners_).forall(v =>
      memberHealth_.keys().contains(v) and memberHealth_.get(v) == Healthy) and
    leaderAt_.keys().contains(currentTerm_) and
    machines_.forall(m =>
      decision_.keys().contains(m) implies
        (decision_.get(m) == NoRemediationNeeded
          or decision_.get(m) == RemediationInFlight)) and
    not(preflightBlocked_) and
    machines_.forall(m =>
      observation_.keys().contains(m) and
      observation_.get(m) == ReachableHealthy) and
    machines_.forall(m =>
      template_.keys().contains(m) and template_.get(m) == desiredTemplate_)

  val MgmtClusterHealthy =
    HealthyControlPlane(
      desiredReplicas.get(MGMT_CLUSTER),
      machines.get(MGMT_CLUSTER),
      nodeRefSet.get(MGMT_CLUSTER),
      members.get(MGMT_CLUSTER),
      learners.get(MGMT_CLUSTER),
      memberHealth.get(MGMT_CLUSTER),
      leaderAt.get(MGMT_CLUSTER),
      currentTerm.get(MGMT_CLUSTER),
      decision.get(MGMT_CLUSTER),
      preflightBlocked.get(MGMT_CLUSTER),
      observation.get(MGMT_CLUSTER),
      template.get(MGMT_CLUSTER),
      desiredTemplate.get(MGMT_CLUSTER))

  val AllClustersHealthy =
    activeClusters.forall(cl =>
      HealthyControlPlane(
        desiredReplicas.get(cl),
        machines.get(cl),
        nodeRefSet.get(cl),
        members.get(cl),
        learners.get(cl),
        memberHealth.get(cl),
        leaderAt.get(cl),
        currentTerm.get(cl),
        decision.get(cl),
        preflightBlocked.get(cl),
        observation.get(cl),
        template.get(cl),
        desiredTemplate.get(cl)))

  // FM-35 specific: KCP-on-mgmt-cluster is paused AND mgmt cluster
  // has at least one machine on the old template (upgrade not done).
  val FM35Deadlocked =
    not(kcpReconcileEnabled.get(MGMT_CLUSTER)) and
    machines.get(MGMT_CLUSTER).exists(m =>
      template.get(MGMT_CLUSTER).keys().contains(m) and
      template.get(MGMT_CLUSTER).get(m) != desiredTemplate.get(MGMT_CLUSTER))

  // ===============================================================
  // Self-hosted scenario inits
  // ===============================================================

  // selfHostedSteadyInit — 3-CP self-hosted cluster healthy.
  // mgmtCluster[0] = 0 (cluster manages itself).
  action selfHostedSteadyInit = all {
    members'      = Map(0 -> Set(1, 2, 3), 1 -> Set()),
    learners'     = Map(0 -> Set(), 1 -> Set()),
    leaderAt'     = Map(0 -> Map(1 -> 1), 1 -> Map()),
    currentTerm'  = Map(0 -> 1, 1 -> 1),
    progress'     = Map(0 -> Map(), 1 -> Map()),
    memberHealth' = Map(0 -> Set(1, 2, 3).mapBy(_ => Healthy), 1 -> Map()),
    phase'                 = Map(0 -> Set(1, 2, 3).mapBy(_ => JoinComplete),
                                 1 -> MACHINES.mapBy(_ => NotStarted)),
    failureReason'         = Map(0 -> Map(), 1 -> Map()),
    etcdMemberRegistered'  = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> MACHINES.mapBy(_ => false)),
    nodeLocallyRegistered' = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> MACHINES.mapBy(_ => false)),
    machines'              = Map(0 -> Set(1, 2, 3), 1 -> Set()),
    nodeRefSet'            = Map(0 -> Set(1, 2, 3).mapBy(_ => true), 1 -> Map()),
    machineHealthLabel'    = Map(0 -> Set(1, 2, 3).mapBy(_ => HealthyMachine),
                                 1 -> Map()),
    decision'              = Map(0 -> Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
                                 1 -> Map()),
    blockReason'           = Map(0 -> Map(), 1 -> Map()),
    preflightBlocked'      = Map(0 -> false, 1 -> false),
    desiredReplicas'       = Map(0 -> 3, 1 -> 0),
    template'              = Map(0 -> Set(1, 2, 3).mapBy(_ => 1), 1 -> Map()),
    desiredTemplate'       = Map(0 -> 1, 1 -> 1),
    observation'           = Map(0 -> Set(1, 2, 3).mapBy(_ => ReachableHealthy),
                                 1 -> Map()),
    drainBlocked'          = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    pdbViolatedFor'        = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    mgmtCluster'           = Map(0 -> 0, 1 -> 0),  // self-hosted: c=0 → mgmt=0
    kcpReconcileEnabled'   = Map(0 -> true, 1 -> true),
    activeClusters'        = Set(0),               // single self-hosted cluster
    kcpHost'               = Map(0 -> 1, 1 -> 1),
  }

  // selfHostedDeadlockInit — KCP host (Machine 1) paused
  // mid-upgrade. desiredTemplate=2, machines on template 1.
  // KCP cannot reconcile.
  action selfHostedDeadlockInit = all {
    members'      = Map(0 -> Set(1, 2, 3), 1 -> Set()),
    learners'     = Map(0 -> Set(), 1 -> Set()),
    leaderAt'     = Map(0 -> Map(1 -> 1), 1 -> Map()),
    currentTerm'  = Map(0 -> 1, 1 -> 1),
    progress'     = Map(0 -> Map(), 1 -> Map()),
    memberHealth' = Map(0 -> Set(1, 2, 3).mapBy(_ => Healthy), 1 -> Map()),
    phase'                 = Map(0 -> Set(1, 2, 3).mapBy(_ => JoinComplete),
                                 1 -> MACHINES.mapBy(_ => NotStarted)),
    failureReason'         = Map(0 -> Map(), 1 -> Map()),
    etcdMemberRegistered'  = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> MACHINES.mapBy(_ => false)),
    nodeLocallyRegistered' = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> MACHINES.mapBy(_ => false)),
    machines'              = Map(0 -> Set(1, 2, 3), 1 -> Set()),
    nodeRefSet'            = Map(0 -> Set(1, 2, 3).mapBy(_ => true), 1 -> Map()),
    machineHealthLabel'    = Map(0 -> Set(2, 3).mapBy(_ => HealthyMachine)
                                       .put(1, UnhealthyMachine),
                                 1 -> Map()),
    decision'              = Map(0 -> Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
                                 1 -> Map()),
    blockReason'           = Map(0 -> Map(), 1 -> Map()),
    preflightBlocked'      = Map(0 -> false, 1 -> false),
    desiredReplicas'       = Map(0 -> 3, 1 -> 0),
    template'              = Map(0 -> Set(1, 2, 3).mapBy(_ => 1), 1 -> Map()),
    desiredTemplate'       = Map(0 -> 2, 1 -> 1),  // upgrade requested
    observation'           = Map(0 -> Set(1, 2, 3).mapBy(_ => ReachableHealthy),
                                 1 -> Map()),
    drainBlocked'          = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    pdbViolatedFor'        = Map(0 -> Set(1, 2, 3).mapBy(_ => false), 1 -> Map()),
    mgmtCluster'           = Map(0 -> 0, 1 -> 0),
    kcpReconcileEnabled'   = Map(0 -> false, 1 -> true),  // KCP host paused
    activeClusters'        = Set(0),
    kcpHost'               = Map(0 -> 1, 1 -> 1),
  }

  // dualClusterSteadyInit — Cluster 0 (mgmt) and cluster 1
  // (workload) both healthy. mgmtCluster[1] = 0.
  action dualClusterSteadyInit = all {
    members'      = Map(0 -> Set(1, 2, 3),
                        1 -> Set(1, 2, 3)),
    learners'     = Map(0 -> Set(), 1 -> Set()),
    leaderAt'     = Map(0 -> Map(1 -> 1), 1 -> Map(1 -> 1)),
    currentTerm'  = Map(0 -> 1, 1 -> 1),
    progress'     = Map(0 -> Map(), 1 -> Map()),
    memberHealth' = Map(0 -> Set(1, 2, 3).mapBy(_ => Healthy),
                        1 -> Set(1, 2, 3).mapBy(_ => Healthy)),
    phase'                 = Map(0 -> Set(1, 2, 3).mapBy(_ => JoinComplete),
                                 1 -> Set(1, 2, 3).mapBy(_ => JoinComplete)),
    failureReason'         = Map(0 -> Map(), 1 -> Map()),
    etcdMemberRegistered'  = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> Set(1, 2, 3).mapBy(_ => true)),
    nodeLocallyRegistered' = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> Set(1, 2, 3).mapBy(_ => true)),
    machines'              = Map(0 -> Set(1, 2, 3), 1 -> Set(1, 2, 3)),
    nodeRefSet'            = Map(0 -> Set(1, 2, 3).mapBy(_ => true),
                                 1 -> Set(1, 2, 3).mapBy(_ => true)),
    machineHealthLabel'    = Map(0 -> Set(1, 2, 3).mapBy(_ => HealthyMachine),
                                 1 -> Set(1, 2, 3).mapBy(_ => HealthyMachine)),
    decision'              = Map(0 -> Set(1, 2, 3).mapBy(_ => NoRemediationNeeded),
                                 1 -> Set(1, 2, 3).mapBy(_ => NoRemediationNeeded)),
    blockReason'           = Map(0 -> Map(), 1 -> Map()),
    preflightBlocked'      = Map(0 -> false, 1 -> false),
    desiredReplicas'       = Map(0 -> 3, 1 -> 3),
    template'              = Map(0 -> Set(1, 2, 3).mapBy(_ => 1),
                                 1 -> Set(1, 2, 3).mapBy(_ => 1)),
    desiredTemplate'       = Map(0 -> 1, 1 -> 1),
    observation'           = Map(0 -> Set(1, 2, 3).mapBy(_ => ReachableHealthy),
                                 1 -> Set(1, 2, 3).mapBy(_ => ReachableHealthy)),
    drainBlocked'          = Map(0 -> Set(1, 2, 3).mapBy(_ => false),
                                 1 -> Set(1, 2, 3).mapBy(_ => false)),
    pdbViolatedFor'        = Map(0 -> Set(1, 2, 3).mapBy(_ => false),
                                 1 -> Set(1, 2, 3).mapBy(_ => false)),
    mgmtCluster'           = Map(0 -> 0, 1 -> 0),  // cluster 0 manages both
    kcpReconcileEnabled'   = Map(0 -> true, 1 -> true),
    activeClusters'        = Set(0, 1),
    kcpHost'               = Map(0 -> 1, 1 -> 1),
  }

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // FM-35's deadlock shape: from steady, operator bumps template
  // (upgrade requested), then KCP host gets paused mid-upgrade.
  // After this, FM35Deadlocked holds.
  run selfHostedDeadlockTrace = selfHostedSteadyInit
    .then(OperatorBumpTemplate(0, 2))
    .then(KcpHostPause(0))

  // Operator workaround: from deadlock state, fail KCP over to a
  // healthy non-paused Machine.
  run selfHostedRecoveryTrace = selfHostedDeadlockInit
    .then(KcpReconcileResume(0, 2))

  // ===============================================================
  // Invariants
  // ===============================================================

  val SafetyInvariants = all {
    // Self-hosted invariant: management = workload at MGMT_CLUSTER.
    activeClusters.contains(0) implies mgmtCluster.get(0) == 0,
    // KCP host is always in mgmt cluster's machine set.
    activeClusters.forall(cl =>
      machines.get(mgmtCluster.get(cl)).contains(kcpHost.get(mgmtCluster.get(cl)))),
    // Voter set non-empty for active clusters that have machines.
    activeClusters.forall(cl =>
      machines.get(cl).size() > 0 implies
        voters(members.get(cl), learners.get(cl)).size() >= 1),
    // Learner set is a subset of member set (per cluster).
    activeClusters.forall(cl =>
      learners.get(cl).subseteq(members.get(cl))),
  }
}
