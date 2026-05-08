# AGENTS — machine-readable summary for LLM agents

This document gives an LLM agent a structured view of the
`formal/` subtree so it can drive verifications, add failure
modes, and update contracts without re-reading the human docs.

The human docs are at:
- [`tutorial.md`](./tutorial.md) — first-time reproduction
- [`how-to.md`](./how-to.md) — recipes
- [`reference.md`](./reference.md) — exhaustive listing
- [`explanation.md`](./explanation.md) — design rationale

## Schema for an agent run

```yaml
goal: <verify-fm | add-fm | refresh-lsp-anchors | run-fairness-witness>
preconditions:
  - cwd: formal/
  - tools_required: [quint, tlc, apalache, python3]
postconditions:
  - exit_code: 0
  - artifacts: <list of files modified>
```

## Capabilities

### Sanity & meta

| Capability | Make target | Underlying command | Expected output marker |
|---|---|---|---|
| Sanity gate | `make verify` | `verify-formal.sh` | `All formal-subtree checks passed.` |
| Regenerate fairness | `make fairness-gen` | `python3 hack/tools/quint-fairness-gen.py` | snippet at `/tmp/fairness-snippet.qnt` |
| List Go LSP anchors | `make lsp-list` | `grep -oE …` | newline-separated paths |

### KCP control plane (Lifecycle.qnt)

| Capability | Make target | Underlying command | Expected output marker |
|---|---|---|---|
| Verify FM-N reachability | `make verify-fmN` | `quint verify --backend=tlc --invariant='not(HealthyControlPlane)'` | `[violation] Found an issue` (good — recovery is reachable) |
| Verify FM-N hopelessness | (Apalache) `make verify-fmN` | `quint verify --backend=apalache --invariant='not(HealthyControlPlane)' --step=stepNoRecovery` | `[ok] No violation found` (good — hopeless without recovery) |
| Verify IC-11 recovery | `make verify-ic11` | `quint run` deterministic | `[violation]` (HealthyControlPlane reached) |
| Run fairness witness | `make verify-fm9-witness` | `quint run --init=fairConvergenceWitnessRun` | `[ok] No violation found` |
| Self-hosted deadlock | `make verify-selfhosted-deadlock` | `quint run --invariant='not(Deadlocked)'` | `[violation]` (Deadlocked reached) |
| Self-hosted recovery | `make verify-selfhosted-recovery` | `quint run` | `[ok]` |

### MachineSet preflight (FM-33, MachineSetPreflight.qnt)

| Capability | Make target | Expected output marker |
|---|---|---|
| FM-33 blocked | `make verify-fm33-blocked` | `[ok]` |
| FM-33 admitted-after-upgrade | `make verify-fm33-admitted-after-upgrade` | `[ok]` |
| FM-33 version-skew | `make verify-fm33-versionskew` | `[ok]` |
| FM-33 aggregate | `make verify-fm33` | `[ok]` × 3 |

### ClusterTopology + runtime extensions (FM-39/40/41, Topology.qnt)

| Capability | Make target | Expected output marker |
|---|---|---|
| Topology happy create | `make verify-topology-create` | `[ok]` |
| Topology single upgrade | `make verify-topology-upgrade` | `[ok]` |
| Topology multi-step upgrade | `make verify-topology-multistep` | `[ok]` |
| Topology blocked-by-annotation | `make verify-topology-blocked` | `[ok]` |
| Topology delete path | `make verify-topology-delete` | `[ok]` |
| Topology random walk | `make verify-topology-random` | `[ok]` × 4 |
| Topology aggregate | `make verify-topology` | end-to-end |

### In-place updates (FM-42/43/44, InPlaceUpdate.qnt)

| Capability | Make target | Expected output marker |
|---|---|---|
| Happy in-place | `make verify-inplace-happy` | `[ok]` |
| Fallback to rolling | `make verify-inplace-fallback` | `[ok]` |
| Multi-extension reject | `make verify-inplace-multi-ext` | `[ok]` |
| Idempotence retry | `make verify-inplace-retry` | `[ok]` |
| Cleanup orphaned hook | `make verify-inplace-cleanup` | `[ok]` |
| Random walk (2000×80) | `make verify-inplace-random` | `[ok]` × 5 |
| Aggregate | `make verify-inplace` | end-to-end |

### controller-runtime substrate (FM-45/46/47, ControllerRuntime.qnt)

| Capability | Make target | Expected output marker |
|---|---|---|
| Manager start | `make verify-cr-happy` | `[ok]` |
| Multi-worker dispatch | `make verify-cr-multiworker` | `[ok]` |
| Dedup-during-inflight | `make verify-cr-dedup` | `[ok]` |
| RequeueAfter loop | `make verify-cr-requeue` | `[ok]` |
| TerminalError no-requeue | `make verify-cr-terminal` | `[ok]` |
| Leader loss | `make verify-cr-leader-loss` | `[ok]` |
| Random walk (500×60) | `make verify-cr-random` | `[ok]` × 4 |
| Aggregate | `make verify-cr` | end-to-end |

### Refinements (Layer 2)

| Capability | Make target |
|---|---|
| TopologyRefined random walk | `make verify-topology-refined` |
| InPlaceUpdateRefined random walk | `make verify-inplace-refined` |
| MachineSetPreflightRefined random walk | `make verify-mspreflight-refined` |
| Aggregate | `make verify-refinements` |

### End-to-end cluster lifecycle (FM-48/49/50, ClusterE2E.qnt)

| Capability | Make target | Expected output marker |
|---|---|---|
| Bring-up to Stable | `make verify-e2e-bringup` | `[ok]` |
| Rolling upgrade | `make verify-e2e-rolling` | `[ok]` |
| In-place upgrade | `make verify-e2e-inplace` | `[ok]` |
| Random walk (300×60) | `make verify-e2e-random` | `[ok]` × 12 |
| Aggregate | `make verify-e2e` | end-to-end |

## Failure-mode catalogue (one row per FM)

| FM | Class | Init action | Recovery sequence | Verdict |
|---|---|---|---|---|
| 1 | KCP-BUG | `incidentInit` | `RemoveStuckLearner → DeleteFailedMachine → AddMachine` | TLC: 6.5K states from incidentInit |
| 2 | EXOGENOUS | `twoMachineBothUnhealthyInit` | `HealEtcdReachability` | Apalache: hopelessness proven (~80s); CAPD e2e PASSES |
| 3 | EXOGENOUS | `partitionedClusterInit` | `HealEtcdReachability` | Apalache: hopelessness proven |
| 4 | TRANSIENT | `nodeRefDelayScenario` (run) | `ResolveNodeRef` | TLC: self-resolving |
| 5 | KCP-BUG (latent) | `noCorrespondingMemberInit` | `DeleteFailedMachine` | TLC: 165K states |
| 6 | TRANSIENT | `leaderVacancyScenario` (run) | `ElectLeader` | TLC: self-resolving |
| 7 | TRANSIENT | `cascadingRemediationScenario` (run) | sequential `CompleteRemediation` | TLC: serialised |
| 8 | KCP-BUG | counterexample to `InformativenessObligation` | (projection rewrite) | Quint counterexample |
| 9 | MODEL-INCOMPLETE | n/a | `weakFair(step)` → per-action fair (Phase 11b) | TLC: tautology (capacity-limited; see Phase 11c) |
| 10 | TRANSIENT | `staleHealthRollupScenario` (run) | `MachineHealthChange` | TLC: races resolve |
| 11 | KCP-BUG (latent) | `invalidKubeletInit` | MHC + remediation | TLC: 18.4K states |
| 12 | KCP-BUG (latent) | `slowStorageEtcdJoinInit` | `DeleteFailedMachine` | TLC: 3.5K states |
| 13 | EXOGENOUS | `lbBrokenInit` | `HealLb + HealEtcdReachability` | Apalache: hopelessness proven |
| 14 | KCP-BUG (latent) | `nodeNeverJoinsInit` | `RestoreNodeReachability + remediation` | TLC: 25K states |
| 15 | TRANSIENT | `upgradeInFlightInit` | rolling update completes | TLC: 2.8M states at depth 8 |
| 16 | EXOGENOUS | `singleNodeLostVoterInit` | `RestoreClusterFromSnapshot` | Apalache: hopelessness proven |
| 17 | KCP-BUG | `kubeadmMisconfigInit` | `DeleteFailedMachine + AddMachine` | Apalache: hopelessness proven |
| 18 | TRANSIENT | `concurrentScaleAndRemediateInit` | `targetEtcdClusterHealthy` serialisation | TLC: 9.5K states |
| 19 | TRANSIENT | `apiserverRestartInit` | `HealLb` | TLC: 10.9K states |
| 20 | KCP-DESIGN-GAP | `upgradeRollbackMidFlightInit` | `JoinFailedAt → RemoveMember → DeleteFailedMachine` | TLC: 19.4K states; IC-11 verified |
| 21 | TRANSIENT | `fiveNodeTwoFailuresInit` | sequential remediation | TLC: 17.7K states |
| 22 | EXOGENOUS | `singleNodeScaleUpFailureInit` | `HealEtcdReachability` (FM-2 sub-shape) | TLC: 13.5K states |
| 23 | KCP-BUG (latent) | `drainStuckInit` | `DrainTimeout` | Apalache: AllSafetyInvariants holds (~278s) |
| 24 | TRANSIENT | `etcdDefragPauseInit` | defrag completes | TLC: 12.5K states |
| 31 | KCP-DESIGN-GAP | `customConditionInit` | (surface, not heal) | TLC: random walk passes |
| 32 | TRANSIENT | `webhookRotationInit` | `WebhookHeal` | TLC: random walk passes |
| 34 | KCP-BUG (latent) | `mhcCacheStaleInit` | `MhcCacheRefresh` | TLC: random walk passes |
| 35 | MODEL-EXPANSION | `selfHostedDeadlockInit` (SelfHosted.qnt) | `KcpReconcileResume` | quint run: deadlock + recovery traces verified |
| 37 | KCP-BUG (latent) | `lifecycleHookSkippedInit` | `TriggerPreUpgradeHook` | TLC: random walk passes |
| 33 | KCP-DESIGN-GAP (closed) | `fm33ScaleUpDuringCpUpgradeInit` (`MachineSetPreflight.qnt`) | `KcpFinishUpgrade + EvaluatePreflight` | 3 demo runs verify gating |
| 39 | MODELLING (closed) | `multiStepUpgradeRun` (`Topology.qnt`) | n/a — invariant of upstream contract | 5 demos + 200×30 random walk |
| 40 | MODELLING (closed) | `annotationBlockedUpgradeRun` (`Topology.qnt`) | Operator removes annotation | 5 demos + 200×30 random walk |
| 41 | MODELLING (closed) | (state invariant — `Topology.qnt`) | n/a | 200×30 random walk |
| 42 | MODELLING (closed) | (state invariant — `InPlaceUpdate.qnt`) | n/a | 5 demos + 2000×80 random walk |
| 43 | MODELLING (closed) | `updateMachineRetryLoopRun` (`InPlaceUpdate.qnt`) | n/a — idempotence invariant | 5 demos + 2000×80 random walk |
| 44 | MODELLING (closed) | `multiExtensionRejectRun` (`InPlaceUpdate.qnt`) | Operator removes duplicate extension | 5 demos + 2000×80 random walk |
| 45 | MODELLING (closed) | (state invariant — `ControllerRuntime.qnt`) | n/a — per-key serialisation | 6 demos + 500×60 random walk |
| 46 | MODELLING (closed) | `terminalErrorRun` (`ControllerRuntime.qnt`) | n/a — TerminalError no-requeue | 6 demos + 500×60 random walk |
| 47 | MODELLING (closed) | (state invariant — `ControllerRuntime.qnt`) | n/a — cache lag | 500×60 random walk |
| 48 | MODELLING (closed) | (state invariant — `ClusterE2E.qnt`) | n/a — KCP-not-before-InfraReady | 3 demos + 300×60 random walk |
| 49 | MODELLING (closed) | (state invariant — `ClusterE2E.qnt`) | n/a — workers-not-before-CPInit | 3 demos + 300×60 random walk |
| 50 | MODELLING (closed) | (state invariant — `ClusterE2E.qnt`) | n/a — endpoint monotonicity | 3 demos + 300×60 random walk |

## Spec-module inventory

The corpus comprises 16 Quint modules organised in four layers.
For exhaustive state-variable listings per module, read each
spec's State section (the comment blocks at the top of each
file group state vars by component with LSP anchors). The
[`reference.md` §State variables](./reference.md#state-variables-lifecycleqnt)
section catalogues `Lifecycle.qnt`'s 41 vars in detail.

### Layer 0 (substrate)
- `ControllerRuntime.qnt` — Manager + worker pool + priority
  queue + leader election + cache vs APIReader. Multi-worker
  variabilised via `WORKERS = 1.to(N)`.

### Layer 1 (per-component abstract specs)
- `Lifecycle.qnt` — KCP + etcd + kubeadm-join + MHC (41 vars,
  ~70 actions). Monolithic for TLC/Apalache verification.
- `EtcdMembership.qnt`, `KCPReconcile.qnt`, `KubeadmJoin.qnt`,
  `MachineHealthCheck.qnt`, `Composition.qnt` — modular
  decomposition of `Lifecycle.qnt`, kept for documentation
  and abstraction-mapping checks.
- `Lifecycle.multicluster.qnt` — per-cluster expansion for
  FM-35 self-hosted topology.
- `SelfHosted.qnt` — focused FM-35 deadlock + recovery model.
- `Topology.qnt` — ClusterTopology reconciler + 8 lifecycle
  hooks + multi-step upgrade plan.
- `MachineSetPreflight.qnt` — worker MS preflight gating.
- `InPlaceUpdate.qnt` — in-place machine update choreography
  across MD/MS/Machine controllers (10 actions, 5 demo runs).

### Layer 2 (refinements)
- `TopologyRefined.qnt` — Topology + CR substrate, single
  Cluster, multi-worker.
- `InPlaceUpdateRefined.qnt` — InPlaceUpdate (slice) + CR
  substrate, two Machines, multi-worker.
- `MachineSetPreflightRefined.qnt` — MachineSetPreflight (slice)
  + CR substrate, two MachineSets, multi-worker.

### Layer 3 (end-to-end)
- `ClusterE2E.qnt` — full cluster lifecycle: bring-up
  (BeforeClusterCreate → InfraCluster provision → KCP first CP
  Machine → CP scale-up → ControlPlaneInitialized → MD creates
  workers) plus rolling and in-place upgrade strategies.

### TLA+
- `Remediation.tla` — concurrent-remediation scheduler
  (TLC-only, used to verify `Remediation.cfg` invariants).

## Workflow: add a new FM

1. **Pick the right spec module** by domain:
   - KCP / etcd / kubeadm-join / MHC → `Lifecycle.qnt`
   - ClusterTopology / runtime hooks → `Topology.qnt`
   - Worker MachineSet preflight → `MachineSetPreflight.qnt`
   - In-place machine updates → `InPlaceUpdate.qnt`
   - controller-runtime substrate → `ControllerRuntime.qnt`
   - End-to-end ordering → `ClusterE2E.qnt`
2. Decide on a name (next free FM-N) and an init action name.
3. Edit the spec module:
   - Copy a similar init/action as a template.
   - Adjust state-variable bindings to capture the new fault.
4. Edit `formal/failure-modes.md`:
   - Add `## FM-N — <name>` section with trigger, recovery,
     classification, LSP grounding (file:line citations).
5. Run typecheck:
   ```sh
   cd formal && make typecheck
   ```
6. Verify reachability under `step` (replace `<Module>` and
   `<invariant>` per spec):
   ```sh
   quint verify --main=<Module> --init=<your-init> --step=step \
                --max-steps=8 --backend=tlc \
                --invariant='not(<invariant>)' \
                formal/specs/<Module>.qnt
   ```
   Expected: `[violation]` (the recovery state is reachable).
7. Verify hopelessness under `stepNoRecovery` (Apalache, when
   applicable):
   ```sh
   echo y | quint verify --main=<Module> --init=<your-init> \
                          --step=stepNoRecovery --max-steps=4 \
                          --backend=apalache \
                          --invariant='not(<invariant>)' \
                          formal/specs/<Module>.qnt
   ```
   Expected: `[ok] No violation found`.
8. Add a `verify-fm<N>` Make target in `formal/Makefile`.
9. Add abstraction-mapping rows for any new actions in
   `formal/abstraction-mapping.md` (one row per action,
   `| <Module> | <Action> | <go-file:line> | <purpose> |`).
10. Add an issue-corpus row in `formal/issue-corpus.md` if
    there's a corresponding upstream gap.
11. Run the CI gate:
    ```sh
    ./scripts/verify-formal.sh
    ```
    Expected: `All formal-subtree checks passed.`.
12. Commit on `formality` branch with subject
    `formal: FM-N <name>`.

## Workflow: re-bind a stale Go LSP anchor

1. Find the new symbol location:
   ```
   mcp__gopls__go_search "<symbol_name>"
   ```
2. Update the row in `formal/abstraction-mapping.md`.
3. Update any matching row in `formal/lsp-grounding.md`.
4. Run:
   ```sh
   cd formal && make lsp-list | grep <new-path>
   ```
   Confirm the new anchor appears.
5. Run drift check:
   ```sh
   make drift
   ```
   Expected: `OK drift check (NN actions covered)`.

## Known errata

- TLC reports `ConvergenceFair` a "tautology (negation
  unsatisfiable)" — this is a TLC capacity artifact at the 65-
  conjunct fairness level, not a genuine verification. See
  [`explanation.md` §Phase 11c](./explanation.md#phase-11c-tlc-tautology).
- The Quint rust evaluator hits a recursion limit on the per-action
  ConvergenceFair temporal expression. The Make targets default
  `QUINT_BACKEND=typescript` for `quint run`. TLC and Apalache
  verification are unaffected.
- Apalache temporal verification is "experimental" and prompts for
  permission. Make targets pipe `y` automatically.
