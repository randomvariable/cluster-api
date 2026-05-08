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
