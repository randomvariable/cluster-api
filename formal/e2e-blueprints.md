# e2e blueprints — TBD failure-mode reproducers

`test/e2e/fm2_quorum_loss.go` is the working example. The
following blueprints sketch the spec body for additional FMs
that are realistic to implement on a CAPD-based test
infrastructure. Each blueprint is ~150 LoC of Go and ~5–25
minutes of e2e wall time.

The blueprints below are KCP-focused (FM-1..FM-24) — these are
the FMs with the most operational urgency and the clearest
docker-primitive mapping. The non-KCP failure modes (FM-33,
FM-39..FM-50) are largely modelling-level invariants of upstream
contracts; they don't have concrete failure shapes that a CAPD
test can reproduce. Future work could add e2e blueprints for
e.g. multi-step upgrade hook ordering (FM-39) or in-place
update idempotence (FM-43), but the marginal value is low.

The fault catalogue in `dst-methodology.md` §2 maps every
abstract action to a Docker primitive. The blueprints below cite
the Docker primitive(s) each spec will use.

## FM-3 — Persistent etcd unreachability (3-node, network partition)

**Docker primitive**: `iptables -I OUTPUT -d <other-cp-ip> -p tcp --dport 2379:2380 -j DROP` inside each CP container, isolating etcd's client + peer ports from the others. Or simpler: `docker network disconnect kind <node-container>` to remove the container from the kind network entirely.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster as in fm2_quorum_loss.go.
// 2. Pick the leader Machine (use etcdctl to identify) and 1 follower.
// 3. iptables-isolate them from the third CP container.
// 4. Consistently(no Machine deleted) for 3 min.
// 5. iptables-restore connectivity.
// 6. Consistently(no Machine churn) for 3 min.
```

**Asserts**: same as FM-2 — Machine set stable through partition + recovery.

## FM-13 — apiserver LB proxy broken

**Docker primitive**: `docker pause <cluster-name>-lb`.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster.
// 2. docker pause $CLUSTER-lb.
// 3. Eventually(EtcdMemberHealthy != True on all CP Machines)
//    — wait window long because LB pause removes apiserver
//    reachability for the entire cluster (5–10 min).
// 4. Consistently(no Machine deleted) for 3 min.
// 5. docker unpause $CLUSTER-lb.
// 6. Eventually(EtcdMemberHealthy = True on all) within wait-cluster.
```

**Asserts**: when LB returns errors, KCP cannot determine cluster health and refuses to act. When LB heals, KCP resumes normal operation without spurious churn.

## FM-15 — Upgrade in flight

**Docker primitive**: clusterctl-driven; no fault injection.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster at v1.34.0.
// 2. Patch KubeadmControlPlane.spec.version = v1.35.0.
// 3. Eventually(KCP.status.readyReplicas == 3 && all Machines on v1.35.0)
//    within wait-cluster (15+ min for rolling upgrade).
// 4. Consistently(no spurious remediation during the rollout).
```

**Asserts**: rolling upgrade completes; the KCP gates serialise the membership changes correctly so only one Machine is mid-replacement at any time.

## FM-19 — apiserver restart relist storm

**Docker primitive**: `docker exec <leader-cp-container> kubectl --kubeconfig=/etc/kubernetes/admin.conf delete pod -n kube-system kube-apiserver-<leader-host>`.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster.
// 2. Identify the leader's CP container.
// 3. kubectl delete kube-apiserver pod on the leader.
// 4. Consistently(no Machine churn) for 1 min while apiserver restarts.
// 5. Eventually(KCP shows healthy) within 2 min.
```

**Asserts**: apiserver restart doesn't trigger MHC remediation false-positive.

## FM-23 — Drain stuck on PDB

**Docker primitive**: deploy a PDB on a kube-system pod (coredns) with `maxUnavailable: 0`; then trigger remediation on the Machine hosting that pod by adding `mhc-test=fail` label.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster (kcp-remediation flavor with bootstrap signal).
// 2. Apply PDB on the workload cluster: maxUnavailable: 0 over coredns.
// 3. Patch one CP Machine with mhc-test=fail label.
// 4. Eventually(MachineHealthCheck flags it) within 30s.
// 5. Eventually(Machine deletion is initiated) within 1 min.
// 6. Consistently(Machine is NOT actually deleted, drain stalls) for 5 min.
//    [Asserts: KCP correctly waits on the drain.]
// 7. Remove the PDB.
// 8. Eventually(Machine deletion completes + replacement up) within 10 min.
```

**Asserts**: KCP waits on drain when PDBs block it; once PDBs are removed the deletion proceeds and the cluster recovers.

## FM-24 — Etcd defrag pause

**Docker primitive**: `docker exec <leader-cp> ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/peer.crt --key=/etc/kubernetes/pki/etcd/peer.key defrag`.

**Spec sketch**:

```go
// 1. Bring up 3-CP cluster.
// 2. Write a workload to fill etcd to ~50% of quota (synthetic ConfigMaps).
// 3. Run etcdctl defrag on the leader.
// 4. During the defrag (10–60s), Consistently(no Machine churn).
// 5. After defrag completes, Eventually(EtcdMemberHealthy = True on all).
```

**Asserts**: defrag pause produces transient EtcdMemberHealthy=Unknown but no spurious remediation.

## What is NOT covered by an e2e blueprint

The catalogue includes failure modes that CAPD cannot reproduce
on a developer laptop:

| FM | Why no e2e |
|---|---|
| FM-9 fairness gap | Model-side gap, not a runtime concern |
| FM-26 workload apiserver TLS expiry | Requires fast-forward of system clock or pre-expired cert; out of scope |
| FM-31 custom Node conditions | Feature request, not a failure |
| FM-35 self-hosted upgrade deadlock | Requires self-hosted topology, not standard CAPD |

All other modes (FM-1, FM-2, FM-3, FM-5, FM-6, FM-10, FM-11,
FM-12, FM-13, FM-14, FM-15, FM-17, FM-18, FM-19, FM-20, FM-21,
FM-22, FM-23, FM-24) have CAPD-realisable e2e shapes, summarised
either above or by analogy to FM-2's working spec.

## Implementation order (recommended)

1. **FM-3** — variant of FM-2's pattern; ~1 day to implement and test.
2. **FM-13** — same shape as FM-2 with the LB container instead of CP nodes.
3. **FM-15** — pure clusterctl-driven; no fault injection; longest e2e but well-understood.
4. **FM-23** — exercises PDB-blocked drain; longest spec.
5. **FM-19, FM-24** — short-window faults; quickest specs.

The `WaitForControlPlaneIntervals` for each spec should follow
the catalogue in `test/e2e/config/docker.yaml` —
`fm2-quorum-loss/*` keys are the pattern; add per-FM keys as
specs land.

## Trace recording (issue #8)

Every FM-* e2e spec wires a `tracerecord.E2ERecorder` (in
`test/e2e/internal/tracerecord/`) that writes JSON-Lines events
to `<ArtifactFolder>/trace/<scenario>.trace.jsonl`. The recorder
is observer-style: the e2e test reads Kubernetes object state
via the management cluster proxy and emits a `TraceRecord`
whenever it observes a spec-relevant transition. The CAPI
controllers themselves are not modified — this keeps the wiring
strictly inside `test/e2e/` and the upstream binaries
unaffected.

After the e2e finishes, `make test-e2e-trace` builds the
`hack/tools/trace-validator/` binary and runs every checker in
`internal/trace/checkers/` against each recorded trace. The
target exits non-zero if any checker reports a violation or if
no trace files were produced.

The CI gate (`scripts/verify-formal.sh`) does NOT run the CAPD
e2e (too heavy for a per-commit gate). Instead, it runs
`internal/trace/recorder_validator_integration_test.go`, which
exercises the same recorder → JSONL → loader → checker pipeline
on a synthesised FM-2-shaped trace and asserts a green verdict.
That test is the CI-runnable counterpart to the CAPD e2e and
guards against silent regressions in the recorder/loader
plumbing.

Adding trace recording to a new FM-* spec is three steps:

1. In the spec's main test body, after the cluster reaches
   steady state, call `tracerecord.Start(input.ArtifactFolder,
   "<scenario>")` and `defer` the returned close function.
2. Once the initial voter set is observable, call
   `recorder.Bootstrap(<nodeNames>)`.
3. As the test progresses, emit transition events
   (`AddLearner`, `RemoveMember`, `PromoteLearner`,
   `ObserveLearnerProgress`) at the points where the spec's
   abstraction-mapping row would fire the corresponding
   action. The Bootstrap-only path is sufficient for FMs whose
   load-bearing assertion is the absence of membership change
   (FM-2's hopelessness, for example).
