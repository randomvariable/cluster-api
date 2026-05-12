# formal/ — overview and reading order

This subtree is a layered formal-modelling corpus for Cluster API.
It pairs Quint specifications of controller-runtime, KCP, etcd
membership, kubeadm-join, ClusterTopology + runtime extensions,
MachineSet preflight, in-place machine updates, MachineHealthCheck,
and an end-to-end cluster lifecycle, with TLC / Apalache
verification, a Go trace-refinement runtime, RFC-2119 contracts
pinned to upstream commits, Lean 4 deductive proofs, and a
working CAPD e2e reproducer.

The CAEP at
[`docs/proposals/20260507-formal-control-plane-lifecycle-model.md`](../docs/proposals/20260507-formal-control-plane-lifecycle-model.md)
is the original entry point (written when the corpus was KCP-only).
The corpus has since grown to cover the full Cluster API surface;
[`README.md`](./README.md) sketches the present layered scope.

## Layered architecture

The specs split into four layers; reading them in this order
mirrors the dependency graph.

```text
Layer 3 (E2E):           ClusterE2E.qnt
                                ▲
                                │ uses
Layer 2 (refinements):   TopologyRefined.qnt
                         InPlaceUpdateRefined.qnt
                         MachineSetPreflightRefined.qnt
                                ▲
                                │ refines onto
Layer 0 (substrate):     ControllerRuntime.qnt
                                ▲
                                │ underpins
Layer 1 (per-component abstract specs):
   Lifecycle.qnt + EtcdMembership / KubeadmJoin / KCPReconcile / MachineHealthCheck / Composition
   Topology.qnt
   MachineSetPreflight.qnt
   InPlaceUpdate.qnt
   SelfHosted.qnt + Lifecycle.multicluster.qnt   (FM-35 self-hosted topology)
```

## Reading order

For a code reviewer:

1. [`overview.md`](./overview.md) (this file) — what's here, why.
2. [`test-corpus-spec.md`](./test-corpus-spec.md) — MoSCoW prioritisation, feature model, definition of done.
3. [`failure-modes.md`](./failure-modes.md) — catalogue of FM-1..FM-50 covering all four CAPI controller domains.
4. [`issue-corpus.md`](./issue-corpus.md) — model-found issues classified by component + severity.
5. [`upstream-issues-research.md`](./upstream-issues-research.md) — GitHub-issue mining; informs the FM corpus.
6. [`lsp-grounding.md`](./lsp-grounding.md) — methodology for LSP-grounded refinement anchors.
7. [`abstraction-mapping.md`](./abstraction-mapping.md) — per-action refinement-mapping table (the canonical reference).
8. [`dst-methodology.md`](./dst-methodology.md) — fault catalogue mapping abstract actions to docker primitives.
9. [`e2e-blueprints.md`](./e2e-blueprints.md) — CAPD e2e spec sketches.
10. [`verify-runbook.md`](./verify-runbook.md) — copy-paste commands to reproduce every TLC / Apalache / random-walk verdict.
11. [`counterexample-log.md`](./counterexample-log.md) — append-only ledger for spec violations.
12. **Layer 0 substrate**: [`specs/ControllerRuntime.qnt`](./specs/ControllerRuntime.qnt) — controller-runtime worker pool + workqueue + leader election + cache.
13. **Layer 1 per-component**:
    - [`specs/Lifecycle.qnt`](./specs/Lifecycle.qnt) — KCP/etcd/kubeadm-join lifecycle (the original spec).
    - [`specs/Topology.qnt`](./specs/Topology.qnt) — ClusterTopology reconciler + runtime-extension lifecycle hooks.
    - [`specs/MachineSetPreflight.qnt`](./specs/MachineSetPreflight.qnt) — worker MachineSet preflight gating.
    - [`specs/InPlaceUpdate.qnt`](./specs/InPlaceUpdate.qnt) — in-place machine update choreography.
    - [`specs/SelfHosted.qnt`](./specs/SelfHosted.qnt) + [`Lifecycle.multicluster.qnt`](./specs/Lifecycle.multicluster.qnt) — FM-35 self-hosted topology.
14. **Layer 2 refinements**: [`TopologyRefined.qnt`](./specs/TopologyRefined.qnt), [`InPlaceUpdateRefined.qnt`](./specs/InPlaceUpdateRefined.qnt), [`MachineSetPreflightRefined.qnt`](./specs/MachineSetPreflightRefined.qnt) — abstract specs composed onto the controller-runtime substrate.
15. **Layer 3 E2E**: [`specs/ClusterE2E.qnt`](./specs/ClusterE2E.qnt) — end-to-end bring-up + topology hooks + rolling/in-place upgrades.
16. **Cross-spec composition**: [`specs/WorkerLifecycle.qnt`](./specs/WorkerLifecycle.qnt) — Topology + MachineSetPreflight + InPlaceUpdate joint state machine (issue #2 + FM-51).

For a contributor adding a new failure mode:

1. Identify the controller domain (KCP / Topology / MachineSet /
   InPlace / cross-cutting) and pick the right spec module.
2. Read `dst-methodology.md` §2 to identify the docker primitive
   if the FM is exogenous.
3. Add the init action / fault action in that module; verify
   with `quint typecheck`.
4. Add an entry in `failure-modes.md` (the next free FM-N).
5. Add an `IC-NN` row in `issue-corpus.md` if there's a
   corresponding upstream gap.
6. Run `quint verify --backend=tlc` for reachability under
   `step` and `--backend=apalache` under `stepNoRecovery` (when
   applicable) for hopelessness.
7. Add abstraction-mapping rows in `abstraction-mapping.md` for
   any new actions.
8. Add a `make verify-fmN` (or `verify-<scenario>`) target in
   the Makefile.

## What's verified

| FM range | Spec module | Verdicts |
|---|---|---|
| FM-1..FM-24 | `specs/Lifecycle.qnt` + companions | 19 with TLC reachability; 6 with Apalache hopelessness (FM-2/3/13/16/17/23); 1 CAPD e2e PASS (FM-2); 4 CAPD e2e specs LANDED-PENDING-VERIFICATION (FM-3/13/15/19/23) |
| FM-31/32/34/37 | `specs/Lifecycle.qnt` (custom Node conditions, webhook rotation, MHC cache, lifecycle hooks) | TLC reachability via dedicated init actions |
| FM-9 | `proofs/ControlPlane/Convergence.lean` | Lean 4 deductive recurrence proof (5 theorems, no `sorry`) |
| FM-33 | `specs/MachineSetPreflight.qnt` | 3 demo runs verify CP-stable + version-skew gating |
| FM-35 | `specs/SelfHosted.qnt` + `Lifecycle.multicluster.qnt` | Per-cluster deadlock + recovery traces |
| FM-39/40/41 | `specs/Topology.qnt` | Multi-step hook ordering, annotation gating, AfterClusterUpgrade quiescence |
| FM-42/43/44 | `specs/InPlaceUpdate.qnt` | Premature admission, hook idempotence, multi-extension fast-fail |
| FM-45/46/47 | `specs/ControllerRuntime.qnt` | Per-key serialisation under multi-worker, TerminalError no-requeue, cache lag |
| FM-48/49/50 | `specs/ClusterE2E.qnt`, `specs/ClusterE2ERefined.qnt` | No CP before InfraReady, no workers before CPInit, endpoint monotonicity |

50 failure modes total. Per-spec verdicts:

| Spec module | Demo runs | Random-walk sweep | Apalache | CAPD e2e |
|---|---|---|---|---|
| Lifecycle.qnt | 19 inits | 5000×30 across SafetyInvariants | 6 hopelessness verdicts (FM-2/3/13/16/17/23) | FM-2 PASS; FM-3/13/15/19/23 specs landed (`test/e2e/fm{3,13,15,19,23}_*.go`), pending CAPD verification |
| Topology.qnt | 5 | 200×30 | **10/10 invariants** at depth 4 | — |
| MachineSetPreflight.qnt | 3 | (deterministic) | — | — |
| InPlaceUpdate.qnt | 5 | 2000×80 | **9/9 invariants** at depth 4 (FM-42 also at depth 8) | — |
| ControllerRuntime.qnt | 6 | 500×60 | **7/7 invariants** at depth 4 (FM-45 also at depth 8) | — |
| AdversaryHarness.qnt | 2 | 300×40 | **3/3 stable adversary bookkeeping invariants** under random walk; explicit uncleared-fault outage counterexample `NoPermanentUnavailability` reachable at Apalache depth 4 | — |
| CrossControllerCycle.qnt | 2 | 300×40 | **2/2 stable invariants** under random walk; explicit livelock counterexample `NoCyclicLivelock` reachable at Apalache depth 4 | — |
| ReflectorRelistStorm.qnt | 2 | 300×40 | **2/2 stable watch invariants** under random walk; explicit duplicate-create counterexample `NoDuplicateMachineLeak` reachable at Apalache depth 4 | — |
| StaleEnqueueShutdown.qnt | 2 | 300×40 | **2/2 stable queue/object invariants** under random walk; explicit nil-read counterexample `NoNilReadAfterDelete` reachable at Apalache depth 4 | — |
| WebhookOrdering.qnt | 2 | 300×40 | **1/1 stable admission-ordering invariants** under random walk; explicit stale-validator-read counterexample `ObservedValueIsFinal` reachable at Apalache depth 4 | — |
| WebhookSelfReference.qnt | 2 | 300×40 | **1/1 stable policy-safety invariants** under random walk; explicit fail-closed deadlock counterexample `UpgradeProgressDespiteWebhookGap` reachable at Apalache depth 4 | — |
| WebhookCABundleStaleness.qnt | 2 | 300×40 | **1/1 stable cache-refresh invariants** under random walk; explicit stale-trust counterexample `CurrentlyTrusted` reachable at Apalache depth 4 | — |
| DryRunSideEffects.qnt | 2 | 300×40 | **2/2 stable bookkeeping invariants** under random walk; explicit dry-run side-effect counterexample `DryRunHasNoSideEffects` reachable at Apalache depth 4 | — |
| AsymmetricPartition.qnt | 2 | 300×40 | **2/2 stable term/election invariants** under random walk; explicit dual-leader counterexample `NoSimultaneousLeaders` reachable at Apalache depth 4 | — |
| SnapshotRestoreCompaction.qnt | 2 | 300×40 | **2/2 stable restore/compaction invariants** under random walk; explicit restore-race counterexample `NoLogInconsistency` reachable at Apalache depth 4 | — |
| DefragQuorumLoss.qnt | 2 | 300×40 | **3/3 stable defrag bookkeeping invariants** under random walk; explicit quorum-loss counterexample `NoQuorumLossUnderSingleMaintenanceFault` reachable at Apalache depth 4 | — |
| EtcdWalFaults.qnt | 2 | 300×40 | **2/2 stable remediation bookkeeping invariants** under random walk; explicit silent-member-loss counterexample `NoSilentMemberLoss` reachable at Apalache depth 4 | — |
| EtcdMembershipBatch.qnt | 2 | 300×40 | **3/3 stable batch-membership invariants** under random walk; explicit same-batch churn counterexample `NoSameBatchAddRemove` reachable at Apalache depth 4 | — |
| EtcdFiveNodeFailure.qnt | 2 | 300×40 | **3/3 stable 5-node recovery invariants** under random walk; explicit triple-failure remediation-ordering counterexample `NoDoublePromotionDuringRecovery` reachable at Apalache depth 4 | — |
| AzFailoverCapacity.qnt | 2 | 300×40 | **2/2 stable AZ/capacity bookkeeping invariants** under random walk; explicit failover-stall counterexample `NoIndefiniteScaleAttempt` reachable at Apalache depth 4 | — |
| KubeletPlegHang.qnt | 2 | 300×40 | **2/2 stable CRI/PLEG bookkeeping invariants** under random walk; explicit over-eager-remediation counterexample `RemediationAfterStableNotReady` reachable at Apalache depth 4 | — |
| RegistryPullBackoff.qnt | 2 | 300×40 | **1/1 stable pull/backoff invariants** under random walk; explicit bootstrap-timeout counterexample `NoFalseBootstrapFailure` reachable at Apalache depth 4 | — |
| StaticPodMemPressure.qnt | 2 | 300×40 | **1/1 stable mem-pressure bookkeeping invariant** under random walk; explicit mis-priority static-pod eviction counterexample `CriticalStaticPodsImmuneFromEviction` reachable at Apalache depth 4 | — |
| StaticPodDiskFull.qnt | 2 | 300×40 | **1/1 stable disk-pressure bookkeeping invariant** under random walk; explicit static-pod crashloop counterexample `KcpRecognisesDiskPressureAsTransient` reachable at Apalache depth 4 | — |
| StaticPodHashReloadRace.qnt | 2 | 300×40 | **2/2 stable manifest/reload bookkeeping invariants** under random walk; explicit manifest-hash collision counterexample `NoHashCollisionAcrossDistinctIntents` reachable at Apalache depth 4 | — |
| BootstrapCsrLag.qnt | 2 | 300×40 | **2/2 stable CSR queue invariants** under random walk; explicit approval-timeout counterexample `BootstrapTimeoutCoversCsrLatency` reachable at Apalache depth 4 | — |
| ServiceAccountTokenRotation.qnt | 2 | 300×40 | **1/1 stable token bookkeeping invariant** under random walk; explicit stale-token auth failure counterexample `NoSilentReconcileFailure` reachable at Apalache depth 4 | — |
| CloudIamPermissionLoss.qnt | 2 | 300×40 | **2/2 stable IAM/provisioning bookkeeping invariants** under random walk; explicit zombie-machine counterexample `NoZombieMachine` reachable at Apalache depth 4 | — |
| IpamExhaustion.qnt | 2 | 300×40 | **2/2 stable subnet/IPAM bookkeeping invariants** under random walk; explicit silent-retry counterexample `NoSilentInfiniteRetry` reachable at Apalache depth 4 | — |
| ConditionMessageTruncation.qnt | 2 | 300×40 | **2/2 stable truncation bookkeeping invariants** under random walk; explicit tail-loss counterexample `RootCauseSurvivesTruncation` reachable at Apalache depth 4 | — |
| MtuFragmentation.qnt | 2 | 300×40 | **1/1 stable MTU bookkeeping invariant** under random walk; explicit silent-fragmentation counterexample `EtcdSnapshotEventuallySucceeds` reachable at Apalache depth 4 | — |
| CniVethRace.qnt | 2 | 300×40 | **2/2 stable CNI/veth bookkeeping invariants** under random walk; explicit pre-veth probe-loop counterexample `NoContainerStartBeforeCni` reachable at Apalache depth 4 | — |
| LoadBalancerDrain.qnt | 2 | 300×40 | **2/2 stable LB-drain bookkeeping invariants** under random walk; explicit blackholed-connection counterexample `KcpUpgradeAccountsForLbDrain` reachable at Apalache depth 4 | — |
| EndpointSwapKubeconfig.qnt | 2 | 300×40 | **2/2 stable endpoint bookkeeping invariants** under random walk; explicit stale-kubeconfig counterexample `AllKubeconfigsConvergeToCurrent` reachable at Apalache depth 4 | — |
| ConntrackExhaustion.qnt | 2 | 300×40 | **2/2 stable conntrack bookkeeping invariants** under random walk; explicit saturation counterexample `EventualConvergence` reachable at Apalache depth 4 | — |
| NetworkPolicyMidFlight.qnt | 2 | 300×40 | **2/2 stable policy/connection bookkeeping invariants** under random walk; explicit silent-stall counterexample `NoSilentControllerStall` reachable at Apalache depth 4 | — |
| 3 refined modules | 6 | 300×40 each | — | — |
| ClusterE2E.qnt | 3 | 300×60 | **11/11 invariants** at depth 4 | — |
| ClusterE2ERefined.qnt | 2 | 500×60 | **6/6 joint invariants** at depth 4 | — |
| WorkerLifecycle.qnt | 2 | 1000×60 | — (5 cross-cutting joint invariants verified) | — |
| MachineDeploymentRollout.qnt | 2 | 1000×60 | **6/6 stable invariants** at depth 4; `AvailabilityBound` and `NoStarveOldMS` retained as counterexample candidates | — |
| ClusterClassPatches.qnt | 2 | 1000×60 | **5/5 stable invariants** at depth 4; `mergeDeterministicAllOrders` and `immutableMergedCandidate` retained as counterexample candidates | — |
| ClusterClassTopologyRace.qnt | 2 | 300×40 | **2/2 stable ClusterClass topology invariants** under random walk; explicit torn-read counterexample `ConsistentCCViewPerReconcile` reachable at Apalache depth 4 | — |
| ClusterResourceSetTiming.qnt | 2 | 300×40 | **2/2 stable CRS timing invariants** under random walk; explicit ApplyOnce timing counterexample `ApplyOnceEventuallyTakesEffect` reachable at Apalache depth 4 | — |
| PvcBootstrapPending.qnt | 2 | 300×40 | **2/2 stable PVC/bootstrap bookkeeping invariants** under random walk; explicit pending-bootstrap counterexample `BootstrapDependencyOrdering` reachable at Apalache depth 4 | — |
| ConcurrentClusterSpecEdits.qnt | 2 | 300×40 | **3/3 stable concurrent-edit invariants** under random walk; explicit lost-edit counterexample `NoLostEdit` reachable at Apalache depth 4 | — |
| ClusterRoleDrift.qnt | 2 | 300×40 | **2/2 stable RBAC drift bookkeeping invariants** under random walk; explicit foreign-overwrite counterexample `NoSilentPermissionLossAfterDrift` reachable at Apalache depth 4 | — |
| SsaFieldManagerConflict.qnt | 2 | 300×40 | **2/2 stable SSA ownership invariants** under random walk; explicit stale-manager revert counterexample `NoSilentRevertAfterConflict` reachable at Apalache depth 4 | — |
| PartialRollbackDrop.qnt | 2 | 300×40 | **2/2 stable rollback/default bookkeeping invariants** under random walk; explicit redefine-loop counterexample `RedefaultConverges` reachable at Apalache depth 4 | — |
| ClusterEditDeleteRace.qnt | 2 | 300×40 | **2/2 stable edit/delete bookkeeping invariants** under random walk; explicit stale-write-after-delete counterexample `NoWriteAfterDeleteObserved` reachable at Apalache depth 4 | — |
| AutoscalerKcpSurgeRace.qnt | 2 | 300×40 | **3/3 stable autoscaler/rollout bookkeeping invariants** under random walk; explicit concurrent-scale counterexample `SurgeBoundUnderConcurrentScale` reachable at Apalache depth 4 | — |
| EtcdKubernetesVersionSkew.qnt | 2 | 300×40 | **2/2 stable version/dependency invariants** under random walk; explicit mid-rollout dependency-trap counterexample `NoMidRolloutDependencyTrap` reachable at Apalache depth 4 | — |
| RollbackSurgeRace.qnt | 2 | 300×40 | **2/2 stable rollback/surge bookkeeping invariants** under random walk; explicit mid-cycle rollback counterexample `NoTransientSurgeBeyondBound` reachable at Apalache depth 4 | — |
| BootstrapInfraReadyRace.qnt | 2 | 300×40 | **2/2 stable observed-readiness invariants** under random walk; explicit missing-event counterexample `NoStuckUnreadyDespiteBothChildrenReady` reachable at Apalache depth 4 | — |
| ConcurrentRemediationGate.qnt | 2 | 200×12 fixed / depth-8 counterexample | fixed atomic variant preserves quorum; explicit stale-read counterexample `NoConcurrentQuorumLoss` reachable at Apalache depth 8 | — |
| StatusSubresourceLag.qnt | 2 | 300×40 | **2/2 stable spec/status bookkeeping invariants** under random walk; explicit stale-status counterexample `LevelTriggeredControllersTolerateLag` reachable at Apalache depth 4 | — |
| MachinePoolScaleConflict.qnt | 2 | 300×40 | **2/2 stable MachinePool scale bookkeeping invariants** under random walk; explicit oscillation counterexample `NoOscillation` reachable at Apalache depth 4 | — |
| KcpMhcDeleteRace.qnt | 2 | 300×40 | **3/3 stable delete-race bookkeeping invariants** under random walk; explicit double-delete counterexample `NoDoubleDelete` reachable at Apalache depth 4 | — |
| ControllerManagerReplay.qnt | 2 | 300×40 | **2/2 stable leader/replay bookkeeping invariants** under random walk; explicit replay double-effect counterexample `NoDoubleEffect` reachable at Apalache depth 4 | — |
| ControllerLeaderSplitBrain.qnt | 2 | 300×40 | **2/2 stable split-brain lease invariants** under random walk; explicit duplicate-effect counterexample `NoDuplicateEffectAcrossLeaders` reachable at Apalache depth 4 | — |
| RuntimeSDK.qnt | 2 | 1000×60 | **5/5 stable invariants** at depth 4; `restartCacheReuseCandidate` and `partialFailureSingleTransportCandidate` retained as counterexample candidates | — |
| Finalizers.qnt | 1 | 1000×60 | **4/4 stable invariants** at depth 4; `ownerDeletionWaitsForChildrenCandidate` and `progressFromAnyStateCandidate` retained as counterexample candidates | `ControlPlane/Finalizers.lean::finalizer_set_eventually_empty` |
| EtcdJoiningNameDelay.qnt | 2 | 300×40 | **2/2 stable joining/member bookkeeping invariants** under random walk; explicit orphan-joining-member counterexample `NoOrphanJoiningMemberAfterMachineGone` reachable at Apalache depth 4 | — |
| OrphanLearnerCorrelation.qnt | 2 | 300×40 | **4/4 post-fix correlation-chain invariants** checked, including Apalache depth-8 checks on the six-step chain / ID-removal / blocking-hook logic | — |
| VolumeDetachFinalizer.qnt | 2 | 300×40 | **1/1 stable detach bookkeeping invariant** under random walk; explicit stuck-detach counterexample `OperatorEscapeHatch` reachable at Apalache depth 4 | — |
| Pivot.qnt | 2 | 1000×60 | **6/6 stable invariants** at depth 4; `crashMutualExclusionCandidate` and `partialPivotOrphanCandidate` retained as counterexample candidates | — |
| ConversionWebhook.qnt | 2 | 1000×60 | **5/5 stable invariants** at depth 4; `roundTripStatusInformative`, `informationLossDocumented`, and `noneConverterCrossVersionCandidate` retained as concrete counterexample entry points via dedicated bad-state inits | `ControlPlane/Informativeness.lean::informativeness_obligation_violated_for_v1beta2_today` |
| KubeletPKI.qnt | 2 | 1000×60 | **5/5 stable invariants** at depth 4; `ownedSecretOnlyRotates`, `caNotRecreatedAfterInit`, and `rotationPreservesEndpoint` retained as concrete counterexample entry points via dedicated bad-state inits | — |

Total: ~57 demo runs, ~3000 actions covered by random walks, 206
abstraction-mapping rows under the drift check.

## Closed gaps

The corpus has progressed through several phases of expansion:

| Phase | Closure |
|---|---|
| 1 | Transient bounds (start/end/infra causes) for FM-4, 6, 7, 10, 15, 18, 19, 21, 24 |
| 2 | Etcd leader-following: `LeaderStepDown`, `TransferLeadership`, `RemoveMember` gated on leader ≠ id |
| 3 | Kubeadm join phases expanded from 7 to 16; kubelet local Node registration; CRI-bound flags |
| 4 | `drainBlocked` + `pdbViolatedFor` flags; `BeginDrain` / `DrainTimeout`; LSP-grounded in CAPI Machine controller drain |
| 4b | `criRuntimeReady`, `criImagesPulled`, `criPodSandboxRunning`, `criContainersRunning`; ContainerdReady/Crash/PullStaticPodImages/CreatePodSandbox/StartStaticPodContainers |
| 5 | FM-23 Apalache safety verdict (`AllSafetyInvariants` holds at depth 4 under stepNoRecovery, ~278 s) |
| 6 | IC-11 deterministic recovery: `upgradeRollbackRecoveryRun` reaches `HealthyControlPlane` |
| 7 | FM-31 `customCondition` + `CustomConditionObserved` action |
| 8 | FM-32 `webhooksAvailable` + `WebhookRotationFault` / `WebhookHeal` |
| 9 | FM-34 `mhcCacheStale` + `MhcCacheStale` / `MhcCacheRefresh` |
| 10 | FM-37 `hooksTriggered` + `TriggerPreUpgradeHook` |
| 11 | FM-9 `ConvergenceFair` temporal property + Lean 4 deductive proof |
| 12 | FM-35 dual-cluster `SelfHosted.qnt` + `Lifecycle.multicluster.qnt` per-cluster expansion; issue #96 deepens `SelfHosted.qnt` with explicit `EtcdRollRequiresEtcdWrite` trap and `EscapeHatchExists` recovery path |
| 13 | FM-33 worker-MachineSet preflight (`MachineSetPreflight.qnt`) |
| 14 | FM-39/40/41 Topology + runtime extensions (`Topology.qnt`) |
| 15 | FM-42/43/44 in-place machine updates (`InPlaceUpdate.qnt`) |
| 16 | FM-45/46/47 controller-runtime substrate (`ControllerRuntime.qnt`) + 3 refinement modules |
| 17 | FM-48/49/50 end-to-end cluster lifecycle (`ClusterE2E.qnt`) |
| 18 | Apalache hopelessness on the four newer specs (issue #1): 37 invariants verified at depth 4. Refactor to `Topology.qnt` to replace dynamic `(cpV+1).to(tV)` with constant-bounded filter (Apalache parser limitation). Make targets `verify-{cr,topology,inplace,e2e}-apalache`. |
| 19 | Cross-spec composition (issue #2): `WorkerLifecycle.qnt` joins Topology + MachineSetPreflight + InPlaceUpdate; surfaces FM-51 (level-triggered preflight re-evaluation race). 1000×60 random walk holds 9 cross-cutting joint invariants. |
| 20 | Liveness properties beyond FM-9 (issue #3): 3 in `InPlaceUpdate.qnt` (`L1_EventuallyAllMachinesSettled`, `L2_EventuallyHookPendingCleared`, `L3_EventuallyVersionStable`), 1 in `Topology.qnt` (`LT1_EventuallyPendingHooksClear`). Topology's stronger eventual-progress is paradox-limited (documented for follow-up). FM-9 unchanged. |
| 21 | Mutation testing (issue #4): `hack/tools/quint-mutation-tester.py` applies 8 systematic mutation operators per invariant. 696 mutations attempted across 9 specs; 131 killed (load-bearing), 60 survived. See `formal/mutation-findings.md`. |
| 22 | Depth bump (issue #5): random walks bumped to 200×40 (Topology), 2000×120 (InPlaceUpdate), 500×100 (ControllerRuntime), 300×100 (ClusterE2E), 1000×80 (WorkerLifecycle); all HOLD. Lifecycle FM-1 TLC at depth=12 (90k states, 1.3 s); FM-9 ConvergenceFair16 at depth=12 surfaced fairness-scope gap (EtcdCompactionStart lasso). Added `ConvergenceFair17`. Documented in counterexample-log.md. |
| 23 | Apalache deadlock check (issue #6): all 10 spec modules at depth 4 — no deadlocks. TopologyRefined.qnt needed the same `(cpV+1).to(tV)` → `ALL_VERSIONS.filter` refactor applied earlier to Topology.qnt for Apalache compatibility. Make target `verify-deadlock-check`. |
| 24 | MachineDeployment rollout / MHC / scale concurrency (issue #14): `MachineDeploymentRollout.qnt` + `MachineDeploymentRolloutRefined.qnt`; 6 stable invariants verified, 2 stronger snapshot-style obligations (`AvailabilityBound`, `NoStarveOldMS`) retained as documented counterexample candidates. Make targets `verify-md-rollout*`. |
| 25 | ClusterClass patch ordering / variable scoping / immutable protection (issue #15): `ClusterClassPatches.qnt`; 5 stable invariants verified, plus two deliberate counterexample candidates (`mergeDeterministicAllOrders`, `immutableMergedCandidate`) for overlapping writes and pre-validation immutable-field flips. Make targets `verify-clusterclass-patches*`. |
| 26 | Runtime SDK discovery / registration / partial failure (issue #16): `RuntimeSDK.qnt`; 5 stable invariants verified, Apalache battery holds at depth 4, and two stronger replay-style candidates (`restartCacheReuseCandidate`, `partialFailureSingleTransportCandidate`) are retained as documented counterexamples. Make targets `verify-runtimesdk*`. |
| 27 | Finalizer chain ordering / deletion stalls (issue #18): `Finalizers.qnt` plus `formal/proofs/ControlPlane/Finalizers.lean`; 4 stable invariants verified, Apalache battery holds at depth 4, and two stronger candidates (`ownerDeletionWaitsForChildrenCandidate`, `progressFromAnyStateCandidate`) are retained as documented counterexamples. Make targets `verify-finalizers*`. |
| 28 | clusterctl move / pivot graph preservation (issue #17): `Pivot.qnt`; 6 stable invariants verified, Apalache battery holds at depth 4, and two stronger candidates (`crashMutualExclusionCandidate`, `partialPivotOrphanCandidate`) are retained as documented counterexamples. Make targets `verify-pivot*`. |
| 29 | v1beta1 ↔ v1beta2 conversion-webhook round-tripping (issue #19): `ConversionWebhook.qnt` plus the now-discharged witness in `formal/proofs/ControlPlane/Informativeness.lean`; 5 stable invariants verified, Apalache battery holds at depth 4, and three deliberate bad-state entries (`statusProjectionLossRun`, `undocumentedFieldLossRun`, `outageFallbackRun`) are retained as documented counterexamples. Make targets `verify-conversionwebhook*`. |
| 30 | kubeconfig client-cert rotation / CA availability under KCP reconcile (issue #20): `KubeletPKI.qnt`; 5 stable invariants verified, Apalache battery holds at depth 4, and three deliberate bad-state entries (`userSecretRotationRun`, `postInitCARegenRun`, `endpointRewriteRun`) are retained as documented counterexamples. Make targets `verify-kubeletpki*`. |
| 31 | end-to-end refinement onto controller-runtime substrate (issue #21): `ClusterE2ERefined.qnt`; 6 joint invariants verified at depth 4, random-walk sweep raised to 500×60, and FM-48/49/50 re-recorded against the substrate-aware model. Make target `verify-clustere2e-refined`. |

Plus apiserver↔etcd modelling (`apiserverEtcdReachable`,
`apiserverReady`, `etcdCompactionInProgress`, etc.) and
LSP-grounded refinement anchors across:

- `internal/controllers/cluster/cluster_controller_phases.go`
- `internal/controllers/machine/{machine_controller, drain/drain.go, machine_controller_inplace_update}.go`
- `internal/controllers/machineset/machineset_{controller,preflight}.go`
- `internal/controllers/machinedeployment/machinedeployment_{controller,canupdatemachineset,rollout_*}.go`
- `internal/controllers/topology/cluster/{cluster_controller,reconcile_state}.go`
- `controlplane/kubeadm/internal/controllers/{controller,scale,remediation}.go`
- `controlplane/kubeadm/internal/{workload_cluster,workload_cluster_etcd,workload_cluster_conditions}.go`
- `exp/topology/desiredstate/{desired_state,upgrade_plan,lifecycle_hooks}.go`
- `internal/hooks/tracking.go`
- `pkg/internal/controller/controller.go`,
  `pkg/controller/priorityqueue/priorityqueue.go`,
  `pkg/manager/internal.go`,
  `pkg/{reconcile,source,handler,predicate,cache,client}/*.go`
  (controller-runtime substrate)
- Upstream Kubernetes: `staging/src/k8s.io/apiserver/pkg/storage/etcd3/`,
  `pkg/server/healthz`, `pkg/kubelet/{kubelet_node_status, kuberuntime}/`,
  `cmd/kubeadm/app/cmd/phases/join/`

## Remaining gaps

| Gap | Where documented |
|---|---|
| Most FMs lack e2e specs (5 are blueprinted) | `e2e-blueprints.md` |
| FM-9 fairness verdict beyond TLC's 16-conjunct cap (Lean 4 deductive proof closes this; TLC capacity gap remains) | `failure-modes.md` FM-9 §"Phase 11d" |

## Tooling state

| Tool | Version pinned | Purpose |
|---|---|---|
| Quint | 0.32.0 | Source of truth for the model |
| TLC | 2.18+ via `quint verify --backend=tlc` | Exhaustive reachability checking |
| Apalache | via `quint verify --backend=apalache` | Symbolic hopelessness proofs |
| Lean 4 | v4.16.0 | Deductive proofs (FM-9 fairness, refinement scaffolding) |
| gopls | (mcp) | LSP-grounded refinement anchors |
| CAPD + Kind | v1.34.0 (local override; main pins v1.36.0) | e2e cluster substrate |

## CI gate

`scripts/verify-formal.sh` runs:

1. `quint typecheck` on every `.qnt`.
2. `quint run` with declared `runs`.
3. `lake build` in `formal/proofs/`.
4. `tlc` against `.tla` + `.cfg` pairs.
5. `go build / test / vet` of `internal/trace` + `hack/tools/trace-validator`.
6. Drift check: every Quint action has an abstraction-mapping row.

The gate is non-blocking on tool absence — it reports `SKIP`
rather than silent success. Currently 178 actions covered by
the drift check.

## Branch

The corpus lives on the `formality` branch in the user's fork.
No upstream push, no PR.
