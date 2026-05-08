# Upstream-issue research — control-plane failure-mode candidates

GitHub-issue mining across cluster-api and the major
infrastructure providers (vSphere, AWS, Azure, OpenStack) to
seed the formal model with reported, real-world control-plane
failure modes beyond the modelled scenario that started
this work.

Searches were run against `kubernetes-sigs/cluster-api`,
`kubernetes-sigs/cluster-api-provider-vsphere`,
`kubernetes-sigs/cluster-api-provider-aws`,
`kubernetes-sigs/cluster-api-provider-azure`, and
`kubernetes-sigs/cluster-api-provider-openstack`. State filter:
`open`. Search terms covered: `KCP`, `etcd quorum`, `etcd
learner`, `preflight`, `MachineHealthCheck`, `control plane
upgrade`, `scale control plane`, `remediation`, `NodeRef not
set`, plus per-provider variants.

This is a research artefact — none of these issues are filed by
this work. They are inputs that informed which FM-IDs we
modelled.

## Tier 1 — directly map to FMs we already modelled

### #13221 — KCP does not remove the etcd member for a machine that failed to join the control plane

**Status**: open, kind/bug, area/provider/control-plane-kubeadm.
**CAPI version reported**: v1.10.7. **K8s**: v1.34.2.

This is **FM-1 verbatim**. The modelled scenario that
opened this work (example-cluster / (modelling pass)) and this
upstream issue describe the same failure: KCP creates a Machine,
kubeadm-join adds an etcd learner, the learner never promotes
(in #13221 because kubelet is broken; in FM-1 because of
a gRPC client routing bug), and KCP refuses to remove the
unstarted etcd member because the failed Machine has no NodeRef.
Subsequent join attempts fail because etcd's learner-then-
promote serialization gates further membership changes on the
existing learner being promoted.

The model captures this as `IncidentNeverInFlight` (KCP correctly
refuses to remediate without a NodeRef) plus the
`RemoveStuckLearner` recovery action (which KCP does not yet
fire). TLC has exhaustively verified both invariants from
`incidentInit` at max-steps=4.

The upstream issue cross-references
[`workload_cluster_etcd.go` line 89](https://github.com/kubernetes-sigs/cluster-api/blob/3adb25101d845af093cc44975b67cc1b94838e2e/controlplane/kubeadm/internal/workload_cluster_etcd.go#L89)
as the load-bearing line — it's the early-return that skips
etcd member removal when the Machine has no NodeRef. The same
line is the abstraction-mapping target for FM-1's
`RemoveStuckLearner` recovery in our model.

### #8465 — Allow KCP remediation when access to the etcd leader is not possible

**Status**: open, /kind documentation, /area control-plane,
/triage accepted.

**This is FM-3 / FM-13 in production form**. Reported in
2023-03 against CAPI main, 1.4.0 and older. Stopping the
kubelet on the etcd leader produces this condition shape:

```
message: 'failed to get etcdStatus for workload cluster ...:
   could not establish a connection to any etcd node: unable to
   create etcd client: context deadline exceeded'
reason: RemediationFailed
severity: Error
status: False
type: ControlPlaneReady
```

This is the **v1beta1** condition shape with `severity: Error`
and the upstream gRPC error chain preserved. Its **v1beta2**
counterpart lost both the severity grading and the gRPC error
chain — that is FM-8 (the InformativenessObligation
counterexample our model exposes).

Apalache has proved that under `stepNoRecovery` from
`partitionedClusterInit` (`HealEtcdReachability` disabled),
`HealthyControlPlane` is unreachable in 82 s. The upstream
issue's request — "improve the error message" — maps to FM-8's
fix and the formal `InformativenessObligation` proof obligation.

## Tier 2 — direct seeds for new FMs

### #11826 — Provide a way to surface arbitrary node conditions at machine level

**Status**: open, /kind feature, /area machinehealthcheck.

The submitter wants Machine.status to reflect arbitrary
workload-cluster Node conditions WITHOUT having to use
MachineHealthCheck (which couples observation to remediation).
This is the upstream version of our FM-8 framing: the v1beta2
condition surface drops information the operator needs to
diagnose state. The model abstracts this as the
`InformativenessObligation` over `MachineHealthCheck.qnt`'s
`projectV1Beta2`.

Seeds: a new FM **FM-31 — operator-surfaced custom conditions
not modelled in MHC**. The model would extend
`MachineHealthCheck.qnt` with a `customConditions: MachineId ->
str -> str` map and require the v1beta2 projection to preserve
every key in that map.

### #10522 — Cert-manager certificate rotation may lead to downtime of webhooks for up to 90 s

**Status**: open, /kind bug.

Cert-manager rotates the webhook serving cert; during the
rotation window CAPI's webhooks (mutating + validating) are
unreachable. KCP reconciles that hit a webhook fail; if KCP is
mid-remediation, this can interleave dangerously.

Seeds: **FM-32 — webhook-rotation-induced reconcile gap**. Model
as a `WebhooksUnavailable` flag plus a `WebhookHeal` recovery
action; verify that all of KCP's safety invariants hold while
webhooks are unreachable (they should; the gates are pure
and don't reach the webhook layer).

### #11117 — Feature: MachineSetPreflightChecks

**Status**: open, /kind feature.

Mirror of KCP's preflight checks for MachineSet (worker)
remediation. Adds the same "matchable / quorum / health-rollup"
gate to worker-machine flows.

Not relevant to control-plane FMs directly, but pinpoints a
useful model extension: **FM-33 — worker-machine preflight gap**.
Out of scope for this round (control-plane focus); recorded for
future work.

### #12363 — MachineHealthcheck controller fails to get cluster connection from cache

**Status**: open, /kind bug.

The MHC controller's cache-backed cluster client returns stale
or unavailable cluster connections during apiserver restart.
This is a more specific instance of the LB-broken FM-13: the LB
is up but the cache is stale. KCP relies on MHC's view of
machine health, so a stale view can mis-trigger remediation.

Seeds: **FM-34 — stale MHC cluster-cache during apiserver
restart**. Model as a `MhcCacheStale(m)` action that decouples
`observation[m]` from the underlying `etcdReachable` for a
window. Apalache should verify that under stepNoRecovery,
HealthyControlPlane is still reachable once the cache invalidates
(short-lived).

### #12886 — [e2e test] Cluster API working on self-hosted clusters using ClusterClass failing with timed out error

**Status**: open, /kind bug.

Self-hosted CAPI: the management cluster IS the workload
cluster's control plane. Reconcile loops can deadlock during
upgrade if the management cluster's KCP rolls itself.

Seeds: **FM-35 — self-hosted upgrade deadlock**. Captures the
"KCP rolls its own host" feedback loop where the reconciler pod
must pause its own Node to upgrade it, but pausing the Node halts
reconciliation.

**Phase 12 verdict.** A new `formal/specs/SelfHosted.qnt` module
captures FM-35's dynamics with a focused 3-machine self-hosted
model:
- States: `mgmtMachines`, `kcpHost`, `kcpStatus`,
  `machinePaused`, `machineTemplate`, `desiredMgmtTemplate`,
  `wlIsMgmt`, `upgradePhase`.
- Actions: `OperatorBumpTemplate`, `KcpStartUpgrade`,
  `KcpUpgradeMachine`, `KcpUpgradeOwnHost` (deadlock entry),
  `KcpReconcileResume` (operator workaround).
- Verdict: `selfHostedDeadlockTrace` reaches the `Deadlocked`
  state in 4 steps; `selfHostedRecoveryTrace` from the deadlock
  init resolves via `KcpReconcileResume` (operator manually
  re-hosts the KCP pod on a healthy non-paused Machine).

A faithful proof against the full Lifecycle.qnt would require
the per-cluster expansion described in
`/home/naadir/.claude/plans/immutable-wibbling-dewdrop.md` Phase
12 (every state variable wrapped to `ClusterId -> X`, every
action gaining a `cluster` parameter). The SelfHosted.qnt module
captures the load-bearing FM-35 dynamics without that refactor.

### #13508 — Machine drain stuck indefinitely when node is unreachable and PDBs block eviction

**Status**: open, /kind bug.

When a Machine is being deleted and the underlying Node is
unreachable, drain stalls because PodDisruptionBudgets cannot be
evaluated. Combined with an unhealthy KCP node this can block
remediation indefinitely.

Seeds: **FM-23 (revised)** and **FM-36 — drain-blocked-by-PDB
during remediation**. The current model has `DeleteFailedMachine`
as an atomic action; reality is a multi-stage drain that can stall.

### #10949 — Consider if to add more on KCP checks on machine status

**Status**: open, /kind feature.

Discussion of additional KCP preflight checks beyond the
existing set. Potential model extensions but not a concrete bug.
Recorded for the issue corpus.

### #8942 — BeforeClusterUpgrade is not called with cp unavailable

**Status**: open.

Lifecycle hook (`BeforeClusterUpgrade`) is skipped when the
control plane is unavailable. Hooks in the formal model are not
yet captured; introducing them is FM-37.

Seeds: **FM-37 — lifecycle hook skipped under control-plane
unavailability**. Model as a hook-state variable plus
verification that hook firing matches the contract regardless of
cluster health.

### Provider issues

| Issue | Provider | Maps to |
|---|---|---|
| capa-provider#4198 — Enable CAPI kcp remediation tests in CAPA | AWS | FM-1, FM-2, FM-3 (provider-side coverage) |
| capz-provider#1660 — Automatic certificate rotation | Azure | FM-26 (workload apiserver TLS expiry) |
| capz-provider#5546 — Inconsistencies with MachinePools during Kubernetes upgrade | Azure | FM-15 (upgrade in flight) |
| capv-provider#3866 — Problem while upgrading existing cluster from 1.32 to 1.33 | vSphere | FM-15 (upgrade in flight) |

Provider repos have far fewer issue-level discussions of control-
plane choreography failures because most of that lives in CAPI
core. Each provider has a long tail of provider-specific
infrastructure bugs (cloud API failures, instance metadata,
networking) that interact with the control-plane lifecycle but
are not failure modes of the lifecycle itself — they are
exogenous fault classes the model already abstracts via
`Partition`, `LbBroken`, `NodeNeverJoins`, etc.

## Tier 3 — surveyed but not modelled this round

| Issue | One-liner | Reason for parking |
|---|---|---|
| capi#10911 | Deleting retries history during KCP remediation | Bug in retry-state persistence; orthogonal to convergence |
| capi#12553 | Add maxRetry to RemediationStrategy in Machinedeployment | Worker-machine, not control-plane |
| capi#7459 | Highly available CAPI management components | Architectural feature, not a failure mode |
| capi#5291 | Improve UX of MachineHealthCheck status fields | UX, not a model concern |
| capi#11944 | Events generation for cluster-state changes | Observability, not a failure mode |
| capi#13315 | Research on joining nodes in older versions | Compat work |

## Methodology note

This research uses GitHub's issue search through `gh search
issues`. Rate limit is 30 queries / minute on a personal token;
the research above used ~16 queries serial-spaced. To
re-run:

```sh
for q in "KCP stuck" "etcd quorum" "etcd learner" "preflight" \
         "MachineHealthCheck" "control plane upgrade" \
         "scale control plane" "remediation" \
         "NodeRef not set"; do
  gh search issues "$q" \
     --repo kubernetes-sigs/cluster-api \
     --state open --limit 10 --json number,title,createdAt,url
  sleep 1
done
```

Issues found in `tier 1` and `tier 2` are seeds for the
FM-17..FM-40 range introduced in `failure-modes.md` after this
research.
