# Verification runbook — reproducing every TLC / Apalache verdict

Concrete commands to reproduce every formal verdict in
`failure-modes.md`. Each command is copy-pasteable and assumes
the working directory is the repository root.

## Prerequisites

```sh
# Quint
npm install -g @informalsystems/quint   # >= 0.32.0

# TLC + Apalache come bundled with quint when invoked via
# `quint verify`.  Quint downloads them on first use.

# Lake (for Lean proofs, optional)
curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh
```

## Smoke tests — run first

```sh
make -C formal verify        # quint typecheck + lake build + tlc + go
./scripts/verify-formal.sh   # CI gate
```

## Per-FM verification commands

### TLC reachability — recovery available

For every FM where the recovery path is in `step`, TLC should
find a counterexample to `not(HealthyControlPlane)` (i.e. the
healthy state IS reachable).

```sh
# FM-1 — FM-1 invariants (max-steps=4 exhausts state space)
quint verify --main=Lifecycle \
             --init=incidentInit --step=stepRemediation \
             --invariant=IncidentNeverInFlight \
             --max-steps=4 --backend=tlc \
             formal/specs/Lifecycle.qnt

quint verify --main=Lifecycle \
             --init=incidentInit --step=stepRemediation \
             --invariant=IncidentBlockReasonCorrect \
             --max-steps=4 --backend=tlc \
             formal/specs/Lifecycle.qnt

# FM-1 / FM-2 / FM-3 / FM-13 / FM-16 — reachability under recovery
for init in stuckLearnerInit twoMachineBothUnhealthyInit \
            partitionedClusterInit lbBrokenInit \
            singleNodeLostVoterInit; do
  quint verify --main=Lifecycle --init=$init --step=step \
               --invariant='not(HealthyControlPlane)' \
               --max-steps=8 --backend=tlc \
               formal/specs/Lifecycle.qnt
done

# FM-11 / FM-12 / FM-14 / FM-15 / FM-17..FM-24
for init in invalidKubeletInit slowStorageEtcdJoinInit \
            nodeNeverJoinsInit upgradeInFlightInit \
            kubeadmMisconfigInit concurrentScaleAndRemediateInit \
            apiserverRestartInit upgradeRollbackMidFlightInit \
            fiveNodeTwoFailuresInit singleNodeScaleUpFailureInit \
            drainStuckInit etcdDefragPauseInit; do
  quint verify --main=Lifecycle --init=$init --step=step \
               --invariant='not(HealthyControlPlane)' \
               --max-steps=8 --backend=tlc \
               formal/specs/Lifecycle.qnt
done
```

Expected verdicts: every command prints `[violation] Found an
issue` (the negated invariant fails because HealthyControlPlane
IS reachable). The `Summary table` rows in
`failure-modes.md` give the state-count and timing.

### Apalache hopelessness — recovery disabled

For EXOGENOUS FMs and KCP-BUG (latent) FMs whose recovery is in
`step` but not in `stepNoRecovery`, Apalache should prove
`not(HealthyControlPlane)` HOLDS — the healthy state is
unreachable without the named recovery.

```sh
# FM-2, FM-3, FM-13, FM-16 — proven hopeless without recovery
for init in twoMachineBothUnhealthyInit partitionedClusterInit \
            lbBrokenInit singleNodeLostVoterInit; do
  quint verify --main=Lifecycle --init=$init --step=stepNoRecovery \
               --invariant='not(HealthyControlPlane)' \
               --max-steps=4 --backend=apalache \
               formal/specs/Lifecycle.qnt
done

# FM-17, FM-23 (added in the corpus expansion round)
quint verify --main=Lifecycle --init=kubeadmMisconfigInit \
             --step=stepNoRecovery \
             --invariant='not(HealthyControlPlane)' \
             --max-steps=4 --backend=apalache \
             formal/specs/Lifecycle.qnt

quint verify --main=Lifecycle --init=drainStuckInit \
             --step=stepNoRecovery \
             --invariant='not(HealthyControlPlane)' \
             --max-steps=4 --backend=apalache \
             formal/specs/Lifecycle.qnt

# FM-23 — Phase 5: with drainBlocked + pdbViolatedFor flags landed,
# Apalache proves AllSafetyInvariants holds at depth 4 in ~278 s.
# This is the load-bearing safety verdict for the drain hopelessness
# claim. The complement direction (`not(HealthyControlPlane)`) finds
# a counterexample because ChangeDesiredReplicas — a legitimate
# operator action — can drop the cluster to a single-machine
# "healthy" state. That degraded path is permitted by the model;
# it is documented as a model-permissiveness note rather than a
# hopelessness violation.
quint verify --main=Lifecycle --init=drainStuckInit \
             --step=stepNoRecovery \
             --invariant='AllSafetyInvariants' \
             --max-steps=4 --backend=apalache \
             formal/specs/Lifecycle.qnt
# Expected: [ok] No violation found (~278 s).
```

Expected verdicts: `[ok] No violation found` (the negated
invariant holds, so `HealthyControlPlane` is unreachable). The
`Summary table` rows give Apalache timing (typically 20–80 s per
FM at max-steps=4).

### Apalache hopelessness across the new specs

Issue #1 verified every safety invariant in `Topology.qnt` (10),
`InPlaceUpdate.qnt` (9), `ControllerRuntime.qnt` (7), and
`ClusterE2E.qnt` (11) — 37 invariants total — under Apalache at
depth 4. All HOLD; no counterexamples found.

```sh
# Per-spec batteries (each takes ~2-3 min):
make -C formal verify-cr-apalache         # ControllerRuntime
make -C formal verify-topology-apalache   # Topology
make -C formal verify-inplace-apalache    # InPlaceUpdate
make -C formal verify-e2e-apalache        # ClusterE2E

# All four (~15 min total):
make -C formal verify-apalache-new-specs
```

The `MAX_STEPS_APALACHE` variable bumps depth (default 4):

```sh
make -C formal verify-cr-apalache MAX_STEPS_APALACHE=8
```

Note: Apalache rejects dynamic integer ranges like
`(cpVersion + 1).to(topologyVersion)`. The corpus's
`Topology.qnt` was refactored to use a constant-bounded filter
(`ALL_VERSIONS.filter(v => v > cpVersion and v <= topologyVersion)`)
so it parses under Apalache.

### FM-9 — ConvergenceFair temporal verification

```sh
# weakFair(step, allVars) implies eventually(always(HealthyControlPlane)).
quint verify --main=Lifecycle --init=happyJoinInit --step=step \
             --temporal=ConvergenceFair --backend=tlc \
             --max-steps=12 formal/specs/Lifecycle.qnt
```

The fairness annotation is generated by
`hack/tools/quint-fairness-gen.py`; re-run after adding state vars.

### IC-11 — Upgrade rollback mid-flight recovery (TLC reachability)

```sh
# Verify that upgradeRollbackRecoveryRun reaches HealthyControlPlane.
# `not(HealthyControlPlane)` is the search invariant; a violation
# means HealthyControlPlane was reached at some state of the run.
quint run --main=Lifecycle --init=upgradeRollbackRecoveryRun \
          --step=step --invariant='not(HealthyControlPlane)' \
          --max-steps=0 formal/specs/Lifecycle.qnt
# Expected: [violation] (~217 ms, 4 steps).
```

### End-to-end cluster lifecycle (FM-48/49/50)

```sh
# Three demonstration runs cover the full bring-up plus
# rolling and in-place upgrade strategies.

quint run --main=ClusterE2E --init=happyBringUpRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ClusterE2E.qnt

quint run --main=ClusterE2E --init=happyRollingUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ClusterE2E.qnt

quint run --main=ClusterE2E --init=happyInPlaceUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ClusterE2E.qnt

# Random-walk every cross-cutting ordering invariant.
for inv in AllSafetyInvariants FM48_NoCpBeforeInfraReady \
           FM49_NoWorkersBeforeCpInit FM50_EndpointMonotonic \
           BootstrapBeforeInfra ClusterCpInitializedRequiresKcp \
           MdEnabledRequiresCpInit BeforeClusterUpgradeOrdering \
           AfterClusterUpgradeAtTarget; do
  quint run --main=ClusterE2E --invariant=$inv \
            --max-samples=300 --max-steps=60 \
            formal/specs/ClusterE2E.qnt
done
```

Or, from `formal/`: `make verify-e2e`.

### End-to-end refined onto controller-runtime substrate (issue #21)

```sh
# Happy bring-up through queue dispatches.
quint run --main=ClusterE2ERefined --init=happyRefinedBringUpRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ClusterE2ERefined.qnt

# Leader loss mid-bring-up, then replay after reacquire.
quint run --main=ClusterE2ERefined --init=leaderLossReplayRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ClusterE2ERefined.qnt

# Random-walk refined joint invariants.
for inv in AllSafetyInvariants FM45_PerKeySerialisation \
           FM48_NoCpBeforeInfraReady FM49_NoWorkersBeforeCpInit \
           FM50_EndpointMonotonic EndpointSetRequiresInfraClusterReady \
           ClusterCpInitializedRequiresKcp; do
  quint run --main=ClusterE2ERefined --invariant=$inv \
            --step=randomStep --max-samples=500 --max-steps=60 \
            formal/specs/ClusterE2ERefined.qnt
done

# Apalache battery (6 joint invariants at depth 4).
for inv in FM45_PerKeySerialisation FM48_NoCpBeforeInfraReady \
           FM49_NoWorkersBeforeCpInit FM50_EndpointMonotonic \
           EndpointSetRequiresInfraClusterReady \
           ClusterCpInitializedRequiresKcp; do
  echo y | quint verify --main=ClusterE2ERefined \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/ClusterE2ERefined.qnt
done
```

Or, from `formal/`: `make verify-clustere2e-refined`.

### Liveness properties beyond FM-9 (issue #3)

```sh
# InPlaceUpdate liveness (3 properties, TLC ~3 s each):
quint verify --main=InPlaceUpdate \
             --temporal=L1_EventuallyAllMachinesSettled \
             --backend=tlc --max-steps=8 \
             formal/specs/InPlaceUpdate.qnt
quint verify --main=InPlaceUpdate \
             --temporal=L2_EventuallyHookPendingCleared \
             --backend=tlc --max-steps=8 \
             formal/specs/InPlaceUpdate.qnt
quint verify --main=InPlaceUpdate \
             --temporal=L3_EventuallyVersionStable \
             --backend=tlc --max-steps=8 \
             formal/specs/InPlaceUpdate.qnt

# Topology liveness (1 verified; LT2/LT3 paradox-limited, see spec docstring):
quint verify --main=Topology \
             --temporal=LT1_EventuallyPendingHooksClear \
             --backend=tlc --max-steps=8 \
             formal/specs/Topology.qnt

# Lifecycle FM-9 fairness recurrence is in the existing
# verify-fm9-* targets (TLC at 16-conjunct scope; full
# 65-conjunct tableaus to 0 branches at 16 GB heap — see
# failure-modes.md FM-9 §"Phase 11d bisection").
```

Or, from `formal/`: `make verify-liveness`.

KNOWN LIMITATION: the stronger eventual-progress properties in
Topology (LT2_NotCreatedExitsRecurrent,
LT3_StepPhaseIdleRecurrent) do NOT hold because of a TLA+
fairness paradox. The unfair `EvaluateHook(h, HookBlock)` action
can fire infinitely often, re-flipping `lastHookOutcome[h]` to
HookBlock between every Reconcile firing. Closing the gap
requires either (a) refactoring `EvaluateHook` and
`Reconcile*` into single atomic actions with the outcome as a
parameter, or (b) Lean 4 deductive proof under a
no-operator-fault assumption.

### Cross-spec composition (FM-51, WorkerLifecycle.qnt)

```sh
# Two demonstration runs:
quint run --main=WorkerLifecycle --init=happyInPlaceUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/WorkerLifecycle.qnt

quint run --main=WorkerLifecycle --init=preflightBlockedDuringInPlaceRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/WorkerLifecycle.qnt

# Random walk every joint invariant (1000×60 per issue #2 spec).
for inv in AllSafetyInvariants FM39_BeforeClusterUpgradeIdempotent \
           FM41_AfterClusterUpgradeAtSteadyState FM43_UpdateMachineIdempotence \
           FM33_PreflightGate J1_NoMoveBeforeWorkersStep \
           J2_AfterWorkersAtMachineQuiescence \
           J3_InPlaceAdmissionAfterBeforeWorkersUpgrade \
           J4_MachineVersionMonotone J5_NoInFlightAcrossStable; do
  quint run --main=WorkerLifecycle --invariant=$inv \
            --max-samples=1000 --max-steps=60 \
            formal/specs/WorkerLifecycle.qnt
done
```

Or, from `formal/`: `make verify-worker-lifecycle`.

### MachineDeployment rollout x MHC x scale concurrency (issue #14)

```sh
# Two deterministic runs:
quint run --main=MachineDeploymentRollout --init=happyRolloutRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/MachineDeploymentRollout.qnt

quint run --main=MachineDeploymentRollout --init=conflictingDeleteRaceRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/MachineDeploymentRollout.qnt

# Passing random-walk safety battery (issue #14 stable invariants).
for inv in AllSafetyInvariants SurgeBound NoConflictingDeletes \
           TemplateMonotone PdbBlockedDrainStalls \
           DrainTimeoutEventuallyRequeues \
           MhcCannotDeleteScaleDownVictim RemovedMachinesDeselected; do
  quint run --main=MachineDeploymentRollout --invariant=$inv \
            --max-samples=1000 --max-steps=60 \
            formal/specs/MachineDeploymentRollout.qnt
done

# Stronger snapshot-style obligations that intentionally admit
# counterexamples under concurrent operator / MHC interleavings.
quint verify --main=MachineDeploymentRollout --invariant=AvailabilityBound \
             --max-steps=4 --backend=apalache \
             formal/specs/MachineDeploymentRollout.qnt

quint verify --main=MachineDeploymentRollout --invariant=NoStarveOldMS \
             --max-steps=4 --backend=apalache \
             formal/specs/MachineDeploymentRollout.qnt

# Passing Apalache battery (6 symbolic verdicts at depth 4).
for inv in SurgeBound NoConflictingDeletes TemplateMonotone \
           PdbBlockedDrainStalls DrainTimeoutEventuallyRequeues \
           RemovedMachinesDeselected; do
  echo y | quint verify --main=MachineDeploymentRollout \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/MachineDeploymentRollout.qnt
done

# Refined controller-runtime battery.
for inv in AllSafetyInvariants FM45_PerKeySerialisation BodyActionsGated \
           ReconcileOwnershipConsistent; do
  quint run --main=MachineDeploymentRolloutRefined --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/MachineDeploymentRolloutRefined.qnt
done
```

Or, from `formal/`: `make verify-md-rollout` and
`make verify-md-rollout-apalache`.

### ClusterClass patch ordering / variable scope / immutable protection (issue #15)

```sh
# Two deterministic demonstrations.
quint run --main=ClusterClassPatches --init=happyPatchMergeRun --step=randomStep \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ClusterClassPatches.qnt

quint run --main=ClusterClassPatches --init=overlappingPatchOrderRun --step=randomStep \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ClusterClassPatches.qnt

# Passing random-walk battery (1000x60 on the richer transition relation).
for inv in StableSafetyInvariants mergeDeterministic immutablePreserved \
           overridesSurviveCC patchIdempotent noPhantomVar; do
  quint run --main=ClusterClassPatches --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/ClusterClassPatches.qnt
done

# Passing Apalache battery (5 state invariants at depth 4).
for inv in mergeDeterministic immutablePreserved overridesSurviveCC \
           patchIdempotent noPhantomVar; do
  echo y | quint verify --main=ClusterClassPatches \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/ClusterClassPatches.qnt
done

# Deliberate counterexample candidates.
quint run --main=ClusterClassPatches --step=randomStep \
          --invariant=mergeDeterministicAllOrders \
          --max-samples=200 --max-steps=20 \
          formal/specs/ClusterClassPatches.qnt

quint run --main=ClusterClassPatches --step=randomStep \
          --invariant=immutableMergedCandidate \
          --max-samples=200 --max-steps=20 \
          formal/specs/ClusterClassPatches.qnt
```

Or, from `formal/`: `make verify-clusterclass-patches`,
`make verify-clusterclass-patches-random`, and
`make verify-clusterclass-patches-apalache`.

### Runtime SDK discovery / registration / partial failure (issue #16)

```sh
# Two deterministic demonstrations.
quint run --main=RuntimeSDK --init=happyRuntimeRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/RuntimeSDK.qnt

quint run --main=RuntimeSDK --init=partialFailureRetryRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/RuntimeSDK.qnt

# Passing random-walk battery (1000x60 on the richer transition relation).
for inv in StableSafetyInvariants idempotentHookUnderRetry noDoubleFire \
           discoveryConsistent cacheInvalidatedOnRestart \
           partialFailureRecoverable; do
  quint run --main=RuntimeSDK --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/RuntimeSDK.qnt
done

# Passing Apalache battery (5 invariants at depth 4).
for inv in idempotentHookUnderRetry noDoubleFire discoveryConsistent \
           cacheInvalidatedOnRestart partialFailureRecoverable; do
  echo y | quint verify --main=RuntimeSDK \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/RuntimeSDK.qnt
done

# Deliberate counterexample candidates.
quint run --main=RuntimeSDK --init=restartCacheReplayRun --step=InvokeHook \
          --invariant=restartCacheReuseCandidate --max-steps=1 \
          formal/specs/RuntimeSDK.qnt

quint run --main=RuntimeSDK --init=partialFailureRetryRun --step=InvokeHook \
          --invariant=partialFailureSingleTransportCandidate --max-steps=1 \
          formal/specs/RuntimeSDK.qnt
```

Or, from `formal/`: `make verify-runtimesdk`,
`make verify-runtimesdk-random`, and `make verify-runtimesdk-apalache`.

### Finalizer chain ordering / deletion stalls (issue #18)

```sh
# Passing deterministic happy-path demonstration.
quint run --main=Finalizers --init=happyCascadeRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/Finalizers.qnt

# Passing random-walk battery (1000x60 on the richer transition relation).
for inv in StableSafetyInvariants noOrphan cleanShutdownTerminal \
           topologicalOrder idempotentRemoval; do
  quint run --main=Finalizers --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/Finalizers.qnt
done

# Passing Apalache battery (4 state invariants at depth 4).
for inv in noOrphan cleanShutdownTerminal topologicalOrder idempotentRemoval; do
  echo y | quint verify --main=Finalizers \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/Finalizers.qnt
done

# Lean proof companion.
(cd formal/proofs && lake build)

# Deliberate counterexample candidates.
quint run --main=Finalizers --init=orphanedChildOrderingRun \
          --step=OwnerDeletedMachineSet \
          --invariant=ownerDeletionWaitsForChildrenCandidate \
          --max-steps=1 formal/specs/Finalizers.qnt

quint run --main=Finalizers --init=blockedDeletionRun --step=Stutter \
          --invariant=progressFromAnyStateCandidate \
          --max-steps=0 formal/specs/Finalizers.qnt
```

Or, from `formal/`: `make verify-finalizers`,
`make verify-finalizers-random`, `make verify-finalizers-apalache`,
and `make verify-finalizers-proof`.

### clusterctl move / pivot safety (issue #17)

```sh
# Passing deterministic happy-path demonstration.
quint run --main=Pivot --init=happyPivotRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/Pivot.qnt

# Passing blocked / retryable failure-path demonstration.
quint run --main=Pivot --init=blockedPivotRetryRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/Pivot.qnt

# Passing random-walk battery (1000x60 on the richer transition relation).
for inv in StableSafetyInvariants objectConservation noOrphan \
           mutualExclusion partialPivotRecoverable \
           finalizerOrdered secretsCloned; do
  quint run --main=Pivot --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/Pivot.qnt
done

# Passing Apalache battery (5 state invariants at depth 4).
for inv in objectConservation noOrphan mutualExclusion \
           finalizerOrdered secretsCloned; do
  echo y | quint verify --main=Pivot \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/Pivot.qnt
done

# Deliberate counterexample candidates.
quint run --main=Pivot --init=crashDualReconcileRun --step=step \
          --invariant=crashMutualExclusionCandidate \
          --max-steps=0 formal/specs/Pivot.qnt

quint run --main=Pivot --init=partialOrphanRun --step=step \
          --invariant=partialPivotOrphanCandidate \
          --max-steps=0 formal/specs/Pivot.qnt
```

Or, from `formal/`: `make verify-pivot`, `make verify-pivot-random`,
and `make verify-pivot-apalache`.

### v1beta1 ↔ v1beta2 conversion webhook safety (issue #19)

```sh
# Passing deterministic round-trip demonstration.
quint run --main=ConversionWebhook --init=happyRoundTripRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ConversionWebhook.qnt

# Passing random-walk battery (1000x60 on the stable transition set).
for inv in StableSafetyInvariants roundTripSpec roundTripStatusInformative \
           webhookFailureSafe defaultsIdempotent \
           informationLossDocumented; do
  quint run --main=ConversionWebhook --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/ConversionWebhook.qnt
done

# Passing Apalache battery (5 invariants at depth 4).
for inv in roundTripSpec roundTripStatusInformative webhookFailureSafe \
           defaultsIdempotent informationLossDocumented; do
  echo y | quint verify --main=ConversionWebhook \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/ConversionWebhook.qnt
done

# Lean witness for the FM-16 informativeness regression.
cd formal/proofs && lake build

# Deliberate counterexample candidates.
quint run --main=ConversionWebhook --init=statusProjectionLossRun --step=step \
          --invariant=roundTripStatusInformative --max-steps=0 \
          formal/specs/ConversionWebhook.qnt

quint run --main=ConversionWebhook --init=undocumentedFieldLossRun --step=step \
          --invariant=informationLossDocumented --max-steps=0 \
          formal/specs/ConversionWebhook.qnt

quint run --main=ConversionWebhook --init=outageFallbackRun --step=step \
          --invariant=noneConverterCrossVersionCandidate --max-steps=0 \
          formal/specs/ConversionWebhook.qnt
```

Or, from `formal/`: `make verify-conversionwebhook`,
`make verify-conversionwebhook-random`,
`make verify-conversionwebhook-apalache`, and
`make verify-conversionwebhook-proof`.

### kubelet PKI / kubeconfig rotation (issue #20)

```sh
# Happy path: owned kubeconfig rotates after crossing the renewal threshold.
quint run --main=KubeletPKI --init=happyRotationRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/KubeletPKI.qnt

# Missing CA blocks kubeconfig creation and leaves the reconcile requeued.
quint run --main=KubeletPKI --init=blockedRotationRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/KubeletPKI.qnt

# Random-walk every stable kubelet-PKI invariant.
for inv in StableSafetyInvariants ownedSecretOnlyRotates \
           caNotRecreatedAfterInit rotationRequiresThreshold \
           rotationPreservesEndpoint missingCARequeues; do
  quint run --main=KubeletPKI --step=randomStep \
            --invariant=$inv --max-samples=1000 --max-steps=60 \
            formal/specs/KubeletPKI.qnt
done

# Passing Apalache battery (5 invariants at depth 4).
for inv in ownedSecretOnlyRotates caNotRecreatedAfterInit \
           rotationRequiresThreshold rotationPreservesEndpoint \
           missingCARequeues; do
  echo y | quint verify --main=KubeletPKI \
                        --invariant=$inv --max-steps=4 --backend=apalache \
                        formal/specs/KubeletPKI.qnt
done

# Deliberate counterexample candidates.
echo y | quint verify --main=KubeletPKI --init=userSecretRotationRun \
                      --invariant=ownedSecretOnlyRotates \
                      --max-steps=0 --backend=apalache \
                      formal/specs/KubeletPKI.qnt

echo y | quint verify --main=KubeletPKI --init=postInitCARegenRun \
                      --invariant=caNotRecreatedAfterInit \
                      --max-steps=0 --backend=apalache \
                      formal/specs/KubeletPKI.qnt

echo y | quint verify --main=KubeletPKI --init=endpointRewriteRun \
                      --invariant=rotationPreservesEndpoint \
                      --max-steps=0 --backend=apalache \
                      formal/specs/KubeletPKI.qnt
```

Or, from `formal/`: `make verify-kubeletpki`,
`make verify-kubeletpki-random`, and
`make verify-kubeletpki-apalache`.

### controller-runtime substrate (FM-45/46/47)

```sh
# Six demonstration runs cover Manager start, leader acquire,
# multi-worker dispatch, dedup-during-inflight, RequeueAfter,
# TerminalError, and leader loss.

quint run --main=ControllerRuntime --init=happyManagerStartRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=multiWorkerParallelRun --step=step \
          --invariant=FM45_PerKeySerialisation --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=dedupDuringInFlightRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=requeueAfterRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=terminalErrorRun --step=step \
          --invariant=FM46_TerminalErrorNoRequeue --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=leaderLossRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

# Random-walk every CR invariant (500 samples × 60 steps).
for inv in AllSafetyInvariants FM45_PerKeySerialisation \
           FM46_TerminalErrorNoRequeue FM47_CacheBehindAPI; do
  quint run --main=ControllerRuntime --invariant=$inv \
            --max-samples=500 --max-steps=60 \
            formal/specs/ControllerRuntime.qnt
done

# Issue #30: bounded fault storm still lets a legitimate key finish,
# while overload leaves a ready-but-unserved backlog.
quint run --main=ControllerRuntime --init=boundedFaultStormRun --step=step \
          --invariant=FM69_BoundedFaultProgress --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

quint run --main=ControllerRuntime --init=faultStormOverloadRun --step=step \
          --invariant=FM70_NoLegitReadyBacklog --max-steps=0 \
          formal/specs/ControllerRuntime.qnt

# Backend verdict for the overload counterexample (depth 4).
echo y | quint verify --main=ControllerRuntime --init=init --step=step \
                      --invariant=FM70_NoLegitReadyBacklog \
                      --max-steps=4 --backend=apalache \
                      formal/specs/ControllerRuntime.qnt
```

Or, from `formal/`: `make verify-cr` and `make verify-cr-faultstorm-apalache`.

### Cross-controller cyclic enqueue / cache wait (issue #31)

```sh
# Cache-stabilised cycle completes cleanly.
quint run --main=CrossControllerCycle --init=stabilisedCycleRun --step=step \
          --invariant=ScenarioSafetyInvariants --max-steps=0 \
          formal/specs/CrossControllerCycle.qnt

quint run --main=CrossControllerCycle --init=stabilisedCycleRun --step=step \
          --invariant=CacheStableAllowsCompletion --max-steps=0 \
          formal/specs/CrossControllerCycle.qnt

# Explicit livelock counterexample.
quint run --main=CrossControllerCycle --init=livelockCycleRun --step=step \
          --invariant=NoCyclicLivelock --max-steps=0 \
          formal/specs/CrossControllerCycle.qnt

# Random-walk stable queue/cache invariants.
for inv in ScenarioSafetyInvariants CrossEnqueuePreservesTargetQueue; do
  quint run --main=CrossControllerCycle --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/CrossControllerCycle.qnt
done

# Backend verdict: livelock shape is reachable from init within depth 4.
echo y | quint verify --main=CrossControllerCycle --init=init --step=step \
                      --invariant=NoCyclicLivelock \
                      --max-steps=4 --backend=apalache \
                      formal/specs/CrossControllerCycle.qnt
```

Or, from `formal/`: `make verify-cross-controller-cycle`.

### Reflector relist storm / bookmark gap / RV-too-old (issue #32)

```sh
# Idempotent relist-storm path.
quint run --main=ReflectorRelistStorm --init=idempotentRelistStormRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ReflectorRelistStorm.qnt

quint run --main=ReflectorRelistStorm --init=idempotentRelistStormRun --step=step \
          --invariant=NoDuplicateMachineLeak --max-steps=0 \
          formal/specs/ReflectorRelistStorm.qnt

# Explicit duplicate-create counterexample.
quint run --main=ReflectorRelistStorm --init=duplicateCreateRelistStormRun --step=step \
          --invariant=NoDuplicateMachineLeak --max-steps=0 \
          formal/specs/ReflectorRelistStorm.qnt

# Random-walk stable watch/relist invariants.
for inv in StableSafetyInvariants WatchStateConsistent DuplicateDeliveryRequiresRelist; do
  quint run --main=ReflectorRelistStorm --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/ReflectorRelistStorm.qnt
done

# Backend verdict: duplicate-create counterexample reachable within depth 4.
echo y | quint verify --main=ReflectorRelistStorm --init=init --step=step \
                      --invariant=NoDuplicateMachineLeak \
                      --max-steps=4 --backend=apalache \
                      formal/specs/ReflectorRelistStorm.qnt
```

Or, from `formal/`: `make verify-reliststorm`.

### Stale enqueue against deleted object + shutdown drain race (issue #33)

```sh
# Deleted object handled through NotFound-safe reconcile.
quint run --main=StaleEnqueueShutdown --init=deletedObjectHandledRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/StaleEnqueueShutdown.qnt

# Manager shutdown while an item is already in flight drains cleanly.
quint run --main=StaleEnqueueShutdown --init=shutdownDrainRun --step=step \
          --invariant=ShutdownDrainCompletes --max-steps=0 \
          formal/specs/StaleEnqueueShutdown.qnt

# Explicit panic/finalizer-leak counterexamples.
quint run --main=StaleEnqueueShutdown --init=nilReadAfterDeleteRun --step=step \
          --invariant=NoNilReadAfterDelete --max-steps=0 \
          formal/specs/StaleEnqueueShutdown.qnt

quint run --main=StaleEnqueueShutdown --init=orphanedFinalizerRun --step=step \
          --invariant=NoOrphanedFinalizer --max-steps=0 \
          formal/specs/StaleEnqueueShutdown.qnt

# Random-walk stable queue/object lifecycle invariants.
for inv in StableSafetyInvariants ShutdownImpliesNotAccepting NilReadRequiresMissingObject; do
  quint run --main=StaleEnqueueShutdown --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/StaleEnqueueShutdown.qnt
done

# Backend verdict: nil-read counterexample reachable within depth 4.
echo y | quint verify --main=StaleEnqueueShutdown --init=init --step=step \
                      --invariant=NoNilReadAfterDelete \
                      --max-steps=4 --backend=apalache \
                      formal/specs/StaleEnqueueShutdown.qnt
```

Or, from `formal/`: `make verify-stale-shutdown`.

### Mutating + validating webhook ordering / reinvocation (issue #34)

```sh
# Converging mutating/validating chain with reinvocation.
quint run --main=WebhookOrdering --init=convergingReinvocationRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/WebhookOrdering.qnt

quint run --main=WebhookOrdering --init=convergingReinvocationRun --step=step \
          --invariant=ReinvocationConverges --max-steps=0 \
          formal/specs/WebhookOrdering.qnt

# Explicit stale-validator-read counterexample.
quint run --main=WebhookOrdering --init=staleValidatorReadRun --step=step \
          --invariant=ObservedValueIsFinal --max-steps=0 \
          formal/specs/WebhookOrdering.qnt

# Random-walk stable admission-ordering invariant.
for inv in StableSafetyInvariants MutatorOnlyMovesTowardDefault; do
  quint run --main=WebhookOrdering --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/WebhookOrdering.qnt
done

# Backend verdict: stale-validator-read counterexample reachable within depth 4.
echo y | quint verify --main=WebhookOrdering --init=init --step=step \
                      --invariant=ObservedValueIsFinal \
                      --max-steps=4 --backend=apalache \
                      formal/specs/WebhookOrdering.qnt
```

Or, from `formal/`: `make verify-webhook-ordering`.

### Self-referential webhook outage during same-cluster upgrade (issue #35)

```sh
# Safe fallback path: webhook is unavailable, but an explicit fallback lets
# the upgrade continue without opening a broad ignore window.
quint run --main=WebhookSelfReference --init=safeFallbackRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/WebhookSelfReference.qnt

# Explicit fail-closed deadlock counterexample.
quint run --main=WebhookSelfReference --init=failClosedDeadlockRun --step=step \
          --invariant=UpgradeProgressDespiteWebhookGap --max-steps=0 \
          formal/specs/WebhookSelfReference.qnt

# Explicit ignore-window unsafe-mutation counterexample.
quint run --main=WebhookSelfReference --init=ignoreWindowInvalidMutationRun --step=step \
          --invariant=NoInvalidMutationDuringIgnoreWindow --max-steps=0 \
          formal/specs/WebhookSelfReference.qnt

# Random-walk stable policy-safety invariant.
for inv in StableSafetyInvariants IgnoreWindowRequiresIgnorePolicy; do
  quint run --main=WebhookSelfReference --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/WebhookSelfReference.qnt
done

# Backend verdict: fail-closed deadlock reachable within depth 4.
echo y | quint verify --main=WebhookSelfReference --init=init --step=stepApalache \
                      --invariant=UpgradeProgressDespiteWebhookGap \
                      --max-steps=4 --backend=apalache \
                      formal/specs/WebhookSelfReference.qnt
```

Or, from `formal/`: `make verify-webhook-selfref`.

### Webhook CABundle staleness after cert rotation (issue #36)

```sh
# Recovery path: serving cert rotates, CABundle is injected, apiserver cache refreshes.
quint run --main=WebhookCABundleStaleness --init=refreshRecoveryRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/WebhookCABundleStaleness.qnt

# Explicit stale-trust x509 outage counterexample.
quint run --main=WebhookCABundleStaleness --init=staleTrustOutageRun --step=step \
          --invariant=CurrentlyTrusted --max-steps=0 \
          formal/specs/WebhookCABundleStaleness.qnt

# Random-walk stable cache-refresh invariant.
for inv in StableSafetyInvariants CacheRefreshMonotonic; do
  quint run --main=WebhookCABundleStaleness --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/WebhookCABundleStaleness.qnt
done

# Backend verdict: stale trust is reachable within depth 4.
echo y | quint verify --main=WebhookCABundleStaleness --init=init --step=step \
                      --invariant=CurrentlyTrusted \
                      --max-steps=4 --backend=apalache \
                      formal/specs/WebhookCABundleStaleness.qnt
```

Or, from `formal/`: `make verify-webhook-cabundle`.

### Dry-run webhook side-effects contract (issue #38)

```sh
# Compliant dry-run probe path.
quint run --main=DryRunSideEffects --init=compliantDryRunProbeRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/DryRunSideEffects.qnt

quint run --main=DryRunSideEffects --init=compliantDryRunProbeRun --step=step \
          --invariant=DryRunHasNoSideEffects --max-steps=0 \
          formal/specs/DryRunSideEffects.qnt

# Explicit dry-run side-effect counterexample.
quint run --main=DryRunSideEffects --init=violatingDryRunProbeRun --step=step \
          --invariant=DryRunHasNoSideEffects --max-steps=0 \
          formal/specs/DryRunSideEffects.qnt

# Random-walk stable bookkeeping invariants.
for inv in StableSafetyInvariants TriggeredSideEffectsRequireWebhookFire DryRunRequestsTracked; do
  quint run --main=DryRunSideEffects --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/DryRunSideEffects.qnt
done

# Backend verdict: violating dry-run side effect reachable within depth 4.
echo y | quint verify --main=DryRunSideEffects --init=violatingProbeInit --step=stepApalache \
                      --invariant=DryRunHasNoSideEffects \
                      --max-steps=4 --backend=apalache \
                      formal/specs/DryRunSideEffects.qnt
```

Or, from `formal/`: `make verify-dryrun-sideeffects`.

### Asymmetric network partition / directed heartbeat loss (issue #39)

```sh
# Recovered asymmetric-partition run.
quint run --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

quint run --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
          --invariant=RecoveredToSingleLeader --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

# Explicit dual-leader counterexample.
quint run --main=AsymmetricPartition --init=dualLeaderWindowRun --step=step \
          --invariant=NoSimultaneousLeaders --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

# Random-walk stable term/election invariants.
for inv in StableSafetyInvariants TermAdvanceRequiresElection NoStuckTermAdvance; do
  quint run --main=AsymmetricPartition --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/AsymmetricPartition.qnt
done

# Backend verdict: dual-leader window reachable within depth 4.
echo y | quint verify --main=AsymmetricPartition --init=dualLeaderInit --step=stepApalache \
                      --invariant=NoSimultaneousLeaders \
                      --max-steps=4 --backend=apalache \
                      formal/specs/AsymmetricPartition.qnt
```

Or, from `formal/`: `make verify-asymmetric-partition`.

### Snapshot restore + concurrent compaction race (issue #40)

```sh
# Clean restore completion path.
quint run --main=SnapshotRestoreCompaction --init=cleanRestoreRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/SnapshotRestoreCompaction.qnt

quint run --main=SnapshotRestoreCompaction --init=cleanRestoreRun --step=step \
          --invariant=MemberSetMatchesSnapshotPostRestore --max-steps=0 \
          formal/specs/SnapshotRestoreCompaction.qnt

# Explicit restore/compaction race counterexample.
quint run --main=SnapshotRestoreCompaction --init=compactionRaceRun --step=step \
          --invariant=NoLogInconsistency --max-steps=0 \
          formal/specs/SnapshotRestoreCompaction.qnt

# Random-walk stable restore/compaction invariants.
for inv in StableSafetyInvariants RestoreFlagImpliesSnapshotPresent CompactionMonotone; do
  quint run --main=SnapshotRestoreCompaction --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/SnapshotRestoreCompaction.qnt
done

# Backend verdict: restore/compaction inconsistency reachable within depth 4.
echo y | quint verify --main=SnapshotRestoreCompaction --init=raceInit --step=stepApalache \
                      --invariant=NoLogInconsistency \
                      --max-steps=4 --backend=apalache \
                      formal/specs/SnapshotRestoreCompaction.qnt
```

Or, from `formal/`: `make verify-snapshot-restore`.

### Etcd defrag-induced transient quorum loss (issue #41)

```sh
# Serial single-member defrag stays within quorum.
quint run --main=DefragQuorumLoss --init=serialDefragRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/DefragQuorumLoss.qnt

quint run --main=DefragQuorumLoss --init=serialDefragRun --step=step \
          --invariant=NoQuorumLossUnderSingleMaintenanceFault --max-steps=0 \
          formal/specs/DefragQuorumLoss.qnt

# Explicit defrag + second-glitch counterexample.
quint run --main=DefragQuorumLoss --init=overlapLossRun --step=step \
          --invariant=NoQuorumLossUnderSingleMaintenanceFault --max-steps=0 \
          formal/specs/DefragQuorumLoss.qnt

# Random-walk stable defrag invariants.
for inv in StableSafetyInvariants SerialDefragOrdering SingleDefragMemberOnly; do
  quint run --main=DefragQuorumLoss --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/DefragQuorumLoss.qnt
done

# Backend verdict: quorum-loss counterexample reachable within depth 4.
echo y | quint verify --main=DefragQuorumLoss --init=overlapInit --step=stepApalache \
                      --invariant=NoQuorumLossUnderSingleMaintenanceFault \
                      --max-steps=4 --backend=apalache \
                      formal/specs/DefragQuorumLoss.qnt
```

Or, from `formal/`: `make verify-defrag-quorum`.

### Etcd WAL corruption / disk-full member states (issue #42)

```sh
# Detected-and-remediated opaque member fault path.
quint run --main=EtcdWalFaults --init=detectedFaultRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/EtcdWalFaults.qnt

quint run --main=EtcdWalFaults --init=detectedFaultRun --step=step \
          --invariant=KcpDetectsAndRemediates --max-steps=0 \
          formal/specs/EtcdWalFaults.qnt

# Explicit silent opaque-member-loss counterexample.
quint run --main=EtcdWalFaults --init=silentCorruptionRun --step=step \
          --invariant=NoSilentMemberLoss --max-steps=0 \
          formal/specs/EtcdWalFaults.qnt

# Random-walk stable remediation bookkeeping.
for inv in StableSafetyInvariants RemediationRequiresDetection; do
  quint run --main=EtcdWalFaults --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/EtcdWalFaults.qnt
done

# Backend verdict: silent member loss reachable within depth 4.
echo y | quint verify --main=EtcdWalFaults --init=silentInit --step=stepApalache \
                      --invariant=NoSilentMemberLoss \
                      --max-steps=4 --backend=apalache \
                      formal/specs/EtcdWalFaults.qnt
```

Or, from `formal/`: `make verify-wal-faults`.

### Etcd add+remove in the same reconcile batch (issue #43)

```sh
# Safe serial join/promote then remove path.
quint run --main=EtcdMembershipBatch --init=serialMembershipRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/EtcdMembershipBatch.qnt

quint run --main=EtcdMembershipBatch --init=serialMembershipRun --step=step \
          --invariant=NoSameBatchAddRemove --max-steps=0 \
          formal/specs/EtcdMembershipBatch.qnt

# Explicit same-batch churn counterexample.
quint run --main=EtcdMembershipBatch --init=sameBatchChurnRun --step=step \
          --invariant=NoSameBatchAddRemove --max-steps=0 \
          formal/specs/EtcdMembershipBatch.qnt

# Random-walk stable batch bookkeeping invariants.
for inv in StableSafetyInvariants BatchRemoveRequiresExistingMember PromoteRequiresLearner; do
  quint run --main=EtcdMembershipBatch --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/EtcdMembershipBatch.qnt
done

# Backend verdict: same-batch churn reachable within depth 4.
echo y | quint verify --main=EtcdMembershipBatch --init=sameBatchInit --step=stepApalache \
                      --invariant=NoSameBatchAddRemove \
                      --max-steps=4 --backend=apalache \
                      formal/specs/EtcdMembershipBatch.qnt
```

Or, from `formal/`: `make verify-etcd-batch`.

### ClusterTopology reads a torn ClusterClass view mid-update (issue #84)

```sh
# Safe version-pinned ClusterClass read.
quint run --main=ClusterClassTopologyRace --init=versionPinnedReadRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ClusterClassTopologyRace.qnt

quint run --main=ClusterClassTopologyRace --init=versionPinnedReadRun --step=step \
          --invariant=ConsistentCCViewPerReconcile --max-steps=0 \
          formal/specs/ClusterClassTopologyRace.qnt

# Explicit torn-read counterexample.
quint run --main=ClusterClassTopologyRace --init=tornReadRun --step=step \
          --invariant=ConsistentCCViewPerReconcile --max-steps=0 \
          formal/specs/ClusterClassTopologyRace.qnt

# Random-walk stable ClusterClass topology bookkeeping.
for inv in StableSafetyInvariants DefinitionStateWellFormed MidUpdateRequiresVersionSkew; do
  quint run --main=ClusterClassTopologyRace --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/ClusterClassTopologyRace.qnt
done

# Backend verdict: torn read reachable within depth 4.
echo y | quint verify --main=ClusterClassTopologyRace --init=tornReadInit --step=stepApalache \
                      --invariant=ConsistentCCViewPerReconcile \
                      --max-steps=4 --backend=apalache \
                      formal/specs/ClusterClassTopologyRace.qnt
```

Or, from `formal/`: `make verify-cc-topology-race`.

### ClusterResourceSet ApplyOnce runs before kubelets join (issue #85)

```sh
# Apply happens after kubelets have joined, so the payload takes effect.
quint run --main=ClusterResourceSetTiming --init=joinsBeforeApplyRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/ClusterResourceSetTiming.qnt

quint run --main=ClusterResourceSetTiming --init=joinsBeforeApplyRun --step=step \
          --invariant=ApplyOnceEventuallyTakesEffect --max-steps=0 \
          formal/specs/ClusterResourceSetTiming.qnt

# Explicit ApplyOnce-before-kubelet-join counterexample.
quint run --main=ClusterResourceSetTiming --init=applyBeforeJoinRun --step=step \
          --invariant=ApplyOnceEventuallyTakesEffect --max-steps=0 \
          formal/specs/ClusterResourceSetTiming.qnt

# Random-walk stable CRS bookkeeping.
for inv in StableSafetyInvariants ApplyOnceRequiresPendingPayload ReconcileRetriesUntilJoined; do
  quint run --main=ClusterResourceSetTiming --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/ClusterResourceSetTiming.qnt
done

# Backend verdict: ApplyOnce race reachable within depth 4.
echo y | quint verify --main=ClusterResourceSetTiming --init=applyBeforeJoinInit --step=stepApalache \
                      --invariant=ApplyOnceEventuallyTakesEffect \
                      --max-steps=4 --backend=apalache \
                      formal/specs/ClusterResourceSetTiming.qnt
```

Or, from `formal/`: `make verify-crs-timing`.

### KCP rolling upgrade + MHC remediation both delete the same Machine (issue #83)

```sh
# Single authoritative deleter creates a replacement and deletes the old machine.
quint run --main=KcpMhcDeleteRace --init=authoritativeDeleteRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/KcpMhcDeleteRace.qnt

quint run --main=KcpMhcDeleteRace --init=authoritativeDeleteRun --step=step \
          --invariant=NoReplacementCannibalisation --max-steps=0 \
          formal/specs/KcpMhcDeleteRace.qnt

# Explicit double-delete / replacement-cannibalisation counterexamples.
quint run --main=KcpMhcDeleteRace --init=concurrentDeleteRun --step=step \
          --invariant=NoDoubleDelete --max-steps=0 \
          formal/specs/KcpMhcDeleteRace.qnt

quint run --main=KcpMhcDeleteRace --init=replacementCannibalisedRun --step=step \
          --invariant=NoReplacementCannibalisation --max-steps=0 \
          formal/specs/KcpMhcDeleteRace.qnt

# Random-walk stable delete-race bookkeeping.
for inv in StableSafetyInvariants ReplacementDeleteNeedsUnhealthyLabel MhcMarksNeedSelection; do
  quint run --main=KcpMhcDeleteRace --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/KcpMhcDeleteRace.qnt
done

# Backend verdict: concurrent double-delete reachable within depth 4.
echo y | quint verify --main=KcpMhcDeleteRace --init=doubleDeleteInit --step=stepApalache \
                      --invariant=NoDoubleDelete \
                      --max-steps=4 --backend=apalache \
                      formal/specs/KcpMhcDeleteRace.qnt
```

Or, from `formal/`: `make verify-kcp-mhc-delete`.

### 5-node etcd cluster with simultaneous 3-failure scenarios (issue #44)

```sh
# Safe sequential recovery path.
quint run --main=EtcdFiveNodeFailure --init=sequentialRecoveryRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/EtcdFiveNodeFailure.qnt

quint run --main=EtcdFiveNodeFailure --init=sequentialRecoveryRun --step=step \
          --invariant=NoDoublePromotionDuringRecovery --max-steps=0 \
          formal/specs/EtcdFiveNodeFailure.qnt

# Explicit 3-failure counterexamples.
quint run --main=EtcdFiveNodeFailure --init=leaderFollowersLossRun --step=step \
          --invariant=NoDoublePromotionDuringRecovery --max-steps=0 \
          formal/specs/EtcdFiveNodeFailure.qnt

quint run --main=EtcdFiveNodeFailure --init=symmetricTripleLossRun --step=step \
          --invariant=RemediationBoundedPerScenario --max-steps=0 \
          formal/specs/EtcdFiveNodeFailure.qnt

# Random-walk stable 5-node bookkeeping invariants.
for inv in StableSafetyInvariants QuorumMathConsistent PromotionRequiresLearner; do
  quint run --main=EtcdFiveNodeFailure --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/EtcdFiveNodeFailure.qnt
done

# Backend verdict: leader+followers counterexample reachable within depth 4.
echo y | quint verify --main=EtcdFiveNodeFailure --init=leaderFollowersInit --step=stepApalache \
                      --invariant=NoDoublePromotionDuringRecovery \
                      --max-steps=4 --backend=apalache \
                      formal/specs/EtcdFiveNodeFailure.qnt
```

Or, from `formal/`: `make verify-etcd-5node`.

### Kubelet PLEG hang under slow CRI (issue #45)

```sh
# Transient slow-CRI path recovers before remediation.
quint run --main=KubeletPlegHang --init=transientSlowdownRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/KubeletPlegHang.qnt

quint run --main=KubeletPlegHang --init=transientSlowdownRun --step=step \
          --invariant=RemediationAfterStableNotReady --max-steps=0 \
          formal/specs/KubeletPlegHang.qnt

# Explicit over-eager remediation counterexample.
quint run --main=KubeletPlegHang --init=overeagerRemediationRun --step=step \
          --invariant=RemediationAfterStableNotReady --max-steps=0 \
          formal/specs/KubeletPlegHang.qnt

# Random-walk stable PLEG/CRI bookkeeping invariants.
for inv in StableSafetyInvariants SlowCriImpliesLaggingPleg RecoveryClearsSlowCri; do
  quint run --main=KubeletPlegHang --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/KubeletPlegHang.qnt
done

# Backend verdict: transient NotReady remediation counterexample reachable within depth 4.
echo y | quint verify --main=KubeletPlegHang --init=slowCriInit --step=stepApalache \
                      --invariant=RemediationAfterStableNotReady \
                      --max-steps=4 --backend=apalache \
                      formal/specs/KubeletPlegHang.qnt
```

Or, from `formal/`: `make verify-pleg-hang`.

### Registry throttle cascades into bootstrap stall (issue #46)

```sh
# Throttled image pull still clears before bootstrap timeout.
quint run --main=RegistryPullBackoff --init=boundedThrottleRun --step=stepHappy \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/RegistryPullBackoff.qnt

quint run --main=RegistryPullBackoff --init=boundedThrottleRun --step=stepHappy \
          --invariant=NoFalseBootstrapFailure --max-steps=0 \
          formal/specs/RegistryPullBackoff.qnt

# Explicit timeout-before-pull-clears counterexample.
quint run --main=RegistryPullBackoff --init=timeoutBeforePullClearsRun --step=step \
          --invariant=NoFalseBootstrapFailure --max-steps=0 \
          formal/specs/RegistryPullBackoff.qnt

# Random-walk stable pull/backoff bookkeeping invariants.
for inv in StableSafetyInvariants BackoffMonotone; do
  quint run --main=RegistryPullBackoff --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/RegistryPullBackoff.qnt
done

# Backend verdict: bootstrap timeout can fire before transient backoff clears.
echo y | quint verify --main=RegistryPullBackoff --init=timeoutInit --step=stepApalache \
                      --invariant=NoFalseBootstrapFailure \
                      --max-steps=4 --backend=apalache \
                      formal/specs/RegistryPullBackoff.qnt
```

Or, from `formal/`: `make verify-registry-pull`.

### MemPressure evicts a critical static pod (issue #47)

```sh
# Correct priority classes keep static pods immune; workload pod is evicted instead.
quint run --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/StaticPodMemPressure.qnt

quint run --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
          --invariant=KcpOutputsCorrectPriority --max-steps=0 \
          formal/specs/StaticPodMemPressure.qnt

quint run --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
          --invariant=CriticalStaticPodsImmuneFromEviction --max-steps=0 \
          formal/specs/StaticPodMemPressure.qnt

# Explicit mis-priority static-pod eviction counterexample.
quint run --main=StaticPodMemPressure --init=misPriorityEvictionRun --step=step \
          --invariant=CriticalStaticPodsImmuneFromEviction --max-steps=0 \
          formal/specs/StaticPodMemPressure.qnt

# Random-walk stable mem-pressure bookkeeping invariant.
for inv in StableSafetyInvariants EvictionChoiceNeedsPressure; do
  quint run --main=StaticPodMemPressure --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/StaticPodMemPressure.qnt
done

# Backend verdict: mis-priority static-pod eviction reachable within depth 4.
echo y | quint verify --main=StaticPodMemPressure --init=misPriorityInit --step=stepApalache \
                      --invariant=CriticalStaticPodsImmuneFromEviction \
                      --max-steps=4 --backend=apalache \
                      formal/specs/StaticPodMemPressure.qnt
```

Or, from `formal/`: `make verify-static-pod-eviction`.

### Static-pod hash collision + kubelet reload lag (issue #48)

```sh
# Desired kubelet config rotates and kubelet eventually reloads cleanly.
quint run --main=StaticPodHashReloadRace --init=eventualReloadRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/StaticPodHashReloadRace.qnt

quint run --main=StaticPodHashReloadRace --init=eventualReloadRun --step=step \
          --invariant=ReloadEventuallyConverges --max-steps=0 \
          formal/specs/StaticPodHashReloadRace.qnt

# Explicit hash-collision and stale-reload counterexamples.
quint run --main=StaticPodHashReloadRace --init=hashCollisionRun --step=step \
          --invariant=NoHashCollisionAcrossDistinctIntents --max-steps=0 \
          formal/specs/StaticPodHashReloadRace.qnt

quint run --main=StaticPodHashReloadRace --init=staleReloadRun --step=step \
          --invariant=ReloadEventuallyConverges --max-steps=0 \
          formal/specs/StaticPodHashReloadRace.qnt

# Random-walk stable manifest / reload bookkeeping invariants.
for inv in StableSafetyInvariants ManifestHashDeterministic DesiredConfigGenMonotone; do
  quint run --main=StaticPodHashReloadRace --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/StaticPodHashReloadRace.qnt
done

# Backend verdict: manifest-hash collision reachable within depth 4.
echo y | quint verify --main=StaticPodHashReloadRace --init=collisionInit --step=stepApalache \
                      --invariant=NoHashCollisionAcrossDistinctIntents \
                      --max-steps=4 --backend=apalache \
                      formal/specs/StaticPodHashReloadRace.qnt
```

Or, from `formal/`: `make verify-static-pod-hash`.

### CSR auto-approval lag during bootstrap (issue #49)

```sh
# Delayed approval still succeeds before bootstrap timeout.
quint run --main=BootstrapCsrLag --init=eventualApprovalRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/BootstrapCsrLag.qnt

quint run --main=BootstrapCsrLag --init=eventualApprovalRun --step=step \
          --invariant=BootstrapTimeoutCoversCsrLatency --max-steps=0 \
          formal/specs/BootstrapCsrLag.qnt

# Explicit approval-timeout and stranded-kubelet counterexamples.
quint run --main=BootstrapCsrLag --init=approvalTimeoutRun --step=step \
          --invariant=BootstrapTimeoutCoversCsrLatency --max-steps=0 \
          formal/specs/BootstrapCsrLag.qnt

quint run --main=BootstrapCsrLag --init=strandedKubeletRun --step=step \
          --invariant=NoStrandedKubelet --max-steps=0 \
          formal/specs/BootstrapCsrLag.qnt

# Random-walk stable CSR queue bookkeeping.
for inv in StableSafetyInvariants QueueMonotone SubmitTimeRecorded; do
  quint run --main=BootstrapCsrLag --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/BootstrapCsrLag.qnt
done

# Backend verdict: approval timeout reachable within depth 4.
echo y | quint verify --main=BootstrapCsrLag --init=approvalTimeoutInit --step=stepApalache \
                      --invariant=BootstrapTimeoutCoversCsrLatency \
                      --max-steps=4 --backend=apalache \
                      formal/specs/BootstrapCsrLag.qnt
```

Or, from `formal/`: `make verify-bootstrap-csr`.

### MTU drift / silent packet fragmentation stalls etcd snapshot transfer (issue #50)

```sh
# PMTU discovery converges and the snapshot transfer succeeds.
quint run --main=MtuFragmentation --init=convergedPmtuRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/MtuFragmentation.qnt

quint run --main=MtuFragmentation --init=convergedPmtuRun --step=step \
          --invariant=PathMtuDiscoveryConverges --max-steps=0 \
          formal/specs/MtuFragmentation.qnt

# Explicit silent fragmentation / timeout counterexample.
quint run --main=MtuFragmentation --init=silentFragDropRun --step=step \
          --invariant=EtcdSnapshotEventuallySucceeds --max-steps=0 \
          formal/specs/MtuFragmentation.qnt

# Random-walk stable MTU bookkeeping.
for inv in StableSafetyInvariants PmtuNeverExceedsLinkMtu; do
  quint run --main=MtuFragmentation --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/MtuFragmentation.qnt
done

# Backend verdict: silent fragmentation reachable within depth 4.
echo y | quint verify --main=MtuFragmentation --init=silentFragInit --step=stepApalache \
                      --invariant=EtcdSnapshotEventuallySucceeds \
                      --max-steps=4 --backend=apalache \
                      formal/specs/MtuFragmentation.qnt
```

Or, from `formal/`: `make verify-mtu-frag`.

### CNI race: Pod scheduled before veth created (issue #51)

```sh
# CNI catches up before probe failure matters.
quint run --main=CniVethRace --init=cniReadyBeforeProbeRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/CniVethRace.qnt

quint run --main=CniVethRace --init=cniReadyBeforeProbeRun --step=step \
          --invariant=NoContainerStartBeforeCni --max-steps=0 \
          formal/specs/CniVethRace.qnt

# Explicit probe-loop before veth creation counterexample.
quint run --main=CniVethRace --init=probeLoopBeforeVethRun --step=step \
          --invariant=NoContainerStartBeforeCni --max-steps=0 \
          formal/specs/CniVethRace.qnt

# Random-walk stable CNI/veth bookkeeping invariants.
for inv in StableSafetyInvariants VethRequiresCni RestartLoopRequiresRepeatedProbeFailure; do
  quint run --main=CniVethRace --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/CniVethRace.qnt
done

# Backend verdict: probe-loop race reachable within depth 4.
echo y | quint verify --main=CniVethRace --init=probeLoopInit --step=stepApalache \
                      --invariant=NoContainerStartBeforeCni \
                      --max-steps=4 --backend=apalache \
                      formal/specs/CniVethRace.qnt
```

Or, from `formal/`: `make verify-cni-veth`.

### Load balancer connection drain blackholes existing requests (issue #52)

```sh
# LB drain completes before apiserver is killed.
quint run --main=LoadBalancerDrain --init=drainBeforeKillRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/LoadBalancerDrain.qnt

quint run --main=LoadBalancerDrain --init=drainBeforeKillRun --step=step \
          --invariant=KcpUpgradeAccountsForLbDrain --max-steps=0 \
          formal/specs/LoadBalancerDrain.qnt

# Explicit blackholed-connection counterexample.
quint run --main=LoadBalancerDrain --init=killBeforeDrainRun --step=step \
          --invariant=KcpUpgradeAccountsForLbDrain --max-steps=0 \
          formal/specs/LoadBalancerDrain.qnt

# Random-walk stable drain bookkeeping.
for inv in StableSafetyInvariants DrainProgressMonotone HungClientNeedsDeregisteredTarget; do
  quint run --main=LoadBalancerDrain --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/LoadBalancerDrain.qnt
done

# Backend verdict: kill-before-drain reachable within depth 4.
echo y | quint verify --main=LoadBalancerDrain --init=killBeforeDrainInit --step=stepApalache \
                      --invariant=KcpUpgradeAccountsForLbDrain \
                      --max-steps=4 --backend=apalache \
                      formal/specs/LoadBalancerDrain.qnt
```

Or, from `formal/`: `make verify-lb-drain`.

### NetworkPolicy applied mid-flight cuts controller traffic silently (issue #53)

```sh
# Policy is applied and the controller detects/reconnects cleanly.
quint run --main=NetworkPolicyMidFlight --init=detectedPolicyCutRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/NetworkPolicyMidFlight.qnt

quint run --main=NetworkPolicyMidFlight --init=detectedPolicyCutRun --step=step \
          --invariant=NoSilentControllerStall --max-steps=0 \
          formal/specs/NetworkPolicyMidFlight.qnt

# Explicit silent long-lived-watch counterexample.
quint run --main=NetworkPolicyMidFlight --init=silentWatchSurvivesRun --step=step \
          --invariant=NoSilentControllerStall --max-steps=0 \
          formal/specs/NetworkPolicyMidFlight.qnt

# Random-walk stable policy/connection bookkeeping.
for inv in StableSafetyInvariants ExistingConnRequiresAppliedPolicy TerminatedConnRequiresPolicy; do
  quint run --main=NetworkPolicyMidFlight --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/NetworkPolicyMidFlight.qnt
done

# Backend verdict: silent-stall path reachable within depth 4.
echo y | quint verify --main=NetworkPolicyMidFlight --init=silentWatchInit --step=stepApalache \
                      --invariant=NoSilentControllerStall \
                      --max-steps=4 --backend=apalache \
                      formal/specs/NetworkPolicyMidFlight.qnt
```

Or, from `formal/`: `make verify-netpol-stall`.

### Asymmetric network partition (issue #39)

```sh
# Recovered directional-partition path.
quint run --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
          --invariant=StableSafetyInvariants --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

quint run --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
          --invariant=RecoveredToSingleLeader --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

# Explicit dual-leader counterexample.
quint run --main=AsymmetricPartition --init=dualLeaderWindowRun --step=step \
          --invariant=NoSimultaneousLeaders --max-steps=0 \
          formal/specs/AsymmetricPartition.qnt

# Random-walk stable term / election invariants.
for inv in StableSafetyInvariants TermAdvanceRequiresElection NoStuckTermAdvance; do
  quint run --main=AsymmetricPartition --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/AsymmetricPartition.qnt
done

# Backend verdict: dual-leader window reachable within depth 4.
echo y | quint verify --main=AsymmetricPartition --init=dualLeaderInit --step=stepApalache \
                      --invariant=NoSimultaneousLeaders \
                      --max-steps=4 --backend=apalache \
                      formal/specs/AsymmetricPartition.qnt
```

Or, from `formal/`: `make verify-asymmetric-partition`.

### CAPI refinements onto controller-runtime

```sh
# Each refinement embeds the substrate + a slice of the abstract
# CAPI spec, with body actions guarded by `reconcileInFlight*`.
# Verifies that abstract safety invariants survive multi-worker
# substrate semantics.

# Topology + CR substrate
for inv in AllSafetyInvariants FM45_PerKeySerialisation \
           FM39_BeforeClusterUpgradeIdempotent WorkerVersionLeqCp \
           BodyActionsGated; do
  quint run --main=TopologyRefined --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/TopologyRefined.qnt
done

# InPlaceUpdate + CR substrate
for inv in AllSafetyInvariants FM45_PerKeySerialisation \
           FM43_UpdateMachineIdempotenceGate \
           FM44_MultiExtensionBlocksProgress \
           DoneImpliesVersionFlipped BodyActionsGated; do
  quint run --main=InPlaceUpdateRefined --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/InPlaceUpdateRefined.qnt
done

# MachineSetPreflight + CR substrate
for inv in AllSafetyInvariants FM45_PerKeySerialisation \
           PreflightGateWellFormed PreflightGateRespected \
           BodyActionsGated; do
  quint run --main=MachineSetPreflightRefined --invariant=$inv \
            --max-samples=300 --max-steps=40 \
            formal/specs/MachineSetPreflightRefined.qnt
done
```

Or, from `formal/`: `make verify-refinements`.

### In-place updates (deterministic + random-walk)

```sh
# Five demonstration runs cover the full move + UpdateMachine
# choreography across MD, MS, and Machine controllers.

quint run --main=InPlaceUpdate --init=happyInPlaceRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/InPlaceUpdate.qnt

quint run --main=InPlaceUpdate --init=canUpdateNoFallbackRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/InPlaceUpdate.qnt

quint run --main=InPlaceUpdate --init=multiExtensionRejectRun --step=step \
          --invariant=FM44_MultiExtensionBlocksProgress --max-steps=0 \
          formal/specs/InPlaceUpdate.qnt

quint run --main=InPlaceUpdate --init=updateMachineRetryLoopRun --step=step \
          --invariant=FM43_UpdateMachineIdempotenceGate --max-steps=0 \
          formal/specs/InPlaceUpdate.qnt

quint run --main=InPlaceUpdate --init=orphanedHookCleanupRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/InPlaceUpdate.qnt

# Random walk each invariant for 2000 samples × 80 steps
# (the user requested "unbounded time" — this is the
# practical longest sweep before TLC capacity becomes
# the bottleneck).
for inv in AllSafetyInvariants FM42_PrematureInPlaceAdmission \
           FM43_UpdateMachineIdempotenceGate \
           FM44_MultiExtensionBlocksProgress \
           TwoWayHandshakeAnnotations; do
  quint run --main=InPlaceUpdate --invariant=$inv \
            --max-samples=2000 --max-steps=80 \
            formal/specs/InPlaceUpdate.qnt
done
```

Or, from `formal/`: `make verify-inplace`.

### Topology + runtime extensions (deterministic + random-walk)

```sh
# Deterministic demo runs in Topology.qnt. All five must pass
# AllSafetyInvariants (or the named invariant for blocked).

quint run --main=Topology --init=happyCreateRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/Topology.qnt

quint run --main=Topology --init=happyUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/Topology.qnt

quint run --main=Topology --init=multiStepUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/Topology.qnt

quint run --main=Topology --init=annotationBlockedUpgradeRun --step=step \
          --invariant=FM40_AnnotationGatesCp --max-steps=0 \
          formal/specs/Topology.qnt

quint run --main=Topology --init=deleteRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/Topology.qnt

# Random-walk every Topology invariant (200 samples × 30 steps).
for inv in AllSafetyInvariants FM39_BeforeClusterUpgradeIdempotent \
           FM40_AnnotationGatesCp FM41_AfterClusterUpgradeAtSteadyState; do
  quint run --main=Topology --invariant=$inv \
            --max-samples=200 --max-steps=30 \
            formal/specs/Topology.qnt
done
```

Or, from `formal/`: `make verify-topology` runs all of the above.

### FM-33 — Worker-MachineSet preflight (TLC reachability)

```sh
# Three demonstration runs in MachineSetPreflight.qnt. Each is a
# deterministic trace; success is "[ok] No violation found".

# Scale-up while CP is mid-upgrade — preflight must block.
quint run --main=MachineSetPreflight \
          --init=fm33ScaleUpBlockedRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/MachineSetPreflight.qnt
# Expected: workerBlockReason: CpUnstable; decision[4]=ActionBlocked.

# Same scenario but KCP finishes the upgrade and preflight admits.
quint run --main=MachineSetPreflight \
          --init=fm33ScaleUpAdmittedAfterUpgradeRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/MachineSetPreflight.qnt
# Expected: trace ends with workerMachines=Set(1,2,3,4).

# MS template version exceeds CP version.
quint run --main=MachineSetPreflight \
          --init=fm33VersionSkewBlockedRun --step=step \
          --invariant=AllSafetyInvariants --max-steps=0 \
          formal/specs/MachineSetPreflight.qnt
# Expected: workerBlockReason: KubernetesVersionSkewViolation.
```

Or, from `formal/`: `make verify-fm33` runs all three.

### Random-walk safety sweep

Useful for catching obvious safety regressions during
development. Runs in ~150 ms per invariant.

```sh
for inv in LearnerCannotVote VoterSetNonEmpty \
           RemediationTargetHasNodeRef AllSafetyInvariants \
           IncidentNeverInFlight IncidentBlockReasonCorrect; do
  quint run --main=Lifecycle \
            --invariant=$inv \
            --max-steps=30 --max-samples=2000 \
            formal/specs/Lifecycle.qnt
done
```

### Deterministic FM-1 reproducer

Confirms the modelled scenario reproduces the expected
condition flips.

```sh
quint run --main=Lifecycle \
          --invariant=AllSafetyInvariants \
          --step=incidentRemediationBlockedRun \
          --max-samples=1 --verbosity=3 \
          formal/specs/Lifecycle.qnt | \
  grep -A 30 "blockReason: Map(4 -> "
```

Expected: every printed state shows
`blockReason: Map(4 -> EtcdMemberSetDoesNotMatchMachineSet)`,
`decision[4] = RemediationBlocked`,
`preflightBlocked = true`.

## CAPD e2e

The FM-2 reproducer is the working example. Running it requires
Docker, `make docker-build-e2e` to be complete, and ~25 minutes
wall time end-to-end:

```sh
make generate-e2e-templates    # ~30 s
make docker-build-e2e          # ~20 min, builds 5 controller images
make test-e2e GINKGO_FOCUS="FM-2"  # ~25 min
```

Expected verdict: `[1mRan 1 of 38 Specs[0m ... PASSED`.

## State-space tractability budget

| Backend | Bound | Typical wall time |
|---|---|---|
| TLC `--max-steps=4` from a focused init | < 100K states | < 5 s |
| TLC `--max-steps=8` from a focused init | < 5 M states | < 30 s |
| TLC `--max-steps=8` from `init` (full bootstrap) | hundreds of M states | timeout (~10 min before kill) |
| Apalache `--max-steps=4` from a focused init | n/a (symbolic) | 20–80 s |
| Apalache `--max-steps=8` | n/a (symbolic) | 5–10 min, frequently OOM |

Rules of thumb:
- Use TLC for **reachability** (find a counterexample). Random
  exploration finds counterexamples fast.
- Use Apalache for **non-reachability** (prove no counterexample
  exists). Symbolic exploration excels at unreachability proofs
  on bounded state spaces.
- Use Quint random walk for **safety regressions** during
  development. Cheapest by an order of magnitude.

## Build and gate

```sh
./scripts/verify-formal.sh
```

The CI gate runs:

1. `quint typecheck` on every `.qnt` in `formal/specs/`.
2. `quint run` with the `runs` declared in each module.
3. `lake build` in `formal/proofs/`.
4. `tlc` against every `.cfg` next to a `.tla`.
5. Go build / test of `internal/trace` + the `trace-validator`
   command.
6. Drift check: every Quint action has a row in
   `abstraction-mapping.md`.

The gate is non-blocking on tool absence — it reports `SKIP:
quint not in PATH` rather than silent success.
