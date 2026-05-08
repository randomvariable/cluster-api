# What KCP relies on from kubeadm and the kubeadm-managed etcd

> Status: Authoritative. Pinned upstream at the SHA recorded in
> [`commits.yaml`](./commits.yaml) under `repos.kubernetes.sha`.
>
> Conformance keywords (MUST / MUST NOT / SHOULD / SHOULD NOT / MAY)
> follow [RFC 2119](https://datatracker.ietf.org/doc/html/rfc2119).

## Purpose

The Kubeadm Control Plane provider (KCP) does not bootstrap etcd
members directly. It instructs Bootstrap to run `kubeadm join
--control-plane` on each new control-plane Machine; kubeadm in turn
issues the etcd-side membership RPCs against the existing cluster.
Several invariants in the formal model in
[`../specs/`](../specs/) — most notably `IncidentWitness` in
[`../specs/Composition.qnt`](../specs/Composition.qnt) — depend on
kubeadm-join's observable side-effects matching the assumptions
documented here.

This document is the union of behaviours that:

- KCP can observe directly through the workload-cluster API
  surface (etcd `MemberList`, `Status`; Node Ready conditions on
  the workload-cluster apiserver), AND
- KCP relies on as inputs to `canSafelyRemediateMachine`,
  preflight, and condition derivation.

## Scope

This contract covers the `Etcd.Local` (stacked) deployment shape.
The `Etcd.External` shape is out of scope here: the cluster
operator owns the etcd lifecycle and KCP's contact with etcd is
limited to client probes already covered by the
[`etcd-raft-contract.md`](./etcd-raft-contract.md).

## 1. kubeadm-join phase ordering

`kubeadm join --control-plane` runs the phases below in this order
when none are skipped. The list is the appended phase sequence in
`cmd/kubeadm/app/cmd/join.go::newCmdJoin`, lines 222–229:

1. `preflight`
2. `control-plane-prepare`
3. `check-etcd`
4. `kubelet-start`
5. `control-plane-join` → subphase `etcd`
6. `kubelet-wait-bootstrap`
7. `control-plane-join` → subphase `update-status`
8. `wait-control-plane`

The KCP-relevant invariants are:

- **K1** — `kubelet-start` MUST complete before `control-plane-join
  / etcd` runs the `Cluster.MemberAddAsLearner` RPC. The
  `KubeadmJoin.qnt` model captures this with the
  `KubeletStarted` action transitioning to `EtcdJoinAddLearner`.
- **K2** — A successful `Cluster.MemberAddAsLearner` MUST be
  followed by either (a) a successful `Cluster.MemberPromote` and
  the run progressing to `wait-control-plane`, or (b) a join
  failure on the joining Machine. There is no observable phase
  that registers an etcd member without subsequently promoting it
  in the same join run.
- **K3** — The Node corresponding to the joining Machine MUST
  register with the workload-cluster apiserver before
  `wait-control-plane` returns. Until that happens KCP cannot
  match the Machine to an etcd member by node name.

Cited from `cmd/kubeadm/app/cmd/join.go::newCmdJoin` at the SHA
in [`commits.yaml`](./commits.yaml).

## 2. Static-pod manifest shape

When kubeadm writes the etcd static-pod manifest at
`/etc/kubernetes/manifests/etcd.yaml`, the manifest's command,
ports, probes, and volume mounts are determined by
`cmd/kubeadm/app/phases/etcd/local.go::GetEtcdPodSpec` and the
helper `getEtcdCommand`.

### 2.1 Command flags KCP relies on as observable side-effects

The following flags are written into the manifest by
`getEtcdCommand`. KCP does not modify the manifest, but the
condition derivation in `controlplane/kubeadm/internal/workload_cluster_conditions.go`
and the etcd client routing in `internal/etcd/etcd.go` assume
they are present in the listed shape:

| Flag | KCP-observable consequence |
|---|---|
| `--name=${nodeName}` | The etcd member's `Member.name` field equals the joining Machine's node name. KCP's `compareMachinesAndMembers` matches members to Machines by exactly this string. |
| `--listen-client-urls=...,https://${advertise}:2379` | The client port 2379 is reachable on the advertise address. KCP's etcd client dialer assumes 2379 with mTLS. |
| `--advertise-client-urls=https://${advertise}:2379` | `Member.client_urls` reports this address. |
| `--listen-peer-urls=https://${advertise}:2380` | Peer transport is on 2380. |
| `--client-cert-auth=true` | Client mTLS is mandatory. KCP's client cert pair is `apiserver-etcd-client.{crt,key}` (per the cert chain documented in §3 below). |
| `--peer-client-cert-auth=true` | Peer mTLS is mandatory. |
| `--listen-metrics-urls=http://127.0.0.1:2381` | The `/livez` and `/readyz` HTTP endpoints are bound on port 2381 only. KCP does NOT probe this port; the kubelet does. |

Cited from `cmd/kubeadm/app/phases/etcd/local.go::getEtcdCommand`,
defaultArguments slice, at the pinned SHA.

### 2.2 Constants

- **C1** — etcd client port: **2379** (`kubeadmconstants.EtcdListenClientPort`).
- **C2** — etcd peer port: **2380** (`kubeadmconstants.EtcdListenPeerPort`).
- **C3** — etcd metrics + probe port: **2381** (`kubeadmconstants.EtcdMetricsPort`).
- **C4** — etcd API call timeout: **2 minutes** (`kubeadmconstants.EtcdAPICallTimeout`).
- **C5** — etcd API retry interval: **500 ms** (`kubeadmconstants.EtcdAPICallRetryInterval`).

Cited from `cmd/kubeadm/app/constants/constants.go` at lines 95
(C1), 97 (C3), 107 (C2), 229 (C4), 231 (C5) at the pinned SHA.

### 2.3 Probes

The static-pod manifest declares three probes (cited from
`local.go` lines 215–225):

- Liveness: `GET http://${probeHostname}:2381/livez`
- Readiness: `GET http://${probeHostname}:2381/readyz`
- Startup: `GET http://${probeHostname}:2381/readyz`

KCP does NOT consume these probes directly. They appear in this
contract only because the kubelet's failure to reach
`/readyz` blocks the Pod from going Ready, which in turn blocks
`kubelet-wait-bootstrap` and therefore blocks the joining Machine
from receiving a Node registration — which IS a KCP-observable
side-effect. The model captures this transitively through the
`KubeletStarted` → `EtcdQuorumReady` ordering in
`KubeadmJoin.qnt`.

## 3. Certificate chain assumptions

KCP assumes that the cert chain kubeadm generates (or has been
provided externally) lives under `/etc/kubernetes/pki/etcd/` on
each control-plane host with the file names below. KCP itself
does NOT generate these files; the Bootstrap controller is
responsible for ensuring kubeadm-init or kubeadm-join produces
them.

| File | CN | EKUs | Used by |
|---|---|---|---|
| `etcd/ca.{crt,key}` | `etcd-ca` | (CA) | All etcd trust |
| `etcd/server.{crt,key}` | `${nodeName}` | ServerAuth + ClientAuth | etcd's client API on 2379 |
| `etcd/peer.{crt,key}` | `${nodeName}` | ServerAuth + ClientAuth | etcd peer transport on 2380 |
| `etcd/healthcheck-client.{crt,key}` | `kube-etcd-healthcheck-client` | ClientAuth | kubeadm's own etcd RPCs |
| `apiserver-etcd-client.{crt,key}` | `kube-apiserver-etcd-client` | ClientAuth | kube-apiserver AND KCP's `internal/etcd/etcd.go` client |

Cited from `cmd/kubeadm/app/phases/certs/certlist.go` at the
pinned SHA.

The dual-EKU server cert is unusual but required: etcd 3.2+
presents the server cert as the client cert during peer
handshakes. KCP's own client connections do NOT rely on this
detail; it is documented here because operators replacing
kubeadm-generated certs with externally-managed ones often miss
it and produce a quietly-broken peer transport.

## 4. gRPC RPCs kubeadm invokes during join and reset

`kubeadm` is itself an etcd v3 gRPC client. The minimum surface it
exercises against the existing cluster is:

| RPC | Phase | What kubeadm reads |
|---|---|---|
| `Cluster.MemberList` | `check-etcd`, `update-status`, reset | `Members[].{ID, Name, PeerURLs, IsLearner}` |
| `Cluster.MemberAddAsLearner` | `control-plane-join / etcd` | full updated `Members[]` |
| `Cluster.MemberPromote` | `control-plane-join / etcd` (after the joiner is up) | error or nil |
| `Cluster.MemberRemove` | reset | full updated `Members[]` |
| `Maintenance.Status` | `check-etcd`, upgrade, health | presence of OK response |

Cited from `cmd/kubeadm/app/util/etcd/etcd.go` at the pinned SHA,
lines 79 (MemberAddAsLearner declaration), 82 (MemberRemove
declaration), 287 (listMembersOnce), 397 (MemberRemove call site),
488 (MemberAddAsLearner call site), 575 (MemberPromote).

### 4.1 Idempotence sentinels (MUST)

kubeadm's retry loop relies on two specific gRPC error sentinels.
The contract is on etcd, not on kubeadm — but KCP's own retry
behaviour assumes etcd produces these errors faithfully because
KCP cannot retry kubeadm-join without breaking idempotence.

- **R1** — `Cluster.MemberRemove(id)` of an already-removed `id`
  MUST return `etcdserver.ErrMemberNotFound` (matched at
  `cmd/kubeadm/app/util/etcd/etcd.go:402` via `errors.Is`).
- **R2** — `Cluster.MemberAddAsLearner(peerURLs)` against a
  cluster that already contains a member with the same peer URL
  MUST return `etcdserver.ErrPeerURLExist` (matched at
  `cmd/kubeadm/app/util/etcd/etcd.go:500`).

Both are formal contracts on the etcd implementation. They are
documented here because the join/reset call sites that rely on
them are in kubeadm; the [`etcd-raft-contract.md`](./etcd-raft-contract.md)
re-states them on etcd's side.

### 4.2 What kubeadm does NOT use

- `Cluster.MemberAdd` (the non-learner variant). Kubeadm always
  joins via learner first. KCP must not assume any other path.
- `Cluster.MemberUpdate`. Not exercised.
- `Maintenance.Alarm`. Not exercised by kubeadm; KCP queries it
  separately via `internal/etcd/etcd.go`.
- All `KV.*` RPCs. kubeadm does NOT seed cluster state via etcd
  KV; that is the apiserver's job.
- All `Auth.*` RPCs. mTLS is the only auth surface.

## 5. Lifecycle invariants visible to KCP

The formal model in [`../specs/KubeadmJoin.qnt`](../specs/KubeadmJoin.qnt)
collapses kubeadm's eight-phase sequence into five observable
phases. The mapping is:

| KubeadmJoin.qnt phase | kubeadm phase(s) | Observable side-effect |
|---|---|---|
| `Preflight` | `preflight`, `control-plane-prepare`, `check-etcd` | None visible to KCP except via failure. |
| `KubeletStart` | `kubelet-start` | The new control-plane host's kubelet is running and reaches the workload-cluster apiserver. |
| `EtcdJoinAddLearner` | `control-plane-join / etcd` (RPC dispatch) | A new entry appears in `MemberList` with `is_learner=true` and an empty `name`. |
| `WaitForEtcdQuorum` | `control-plane-join / etcd` (post-RPC wait) | `is_learner` flips to false on a subsequent `MemberList`; `name` populates. |
| `MarkControlPlaneReady` | `kubelet-wait-bootstrap`, `control-plane-join / update-status`, `wait-control-plane` | `Machine.status.nodeRef` resolves; `KubeadmControlPlane.status.replicas` reflects the new Machine. |

Cited from `cmd/kubeadm/app/cmd/join.go` and the underlying
phase implementations at the pinned SHA.

## 6. The user-reported incident in this vocabulary

The incident under
`KubeadmControlPlane=ns-vault-prod-ky8ns/kvp22096-98cda1-fpx9t`
exhibits a join run that reached `kubelet-start`,
successfully ran `Cluster.MemberAddAsLearner`, and then stalled.
The corresponding `KubeadmJoin.qnt` trace is:

```
init
  → BeginJoin
  → PreflightPass
  → KubeletStarted
  → EtcdAddLearnerSucceeded
  → JoinFailedAt(LearnerStuckOnPromote)
```

Per **K2**, kubeadm's `wait-control-plane` does not return until
the new member has been promoted. The promotion never fires
(presumed cause: etcd client routing under partition; the
formal model treats the cause as exogenous via the
`LearnerStuck` fault action in `EtcdMembership.qnt`). The Node
never registers per **K3**, so KCP cannot match the new etcd
member to its Machine.

## 7. Conformance summary

| ID | Statement | Source citation |
|---|---|---|
| K1 | `kubelet-start` precedes `control-plane-join / etcd` | `cmd/kubeadm/app/cmd/join.go:225–226` |
| K2 | Learner add MUST be followed by promote or join failure | `cmd/kubeadm/app/cmd/join.go:226–228` |
| K3 | Node registration MUST occur before `wait-control-plane` returns | `cmd/kubeadm/app/cmd/join.go:228–229` |
| C1–C5 | Constants for ports and timeouts | `cmd/kubeadm/app/constants/constants.go:95,97,107,229,231` |
| R1 | MemberRemove of unknown id returns ErrMemberNotFound | `cmd/kubeadm/app/util/etcd/etcd.go:402` |
| R2 | MemberAddAsLearner with existing URL returns ErrPeerURLExist | `cmd/kubeadm/app/util/etcd/etcd.go:500` |

When a row's `Source citation` line range no longer matches the
documented behaviour at the pinned SHA, the row is stale — file
a counterexample-log entry with `Spec=kubeadm-etcd-contract`,
`Action=<row id>`, classification `manual-review`, and bump the
SHA in `commits.yaml` once the upstream change has been
incorporated into the model.
