// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// SelfHosted.qnt — FM-35: self-hosted CAPI deadlock under upgrade.
//
// In a self-hosted CAPI deployment, the management cluster IS the
// workload cluster's control plane. The KCP reconciler runs as a
// pod on the management cluster (which is the cluster KCP manages).
// During an upgrade or remediation, KCP may need to delete or
// restart the very Machine its own pod runs on; if the
// reconciliation pauses (because the host Node is being drained,
// the apiserver is restarting, etcd lost a member), there is no
// other reconciler to drive the upgrade forward. The cluster
// deadlocks.
//
// The full Lifecycle.qnt model is single-cluster — every state
// variable applies to one cluster. Refactoring it to dual-cluster
// requires per-cluster wrapping of every state variable (40+) and
// adding a `cluster` parameter to every action (~70). That refactor
// is the path called out in the Phase 12 plan; this module exists
// alongside Lifecycle.qnt as a focused demonstration of the FM-35
// deadlock dynamics.
//
// The model is deliberately minimal: it captures the essential
// "KCP reconciler depends on its host" feedback loop. A faithful
// proof would require the full per-cluster expansion.
//
// Refines: cluster-api#12886 (upstream-issues-research.md Tier 2).
// Contract: formal/contracts/kcp-machine-contract.md (deferred —
//           contract obligations specific to self-hosted topology
//           need to be added in the dual-cluster expansion).
module SelfHosted {

  // -------------------------------------------------------------
  // Domain types
  // -------------------------------------------------------------

  type ClusterId = int
  type MachineId = int

  // What's currently happening to the management cluster's KCP
  // reconciler pod, viewed at the granularity FM-35 needs:
  //   Running     — pod is healthy, reconciles freely
  //   Paused      — host Node paused (e.g. drain in progress)
  //   Migrating   — KCP pod failover to a different host CP
  type KcpStatus =
    | Running
    | Paused
    | Migrating

  // The phase of the management cluster's rolling upgrade.
  type UpgradePhase =
    | NoUpgrade
    | UpgradeInProgress
    | UpgradeComplete
    | UpgradeDeadlock        // FM-35's terminal state

  // Concrete sub-step for issue #96.
  // EtcdRoll is the problematic phase for a self-hosted control plane:
  // the upgrade needs to persist etcd membership/config changes via the
  // same etcd instance that is currently being rolled.
  type UpgradeStep =
    | Idle
    | EtcdRoll
    | ApiserverRoll

  // -------------------------------------------------------------
  // Bounds
  // -------------------------------------------------------------

  pure val CLUSTERS: Set[ClusterId] = Set(0)
  pure val MGMT_MACHINES: Set[MachineId] = 1.to(3)

  // -------------------------------------------------------------
  // State
  // -------------------------------------------------------------

  // The management cluster's machines.
  var mgmtMachines: Set[MachineId]
  // Which Machine hosts the KCP reconciler pod.
  var kcpHost: MachineId
  // KCP reconciler status.
  var kcpStatus: KcpStatus
  // For each Machine, whether it has been paused (Node drained,
  // host shut down, etc.).
  var machinePaused: MachineId -> bool
  // For each Machine, its template version (1 = old, 2 = new).
  var machineTemplate: MachineId -> int
  // Operator's desired template.
  var desiredMgmtTemplate: int
  // Self-hosted invariant: the cluster IS its own management cluster.
  var wlIsMgmt: bool
  // Upgrade phase.
  var upgradePhase: UpgradePhase
  // Current concrete sub-step of the upgrade.
  var upgradeStep: UpgradeStep
  // Whether the current sub-step still requires a write to the hosted etcd.
  var etcdWriteRequired: bool
  // Operator escape hatch: external etcd, manual staged write, or other
  // side-channel that lets the upgrade continue despite the self-hosted trap.
  var escapeHatch: bool

  // -------------------------------------------------------------
  // Initial states
  // -------------------------------------------------------------

  // Default `init` for `quint run` — uses the steady scenario.
  action init = selfHostedSteadyInit

  // Steady self-hosted cluster: 3-CP, all template 1, KCP runs on
  // Machine 1, no upgrade in flight.
  action selfHostedSteadyInit = all {
    mgmtMachines'        = MGMT_MACHINES,
    kcpHost'             = 1,
    kcpStatus'           = Running,
    machinePaused'       = MGMT_MACHINES.mapBy(_ => false),
    machineTemplate'     = MGMT_MACHINES.mapBy(_ => 1),
    desiredMgmtTemplate' = 1,
    wlIsMgmt'            = true,
    upgradePhase'        = NoUpgrade,
    upgradeStep'         = Idle,
    etcdWriteRequired'   = false,
    escapeHatch'         = false,
  }

  // Upgrade in flight: operator bumped desiredMgmtTemplate to 2;
  // Machine 4 (KCP host's replacement) is mid-upgrade.
  // KCP reconciler still on Machine 1, status Running.
  action selfHostedUpgradeMidFlightInit = all {
    mgmtMachines'        = MGMT_MACHINES,
    kcpHost'             = 1,
    kcpStatus'           = Running,
    machinePaused'       = MGMT_MACHINES.mapBy(_ => false),
    machineTemplate'     = MGMT_MACHINES.mapBy(_ => 1),
    desiredMgmtTemplate' = 2,
    wlIsMgmt'            = true,
    upgradePhase'        = UpgradeInProgress,
    upgradeStep'         = Idle,
    etcdWriteRequired'   = false,
    escapeHatch'         = false,
  }

  // FM-35's deadlock scenario: KCP pod's host Node has been paused
  // (drain in progress as part of the upgrade). KCP cannot
  // reconcile; the upgrade cannot complete.
  action selfHostedDeadlockInit = all {
    mgmtMachines'        = MGMT_MACHINES,
    kcpHost'             = 1,
    kcpStatus'           = Paused,                    // KCP host paused
    machinePaused'       = MGMT_MACHINES.mapBy(_ => false)
                            .put(1, true),
    machineTemplate'     = MGMT_MACHINES.mapBy(_ => 1),
    desiredMgmtTemplate' = 2,
    wlIsMgmt'            = true,
    upgradePhase'        = UpgradeInProgress,
    upgradeStep'         = Idle,
    etcdWriteRequired'   = false,
    escapeHatch'         = false,
  }

  // -------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------

  pure def quorumOf(n: int): int = n / 2 + 1

  // KCP can drive a reconcile only when its pod is Running.
  pure def kcpCanReconcile(s: KcpStatus): bool = s == Running

  // -------------------------------------------------------------
  // Actions — KCP-driven
  // -------------------------------------------------------------

  // OperatorBumpTemplate — operator changes desiredMgmtTemplate
  // (e.g. spec.kubernetesVersion bump in KubeadmControlPlane).
  action OperatorBumpTemplate(t: int): bool = all {
    1.to(2).contains(t),
    t != desiredMgmtTemplate,
    upgradePhase == NoUpgrade,
    desiredMgmtTemplate' = t,
    upgradePhase' = UpgradeInProgress,
    mgmtMachines' = mgmtMachines, kcpHost' = kcpHost,
    kcpStatus' = kcpStatus, machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // KcpStartUpgrade — KCP detects template mismatch (operator
  // bumped desiredMgmtTemplate) and begins reconciling. The
  // upgradePhase advances to UpgradeInProgress.
  action KcpStartUpgrade: bool = all {
    upgradePhase == NoUpgrade,
    mgmtMachines.exists(m => machineTemplate.get(m) != desiredMgmtTemplate),
    upgradePhase' = UpgradeInProgress,
    mgmtMachines' = mgmtMachines, kcpHost' = kcpHost,
    kcpStatus' = kcpStatus, machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // KcpUpgradeMachine — KCP reconciles a Machine to the new
  // template. Pre-conditions: KCP is Running, Machine is not its
  // own host (otherwise causes self-pause), Machine is on the
  // old template.
  action KcpUpgradeMachine(m: MachineId): bool = all {
    kcpCanReconcile(kcpStatus),
    upgradePhase == UpgradeInProgress,
    mgmtMachines.contains(m),
    m != kcpHost,
    machineTemplate.get(m) != desiredMgmtTemplate,
    machineTemplate' = machineTemplate.put(m, desiredMgmtTemplate),
    mgmtMachines' = mgmtMachines, kcpHost' = kcpHost,
    kcpStatus' = kcpStatus, machinePaused' = machinePaused,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradePhase' = upgradePhase,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // KcpUpgradeOwnHost — KCP must upgrade its own host. To do so,
  // it pauses the host's Node (drain in progress); KCP's status
  // flips to Paused. This is the entry to the deadlock state.
  action KcpUpgradeOwnHost: bool = all {
    kcpCanReconcile(kcpStatus),
    upgradePhase == UpgradeInProgress,
    machineTemplate.get(kcpHost) != desiredMgmtTemplate,
    // Pre: every other Machine is on the new template.
    mgmtMachines.exclude(Set(kcpHost)).forall(m =>
      machineTemplate.get(m) == desiredMgmtTemplate),
    machinePaused' = machinePaused.put(kcpHost, true),
    kcpStatus' = Paused,
    mgmtMachines' = mgmtMachines, kcpHost' = kcpHost,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradePhase' = UpgradeDeadlock,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // KcpReconcileResume — operator workaround: KCP reconciler pod
  // fails over to a healthy non-paused Machine. Refines the
  // documented operator workaround for the self-hosted deadlock.
  action KcpReconcileResume: bool = all {
    kcpStatus == Paused,
    // Find a healthy non-paused Machine to host KCP.
    mgmtMachines.exists(m => not(machinePaused.get(m)) and m != kcpHost),
    // Pick the lowest such id.
    val newHost = mgmtMachines.filter(m =>
                    not(machinePaused.get(m)) and m != kcpHost).fold(
                    99,
                    (acc, m) => if (m < acc) m else acc)
    kcpHost' = newHost,
    kcpStatus' = Running,
    mgmtMachines' = mgmtMachines,
    machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    // After failover, the deadlock is broken; upgrade resumes.
    upgradePhase' = UpgradeInProgress,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // EnterEtcdRoll — concrete issue-96 sub-step. The management cluster
  // is now rolling the etcd member that also hosts the management API.
  action EnterEtcdRoll: bool = all {
    upgradePhase == UpgradeInProgress,
    upgradeStep == Idle,
    upgradeStep' = EtcdRoll,
    etcdWriteRequired' = true,
    mgmtMachines' = mgmtMachines,
    kcpHost' = kcpHost,
    kcpStatus' = kcpStatus,
    machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradePhase' = upgradePhase,
    escapeHatch' = escapeHatch,
  }

  // EtcdRollRequiresEtcdWrite — the concrete chicken-and-egg trap. A
  // self-hosted upgrade step needs to write to the same etcd instance it
  // is currently trying to roll. Without an escape hatch, progress halts.
  action EtcdRollRequiresEtcdWrite: bool = all {
    upgradePhase == UpgradeInProgress,
    upgradeStep == EtcdRoll,
    etcdWriteRequired,
    wlIsMgmt,
    not(escapeHatch),
    upgradePhase' = UpgradeDeadlock,
    mgmtMachines' = mgmtMachines,
    kcpHost' = kcpHost,
    kcpStatus' = kcpStatus,
    machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
    escapeHatch' = escapeHatch,
  }

  // EnableEscapeHatch — operator-driven external etcd, staged write, or
  // read-only window that lets the etcd roll step proceed.
  action EnableEscapeHatch: bool = all {
    upgradePhase == UpgradeInProgress,
    upgradeStep == EtcdRoll,
    escapeHatch' = true,
    mgmtMachines' = mgmtMachines,
    kcpHost' = kcpHost,
    kcpStatus' = kcpStatus,
    machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradePhase' = upgradePhase,
    upgradeStep' = upgradeStep,
    etcdWriteRequired' = etcdWriteRequired,
  }

  // ResumeEtcdRollWithEscapeHatch — once an escape hatch exists, the
  // problematic etcd write can be satisfied and the upgrade proceeds.
  action ResumeEtcdRollWithEscapeHatch: bool = all {
    upgradePhase == UpgradeInProgress,
    upgradeStep == EtcdRoll,
    etcdWriteRequired,
    escapeHatch,
    upgradeStep' = ApiserverRoll,
    etcdWriteRequired' = false,
    mgmtMachines' = mgmtMachines,
    kcpHost' = kcpHost,
    kcpStatus' = kcpStatus,
    machinePaused' = machinePaused,
    machineTemplate' = machineTemplate,
    desiredMgmtTemplate' = desiredMgmtTemplate,
    wlIsMgmt' = wlIsMgmt,
    upgradePhase' = upgradePhase,
    escapeHatch' = escapeHatch,
  }

  // -------------------------------------------------------------
  // Step relations
  // -------------------------------------------------------------

  action step = any {
    nondet t = Set(1, 2).oneOf(); OperatorBumpTemplate(t),
    KcpStartUpgrade,
    nondet m = MGMT_MACHINES.oneOf(); KcpUpgradeMachine(m),
    KcpUpgradeOwnHost,
    KcpReconcileResume,
    EnterEtcdRoll,
    EtcdRollRequiresEtcdWrite,
    EnableEscapeHatch,
    ResumeEtcdRollWithEscapeHatch,
  }

  // stepNoRecovery — KCP cannot fail over (no operator
  // intervention). Used to prove deadlock unreachability of recovery.
  action stepNoRecovery = any {
    nondet t = Set(1, 2).oneOf(); OperatorBumpTemplate(t),
    KcpStartUpgrade,
    nondet m = MGMT_MACHINES.oneOf(); KcpUpgradeMachine(m),
    KcpUpgradeOwnHost,
    EnterEtcdRoll,
    EtcdRollRequiresEtcdWrite,
  }

  // -------------------------------------------------------------
  // Predicates
  // -------------------------------------------------------------

  // The cluster has reached an upgrade-complete state.
  val UpgradeCompleteAndHealthy =
    upgradePhase == UpgradeComplete and
    mgmtMachines.forall(m =>
      machineTemplate.get(m) == desiredMgmtTemplate) and
    not(mgmtMachines.exists(m => machinePaused.get(m))) and
    kcpStatus == Running

  // The cluster has deadlocked: KCP host is paused, KCP can't
  // reconcile, and at least one Machine is still on the old template.
  val Deadlocked =
    upgradePhase == UpgradeDeadlock and
    (
      (kcpStatus == Paused and
        mgmtMachines.exists(m => machineTemplate.get(m) != desiredMgmtTemplate)) or
      (upgradeStep == EtcdRoll and etcdWriteRequired and wlIsMgmt and not(escapeHatch))
    )

  val EscapeHatchExists =
    upgradeStep != EtcdRoll or not(etcdWriteRequired) or escapeHatch

  val AllInvariants = all {
    // Self-hosted invariant: management = workload.
    wlIsMgmt,
    // KCP host is always in the management Machine set.
    mgmtMachines.contains(kcpHost),
  }

  // -------------------------------------------------------------
  // Example runs
  // -------------------------------------------------------------

  // FM-35's deadlock trace: from steady state, operator bumps
  // template, KCP starts the upgrade, upgrades others, then
  // upgrades own host — deadlock.
  run selfHostedDeadlockTrace = selfHostedSteadyInit
    .then(OperatorBumpTemplate(2))
    .then(KcpUpgradeMachine(2))
    .then(KcpUpgradeMachine(3))
    .then(KcpUpgradeOwnHost)
    // At this point: kcpStatus=Paused, upgradePhase=UpgradeDeadlock.

  // Operator workaround: after deadlock, manually fail over KCP
  // to a healthy node, then complete the upgrade.
  run selfHostedRecoveryTrace = selfHostedDeadlockInit
    .then(KcpReconcileResume)
    // KCP is now on a non-paused Machine, can resume reconciling.

  // issue-96 trap: upgrade reaches the EtcdRoll step, which still needs
  // a write to the hosted etcd, but no escape hatch exists.
  run selfHostedEtcdTrapTrace = selfHostedUpgradeMidFlightInit
    .then(EnterEtcdRoll)
    .then(EtcdRollRequiresEtcdWrite)

  // issue-96 escape hatch: operator enables an out-of-band write path,
  // then the etcd roll step can resume into the next upgrade phase.
  run selfHostedEtcdEscapeTrace = selfHostedUpgradeMidFlightInit
    .then(EnterEtcdRoll)
    .then(EnableEscapeHatch)
    .then(ResumeEtcdRollWithEscapeHatch)

}
