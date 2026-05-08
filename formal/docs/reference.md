# Reference

Exhaustive listing for the `formal/` subtree. Tutorial-style intro is
in [`tutorial.md`](./tutorial.md); rationale in
[`explanation.md`](./explanation.md).

## Make targets

Run `cd formal && make help`. Targets are grouped by purpose:

### Sanity gates

| Target | Effect | Typical runtime |
|---|---|---|
| `typecheck` | `quint typecheck` every `formal/specs/*.qnt` | <1 s |
| `test` | `quint run --max-samples=200` every spec with declared runs | ~30 s for Lifecycle.qnt |
| `proofs` | `lake build` the Lean 4 project at `formal/proofs/` | ~2 min cold, instant warm |
| `tlc` | run TLC against every `formal/specs/*.cfg` | ~1 s for `Remediation.tla` |
| `drift` | check every Quint action has an `abstraction-mapping.md` row | <1 s |
| `verify` | sequential: `typecheck` → `test` → `tlc` → `proofs` → `drift` | ~3 min cold |
| `clean` | remove `proofs/.lake`, `proofs/build`, `_apalache-out` | instant |

### Per-FM verification

| Target | Property | Backend | Runtime |
|---|---|---|---|
| `verify-fm1` | `incidentInit + stepRemediation` reaches expected RemediationBlocked state | TLC | ~1 s |
| `verify-fm2` | `not(HealthyControlPlane)` under `stepNoRecovery` from `twoMachineBothUnhealthyInit` | Apalache | ~80 s |
| `verify-fm3` | same shape from `partitionedClusterInit` | Apalache | ~80 s |
| `verify-fm13` | same shape from `lbBrokenInit` | Apalache | ~40 s |
| `verify-fm16` | same shape from `singleNodeLostVoterInit` | Apalache | ~25 s |
| `verify-fm17` | same shape from `kubeadmMisconfigInit` | Apalache | ~80 s |
| `verify-fm23` | `AllSafetyInvariants` under `stepNoRecovery` from `drainStuckInit` | Apalache | ~280 s |
| `verify-ic11` | `not(HealthyControlPlane)` under `step` from `upgradeRollbackRecoveryRun` (deterministic) | quint run | <1 s |

Variables: `MAX_STEPS_APALACHE` (default 4), `MAX_STEPS_TLC` (default
8), `QUINT_BACKEND` (default `typescript`).

### FM-9 (fairness)

| Target | Property | Backend |
|---|---|---|
| `verify-fm9-fair` | `ConvergenceFair` (per-action strong/weak fair) | TLC |
| `verify-fm9-recurrent` | `ConvergenceRecurrentFair` (recurrence form) | TLC |
| `verify-fm9-witness` | execute `fairConvergenceWitnessRun` | quint run |
| `fairness-gen` | regenerate `ConvergenceFair` body to `/tmp/fairness-snippet.qnt` | python3 |

### FM-35 (self-hosted)

| Target | Property | Backend |
|---|---|---|
| `verify-selfhosted-deadlock` | `selfHostedDeadlockTrace` reaches `Deadlocked` | quint run |
| `verify-selfhosted-recovery` | `selfHostedRecoveryTrace` clears Deadlocked | quint run |

### Meta

| Target | Effect |
|---|---|
| `verify-all-apalache` | all per-FM Apalache targets sequentially |
| `lsp-list` | prints every Go entry-point cited in abstraction-mapping.md and lsp-grounding.md |

## Per-FM commands (manual invocation)

For FMs without dedicated targets, the template is:

```sh
# TLC reachability under recovery (expect [violation] = HealthyControlPlane reached):
quint verify --main=Lifecycle --init=<init> --step=step \
             --max-steps=8 --backend=tlc \
             --invariant='not(HealthyControlPlane)' \
             formal/specs/Lifecycle.qnt

# Apalache hopelessness under no-recovery (expect [ok] = HealthyControlPlane unreachable):
echo y | quint verify --main=Lifecycle --init=<init> \
                       --step=stepNoRecovery --max-steps=4 \
                       --backend=apalache \
                       --invariant='not(HealthyControlPlane)' \
                       formal/specs/Lifecycle.qnt
```

Replace `<init>` with one of (full list in `Lifecycle.qnt`):

| FM | Init action |
|---|---|
| FM-1 | `incidentInit`, `stuckLearnerInit` |
| FM-2 | `twoMachineBothUnhealthyInit` |
| FM-3 | `partitionedClusterInit` |
| FM-5 | `noCorrespondingMemberInit` |
| FM-11 | `invalidKubeletInit` |
| FM-12 | `slowStorageEtcdJoinInit` |
| FM-13 | `lbBrokenInit` |
| FM-14 | `nodeNeverJoinsInit` |
| FM-15 | `upgradeInFlightInit` |
| FM-16 | `singleNodeLostVoterInit` |
| FM-17 | `kubeadmMisconfigInit` |
| FM-18 | `concurrentScaleAndRemediateInit` |
| FM-19 | `apiserverRestartInit` |
| FM-20 | `upgradeRollbackMidFlightInit` |
| FM-21 | `fiveNodeTwoFailuresInit` |
| FM-22 | `singleNodeScaleUpFailureInit` |
| FM-23 | `drainStuckInit` |
| FM-24 | `etcdDefragPauseInit` |
| FM-31 | `customConditionInit` |
| FM-32 | `webhookRotationInit` |
| FM-34 | `mhcCacheStaleInit` |
| FM-37 | `lifecycleHookSkippedInit` |
| (etcd leader) | `leaderRemovalRaceInit` |

## State variables (Lifecycle.qnt)

The model carries 40 state variables, organised by component.

### EtcdMembership

| Var | Type | Purpose |
|---|---|---|
| `members` | `Set[MachineId]` | Etcd voter set |
| `learners` | `Set[MachineId]` | Strict subset, learners awaiting promote |
| `leaderAt` | `Term -> MachineId` | Per-term leader |
| `currentTerm` | `Term` | Monotone |
| `progress` | `MachineId -> LearnerProgress` | Eligible / LaggingFar / Stuck |
| `memberHealth` | `MachineId -> MemberHealth` | KCP's view of member health |

### KubeadmJoin (16-phase)

| Var | Type | Purpose |
|---|---|---|
| `phase` | `MachineId -> Phase` | NotStarted → Preflight → DownloadCerts → StaticPodManifestsWritten → EtcdHealthCheck → KubeletStart → KubeletTLSBootstrapped → KubeletManifestReady → NodeRegistered → EtcdJoinAddLearner → WaitForEtcdQuorum → KubeadmMarkControlPlane → KubeadmUploadConfig → MarkControlPlaneReady → JoinComplete \| JoinFailed |
| `failureReason` | `MachineId -> JoinFailureReason` | one of 12 documented reasons |
| `etcdMemberRegistered` | `MachineId -> bool` | etcd voter registered |
| `kubeletReady` | `MachineId -> bool` | kubelet process up |
| `tlsBootstrapped` | `MachineId -> bool` | kubelet TLS bootstrap done |
| `kubeletManifestReady` | `MachineId -> bool` | static-pod manifests applied |
| `nodeLocallyRegistered` | `MachineId -> bool` | kubelet's local Node registration |
| `staticPodManifestsWritten` | `MachineId -> bool` | kubeadm wrote `/etc/kubernetes/manifests/` |
| `kubeadmMarkedAsControlPlane` | `MachineId -> bool` | label/taint applied |
| `kubeadmConfigUploaded` | `MachineId -> bool` | ClusterConfiguration uploaded |

### KCP reconcile

| Var | Type | Purpose |
|---|---|---|
| `machines` | `Set[MachineId]` | KCP's machine set |
| `nodeRefSet` | `MachineId -> bool` | NodeRef resolved on Machine |
| `machineHealthLabel` | `MachineId -> MachineHealth` | Healthy / Unhealthy / Unknown |
| `decision` | `MachineId -> RemediationDecision` | None / Requested / Blocked / InFlight |
| `blockReason` | `MachineId -> BlockedReason` | QuorumWouldBeLost / EtcdMemberSetMismatch / … |
| `preflightBlocked` | `bool` | preflight serialisation gate |
| `desiredReplicas` | `int` | spec.replicas |
| `template` | `MachineId -> int` | per-Machine template version |
| `desiredTemplate` | `int` | spec.template |

### MHC

| Var | Type | Purpose |
|---|---|---|
| `observation` | `MachineId -> Observation` | ReachableHealthy / ReachableUnhealthy / UnreachableTimeout / UnreachableNoRoute / NoCorrespondingMember |

### Network / connectivity

| Var | Type | Purpose |
|---|---|---|
| `lbHealthy` | `bool` | apiserver LB reachability |
| `nodeReachable` | `MachineId -> bool` | per-Node reachability |

### Drain & PDB

| Var | Type | Purpose |
|---|---|---|
| `drainBlocked` | `MachineId -> bool` | sticky drain-stalled flag |
| `pdbViolatedFor` | `MachineId -> bool` | PDB refused eviction |

### Apiserver ↔ etcd

| Var | Type | Purpose |
|---|---|---|
| `apiserverEtcdReachable` | `MachineId -> bool` | apiserver's etcd v3 client connection |
| `apiserverReady` | `MachineId -> bool` | readyz returns 200 |
| `etcdCompactionInProgress` | `bool` | bbolt mmap held |

### CRI / containerd

| Var | Type | Purpose |
|---|---|---|
| `criRuntimeReady` | `MachineId -> bool` | containerd CRI socket up |
| `criImagesPulled` | `MachineId -> bool` | static-pod images pulled |
| `criPodSandboxRunning` | `MachineId -> bool` | pod sandbox created |
| `criContainersRunning` | `MachineId -> bool` | apiserver/etcd/scheduler containers running |

### FM-31 / FM-32 / FM-34 / FM-37

| Var | Type | Purpose |
|---|---|---|
| `customCondition` | `MachineId -> Set[str]` | custom Node conditions |
| `webhooksAvailable` | `bool` | CAPI webhook reachability |
| `mhcCacheStale` | `bool` | MHC cluster cache stale |
| `hooksTriggered` | `Set[str]` | runtime hooks fired |

## Contract obligations

Pinned to upstream commits in `formal/contracts/commits.yaml`.

| ID | Statement | Source |
|---|---|---|
| **K1** | kubelet-start MUST complete before control-plane-join/etcd | kubeadm-etcd-contract.md §1 |
| **K2** | static-pod manifests precede kubelet start; local Node registration MAY occur before apiserver-on-this-Machine is serving | kubeadm-etcd-contract.md §1 |
| **K3** | Node registers with workload apiserver before wait-control-plane returns | kubeadm-etcd-contract.md §1 |
| **K4** | successful MemberAddAsLearner is followed by promote OR join failure | kubeadm-etcd-contract.md §1 |
| **K5** | local Node registration precedes etcd-add-learner | kubeadm-etcd-contract.md §1 |
| **R-LEAD-STEP-DOWN** | etcd leader steps down or transfers before being removed | etcd-raft-contract.md §5a |
| **D-DRAIN-TIMEOUT** | nodeDrainTimeout elapses → force-delete bypasses PDB | kcp-machine-contract.md §6 |
| **AS-READYZ** | apiserver readyz gated on etcd reachability | kcp-machine-contract.md §7 |
| **AS-COMPACT** | KCP MHC observation treats compaction-window timeouts as transient Unknown | kcp-machine-contract.md §7 |
| **AS-DISCONNECT** | apiserver readiness flips false on etcd loss | kcp-machine-contract.md §7 |
| **L-HOOK-FIRES** | BeforeClusterUpgrade fires before any upgrade-driven membership change | kcp-machine-contract.md §10 (FM-37) |

## LSP-grounded Go anchors

Run `make lsp-list` to print every Go file referenced by
`abstraction-mapping.md` and `lsp-grounding.md`. Highlights:

- `internal/controllers/machine/machine_controller.go:712`
  (`Reconciler.nodeDrainTimeoutExceeded`)
- `internal/controllers/machine/machine_controller.go:841`
  (`Reconciler.drainNode`)
- `internal/controllers/machine/drain/drain.go`
  (`Helper.{CordonNode,GetPodsForEviction,EvictPods}`)
- `controlplane/kubeadm/internal/workload_cluster_etcd.go:56`
  (`Workload.RemoveEtcdMember`)
- `controlplane/kubeadm/internal/workload_cluster_etcd.go:96`
  (`Workload.ForwardEtcdLeadership`)
- `controlplane/kubeadm/internal/workload_cluster_conditions.go:66`
  (`Workload.updateManagedEtcdConditions`)
- `staging/src/k8s.io/apiserver/pkg/storage/etcd3/store.go`
  (Get:238, Create:274, Delete:342, Watch:968)
- `staging/src/k8s.io/apiserver/pkg/storage/etcd3/preflight/checks.go:56`
  (`EtcdConnection.CheckEtcdServers`)
- `staging/src/k8s.io/apiserver/pkg/storage/etcd3/compact.go:52`
  (`StartCompactorPerEndpoint`)
- `staging/src/k8s.io/apiserver/pkg/server/healthz/healthz.go`
  (readyz)
- `pkg/kubelet/kubelet_node_status.go:52` (`registerWithAPIServer`)
- `pkg/kubelet/kubelet_node_status.go:90` (`tryRegisterWithAPIServer`)
- `pkg/kubelet/kuberuntime/kuberuntime_image.go:33` (`PullImage`)
- `pkg/kubelet/kuberuntime/kuberuntime_sandbox.go:38` (`createPodSandbox`)
- `pkg/kubelet/kuberuntime/kuberuntime_container.go:199` (`startContainer`)
- `cmd/kubeadm/app/cmd/phases/join/{preflight,kubelet,controlplaneprepare,controlplanejoin,checketcd,waitcontrolplane}.go`

## Files

```
formal/
├── README.md                      — entry point
├── overview.md                    — verification matrix + reading order
├── failure-modes.md               — FM-1..FM-37 catalogue
├── issue-corpus.md                — IC-01..IC-15
├── upstream-issues-research.md    — GitHub-issue mining (Tier 1, 2, 3)
├── test-corpus-spec.md            — MoSCoW + feature model
├── lsp-grounding.md               — Quint action ↔ Go entry-point table
├── dst-methodology.md             — fault-injection catalogue (CAPD primitives)
├── e2e-blueprints.md              — sketches of CAPD e2e tests per FM
├── verify-runbook.md              — TLC/Apalache invocation cookbook
├── abstraction-mapping.md         — refinement-mapping table (CI-enforced)
├── counterexample-log.md          — append-only ledger of spec violations
├── docs/                          — Diataxis-style human docs (this directory)
│   ├── tutorial.md                — first-time reproduction
│   ├── how-to.md                  — goal-oriented recipes
│   ├── reference.md               — exhaustive listing
│   ├── explanation.md             — design rationale
│   └── AGENTS.md                  — LLM-friendly machine summary
├── contracts/                     — RFC-2119 contracts pinned to upstream commits
│   ├── commits.yaml               — upstream SHAs
│   ├── etcd-raft-contract.md
│   ├── kcp-machine-contract.md
│   └── kubeadm-etcd-contract.md
├── specs/                         — Quint + TLA+ source
│   ├── Lifecycle.qnt              — monolithic spec (TLC target)
│   ├── EtcdMembership.qnt         — modular spec
│   ├── KCPReconcile.qnt
│   ├── KubeadmJoin.qnt
│   ├── MachineHealthCheck.qnt
│   ├── Composition.qnt
│   ├── SelfHosted.qnt             — FM-35 dual-cluster
│   ├── Remediation.tla            — concurrent-remediation scheduler
│   └── Remediation.cfg
├── proofs/                        — Lean 4 (lake)
│   ├── ControlPlane.lean
│   └── ControlPlane/{Refinement,Safety,Informativeness}.lean
└── Makefile                       — make targets
```

External:

```
hack/tools/
├── quint-fairness-gen.py          — generates ConvergenceFair body
└── trace-validator/main.go        — off-line ITF trace validator
internal/trace/
├── record.go, recorder.go, verdict.go, itf.go
└── checkers/
    ├── etcd_membership.go, kcp_reconcile.go, kubeadm_join.go, mhc.go
scripts/verify-formal.sh           — CI gate (typecheck + runs + tlc + go + drift)
test/e2e/
├── fm2_quorum_loss.go             — CAPD reproducer (PASSES)
└── fm2_quorum_loss_test.go
docs/proposals/20260507-formal-control-plane-lifecycle-model.md  — CAEP
```
