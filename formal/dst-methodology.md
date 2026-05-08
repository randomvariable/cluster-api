# Deterministic simulation testing methodology for CAPI

This document collects the fault-injection and trace-replay
patterns the formal corpus relies on. The intent is to bridge
the gap between abstract actions across all spec modules
(`Partition(m)`, `LbBroken`, `EtcdJoinTimeout(m)`,
`InfraClusterProvision`, `OperatorBumpVersion`, …) and concrete,
reproducible operations on a CAPD-based test cluster.

The methodology applies to every spec in the corpus —
`Lifecycle.qnt`, `Topology.qnt`, `MachineSetPreflight.qnt`,
`InPlaceUpdate.qnt`, and the end-to-end `ClusterE2E.qnt`. The
controller-runtime substrate (`ControllerRuntime.qnt`) is
verified analytically rather than via DST since its faults
(leader loss, cache lag) reduce to ordering invariants on the
abstract substrate state.

The approach takes its cues from public DST literature —
notably Hsieh et al. (NSDI 2017), Conway et al. (FoundationDB,
SIGMOD 2013), and the madsim ecosystem — adapted to the
CAPI/Docker reality where we don't control the runtime kernel
and have to reach into the workload cluster from outside.

## 1. Determinism budget

True deterministic simulation requires:

1. A virtual time source the system reads instead of wall-clock.
2. A deterministic scheduler that picks the next-to-run goroutine
   from a known queue.
3. A virtual network and disk that obey injected fault models.

CAPI's controllers are built on controller-runtime, which uses
real clocks and the kernel scheduler, so we cannot achieve full
DST without rewriting them. The pragmatic alternative is a
**determinism budget** — explicit envelopes within which we *can*
guarantee deterministic ordering:

| Budget | What we control | What we cannot |
|---|---|---|
| **Per-test seeded RNG** | The Quint simulator's random walk; the `--seed` flag in `quint run` and `quint verify` produces byte-for-byte identical traces. | controller-runtime reconcile order. |
| **Frozen-clock fakes** | Fake workload-cluster clients in `fakes_test.go` can read a frozen time; any new Quint→Go fixture should follow this pattern. | Real CAPD-spawned containers run on host clock. |
| **Single-process reconcilers** | When CAPI is launched with `--reconciler-concurrency=1` (development default), reconcile order is deterministic given a fixed input set. | Production runs concurrent reconcilers; the model abstracts this away. |
| **Fault-injection determinism** | `docker pause` / `unpause` are atomic on the daemon's clock; once issued, the effect on the workload cluster is observable within a known small window (sub-second). | Network latency between management cluster and workload cluster's apiserver LB. |

The model's `step` relation is non-deterministic; the runtime's
behaviour is non-deterministic; convergence proofs are over the
**closure** of the model's reachable states rather than a single
trace. Determinism enters only at the seed level (Quint) and the
fault-injection-action level (CAPD).

## 2. Fault catalogue

Every `Partition(m)`, `LbBroken`, `EtcdJoinTimeout(m)`, etc. in
the model has a concrete CAPD operation. The table below is the
authoritative mapping; e2e specs should pick exactly one row per
fault they inject.

| Model action | CAPD operation | Effect | Reversibility |
|---|---|---|---|
| `Partition(m)` | `docker pause <node-container>` | Halts every process inside the container — etcd, kubelet, apiserver, kube-proxy. From the management cluster's perspective every gRPC and HTTP probe to the paused node times out. | `docker unpause <node-container>` — instantaneous; processes resume from their last syscall. |
| `LbBroken` | `docker pause <cluster-name>-lb` | The HAProxy LB sitting in front of the workload-cluster apiservers stalls. KCP's apiserver client and `etcd.Client` both time out. | `docker unpause <cluster-name>-lb`. |
| `EtcdJoinTimeout(m)` | `docker stop --signal=SIGSTOP <node-container>` then `docker exec <node-container> rm /var/lib/kubelet/config.yaml` | Kubelet remains stopped; subsequent `docker start` triggers kubeadm-join which fails because the kubelet config is gone. | `docker exec` to re-write the config and start kubelet — requires test-side regeneration. Better: use `docker rm` to nuke the node and let CAPD's reconcile loop recreate it. |
| `InvalidKubeletConfig(m)` | `docker exec <node-container> sed -i 's@<apiserver-endpoint>@:9999@' /etc/kubernetes/kubelet.conf` then `docker exec <node-container> systemctl restart kubelet` | Kubelet starts but cannot reach the apiserver. Node never registers; NodeRef stays unset on the Machine. | Restore `/etc/kubernetes/kubelet.conf` and restart kubelet. Or `docker rm` for full reset. |
| `NodeNeverJoins(m)` | `iptables -I OUTPUT --dst <apiserver-LB-IP> -p tcp --dport 6443 -j DROP` inside the node container | Kubelet runs but every TCP connection to the apiserver is dropped. Node never registers. | `iptables -D OUTPUT ...`. |
| `LearnerStuck(id)` | `docker exec <node-container> tc qdisc add dev eth0 root netem delay 5000ms` on the *learner's* container | etcd's gRPC heartbeats from the leader to the learner take 5 s, exceeding the leader's `election-timeout`. The learner's match-progress never reaches the threshold; KCP's view of `is_learner=true` stays stuck. | `tc qdisc del dev eth0 root`. |
| `HealEtcdReachability(m)` | `docker unpause <node-container>` (or any of the partition-recovery counterparts above) | Restore network reachability for the affected node. | n/a — this IS the recovery. |
| `RestoreClusterFromSnapshot(m)` | `clusterctl alpha restore --filename=etcd-snapshot.db` (provider-specific). For the formal model this is operator-driven. | The restore atomically rebuilds a single-voter etcd cluster on `m`. | n/a — recovery action. |

## 3. Bursty fault models — Gilbert-Elliott in shell

The model's exogenous fault actions are atomic on/off events. Real
network partitions are bursty. To test KCP's tolerance to
bursty faults, the e2e spec can drive a **Gilbert-Elliott** model
on the LB:

```
state = "good"
while not done:
    if state == "good":
        sleep uniform(2..10)
        if rand() < 0.2:
            state = "bad"
            docker pause $LB
    else:
        sleep uniform(0.2..3)
        if rand() < 0.5:
            state = "good"
            docker unpause $LB
```

Two states: `good` (LB up, mean dwell ~6 s) and `bad` (LB
paused, mean dwell ~1 s). Transition probabilities derived from
the parameters give a mean burst length of ~3 LB outages per
minute, each a few hundred milliseconds. The model action that
maps to this is repeated `LbBroken; HealLb` pairs at random
intervals — the Apalache proof of FM-13 hopelessness still holds
within each `bad` window, which is the relevant claim.

The test runner picks the seed for the `rand()` invocations from
`GINKGO_RANDOM_SEED` so the burst pattern is reproducible.

## 4. Pareto buggify — rare-event fault injection

Many production failures look like the FM-1
incident: a low-frequency triggering event that, once present,
holds the cluster in an unrecoverable state. To exercise these,
inject faults with **Pareto-distributed inter-arrival times**:
many short delays, occasionally a long one. The CAPI build under
test is more likely to fail when faults stack.

```
sleep $(awk -v u=$(printf '0.%04d' $((RANDOM % 9999))) \
            'BEGIN { print 0.1 / (u^0.7) }')
```

That sleep produces a Pareto(α=1/0.7≈1.43) distribution: most
sleeps are sub-second; rarely the next fault waits 10+ minutes.
Combined with the fault catalogue above, this gives a
ParetoBuggify shell that runs alongside the e2e spec and trips
random cluster faults.

Used for: long-running soak tests of the recovery mechanism. Not
useful for verifying specific safety / liveness invariants
(which need bounded fault injection).

## 5. Trace replay

`internal/trace/itf.go` consumes Quint's Informal Trace Format.
Quint's `quint run --out-itf=trace.itf.json` produces an ITF
trace; the trace-validator CLI replays it against the Go
checkers in `internal/trace/checkers/`. This is how a model
counterexample becomes a runtime-verifiable assertion:

```sh
# 1. Quint discovers a counterexample to a safety invariant
quint run --invariant=AllSafetyInvariants \
          --out-itf=cex.itf.json \
          formal/specs/Lifecycle.qnt

# 2. Replay the trace against the Go checkers
hack/tools/bin/trace-validator --format=itf cex.itf.json
```

If the Go checkers find a violation matching the Quint
counterexample, the refinement holds — the runtime correctly
detects the same shape the model identified. If not, the
abstraction-mapping row is wrong.

## 6. Capability matrix — what CAPD can / cannot inject

| Fault class | CAPD-injectable? | Notes |
|---|---|---|
| Network partition (host ↔ container) | **Yes** | `docker pause` (atomic), `iptables -j DROP` (selective). |
| Network latency | **Yes** | `tc qdisc add ... netem delay`. |
| Network packet loss | **Yes** | `tc qdisc add ... netem loss`. |
| Slow disk I/O | **Yes (limited)** | Bind-mount over `tmpfs` with size limits; or `dmsetup delay` on a loopback file. |
| Disk full | **Yes** | `dd if=/dev/zero of=/var/lib/etcd/junk` inside the container. |
| Process kill | **Yes** | `docker exec <c> kill -9 <pid>` for etcd, kubelet, apiserver. |
| Clock skew | **No** | Containers share host clock. Could be done with a custom NTP container, not part of the standard CAPD setup. |
| Etcd corruption | **Partial** | Direct manipulation of `/var/lib/etcd/member/snap/`; not idempotent and may not survive recovery. |
| Kernel OOM | **Yes** | `docker update --memory=64m <c>`. |
| Token / cert expiry | **Yes** | Edit `/etc/kubernetes/pki/*` mtime; or generate a cert with a near-past `NotAfter`. |
| Watch storm (apiserver re-list) | **Yes** | Restart `kube-apiserver` repeatedly via `docker exec`. |

The matrix above bounds the corpus of FMs we can exercise as e2e
tests on a developer laptop. Failure modes outside the
"injectable" rows are documented in the model and verified via
TLC/Apalache, but not via runtime test.

## 7. Recommended e2e spec template

Every new fault-injecting e2e spec under `test/e2e/` should
follow this skeleton (FM-2's `fm2_quorum_loss.go` is the working
example):

```go
1. Bring up a workload cluster (1, 3, or 5 CP).
2. Wait until every CP Machine has Status.NodeRef.IsDefined().
3. Capture the baseline Machine name set.
4. Inject the fault from §2.
5. Consistently(<observe-window>):
       no Machine added / removed from the baseline set.
6. Reverse the fault.
7. Consistently(<observe-window>):
       Machine set still equal to baseline (no spurious churn).
8. AfterEach: cleanup the cluster regardless of pass/fail.
```

The load-bearing assertion is always the
`Consistently(machine-set == baseline)` block. Any per-condition
probe (`EtcdMemberHealthy != True`) is a sanity check, not a
proof — etcd Status RPC has a 2-min timeout and conditions can
take many minutes to propagate. The model says nothing about
condition timing; it says the cluster's *effective topology*
must not regress.
