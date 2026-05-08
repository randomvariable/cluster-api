# Issue corpus — model-found issues

Curated list of issues the formal model surfaces. **This is a
documentation artefact**, not a list of upstream filings; the
intent is to give reviewers a single place to see what the model
has found, classified by severity and component.

Each issue links back to its FM in `failure-modes.md` and, where
applicable, to the upstream issue in `upstream-issues-research.md`.

## Schema

| Field | Description |
|---|---|
| ID | IC-NN — issue corpus identifier |
| Title | One-line description |
| FM | Failure-mode reference |
| Component | KCP / Bootstrap / MHC / Machine / CAPD / etcd / kubeadm / clusterctl |
| Severity | Critical / Major / Minor / Nitpick (matches CAPI review-severity vocabulary) |
| Class | KCP-BUG / KCP-DESIGN-GAP / EXOGENOUS-DOC / MODEL-INCOMPLETE |
| Evidence | TLC verdict, Apalache verdict, e2e result, or trace artefact |
| Suggested remediation | What an upstream PR would change |

## Critical

### IC-01 — KCP cannot recover from stuck-learner state without intervention

**FM**: FM-1
**Component**: KCP (`controlplane/kubeadm/internal/controllers/remediation.go:54` `reconcileUnhealthyMachines`; `workload_cluster_etcd.go:56` `RemoveEtcdMember`)
**Severity**: Critical
**Class**: KCP-BUG
**Upstream**: cluster-api#13221

**Evidence**: TLC exhausts 6,561 distinct states from `incidentInit` under `stepRemediation` at max-steps=4 confirming the `IncidentNeverInFlight` invariant — KCP correctly refuses to remediate. Modelled trace at `example-cluster` shows the same shape; CAPD e2e (`fm2_quorum_loss.go`, FM-2 PASSED) reproduces the `ControlPlaneUnhealthy: Waiting for control plane to pass preflight checks` event verbatim.

**Suggested remediation**: When KCP detects a Machine in `JoinFailed` phase whose etcd member is registered as a learner with no NodeRef, drop the etcd member via `Cluster.MemberRemove(id)` BEFORE deleting the Machine. The current early-return at `workload_cluster_etcd.go:89` is what blocks this — extend the path to look up the member by `peerURLs` (which kubeadm passed at AddLearner time) when `nodeRefName` is empty. Equivalent of the model's `RemoveStuckLearner` action.

### IC-02 — v1beta2 EtcdMemberHealthy condition drops upstream gRPC error chain

**FM**: FM-8
**Component**: KCP (`controlplane/kubeadm/internal/workload_cluster_conditions.go:66` `updateManagedEtcdConditions`)
**Severity**: Critical (operator-blocking diagnostic gap)
**Class**: KCP-BUG
**Upstream**: cluster-api#11826 (broader request)

**Evidence**: Quint produces a counterexample to `Composition.InformativenessObligation` for every observation in `{UnreachableTimeout, UnreachableNoRoute}`. Modelled trace at the modelled scenario ((modelling pass)) shows v1beta1 carrying `failed to get etcdStatus: context deadline exceeded` while v1beta2 reports `reason: InternalError, message: Please check controller logs for errors`. The diagnostic key `context deadline exceeded` is present in v1beta1 and absent from v1beta2.

**Suggested remediation**: The v1beta2 condition message MUST preserve every diagnostic key carried by the v1beta1 message. Specifically, propagate the wrapped gRPC error chain into `metav1.Condition.Message` rather than collapsing it onto `InternalError`. The model's `MachineHealthCheck.qnt::projectV1Beta2` is the spec of the desired behaviour; the current Go produces a strict refinement of this spec (drops information).

## Major

### IC-03 — KCP refuses remediation when both members of a 2-machine transient state are unhealthy

**FM**: FM-2
**Component**: KCP (`canSafelyRemediateMachine`)
**Severity**: Major (correctness; the refusal IS correct, but the operator path forward is undocumented)
**Class**: EXOGENOUS-DOC

**Evidence**: Apalache exhausted at max-steps=4 from `twoMachineBothUnhealthyInit` confirming `not(HealthyControlPlane)` holds under `stepNoRecovery`. The cluster cannot self-recover. CAPD e2e (FM-2) PASSES this assertion concretely.

**Suggested remediation**: Document the operator path explicitly. KCP's preflight-blocked event surfaces "Waiting for control plane to pass preflight checks" but doesn't tell the operator that the path forward is `clusterctl alpha restore` or equivalent. Two options: (a) emit a distinct condition reason `OperatorRestoreRequired` when both members of a 2-cluster are in `UnknownHealth`; (b) extend the user-facing `clusterctl describe --explain` to recognise this state.

### IC-04 — KCP does not detect persistent loss of all etcd reachability

**FM**: FM-3
**Component**: KCP / MHC
**Severity**: Major
**Class**: EXOGENOUS-DOC
**Upstream**: cluster-api#8465

**Evidence**: Apalache exhausted at max-steps=4 from `partitionedClusterInit` proving `HealthyControlPlane` is unreachable under `stepNoRecovery`. The cluster waits for `HealEtcdReachability`. KCP currently produces a `RemediationFailed` reason at v1beta1 severity Error, which lost informational content in v1beta2 (related to IC-02).

**Suggested remediation**: Same as IC-03 — surface a distinct condition reason that names the heal action ("Waiting for etcd member reachability"). Plus IC-02's diagnostic-content fix.

### IC-05 — apiserver LB outage is indistinguishable from etcd outage

**FM**: FM-13
**Component**: KCP probe path
**Severity**: Major
**Class**: KCP-BUG (latent)

**Evidence**: Apalache proven hopeless without `HealLb` AND `HealEtcdReachability`. The model captures these as TWO load-bearing recoveries; the current KCP merges them into the same `EtcdMemberHealthy=Unknown` projection, so the operator cannot tell whether the LB is down or etcd is down.

**Suggested remediation**: Add a probe of the workload-cluster apiserver health that is independent of the etcd Status RPC — e.g., a HEAD request to the apiserver's `/healthz` endpoint. When that fails but etcd's gRPC works (over a different transport), surface a distinct condition reason `ApiServerLBUnreachable`.

### IC-06 — Single-node cluster total-loss recovery is undocumented

**FM**: FM-16
**Component**: KCP / clusterctl
**Severity**: Major (operator UX)
**Class**: EXOGENOUS-DOC

**Evidence**: Apalache proven unreachable from `singleNodeLostVoterInit` under `stepNoRecovery` in 21 s. With `RestoreClusterFromSnapshot` the cluster recovers in 633 states and 0.8 s.

**Suggested remediation**: The `RestoreClusterFromSnapshot` action in the model represents what an operator MUST do — restore etcd from a backup. CAPI doesn't currently provide a first-class command for this; document the `etcdctl snapshot restore` recipe in the KCP runbook section of the CAPI book.

### IC-07 — Invalid kubelet config produces NodeRef-less voter; KCP does not detect

**FM**: FM-11, FM-14
**Component**: KCP, Machine controller
**Severity**: Major
**Class**: KCP-BUG (latent)

**Evidence**: TLC reaches `HealthyControlPlane` from `invalidKubeletInit` and `nodeNeverJoinsInit` in ~25K states under `step` (recovery via `MachineHealthChange + RequestRemediation + CompleteRemediation`). KCP's current Go behaviour relies on MHC flagging the Machine, which has its own latency.

**Suggested remediation**: Detect "etcd voter exists, kubelet was Ready, but NodeRef never resolves within $timeout" as a distinct unhealthy state. This is the FM-14 shape — the kubelet started (`KubeletStarted` fired) but the Node never registered (network or apiserver-LB issue). The current KCP path waits for MHC's `nodeStartupTimeout` which is 30 s by default.

### IC-08 — Etcd join timeout (slow storage) leaves dangling JoinFailed Machine

**FM**: FM-12
**Component**: KCP, Bootstrap
**Severity**: Major
**Class**: KCP-BUG (latent)

**Evidence**: TLC reaches `HealthyControlPlane` from `slowStorageEtcdJoinInit` under `step` with `DeleteFailedMachine` recovery in 3.5K states. The Go side currently lacks the explicit "JoinFailed → Delete" detection.

**Suggested remediation**: When kubeadm-join exits non-zero AND `etcdMember.Name == ""` (i.e., the member was never registered), KCP should accept the JoinFailed condition as a signal to delete and recreate the Machine without waiting for MHC to flag it. The model's `DeleteFailedMachine` action is the spec.

### IC-09 — Etcd leader-forwarding is not modelled

**FM**: (no specific FM yet — model gap)
**Component**: model
**Severity**: Major (model fidelity)
**Class**: MODEL-INCOMPLETE

**Evidence**: `formal/lsp-grounding.md` notes `Workload.ForwardEtcdLeadership` (`workload_cluster_etcd.go:96`) is not refined by any Quint action. KCP forwards etcd leadership before removing a leader-Machine; without modelling, the model's `RemoveMember` is too coarse.

**Suggested remediation**: Add `ForwardEtcdLeadership(from, to)` action to `Lifecycle.qnt` with guard `from == leaderAt[currentTerm]` and post-state `leaderAt' = leaderAt.put(currentTerm, to)`. Re-state the `CompleteRemediation` precondition: if the target is the current leader, ForwardEtcdLeadership must precede.

## Minor

### IC-10 — Concurrent scale-up + remediation race not explicitly documented

**FM**: FM-18
**Component**: KCP scheduler
**Severity**: Minor
**Class**: KCP-DESIGN-GAP

**Evidence**: TLC + `Remediation.tla` enforce `AtMostOneRemediationPerMachine`; the model doesn't expose an outer "at most one membership-change at a time" invariant, but `targetEtcdClusterHealthy`'s learner-set check effectively enforces it.

**Suggested remediation**: Add a regression test that drives `concurrentScaleAndRemediateInit` and asserts the operations serialise.

### IC-11 — Upgrade rollback mid-flight leaves mixed-template cluster

**FM**: FM-20
**Component**: KCP rolling-update
**Severity**: Minor
**Class**: KCP-DESIGN-GAP

**Evidence**: `upgradeRollbackMidFlightInit` produces a cluster where `desiredTemplate=1` but `template[4]=2`. KCP's correct recovery is to abort the in-flight join, remove Machine 4 from etcd, delete the Machine, and settle back at the pre-rollout 3-Machine cluster on template 1.

**Verdict (Phase 6)**: deterministic recovery run `upgradeRollbackRecoveryRun` in `Lifecycle.qnt` drives `upgradeRollbackMidFlightInit` → `JoinFailedAt(4, OtherJoinFailure)` → `RemoveMember(4)` → `DeleteFailedMachine(4)`. `quint run` reaches `HealthyControlPlane` in 4 steps (~217 ms). The MHC `ObservationRefresh` action — added in Phase 6 — closes the otherwise-open gap where the model had no path to flip `observation[m]` from `NoCorrespondingMember` back to `ReachableHealthy` once the underlying state had recovered.

```
quint run --main=Lifecycle --init=upgradeRollbackRecoveryRun \
          --step=step --invariant='not(HealthyControlPlane)' \
          --max-steps=0 formal/specs/Lifecycle.qnt
# Expected: [violation] — confirms HealthyControlPlane reached.
```

### IC-12 — etcd defrag pause causes spurious EtcdMemberHealthy=Unknown

**FM**: FM-24
**Component**: KCP probe
**Severity**: Minor
**Class**: TRANSIENT

**Evidence**: `etcdDefragPauseInit` produces a state matching FM-3 (all observations Unreachable) but for a known cause (etcd defrag, takes 10–60 s on bbolt). KCP's gates correctly refuse to remediate; the cluster recovers when defrag finishes.

**Suggested remediation**: Document defrag as a known cause of transient EtcdMemberHealthy=Unknown. Optionally: surface a distinct condition reason `EtcdDefragInProgress` when KCP's probe encounters a known-defrag pattern.

### IC-13 — Five-node cluster losing 2 of 5 voters is at quorum boundary

**FM**: FM-21
**Component**: KCP gate
**Severity**: Minor
**Class**: TRANSIENT (operationally relevant)

**Evidence**: `fiveNodeTwoFailuresInit` produces `members={1,2,3,4,5}` with 2 unhealthy (4, 5). targetEtcdClusterHealthy(false, 4): targetVoter=4, unhealthy=2 (the other unhealthy + new-replacement-worst-case), quorum=3. 4-2=2 < 3 → REFUSED.

**Suggested remediation**: This is correct KCP behaviour at the boundary, but operationally surprising — operators expect 5-node clusters to tolerate 2 failures. Document explicitly: KCP can remediate ONE failure at a time even on 5-node, because the worst-case-unhealthy assumption on the new member.

## Nitpick

### IC-14 — Drain stuck on PDB blocks remediation indefinitely

**FM**: FM-23 (overlaps cluster-api#13508)
**Component**: Machine controller drain
**Severity**: Nitpick (well-documented pattern)
**Class**: KCP-BUG (latent)

**Evidence**: `drainStuckInit` shows the state where a Machine is mid-deletion but drain is blocked by PDBs on the workload cluster. KCP's `preflightBlocked` flag is set; no further membership change happens.

**Suggested remediation**: Already covered by cluster-api#13508. Adopt the upstream resolution.

### IC-15 — apiserver restart relist storm causes transient UnknownHealth

**FM**: FM-19
**Component**: MHC controller cache
**Severity**: Nitpick (transient, self-resolving)
**Class**: TRANSIENT

**Evidence**: `apiserverRestartInit` is a brief transient state lasting until the workload-cluster apiserver finishes restarting and the MHC cache repopulates. No spurious remediation if the restart completes within `nodeStartupTimeout` (default 30 s).

**Suggested remediation**: Verify via e2e — `docker exec <CP> kubectl --kubeconfig=/etc/kubernetes/admin.conf delete pod -n kube-system kube-apiserver-...` and observe the cluster does not churn.

## Index by component

| Component | Critical | Major | Minor | Nitpick |
|---|---|---|---|---|
| KCP | IC-01, IC-02 | IC-03, IC-04, IC-05, IC-06, IC-07, IC-08 | IC-10, IC-11, IC-12, IC-13 | IC-14, IC-15 |
| MHC | — | — | — | IC-15 |
| Bootstrap | — | IC-08 | — | — |
| Machine controller | — | IC-07 | — | IC-14 |
| Model itself | — | IC-09 | — | — |

## Index by class

| Class | IDs |
|---|---|
| KCP-BUG | IC-01, IC-02, IC-05, IC-07, IC-08 |
| KCP-DESIGN-GAP | IC-10, IC-11 |
| EXOGENOUS-DOC | IC-03, IC-04, IC-06 |
| MODEL-INCOMPLETE | IC-09 |
| TRANSIENT | IC-12, IC-13, IC-15 |
| KCP-BUG (latent) | IC-08 |

## Relationship to upstream issues

| IC | Upstream | Relationship |
|---|---|---|
| IC-01 | cluster-api#13221 | Direct match — same failure mode, same root cause |
| IC-02 | cluster-api#11826 | IC-02 is a specific instance of the broader "surface arbitrary node conditions" request |
| IC-04 | cluster-api#8465 | Direct match — same failure mode |
| IC-14 | cluster-api#13508 | Direct match — same failure mode |

## Maintenance

When a new FM is added to `failure-modes.md` whose model exposes
a previously-undocumented gap, append a new IC row here. The IC
row describes WHAT is wrong; the failure-modes row describes the
state and the recovery; the upstream-issues-research row
describes whether anyone else has reported it.
