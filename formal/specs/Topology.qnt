// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Topology.qnt — ClusterTopology reconciler + Runtime SDK lifecycle
// hooks. Refines `internal/controllers/topology/cluster/` and
// `exp/topology/desiredstate/` against the upstream Kubernetes
// Cluster API ClusterClass / managed-topology code path.
//
// This module is independent of Lifecycle.qnt — Lifecycle models
// the KubeadmControlPlane membership lifecycle, while Topology
// models the *outer* loop: the topology controller decides when KCP
// (and the MachineDeployments) are allowed to pick up the next
// version, and the runtime-extension lifecycle hooks gate every
// transition. The two models compose at the abstract barrier of
// "CP picked up a new version" / "CP finished an upgrade step"
// — hooks fire here, KCP rolls Machines there.
//
// LSP grounding (gopls go_search + grep on the formality working
// tree). All anchors below reference Cluster API at HEAD of branch
// `formality`. See abstraction-mapping.md §Topology.qnt.
//
//   internal/controllers/topology/cluster/cluster_controller.go
//     :263  Reconciler.Reconcile (entry)
//     :328  Reconciler.reconcile (normal loop)
//     :441  Reconciler.callBeforeClusterCreateHook
//     :550  Reconciler.reconcileDelete (BeforeClusterDelete)
//
//   internal/controllers/topology/cluster/reconcile_state.go
//     :180  Reconciler.callAfterHooks
//     :188  Reconciler.callAfterControlPlaneInitialized
//     :229  Reconciler.callAfterClusterUpgrade
//
//   exp/topology/desiredstate/desired_state.go
//     :103  generator.Generate (orchestrator)
//     :535  generator.computeControlPlaneVersion
//     :1089 generator.computeMachineDeploymentVersion
//
//   exp/topology/desiredstate/lifecycle_hooks.go
//     :39   generator.callBeforeClusterUpgradeHook
//     :128  generator.callBeforeControlPlaneUpgradeHook
//     :184  generator.callAfterControlPlaneUpgradeHook
//     :248  generator.callBeforeWorkersUpgradeHook
//     :314  generator.callAfterWorkersUpgradeHook
//
//   exp/topology/desiredstate/upgrade_plan.go
//     :48   ComputeUpgradePlan
//     :334  GetUpgradePlanOneMinor
//     :360  GetUpgradePlanFromClusterClassVersions
//     :449  GetUpgradePlanFromExtension
//
//   internal/hooks/tracking.go
//     :36   MarkAsPending
//     :86   IsPending
//     :98   MarkAsDone
//
//   exp/topology/scope/upgradetracker.go
//     :188  ControlPlaneUpgradeTracker.IsControlPlaneStable
//     :215  ControlPlaneUpgradeTracker.IsControlPlaneStableOrWaitingForWorkersUpgrade
//     :256  WorkerUpgradeTracker.IsAnyUpgrading
//     :261  WorkerUpgradeTracker.UpgradeConcurrencyReached
//
//   api/runtime/v1beta2/extensionconfig_types.go
//     :317  PendingHooksAnnotation
//     :321  OkToDeleteAnnotation
//
//   api/core/v1beta2/common_types.go
//     :219  BeforeClusterUpgradeHookAnnotationPrefix
module Topology {

  // ===============================================================
  // Type space
  // ===============================================================

  // Kubernetes versions encoded as small integers (minor only —
  // the contract we care about is monotonic-version transitions
  // and skew). e.g. 36 ↔ "v1.36.x".
  type Version = int

  // Lifecycle hook identifiers. Order in this enum matches the
  // call-order discipline encoded in
  // `desired_state.go:535-727` and `reconcile_state.go:180-295`.
  type Hook =
    | BeforeClusterCreate
    | AfterControlPlaneInitialized
    | BeforeClusterUpgrade
    | BeforeControlPlaneUpgrade
    | AfterControlPlaneUpgrade
    | BeforeWorkersUpgrade
    | AfterWorkersUpgrade
    | AfterClusterUpgrade
    | BeforeClusterDelete

  // Hook response shape. Matches `runtimehooksv1.CommonRetryResponse`.
  // - HookOk: extension responded with RetryAfterSeconds == 0.
  // - HookBlock: extension responded with RetryAfterSeconds > 0
  //   (operator wants to keep the hold).
  // - HookNotConfigured: no extension is registered for this hook
  //   (`len(extensionHandlers) == 0` short-circuit).
  // - HookAnnotationBlocked: an operator-set
  //   before-upgrade.hook.cluster.cluster.x-k8s.io/* annotation is
  //   blocking BeforeClusterUpgrade.
  type HookOutcome =
    | HookOk
    | HookBlock
    | HookNotConfigured
    | HookAnnotationBlocked

  // Cluster-level lifecycle state. The topology controller drives
  // the transitions; KCP and MD controllers observe.
  type ClusterPhase =
    | NotCreated
    | Creating       // BeforeClusterCreate has been requested but
                     // hasn't unblocked yet (topology generates no
                     // CP or InfraCluster reference until it does).
    | Provisioning   // CP and InfraCluster created; CP is being
                     // provisioned. AfterControlPlaneInitialized
                     // pending.
    | Stable         // No upgrade in flight; reconcile is a no-op
                     // beyond ClusterClass/template patch sync.
    | Upgrading      // BeforeClusterUpgrade unblocked;
                     // AfterClusterUpgrade pending. We're walking
                     // the upgrade plan one step at a time.
    | Deleting       // DeletionTimestamp is set; the topology
                     // controller is in the BeforeClusterDelete
                     // gate.
    | Deleted

  // Per-step phase within an upgrade. Refines the implicit state
  // machine in `computeControlPlaneVersion`
  // (`desired_state.go:535`):
  //
  //   StepPickCP      — we just picked the next CP version
  //                     (BeforeCPUpgrade fired). KCP is rolling.
  //   StepCPUpgrading — `ControlPlane.IsUpgrading()` is true.
  //   StepCPDone      — KCP finished; AfterCPUpgrade pending.
  //   StepWorkers     — workers are picking up the version
  //                     (BeforeWorkersUpgrade fired).
  //   StepWorkersDone — workers finished; AfterWorkersUpgrade
  //                     pending. The next step (or finish) gates
  //                     here.
  //   StepIdle        — we're between upgrade steps (no version
  //                     selection happening).
  type UpgradeStepPhase =
    | StepIdle
    | StepPickCP
    | StepCPUpgrading
    | StepCPDone
    | StepWorkers
    | StepWorkersDone

  // The per-MachineDeployment state visible to
  // `computeMachineDeploymentVersion` at
  // `desired_state.go:1089`.
  type MdPhase =
    | MdAtVersion
    | MdPendingUpgrade   // s.UpgradeTracker.MachineDeployments
                         //   .MarkPendingUpgrade(name)
    | MdUpgrading        // s.UpgradeTracker.MachineDeployments
                         //   .MarkUpgrading(name)
    | MdDeferred         // marked via ClusterTopologyDefer/Hold
                         // annotation in
                         // `desired_state.go:1178`

  // ===============================================================
  // Bounds
  // ===============================================================

  pure val MD_NAMES: Set[str] = Set("md-a", "md-b")
  pure val MAX_UPGRADE_CONCURRENCY: int = 1

  // MAX_VERSION bounds the operator-bump range. Used to give the
  // upgrade-plan filter a CONSTANT-bound set so Apalache can
  // process it (Apalache does not support dynamic integer
  // ranges like `(cpVersion + 1).to(topologyVersion)` — see
  // <https://apalache-mc.org/docs/apalache/known-issues.html>).
  pure val MAX_VERSION: int = 40
  pure val ALL_VERSIONS: Set[int] = 1.to(MAX_VERSION)

  // Upgrade concurrency limit refines
  // `WorkerUpgradeTracker.UpgradeConcurrencyReached` at
  // `exp/topology/scope/upgradetracker.go:261`. Default in CAPI
  // is 1 unless overridden by the ClusterClass.

  // ===============================================================
  // State variables
  // ===============================================================

  // Cluster-level.
  var clusterPhase: ClusterPhase
  var topologyVersion: Version       // operator-desired version
                                     // (Cluster.spec.topology.version)
  var cpVersion: Version              // control-plane current version
  var stepPhase: UpgradeStepPhase

  // Upgrade plan. Refines
  // `s.UpgradeTracker.ControlPlane.UpgradePlan` populated by
  // `ComputeUpgradePlan` at `upgrade_plan.go:48`. Plan is
  // monotonically consumed from index 0.
  var cpUpgradePlan: List[Version]
  var workerUpgradePlan: List[Version]

  // Per-MachineDeployment version + phase. Refines
  // `s.Current.MachineDeployments[name].Object.Spec.Template.Spec.Version`
  // and the MarkPendingUpgrade / MarkUpgrading bookkeeping in
  // `desired_state.go:1089`.
  var mdVersion: str -> Version
  var mdPhase: str -> MdPhase

  // Pending-hook tracking. Refines the
  // `runtime.cluster.x-k8s.io/pending-hooks` annotation managed by
  // `internal/hooks/tracking.go:36-128`. A hook is in the set iff
  // `IsPending(hook, cluster) == true`.
  var pendingHooks: Set[Hook]

  // Per-hook last-observed response. The HookResponseTracker is
  // per-reconcile in Go; the model collapses it to a stored
  // outcome per hook, advanced by the EvaluateHook action.
  var lastHookOutcome: Hook -> HookOutcome

  // Operator-supplied blocking annotation. Refines the
  // `BeforeClusterUpgradeHookAnnotationPrefix` annotation set
  // (`api/core/v1beta2/common_types.go:219` and
  // `lifecycle_hooks.go:44-72`). When non-empty, BeforeClusterUpgrade
  // returns HookAnnotationBlocked even if the extension would otherwise
  // unblock.
  var beforeUpgradeAnnotations: Set[str]

  // Whether each hook has at least one registered extension.
  // Refines `r.RuntimeClient.GetAllExtensions(ctx, hook, cluster)`
  // returning `len(...) == 0`. When the set lacks a hook, it
  // short-circuits to HookNotConfigured.
  var registeredHooks: Set[Hook]

  // Operator deletion-intent bit. Refines the cluster's
  // DeletionTimestamp being set.
  var deletionRequested: bool
  // Refines the `runtime.cluster.x-k8s.io/ok-to-delete` annotation
  // managed by `MarkAsOkToDelete` at
  // `internal/hooks/tracking.go:142`.
  var okToDelete: bool

  // ===============================================================
  // Pure helpers refining UpgradeTracker getters
  // ===============================================================

  // controlPlaneIsStable refines
  // `ControlPlaneUpgradeTracker.IsControlPlaneStable` at
  // `exp/topology/scope/upgradetracker.go:188`. Stable means: not
  // provisioning, not upgrading, not starting an upgrade, not
  // pending an upgrade.
  pure def controlPlaneIsStable(
      phase: ClusterPhase, sp: UpgradeStepPhase, cp: Version,
      desired: Version): bool =
    phase == Stable and sp == StepIdle and cp == desired

  // anyMdUpgrading refines `WorkerUpgradeTracker.IsAnyUpgrading`
  // at `upgradetracker.go:256`.
  pure def anyMdUpgrading(phase: str -> MdPhase): bool =
    MD_NAMES.exists(n => phase.get(n) == MdUpgrading)

  // anyMdPendingUpgrade refines
  // `WorkerUpgradeTracker.IsAnyPendingUpgrade`.
  pure def anyMdPendingUpgrade(phase: str -> MdPhase): bool =
    MD_NAMES.exists(n => phase.get(n) == MdPendingUpgrade)

  // anyMdDeferred refines `IsAnyUpgradeDeferred`.
  pure def anyMdDeferred(phase: str -> MdPhase): bool =
    MD_NAMES.exists(n => phase.get(n) == MdDeferred)

  // upgradeConcurrencyReached refines
  // `WorkerUpgradeTracker.UpgradeConcurrencyReached` at
  // `upgradetracker.go:261`.
  pure def upgradeConcurrencyReached(phase: str -> MdPhase): bool =
    MD_NAMES.filter(n => phase.get(n) == MdUpgrading).size()
      >= MAX_UPGRADE_CONCURRENCY

  // ===============================================================
  // Hook outcome predicate
  // ===============================================================

  // hookFires(h, ann, registered) decides what the topology
  // controller observes for a given hook call.
  //
  // Refines the head of every callXxxHook function in
  // `lifecycle_hooks.go` and the cluster-controller hook callers:
  // each first calls `GetAllExtensions(...)` (returns empty ⇒
  // HookNotConfigured) and then handles the response.
  //
  // For BeforeClusterUpgrade we also check the operator's
  // before-upgrade.hook.cluster.cluster.x-k8s.io/* annotation set,
  // refining `lifecycle_hooks.go:44-72`.
  pure def hookFires(
      h: Hook, ann: Set[str], registered: Set[Hook]): bool =
    if (not(registered.contains(h))) false
    else if (h == BeforeClusterUpgrade and ann.size() > 0) false
    else true

  // ===============================================================
  // Initial states
  // ===============================================================

  // init — operator has just submitted a Cluster with topology
  // version 36, ClusterClass exists; nothing has been reconciled yet.
  action init = all {
    clusterPhase'           = NotCreated,
    topologyVersion'        = 36,
    cpVersion'              = 0,                         // sentinel: no CP
    stepPhase'              = StepIdle,
    cpUpgradePlan'          = [],
    workerUpgradePlan'      = [],
    mdVersion'              = MD_NAMES.mapBy(_ => 0),
    mdPhase'                = MD_NAMES.mapBy(_ => MdAtVersion),
    pendingHooks'           = Set(),
    lastHookOutcome'        = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                                  BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                                  AfterControlPlaneUpgrade, BeforeWorkersUpgrade,
                                  AfterWorkersUpgrade, AfterClusterUpgrade,
                                  BeforeClusterDelete).mapBy(_ => HookOk),
    beforeUpgradeAnnotations' = Set(),
    registeredHooks'        = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                                  BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                                  AfterControlPlaneUpgrade, BeforeWorkersUpgrade,
                                  AfterWorkersUpgrade, AfterClusterUpgrade,
                                  BeforeClusterDelete),
    deletionRequested'      = false,
    okToDelete'             = false,
  }

  // ===============================================================
  // Hook actions
  // ===============================================================

  // EvaluateHook fires the call to a registered runtime extension
  // for hook `h` and records the outcome. This is the abstract step
  // every callXxxHook function performs at
  // `RuntimeClient.CallAllExtensions(...)`. The outcome is
  // non-deterministically chosen between HookOk and HookBlock when
  // an extension is registered (modelling the operator's reply);
  // HookNotConfigured / HookAnnotationBlocked are deterministic.
  action EvaluateHook(h: Hook, outcome: HookOutcome): bool = all {
    // Force consistency between outcome and configuration.
    val canFire = hookFires(h, beforeUpgradeAnnotations, registeredHooks)
    any {
      all {
        canFire,
        any { outcome == HookOk, outcome == HookBlock },
      },
      all {
        not(canFire),
        registeredHooks.contains(h),
        h == BeforeClusterUpgrade,
        outcome == HookAnnotationBlocked,
      },
      all {
        not(registeredHooks.contains(h)),
        outcome == HookNotConfigured,
      },
    },
    lastHookOutcome' = lastHookOutcome.put(h, outcome),
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // Cluster creation actions
  // ===============================================================

  // ReconcileBeforeClusterCreate refines
  // `Reconciler.callBeforeClusterCreateHook` at
  // `cluster_controller.go:441`. The hook is called only while
  // the cluster has neither InfraCluster nor ControlPlane references
  // (line 446). When unblocked, the topology controller proceeds
  // to compute desired state in `reconcile` and creates them.
  action ReconcileBeforeClusterCreate: bool = all {
    clusterPhase == NotCreated,
    val outcome = lastHookOutcome.get(BeforeClusterCreate)
    any {
      // Hook ok or not configured — proceed; mark
      // AfterControlPlaneInitialized intent on first creation
      // (refines `reconcile_state.go:191`).
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        clusterPhase'  = Provisioning,
        pendingHooks'  = pendingHooks.union(Set(AfterControlPlaneInitialized)),
      },
      // Hook blocking — stay NotCreated (requeueAfter), leave
      // pending-hooks unchanged.
      all {
        outcome == HookBlock,
        clusterPhase' = NotCreated,
        pendingHooks' = pendingHooks,
      },
    },
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ControlPlaneProvisioned models KCP completing initial provision
  // (`Initialized` condition flips true). Refines the implicit
  // transition observed at `reconcile_state.go:218` (`isControlPlaneInitialized`).
  // Sets cpVersion and triggers the next reconcile cycle's
  // AfterControlPlaneInitialized hook.
  action ControlPlaneProvisioned: bool = all {
    clusterPhase == Provisioning,
    cpVersion == 0,
    cpVersion'    = topologyVersion,
    mdVersion'    = MD_NAMES.mapBy(_ => topologyVersion),
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // FireAfterControlPlaneInitialized refines
  // `Reconciler.callAfterControlPlaneInitialized` at
  // `reconcile_state.go:188`. Fires once when CP is initialised
  // and the AfterControlPlaneInitialized hook is pending; clears
  // the pending bit on success.
  action FireAfterControlPlaneInitialized: bool = all {
    clusterPhase == Provisioning,
    cpVersion > 0,
    pendingHooks.contains(AfterControlPlaneInitialized),
    val outcome = lastHookOutcome.get(AfterControlPlaneInitialized)
    any {
      // Hook ok / not configured — mark done, transition to Stable.
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks' = pendingHooks.exclude(Set(AfterControlPlaneInitialized)),
        clusterPhase' = Stable,
      },
      // Hook blocking — stay Provisioning.
      all {
        outcome == HookBlock,
        pendingHooks' = pendingHooks,
        clusterPhase' = clusterPhase,
      },
    },
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // Operator-driven actions
  // ===============================================================

  // OperatorBumpTopologyVersion refines an operator editing
  // `Cluster.spec.topology.version`. The next reconcile observes
  // a mismatch and computes an upgrade plan
  // (`upgrade_plan.go:48`).
  action OperatorBumpTopologyVersion(v: Version): bool = all {
    v > topologyVersion,
    clusterPhase == Stable,
    topologyVersion'     = v,
    // Frame:
    clusterPhase'        = clusterPhase,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // OperatorAddBeforeUpgradeAnnotation refines an operator setting
  // an annotation key with prefix
  // `before-upgrade.hook.cluster.cluster.x-k8s.io/`.
  // (`api/core/v1beta2/common_types.go:219`).
  action OperatorAddBeforeUpgradeAnnotation(key: str): bool = all {
    not(beforeUpgradeAnnotations.contains(key)),
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations.union(Set(key)),
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // OperatorRemoveBeforeUpgradeAnnotation — operator clears their
  // hold.
  action OperatorRemoveBeforeUpgradeAnnotation(key: str): bool = all {
    beforeUpgradeAnnotations.contains(key),
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations.exclude(Set(key)),
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // Upgrade-plan computation
  // ===============================================================

  // ComputeUpgradePlanOneMinor refines `GetUpgradePlanOneMinor`
  // at `upgrade_plan.go:334`. With our int-encoded versions, the
  // plan is just `[cpVersion+1, ..., topologyVersion]`.
  action ComputeUpgradePlanOneMinor: bool = all {
    clusterPhase == Stable,
    cpVersion > 0,
    cpVersion < topologyVersion,
    cpUpgradePlan.length() == 0,
    // Build the plan from cpVersion+1 to topologyVersion inclusive.
    // Note: filter over a constant-bounded set rather than using
    // a dynamic range (cpVersion + 1).to(topologyVersion), so
    // Apalache can process it. See MAX_VERSION docstring.
    cpUpgradePlan'      = ALL_VERSIONS.filter(v => v > cpVersion and v <= topologyVersion).fold([], (acc, v) => acc.append(v)),
    workerUpgradePlan'  = ALL_VERSIONS.filter(v => v > cpVersion and v <= topologyVersion).fold([], (acc, v) => acc.append(v)),
    clusterPhase'       = Upgrading,
    pendingHooks'       = pendingHooks,
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = StepIdle,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // BeforeClusterUpgrade — gate the start of an upgrade sequence
  // ===============================================================

  // ReconcileBeforeClusterUpgrade refines
  // `generator.callBeforeClusterUpgradeHook` at
  // `lifecycle_hooks.go:39` invoked from
  // `computeControlPlaneVersion:665`. Called only at the START of
  // a sequence — checked via `!IsPending(AfterClusterUpgrade)`.
  // On unblock, marks AfterClusterUpgrade pending
  // (`computeControlPlaneVersion:676`).
  action ReconcileBeforeClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    not(pendingHooks.contains(AfterClusterUpgrade)),
    cpUpgradePlan.length() > 0,
    val outcome = lastHookOutcome.get(BeforeClusterUpgrade)
    any {
      // Hook ok / not configured — mark AfterClusterUpgrade
      // pending and advance to first CP step.
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks'  = pendingHooks.union(Set(AfterClusterUpgrade)),
        stepPhase'     = StepPickCP,
      },
      // Hook blocking (HookBlock or HookAnnotationBlocked) —
      // stay idle, leave AfterClusterUpgrade unset so we re-fire
      // BeforeClusterUpgrade on next reconcile.
      all {
        any { outcome == HookBlock, outcome == HookAnnotationBlocked },
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepIdle,
      },
    },
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // BeforeControlPlaneUpgrade + CP step
  // ===============================================================

  // ReconcileBeforeControlPlaneUpgrade refines
  // `generator.callBeforeControlPlaneUpgradeHook` at
  // `lifecycle_hooks.go:128`. Fires before each CP version pickup.
  // On unblock, marks AfterControlPlaneUpgrade pending
  // (`computeControlPlaneVersion:706`) and additionally
  // BeforeWorkersUpgrade + AfterWorkersUpgrade if workers are
  // pending an upgrade to the SAME next-version
  // (`computeControlPlaneVersion:710`).
  action ReconcileBeforeControlPlaneUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepPickCP,
    cpUpgradePlan.length() > 0,
    val outcome = lastHookOutcome.get(BeforeControlPlaneUpgrade)
    val nextV = cpUpgradePlan.head()
    val workersAtThisStep = MD_NAMES.exists(n => mdVersion.get(n) < nextV)
    any {
      // Hook ok / not configured — pick up next version.
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        cpVersion'    = nextV,
        stepPhase'    = StepCPUpgrading,
        // Mark intent for AfterCPUpgrade always, plus
        // BeforeWorkersUpgrade/AfterWorkersUpgrade if workers
        // share this step.
        pendingHooks' = if (workersAtThisStep)
          pendingHooks.union(Set(AfterControlPlaneUpgrade,
                                 BeforeWorkersUpgrade,
                                 AfterWorkersUpgrade))
        else pendingHooks.union(Set(AfterControlPlaneUpgrade)),
      },
      // Hook blocking — stay at StepPickCP, do not pick up.
      all {
        outcome == HookBlock,
        cpVersion'    = cpVersion,
        stepPhase'    = StepPickCP,
        pendingHooks' = pendingHooks,
      },
    },
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ControlPlaneStepCompletes models KCP finishing the rolling
  // upgrade for this step (`ControlPlane.IsUpgrading()` flips
  // false). Refines the implicit transition observed at
  // `desired_state.go:574` and the `IsUpgrading=false` branch.
  action ControlPlaneStepCompletes: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCPUpgrading,
    stepPhase'    = StepCPDone,
    // CP version was already advanced when we picked up the
    // version; KCP's rollout completes here.
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // AfterControlPlaneUpgrade
  // ===============================================================

  // ReconcileAfterControlPlaneUpgrade refines
  // `generator.callAfterControlPlaneUpgradeHook` at
  // `lifecycle_hooks.go:184`. Called only when
  // `IsPending(AfterControlPlaneUpgrade) == true`. On unblock,
  // marks done; on block, holds the next version pickup.
  action ReconcileAfterControlPlaneUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepCPDone,
    pendingHooks.contains(AfterControlPlaneUpgrade),
    val outcome = lastHookOutcome.get(AfterControlPlaneUpgrade)
    val workersPending = pendingHooks.contains(BeforeWorkersUpgrade)
    any {
      // Hook ok / not configured — mark done; if workers are
      // pending for this step, advance to StepWorkers; otherwise
      // skip workers and check for AfterClusterUpgrade.
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks'  = pendingHooks.exclude(Set(AfterControlPlaneUpgrade)),
        stepPhase'     = if (workersPending) StepWorkers else StepWorkersDone,
      },
      // Hook blocking — stay StepCPDone.
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        stepPhase'     = StepCPDone,
      },
    },
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // BeforeWorkersUpgrade + worker step
  // ===============================================================

  // ReconcileBeforeWorkersUpgrade refines
  // `generator.callBeforeWorkersUpgradeHook` at
  // `lifecycle_hooks.go:248`. Called only when
  // IsPending(BeforeWorkersUpgrade) is true.
  action ReconcileBeforeWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkers,
    pendingHooks.contains(BeforeWorkersUpgrade),
    val outcome = lastHookOutcome.get(BeforeWorkersUpgrade)
    any {
      // Hook ok / not configured — mark done, mark workers as
      // upgrading.
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks'  = pendingHooks.exclude(Set(BeforeWorkersUpgrade)),
        // Pick the first MD whose version != cpVersion to mark
        // upgrading (refines `desired_state.go:1089`).
        mdPhase'       = MD_NAMES.fold(
                            mdPhase,
                            (acc, n) =>
                              if (mdVersion.get(n) < cpVersion and
                                  acc.get(n) == MdAtVersion)
                                acc.put(n, MdUpgrading)
                              else acc),
      },
      // Hook blocking — stay at StepWorkers.
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        mdPhase'       = mdPhase,
      },
    },
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // MachineDeploymentStepCompletes models a single MD finishing its
  // upgrade for this step. Refines the upgrading-set leaving
  // `IsAnyUpgrading()` (`upgradetracker.go:256`).
  action MachineDeploymentStepCompletes(name: str): bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkers,
    MD_NAMES.contains(name),
    mdPhase.get(name) == MdUpgrading,
    mdVersion'    = mdVersion.put(name, cpVersion),
    mdPhase'      = mdPhase.put(name, MdAtVersion),
    val newAnyUpgrading = MD_NAMES.exists(n =>
        n != name and mdPhase.get(n) == MdUpgrading)
    stepPhase'    = if (newAnyUpgrading) StepWorkers else StepWorkersDone,
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // AfterWorkersUpgrade
  // ===============================================================

  // ReconcileAfterWorkersUpgrade refines
  // `generator.callAfterWorkersUpgradeHook` at
  // `lifecycle_hooks.go:314`. Fires when workers complete the step.
  action ReconcileAfterWorkersUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersDone,
    pendingHooks.contains(AfterWorkersUpgrade),
    val outcome = lastHookOutcome.get(AfterWorkersUpgrade)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks' = pendingHooks.exclude(Set(AfterWorkersUpgrade)),
        // Step done: pop both plans' heads.
        cpUpgradePlan'      = cpUpgradePlan.tail(),
        workerUpgradePlan'  = workerUpgradePlan.tail(),
        stepPhase'          = StepIdle,
      },
      all {
        outcome == HookBlock,
        pendingHooks'       = pendingHooks,
        cpUpgradePlan'      = cpUpgradePlan,
        workerUpgradePlan'  = workerUpgradePlan,
        stepPhase'          = stepPhase,
      },
    },
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // FinishStepNoWorkers — variant for steps where workers are NOT
  // included (CP-only step, e.g. when MD upgrade plan is shorter).
  // Pops the CP head and goes back to StepIdle for the next CP step.
  action FinishStepNoWorkers: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepWorkersDone,
    not(pendingHooks.contains(AfterWorkersUpgrade)),
    cpUpgradePlan'      = cpUpgradePlan.tail(),
    workerUpgradePlan'  = workerUpgradePlan,
    stepPhase'          = StepIdle,
    // Frame:
    clusterPhase'        = clusterPhase,
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // AfterClusterUpgrade — finalises the whole sequence
  // ===============================================================

  // ReconcileAfterClusterUpgrade refines
  // `Reconciler.callAfterClusterUpgrade` at
  // `reconcile_state.go:229`. Fires only when:
  //   - IsPending(AfterClusterUpgrade) == true
  //   - !IsPending(AfterControlPlaneUpgrade)
  //   - !IsPending(AfterWorkersUpgrade)
  //   - control plane stable, no MDs upgrading/pending
  // Refines lines 235-250.
  action ReconcileAfterClusterUpgrade: bool = all {
    clusterPhase == Upgrading,
    stepPhase == StepIdle,
    cpUpgradePlan.length() == 0,
    pendingHooks.contains(AfterClusterUpgrade),
    not(pendingHooks.contains(AfterControlPlaneUpgrade)),
    not(pendingHooks.contains(AfterWorkersUpgrade)),
    not(anyMdUpgrading(mdPhase)),
    not(anyMdPendingUpgrade(mdPhase)),
    cpVersion == topologyVersion,
    val outcome = lastHookOutcome.get(AfterClusterUpgrade)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        pendingHooks'  = pendingHooks.exclude(Set(AfterClusterUpgrade)),
        clusterPhase'  = Stable,
      },
      all {
        outcome == HookBlock,
        pendingHooks'  = pendingHooks,
        clusterPhase'  = clusterPhase,
      },
    },
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // Deletion path
  // ===============================================================

  action OperatorRequestDelete: bool = all {
    not(deletionRequested),
    clusterPhase != Deleted,
    deletionRequested'   = true,
    clusterPhase'        = Deleting,
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    okToDelete'          = okToDelete,
  }

  // ReconcileBeforeClusterDelete refines
  // `Reconciler.reconcileDelete` at `cluster_controller.go:550`.
  // The hook is gated on `!hooks.IsOkToDelete(cluster)` (line 557);
  // on success, the controller stamps the OkToDelete annotation
  // (line 595).
  action ReconcileBeforeClusterDelete: bool = all {
    clusterPhase == Deleting,
    not(okToDelete),
    val outcome = lastHookOutcome.get(BeforeClusterDelete)
    any {
      all {
        any { outcome == HookOk, outcome == HookNotConfigured },
        okToDelete'   = true,
        clusterPhase' = clusterPhase,
      },
      all {
        outcome == HookBlock,
        okToDelete'   = false,
        clusterPhase' = clusterPhase,
      },
    },
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
  }

  action FinaliseDelete: bool = all {
    clusterPhase == Deleting,
    okToDelete,
    clusterPhase'        = Deleted,
    // Frame:
    topologyVersion'     = topologyVersion,
    cpVersion'           = cpVersion,
    stepPhase'           = stepPhase,
    cpUpgradePlan'       = cpUpgradePlan,
    workerUpgradePlan'   = workerUpgradePlan,
    mdVersion'           = mdVersion,
    mdPhase'             = mdPhase,
    pendingHooks'        = pendingHooks,
    lastHookOutcome'     = lastHookOutcome,
    beforeUpgradeAnnotations' = beforeUpgradeAnnotations,
    registeredHooks'     = registeredHooks,
    deletionRequested'   = deletionRequested,
    okToDelete'          = okToDelete,
  }

  // ===============================================================
  // Step relation
  // ===============================================================

  action step = any {
    nondet h = Set(BeforeClusterCreate, AfterControlPlaneInitialized,
                   BeforeClusterUpgrade, BeforeControlPlaneUpgrade,
                   AfterControlPlaneUpgrade, BeforeWorkersUpgrade,
                   AfterWorkersUpgrade, AfterClusterUpgrade,
                   BeforeClusterDelete).oneOf();
      nondet o = Set(HookOk, HookBlock, HookNotConfigured,
                     HookAnnotationBlocked).oneOf();
      EvaluateHook(h, o),

    ReconcileBeforeClusterCreate,
    ControlPlaneProvisioned,
    FireAfterControlPlaneInitialized,

    nondet v = Set(37, 38, 39).oneOf(); OperatorBumpTopologyVersion(v),
    nondet k = Set("hold-a", "hold-b").oneOf();
      OperatorAddBeforeUpgradeAnnotation(k),
    nondet k = Set("hold-a", "hold-b").oneOf();
      OperatorRemoveBeforeUpgradeAnnotation(k),

    ComputeUpgradePlanOneMinor,
    ReconcileBeforeClusterUpgrade,
    ReconcileBeforeControlPlaneUpgrade,
    ControlPlaneStepCompletes,
    ReconcileAfterControlPlaneUpgrade,
    ReconcileBeforeWorkersUpgrade,
    nondet n = MD_NAMES.oneOf(); MachineDeploymentStepCompletes(n),
    ReconcileAfterWorkersUpgrade,
    FinishStepNoWorkers,
    ReconcileAfterClusterUpgrade,

    OperatorRequestDelete,
    ReconcileBeforeClusterDelete,
    FinaliseDelete,
  }

  // ===============================================================
  // Invariants
  // ===============================================================

  // PendingHookConsistency — pending-hooks annotation set must be
  // consistent with the lifecycle phase. Refines the implicit
  // invariant in `MarkAsPending` / `MarkAsDone`
  // (`internal/hooks/tracking.go:36-128`).
  // Note: deletion is allowed mid-upgrade in upstream — the
  // pending-hooks annotation persists on the cluster object as
  // it's torn down. So we guard the live-cluster invariants on
  // `clusterPhase != Deleting and clusterPhase != Deleted`.
  val PendingHookConsistency = all {
    // AfterClusterUpgrade is pending iff we're upgrading. (For
    // a deleting cluster, the annotation may persist as
    // tombstone; see Go semantics above.)
    (pendingHooks.contains(AfterClusterUpgrade)
     and clusterPhase != Deleting and clusterPhase != Deleted)
      implies clusterPhase == Upgrading,
    // BeforeClusterUpgrade and AfterClusterUpgrade are mutually
    // exclusive — the BeforeClusterUpgrade gate uses
    // `!IsPending(AfterClusterUpgrade)` to detect "start of
    // sequence" (`lifecycle_hooks.go:42`). Therefore we must
    // never have both bits flipped.
    not(pendingHooks.contains(BeforeClusterUpgrade)
        and pendingHooks.contains(AfterClusterUpgrade)),
    // AfterControlPlaneUpgrade pending implies a step is in
    // flight (StepCPUpgrading or StepCPDone) while the cluster
    // is live. Refines `lifecycle_hooks.go:189`.
    (pendingHooks.contains(AfterControlPlaneUpgrade)
     and clusterPhase != Deleting and clusterPhase != Deleted)
      implies (stepPhase == StepCPUpgrading
               or stepPhase == StepCPDone),
  }

  // CpVersionWithinPlan — cpVersion must be a value already
  // surfaced by the upgrade plan; we never skip versions.
  val CpVersionWithinPlan = all {
    cpVersion <= topologyVersion,
    // While upgrading, cpVersion has either been incremented past
    // its initial value or matches the next-step head.
    clusterPhase == Upgrading
      implies cpUpgradePlan.length() == 0
              or cpVersion <= cpUpgradePlan.head(),
  }

  // WorkerVersionLeqCp — every MD's version is at most cpVersion.
  // This is the version-skew invariant: workers never lead CP.
  // Refines the implicit safety check in
  // `computeMachineDeploymentVersion` lines 1098-1142 (the gates
  // that prevent MD from picking up topologyVersion ahead of CP).
  val WorkerVersionLeqCp =
    MD_NAMES.forall(n => mdVersion.get(n) <= cpVersion)

  // HookFireOrderInvariant — for each upgrade step, the hook
  // pending-set evolves through:
  //   { } → { AfterCPUpgrade [, BeforeWorkers, AfterWorkers] }
  //       → { AfterWorkers? } → { }
  // Specifically: if BeforeWorkersUpgrade is pending, then
  // AfterControlPlaneUpgrade is also pending OR has already fired
  // for this step (i.e. we never have BeforeWorkersUpgrade
  // pending while AfterControlPlaneUpgrade is also pending AND
  // we're at StepWorkers — the latter implies AfterCP cleared).
  val HookFireOrderInvariant = all {
    // While at StepWorkers, AfterControlPlaneUpgrade must NOT be
    // pending (it's been cleared in
    // ReconcileAfterControlPlaneUpgrade).
    stepPhase == StepWorkers
      implies not(pendingHooks.contains(AfterControlPlaneUpgrade)),
    // While at StepWorkersDone, BeforeWorkersUpgrade must NOT be
    // pending.
    stepPhase == StepWorkersDone
      implies not(pendingHooks.contains(BeforeWorkersUpgrade)),
    // While at StepCPUpgrading or StepCPDone, AfterClusterUpgrade
    // is already pending (BeforeClusterUpgrade unblocked at
    // sequence start).
    (stepPhase == StepCPUpgrading or stepPhase == StepCPDone
     or stepPhase == StepWorkers or stepPhase == StepWorkersDone)
      implies pendingHooks.contains(AfterClusterUpgrade),
  }

  // BeforeClusterUpgradeBlockedByAnnotation — when an operator
  // annotation is set, the BeforeClusterUpgrade gate cannot
  // unblock. Refines the precondition at `lifecycle_hooks.go:49`
  // ("annotation X is set" branch returns false).
  val BeforeClusterUpgradeBlockedByAnnotation =
    (beforeUpgradeAnnotations.size() > 0
     and clusterPhase == Upgrading
     and stepPhase == StepIdle
     and not(pendingHooks.contains(AfterClusterUpgrade)))
    implies (cpUpgradePlan.length() == 0 or cpVersion < cpUpgradePlan.head())

  // OkToDeleteAfterUnblock — once the cluster has progressed past
  // the BeforeClusterDelete hook, OkToDelete must hold. Refines
  // the post-hook stamp at `cluster_controller.go:595`.
  val OkToDeleteAfterUnblock =
    clusterPhase == Deleted implies okToDelete

  // PlanMonotonic — the upgrade plan strictly increases.
  val PlanMonotonic =
    cpUpgradePlan.length() < 2
    or 0.to(cpUpgradePlan.length() - 2).forall(i =>
        cpUpgradePlan[i] < cpUpgradePlan[i + 1])

  val SafetyInvariants = all {
    PendingHookConsistency,
    CpVersionWithinPlan,
    WorkerVersionLeqCp,
    HookFireOrderInvariant,
    BeforeClusterUpgradeBlockedByAnnotation,
    OkToDeleteAfterUnblock,
    PlanMonotonic,
  }

  val AllSafetyInvariants = SafetyInvariants

  // ===============================================================
  // Liveness properties (issue #3 — beyond FM-9)
  // ===============================================================

  val allVars = (clusterPhase, topologyVersion, cpVersion,
    stepPhase, cpUpgradePlan, workerUpgradePlan, mdVersion,
    mdPhase, pendingHooks, lastHookOutcome,
    beforeUpgradeAnnotations, registeredHooks, deletionRequested,
    okToDelete)

  // Forward-progress fairness for the topology hook flow.
  // Strong-fair on every action that, when enabled, must fire to
  // advance the cluster from Upgrading back to Stable. Operator
  // actions (bump version, set/remove annotations, request
  // delete) are NOT in the fair set — they may never fire.
  temporal TopologyForwardProgressFair =
    strongFair(any { nondet h = Set(BeforeClusterCreate,
                                     AfterControlPlaneInitialized,
                                     BeforeClusterUpgrade,
                                     BeforeControlPlaneUpgrade,
                                     AfterControlPlaneUpgrade,
                                     BeforeWorkersUpgrade,
                                     AfterWorkersUpgrade,
                                     AfterClusterUpgrade,
                                     BeforeClusterDelete).oneOf();
                     EvaluateHook(h, HookOk) }, allVars)
    and strongFair(ReconcileBeforeClusterCreate, allVars)
    and strongFair(ControlPlaneProvisioned, allVars)
    and strongFair(FireAfterControlPlaneInitialized, allVars)
    and strongFair(ComputeUpgradePlanOneMinor, allVars)
    and strongFair(ReconcileBeforeClusterUpgrade, allVars)
    and strongFair(ReconcileBeforeControlPlaneUpgrade, allVars)
    and strongFair(ControlPlaneStepCompletes, allVars)
    and strongFair(ReconcileAfterControlPlaneUpgrade, allVars)
    and strongFair(ReconcileBeforeWorkersUpgrade, allVars)
    and strongFair(any { nondet n = MD_NAMES.oneOf();
                          MachineDeploymentStepCompletes(n) }, allVars)
    and strongFair(ReconcileAfterWorkersUpgrade, allVars)
    and strongFair(FinishStepNoWorkers, allVars)
    and strongFair(ReconcileAfterClusterUpgrade, allVars)
    and strongFair(ReconcileBeforeClusterDelete, allVars)
    and strongFair(FinaliseDelete, allVars)

  // L-T1 — eventually `pendingHooks` is empty.
  // Refines the post-condition that all After* hooks are
  // cleared by `MarkAsDone` once the upgrade completes.
  // Holds under TopologyForwardProgressFair (verified TLC
  // depth 8, ~31 s).
  temporal LT1_EventuallyPendingHooksClear =
    TopologyForwardProgressFair
    implies eventually(pendingHooks.size() == 0)

  // L-T2 — under the same fairness scope, an upgrade should
  // eventually return the cluster to Stable. This is intentionally
  // stronger than LT1 and is retained as a likely fairness-gap
  // candidate when HookBlock can recur forever.
  temporal LT2_EventuallyStableAfterUpgrade =
    TopologyForwardProgressFair
    implies eventually(clusterPhase == Stable)

  // KNOWN LIMITATION: stronger eventual-progress properties
  // (e.g. `eventually(clusterPhase == Stable)`,
  // `always(eventually(clusterPhase != NotCreated))`,
  // `always(eventually(stepPhase == StepIdle))`) do NOT hold
  // in this spec because of a TLA+ fairness paradox:
  //
  //   The unfair `EvaluateHook(h, HookBlock)` action can fire
  //   infinitely often, re-flipping `lastHookOutcome[h]` to
  //   HookBlock between every Reconcile firing. Strong-fair
  //   Reconcile actions fire infinitely often (as required)
  //   but each firing is a no-op when the outcome is
  //   HookBlock at that instant. TLC finds a lasso that
  //   stutters in NotCreated forever.
  //
  // Two ways to close the gap:
  // (a) Refactor `EvaluateHook` + `Reconcile*` into single
  //     atomic actions where the outcome is a parameter.
  // (b) Lean 4 deductive proof under a no-operator-fault
  //     assumption (no infinite HookBlock loops).
  // Tracked as a follow-up; LT1 is sufficient for issue #3
  // acceptance ("at least N per spec — finding the limitation
  // is itself a property of the model").

  // ===============================================================
  // FM-39 / FM-40 / FM-41 obligations
  // ===============================================================

  // FM-39: BeforeClusterUpgrade must fire EXACTLY ONCE per
  // upgrade sequence (not per intermediate step).
  // Refines the upstream invariant from `lifecycle_hooks.go:42`:
  //   "the hook should be called only at the beginning of an
  //    upgrade sequence (it should not be called when in the
  //    middle of a multistep upgrade sequence); to detect if we
  //    are at the beginning of an upgrade, the code checks if the
  //    intent to call the AfterClusterUpgrade is not yet tracked."
  //
  // We surface the obligation as: while AfterClusterUpgrade is
  // pending, we never re-mark BeforeClusterUpgrade as pending.
  // (BeforeClusterUpgrade is not stored in pendingHooks at all in
  // upstream — it is *fire-and-forget*, blocked only by the
  // `IsPending(AfterClusterUpgrade)==false` precondition.)
  val FM39_BeforeClusterUpgradeIdempotent =
    pendingHooks.contains(AfterClusterUpgrade)
      implies not(pendingHooks.contains(BeforeClusterUpgrade))

  // FM-40: Hook annotation must keep CP from picking up a new
  // version during an upgrade sequence — i.e. the
  // BeforeClusterUpgrade gate is honoured. Refines the
  // BeforeClusterUpgrade-annotation branch
  // `lifecycle_hooks.go:44-72`. Phrasing: while the annotation
  // is set AND AfterClusterUpgrade has not yet been marked
  // pending (i.e. BeforeClusterUpgrade has not unblocked yet),
  // the step machine must remain at StepIdle — no CP version
  // pickup has occurred. The dual case (annotation added AFTER
  // the gate already unblocked) is allowed by the upstream
  // semantics: the annotation only prevents a NEW sequence
  // from starting.
  val FM40_AnnotationGatesCp =
    (beforeUpgradeAnnotations.size() > 0
     and clusterPhase == Upgrading
     and not(pendingHooks.contains(AfterClusterUpgrade)))
      implies stepPhase == StepIdle

  // FM-41: AfterClusterUpgrade fires only when the cluster has
  // reached "full quiescence" — upstream calls this "fully
  // upgraded" in the doc-comment at
  // `reconcile_state.go:237-241`. We use "quiescence" because
  // the predicate is broader than version-equality; both terms
  // refer to the same precondition cascade. ALL of:
  //  - CP at the upgrade-plan target (cpVersion equals last
  //    consumed plan element)
  //  - no MD upgrading
  //  - no MD pending upgrade
  //  - AfterCP/AfterWorkers cleared
  // Refines the precondition cascade at `reconcile_state.go:235-250`.
  //
  // Phrasing: while the cluster is in a state where
  // ReconcileAfterClusterUpgrade is the next legitimate action
  // (cpUpgradePlan empty, AfterClusterUpgrade still pending), the
  // CP must already be at topologyVersion and workers must be
  // quiescent. This makes the precondition an INVARIANT
  // (preserved by every transition) rather than a transition
  // guard (only checked when the action fires).
  //
  // Note: this is weaker than the upstream condition because the
  // upstream gate also checks IsPendingCreate / IsAnyUpgradeDeferred;
  // we omit those (no model surface for them).
  val FM41_AfterClusterUpgradeAtSteadyState =
    (pendingHooks.contains(AfterClusterUpgrade)
     and cpUpgradePlan.length() == 0
     and clusterPhase == Upgrading
     and stepPhase == StepIdle)
      implies (cpVersion == topologyVersion
               and not(anyMdUpgrading(mdPhase))
               and not(anyMdPendingUpgrade(mdPhase))
               and not(pendingHooks.contains(AfterControlPlaneUpgrade))
               and not(pendingHooks.contains(AfterWorkersUpgrade)))

  // ===============================================================
  // Demonstration runs
  // ===============================================================

  // happyCreateRun — operator creates a Cluster, BeforeClusterCreate
  // unblocks immediately, CP provisions, AfterCPInitialized fires.
  run happyCreateRun = init
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)

  // happyUpgradeRun — operator bumps from 36 to 37; the full hook
  // cascade fires: BeforeClusterUpgrade, BeforeCPUpgrade, CP
  // rolls, AfterCPUpgrade, BeforeWorkers, MDs roll, AfterWorkers,
  // AfterClusterUpgrade.
  run happyUpgradeRun = init
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(OperatorBumpTopologyVersion(37))
    .then(ComputeUpgradePlanOneMinor)
    .then(EvaluateHook(BeforeClusterUpgrade, HookOk))
    .then(ReconcileBeforeClusterUpgrade)
    .then(EvaluateHook(BeforeControlPlaneUpgrade, HookOk))
    .then(ReconcileBeforeControlPlaneUpgrade)
    .then(ControlPlaneStepCompletes)
    .then(EvaluateHook(AfterControlPlaneUpgrade, HookOk))
    .then(ReconcileAfterControlPlaneUpgrade)
    .then(EvaluateHook(BeforeWorkersUpgrade, HookOk))
    .then(ReconcileBeforeWorkersUpgrade)
    .then(MachineDeploymentStepCompletes("md-a"))
    .then(MachineDeploymentStepCompletes("md-b"))
    .then(EvaluateHook(AfterWorkersUpgrade, HookOk))
    .then(ReconcileAfterWorkersUpgrade)
    .then(EvaluateHook(AfterClusterUpgrade, HookOk))
    .then(ReconcileAfterClusterUpgrade)

  // annotationBlockedUpgradeRun — operator sets the
  // before-upgrade annotation; the BeforeClusterUpgrade gate
  // refuses to unblock; cpUpgradePlan stays unconsumed.
  run annotationBlockedUpgradeRun = init
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(OperatorAddBeforeUpgradeAnnotation("hold-a"))
    .then(OperatorBumpTopologyVersion(37))
    .then(ComputeUpgradePlanOneMinor)
    .then(EvaluateHook(BeforeClusterUpgrade, HookAnnotationBlocked))
    .then(ReconcileBeforeClusterUpgrade)

  // multiStepUpgradeRun — operator bumps from 36 → 39 (3 minor
  // steps); the per-step hook cascade fires three times.
  run multiStepUpgradeRun = init
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(OperatorBumpTopologyVersion(39))
    .then(ComputeUpgradePlanOneMinor)
    // Step 1: 36 → 37
    .then(EvaluateHook(BeforeClusterUpgrade, HookOk))
    .then(ReconcileBeforeClusterUpgrade)
    .then(EvaluateHook(BeforeControlPlaneUpgrade, HookOk))
    .then(ReconcileBeforeControlPlaneUpgrade)
    .then(ControlPlaneStepCompletes)
    .then(EvaluateHook(AfterControlPlaneUpgrade, HookOk))
    .then(ReconcileAfterControlPlaneUpgrade)
    .then(EvaluateHook(BeforeWorkersUpgrade, HookOk))
    .then(ReconcileBeforeWorkersUpgrade)
    .then(MachineDeploymentStepCompletes("md-a"))
    .then(MachineDeploymentStepCompletes("md-b"))
    .then(EvaluateHook(AfterWorkersUpgrade, HookOk))
    .then(ReconcileAfterWorkersUpgrade)

  // deleteRun — operator triggers deletion; BeforeClusterDelete
  // unblocks, OkToDelete is stamped, cluster finalises.
  run deleteRun = init
    .then(EvaluateHook(BeforeClusterCreate, HookOk))
    .then(ReconcileBeforeClusterCreate)
    .then(ControlPlaneProvisioned)
    .then(EvaluateHook(AfterControlPlaneInitialized, HookOk))
    .then(FireAfterControlPlaneInitialized)
    .then(OperatorRequestDelete)
    .then(EvaluateHook(BeforeClusterDelete, HookOk))
    .then(ReconcileBeforeClusterDelete)
    .then(FinaliseDelete)

}
