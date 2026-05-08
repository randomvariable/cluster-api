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

| Capability | Make target | Underlying command | Expected output marker |
|---|---|---|---|
| Sanity gate | `make verify` | `verify-formal.sh` | `All formal-subtree checks passed.` |
| Verify FM-N reachability | `make verify-fmN` | `quint verify --backend=tlc --invariant='not(HealthyControlPlane)'` | `[violation] Found an issue` (good — recovery is reachable) |
| Verify FM-N hopelessness | (Apalache) `make verify-fmN` | `quint verify --backend=apalache --invariant='not(HealthyControlPlane)' --step=stepNoRecovery` | `[ok] No violation found` (good — hopeless without recovery) |
| Verify IC-11 recovery | `make verify-ic11` | `quint run` deterministic | `[violation]` (HealthyControlPlane reached) |
| Run fairness witness | `make verify-fm9-witness` | `quint run --init=fairConvergenceWitnessRun` | `[ok] No violation found` |
| Self-hosted deadlock | `make verify-selfhosted-deadlock` | `quint run --invariant='not(Deadlocked)'` | `[violation]` (Deadlocked reached) |
| Self-hosted recovery | `make verify-selfhosted-recovery` | `quint run` | `[ok]` |
| Regenerate fairness | `make fairness-gen` | `python3 hack/tools/quint-fairness-gen.py` | snippet at `/tmp/fairness-snippet.qnt` |
| List Go LSP anchors | `make lsp-list` | `grep -oE …` | newline-separated paths |

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

## State-variable inventory

40 state variables across 8 categories. See [`reference.md` §State
variables](./reference.md#state-variables-lifecycleqnt) for the
exhaustive table. Categories:

- EtcdMembership: `members`, `learners`, `leaderAt`, `currentTerm`, `progress`, `memberHealth` (6)
- KubeadmJoin: `phase`, `failureReason`, `etcdMemberRegistered`, `kubeletReady`, `tlsBootstrapped`, `kubeletManifestReady`, `nodeLocallyRegistered`, `staticPodManifestsWritten`, `kubeadmMarkedAsControlPlane`, `kubeadmConfigUploaded` (10)
- KCPReconcile: `machines`, `nodeRefSet`, `machineHealthLabel`, `decision`, `blockReason`, `preflightBlocked`, `desiredReplicas`, `template`, `desiredTemplate` (9)
- MHC: `observation` (1)
- Network: `lbHealthy`, `nodeReachable` (2)
- Drain & PDB: `drainBlocked`, `pdbViolatedFor` (2)
- Apiserver↔etcd: `apiserverEtcdReachable`, `apiserverReady`, `etcdCompactionInProgress` (3)
- CRI: `criRuntimeReady`, `criImagesPulled`, `criPodSandboxRunning`, `criContainersRunning` (4)
- Other: `customCondition` (FM-31), `webhooksAvailable` (FM-32), `mhcCacheStale` (FM-34), `hooksTriggered` (FM-37) (4)

Total: 41 (the count drift between this and `40` in some docs is
documentation sync; the source of truth is the `var` declarations
in `formal/specs/Lifecycle.qnt`).

## Workflow: add a new FM

1. Decide on a name (e.g. FM-25 for the next slot) and an init
   action name (e.g. `myFaultInit`).
2. Edit `formal/specs/Lifecycle.qnt`:
   - Copy a similar `*Init` action (e.g. `lbBrokenInit` for a
     network-fault, `incidentInit` for a Machine-level fault).
   - Adjust state-variable bindings to capture the new fault.
3. Edit `formal/failure-modes.md`:
   - Add `## FM-25 — <name>` section with trigger, recovery,
     classification.
4. Run typecheck:
   ```sh
   cd formal && make typecheck
   ```
5. Verify reachability:
   ```sh
   quint verify --main=Lifecycle --init=myFaultInit --step=step \
                --max-steps=8 --backend=tlc \
                --invariant='not(HealthyControlPlane)' \
                formal/specs/Lifecycle.qnt
   ```
   Expected: `[violation]`.
6. Verify hopelessness if applicable:
   ```sh
   echo y | quint verify --main=Lifecycle --init=myFaultInit \
                          --step=stepNoRecovery --max-steps=4 \
                          --backend=apalache \
                          --invariant='not(HealthyControlPlane)' \
                          formal/specs/Lifecycle.qnt
   ```
   Expected: `[ok] No violation found`.
7. Add a `verify-fm25` Make target in `formal/Makefile`.
8. Add an issue-corpus row in `formal/issue-corpus.md` if there's a
   corresponding upstream gap.
9. Run the CI gate:
   ```sh
   ./scripts/verify-formal.sh
   ```
   Expected: `All formal-subtree checks passed.`.
10. Commit on `formality` branch with subject
    `formal: FM-25 <name> (Phase NN/MM)`.

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
