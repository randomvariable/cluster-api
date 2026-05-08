#!/usr/bin/env python3
"""
quint-fairness-gen.py — emit Phase 11b's per-action fairness for
Lifecycle.qnt's ConvergenceFair temporal property.

Strong-fair (must-progress healing/forward-progress):
- Etcd progress: ElectLeader, PromoteLearner, ObserveLearnerProgress,
  RemoveMember, LeaderStepDown, TransferLeadership, MemberHealthChange.
- Kubeadm join chain: BeginJoin, PreflightPass, DownloadCertsSucceeded,
  EnterEtcdHealthCheck, CheckEtcdHealth, KubeletStarted,
  KubeletTLSBootstrap, RegisterLocalNode, EnterEtcdAddLearner,
  EtcdAddLearnerSucceeded, EtcdQuorumReady, MarkAsControlPlane,
  UploadKubeadmConfig, MarkReady.
- KCP reconcile: AddMachine, ResolveNodeRef, MachineHealthChange,
  RequestRemediation, EvaluateCanSafelyRemediate, CompleteRemediation,
  ScaleUpControlPlane, ScaleDownControlPlane.
- Recovery: HealLb, HealEtcdReachability, RestoreNodeReachability,
  RestoreClusterFromSnapshot, RemoveStuckLearner, DeleteFailedMachine.
- Drain / apiserver / CRI / hooks recovery: DrainTimeout,
  ApiserverEtcdConnect, ApiserverReadinessOk, ContainerdReady,
  PullStaticPodImages, CreatePodSandbox, StartStaticPodContainers,
  TriggerPreUpgradeHook, MhcCacheRefresh, WebhookHeal,
  EtcdCompactionDone, ObservationRefresh.

Weak-fair (best-effort; faults can be 0 or many):
- AdvanceTerm, LearnerStuck, JoinFailedAt.
- Partition, LbBroken, LoseEtcdMember, NodeNeverJoins.
- InvalidKubeletConfig, EtcdJoinTimeout.
- ContainerdCrash, ImagePullFailed.
- WebhookRotationFault, MhcCacheStale, EtcdCompactionStart.
- ApiserverEtcdDisconnect, BeginDrain, CustomConditionObserved.
- ChangeDesiredReplicas, InitiateUpgrade (operator).

NOT FAIR (removed from step or excluded):
- AddLearner (removed from step in Phase 11b).
"""

# Action signature catalogue: (name, params).
# params: list of (name, set-or-int) — used to wrap in `nondet` / parameter set.

STRONG = [
    # name                            param spec
    ("ElectLeader",                   [("c", "MACHINES")]),
    ("PromoteLearner",                [("id", "MACHINES")]),
    ("ObserveLearnerProgress",        [("id", "MACHINES"),
                                        ("p", "Set(Eligible, LaggingFar, Stuck)")]),
    ("RemoveMember",                  [("id", "MACHINES")]),
    ("LeaderStepDown",                [("id", "MACHINES")]),
    ("TransferLeadership",            [("src", "MACHINES"),
                                        ("dst", "MACHINES")]),
    ("MemberHealthChange",            [("id", "MACHINES"),
                                        ("h", "Set(Healthy, Unhealthy, UnknownHealth)")]),
    ("BeginJoin",                     [("m", "MACHINES")]),
    ("PreflightPass",                 [("m", "MACHINES")]),
    ("DownloadCertsSucceeded",        [("m", "MACHINES")]),
    ("EnterEtcdHealthCheck",          [("m", "MACHINES")]),
    ("CheckEtcdHealth",               [("m", "MACHINES")]),
    ("KubeletStarted",                [("m", "MACHINES")]),
    ("KubeletTLSBootstrap",           [("m", "MACHINES")]),
    ("RegisterLocalNode",             [("m", "MACHINES")]),
    ("EnterEtcdAddLearner",           [("m", "MACHINES")]),
    ("EtcdAddLearnerSucceeded",       [("m", "MACHINES")]),
    ("EtcdQuorumReady",               [("m", "MACHINES")]),
    ("MarkAsControlPlane",            [("m", "MACHINES")]),
    ("UploadKubeadmConfig",           [("m", "MACHINES")]),
    ("MarkReady",                     [("m", "MACHINES")]),
    ("AddMachine",                    [("m", "MACHINES")]),
    ("ResolveNodeRef",                [("m", "MACHINES")]),
    ("MachineHealthChange",           [("m", "MACHINES"),
                                        ("h", "Set(HealthyMachine, UnhealthyMachine, UnknownHealthMachine)")]),
    ("RequestRemediation",            [("m", "MACHINES")]),
    ("EvaluateCanSafelyRemediate",    [("m", "MACHINES")]),
    ("CompleteRemediation",           [("m", "MACHINES")]),
    ("ScaleUpControlPlane",           [("m", "MACHINES")]),
    ("ScaleDownControlPlane",         [("m", "MACHINES")]),
    ("HealLb",                        []),
    ("HealEtcdReachability",          [("m", "MACHINES")]),
    ("RestoreNodeReachability",       [("m", "MACHINES")]),
    ("RestoreClusterFromSnapshot",    [("m", "MACHINES")]),
    ("RemoveStuckLearner",            [("m", "MACHINES")]),
    ("DeleteFailedMachine",           [("m", "MACHINES")]),
    ("DrainTimeout",                  [("m", "MACHINES")]),
    ("ApiserverEtcdConnect",          [("m", "MACHINES")]),
    ("ApiserverReadinessOk",          [("m", "MACHINES")]),
    ("ContainerdReady",               [("m", "MACHINES")]),
    ("PullStaticPodImages",           [("m", "MACHINES")]),
    ("CreatePodSandbox",              [("m", "MACHINES")]),
    ("StartStaticPodContainers",      [("m", "MACHINES")]),
    ("TriggerPreUpgradeHook",         []),
    ("MhcCacheRefresh",               []),
    ("WebhookHeal",                   []),
    ("EtcdCompactionDone",            []),
    ("ObservationRefresh",            [("m", "MACHINES")]),
]

WEAK = [
    ("AdvanceTerm",                   []),
    ("LearnerStuck",                  [("id", "MACHINES")]),
    ("JoinFailedAt",                  [("m", "MACHINES"),
                                        ("r", "Set(LearnerStuckOnPromote, KubeletNotReady, "
                                              "PreflightCheckFailed, EtcdJoinAddLearnerFailed, "
                                              "DownloadCertsFailed, StaticPodManifestWriteFailed, "
                                              "EtcdHealthCheckFailed, TLSBootstrapTimeout, "
                                              "LocalNodeRegistrationFailed, "
                                              "KubeadmMarkControlPlaneFailed, "
                                              "KubeadmUploadConfigFailed, OtherJoinFailure)")]),
    ("Partition",                     [("m", "MACHINES")]),
    ("LbBroken",                      []),
    ("LoseEtcdMember",                [("m", "MACHINES")]),
    ("NodeNeverJoins",                [("m", "MACHINES")]),
    ("InvalidKubeletConfig",          [("m", "MACHINES")]),
    ("EtcdJoinTimeout",               [("m", "MACHINES")]),
    ("ContainerdCrash",               [("m", "MACHINES")]),
    ("ImagePullFailed",               [("m", "MACHINES")]),
    ("WebhookRotationFault",          []),
    ("MhcCacheStale",                 []),
    ("EtcdCompactionStart",           []),
    ("ApiserverEtcdDisconnect",       [("m", "MACHINES")]),
    ("BeginDrain",                    [("m", "MACHINES")]),
    ("CustomConditionObserved",       [("m", "MACHINES"),
                                        ("k", 'Set("DiskPressure", "MemoryPressure", "NPDFault")')]),
    ("ChangeDesiredReplicas",         [("n", "Set(1, 3, 5)")]),
    ("InitiateUpgrade",               [("t", "1.to(MAX_TEMPLATE_VERSION)")]),
]


def emit_action_expr(name: str, params: list) -> str:
    """Build a Quint action expression with `nondet`-bound parameters."""
    if not params:
        return name
    bindings = ""
    args = []
    for pname, pset in params:
        bindings += f"nondet {pname} = ({pset}).oneOf(); "
        args.append(pname)
    arg_list = ", ".join(args)
    return f"any {{ {bindings}{name}({arg_list}) }}"


def emit_fair(action_name: str, params: list, kind: str) -> str:
    """Emit one fair conjunct."""
    expr = emit_action_expr(action_name, params)
    return f"      {kind}({expr}, allVars)"


print("// Generated by hack/tools/quint-fairness-gen.py — do not edit.")
print("temporal ConvergenceFair =")
print("  (")
parts = []
for n, p in STRONG:
    parts.append(emit_fair(n, p, "strongFair"))
for n, p in WEAK:
    parts.append(emit_fair(n, p, "weakFair"))
print(" and\n".join(parts))
print("  )")
print("    implies eventually(always(HealthyControlPlane))")
