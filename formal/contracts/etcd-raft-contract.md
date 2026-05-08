# What KCP relies on from etcd's Raft membership semantics

> Status: Authoritative. Pinned upstream at the SHA recorded in
> [`commits.yaml`](./commits.yaml) under `repos.etcd.sha`.
>
> Conformance keywords (MUST / MUST NOT / SHOULD / SHOULD NOT / MAY)
> follow [RFC 2119](https://datatracker.ietf.org/doc/html/rfc2119).

## Purpose

The formal model in [`../specs/EtcdMembership.qnt`](../specs/EtcdMembership.qnt)
abstracts etcd's Raft membership semantics. This contract pins the
specific etcd behaviours the model assumes, so a future etcd
release that deviates from any of them produces a counterexample
in the model rather than silent breakage in production.

## Scope

This contract covers:

- The learner-then-promote membership-change protocol etcd uses
  for new members.
- The leader-side promote-eligibility check that gates
  `MemberPromote`.
- The error sentinels that the kubeadm contract
  ([`kubeadm-etcd-contract.md`](./kubeadm-etcd-contract.md))
  declares load-bearing for join/reset idempotence.
- The `MemberList` and `Status` shapes KCP queries directly via
  `internal/etcd/etcd.go`.

Out of scope: Raft log replication, the learner's snapshot-driven
catchup mechanism, leader election, and pre-vote. These are
correctly modelled by etcd's own TLA+ specification and are
treated as black-box correct here.

## 1. The learner-then-promote protocol

When a new member joins an etcd cluster:

- **E1** — The leader processes `Cluster.MemberAddAsLearner` by
  appending a `ConfChangeAddLearnerNode` to the Raft log. The
  new member receives a unique `id` and is recorded with
  `IsLearner=true` in subsequent `MemberList` responses.
- **E2** — A learner does NOT contribute to quorum. The voter set
  for any committed log entry MUST be exactly the set of members
  with `IsLearner=false`.
- **E3** — A learner is promoted to voter via
  `Cluster.MemberPromote(id)`. Promotion is gated on the leader's
  view of the learner's progress: the leader's `raftStatus.Progress[id].Match`
  MUST be at least `readyPercentThreshold` × the leader's own
  `Match`. Cited from
  `server/etcdserver/server.go::isLearnerReady` at lines 1558–1604,
  with the threshold defined at line 108: `readyPercentThreshold
  = 0.9`.
- **E4** — A failed `MemberPromote` returns `ErrLearnerNotReady`
  when the threshold is not met (line 1599), `ErrIDNotFound` when
  the id is not a current member, or `ErrMemberNotLearner` when
  the id is already a voter.

## 2. The MemberList shape

Every `MemberList` response field KCP reads is documented below.
The fields are declared in
`api/etcdserverpb/rpc.pb.go::Member` at the pinned SHA.

| Field | Type | KCP usage |
|---|---|---|
| `id` | `uint64` | Identifier used for `MemberPromote`, `MemberRemove`. |
| `name` | `string` | The member's reported name. KCP's `compareMachinesAndMembers` matches members to Machines by exactly this string (the Machine's node name). An empty string MUST mean "member added but not yet started" — kubeadm's contract relies on this distinction. |
| `peer_urls` | `[]string` | Used to match a learner being promoted; MUST equal the URLs passed to `MemberAddAsLearner`. |
| `client_urls` | `[]string` | Reported by the running member. Empty until the member's listener is up. |
| `is_learner` | `bool` | KCP's `tryGetEtcdMemberName` and the formal model's `EtcdMembership.AddLearner`/`PromoteLearner` actions both gate on this field. A learner reports `true`; once promoted MUST report `false` on the next `MemberList`. |

Cited from `api/etcdserverpb/rpc.pb.go` field declarations at the
pinned SHA.

## 3. Error sentinels

The two sentinels declared load-bearing by
[`kubeadm-etcd-contract.md`](./kubeadm-etcd-contract.md) §4.1 are
defined in `api/v3rpc/rpctypes/error.go`:

- **R1** — `ErrMemberNotFound` (line 189) — returned when
  `MemberRemove(id)` is called against an `id` no longer in the
  cluster.
- **R2** — `ErrPeerURLExist` (line 186) — returned when
  `MemberAddAsLearner` is called with a `peerURLs` value that
  matches a current member.
- **R3** — `ErrLearnerNotReady` — returned when `MemberPromote`
  is called against a learner whose progress falls below the
  threshold per E3. Defined alongside the other sentinels.

KCP's own retry path in `controlplane/kubeadm/internal/etcd/etcd.go`
treats these the same way kubeadm does: idempotent retry on R1,
R2; back-off and re-poll on R3.

## 4. Status RPC

The `Maintenance.Status` RPC reports the responding member's
local view, not the cluster's. KCP polls it for two purposes:

- **S1** — Aliveness: the presence of an OK response indicates
  the member's gRPC surface is reachable. KCP's
  `EtcdMemberHealthy` condition derivation in
  `controlplane/kubeadm/internal/workload_cluster_conditions.go`
  treats Status timeout as `EtcdMemberHealthy=Unknown`. The
  formal model captures this with the `UnknownHealth` value of
  `MemberHealth` in `EtcdMembership.qnt`.
- **S2** — Leader identity: the response's `leader` field names
  the leader as the responding member sees it. KCP uses this to
  forward etcd leadership during planned member removal in
  `Workload.ForwardEtcdLeadership`.

Cited from `api/etcdserverpb/rpc.proto` `StatusResponse` at the
pinned SHA.

## 5. Behaviours under partition

Etcd's Raft preserves linearizable reads only on the leader. When
the leader is partitioned away from a quorum:

- **P1** — `Status` requests served by the partitioned leader
  return successfully but report stale state. KCP's etcd client
  rotates endpoints across all current members; the formal model
  treats the leader's view of a partitioned learner as
  `Stuck` via the `LearnerStuck` fault action.
- **P2** — `MemberPromote` requests served by the partitioned
  leader return errors (the underlying ConfChange cannot
  commit). The model captures this through the absence of a
  successful `PromoteLearner` action in the trace; the `Stuck`
  precondition implies promotion will not succeed until either
  the partition heals or the leader changes.

P1 + P2 are the etcd-side shape of the user-reported incident.

## 6. Conformance summary

| ID | Statement | Source citation |
|---|---|---|
| E1 | New members join as learners | `api/etcdserverpb/rpc.pb.go:3091` (`IsLearner` field), `server/etcdserver/server.go::AddLearner` |
| E2 | Learners do not contribute to quorum | `server/etcdserver/cluster_util.go` (voter-set computation) |
| E3 | Promotion gated on 90% match-progress threshold | `server/etcdserver/server.go:108`, `server/etcdserver/server.go:1593–1599` |
| E4 | Failed promotes return ErrLearnerNotReady / ErrIDNotFound / ErrMemberNotLearner | `server/etcdserver/server.go:1483–1599` |
| R1 | MemberRemove of unknown id → ErrMemberNotFound | `api/v3rpc/rpctypes/error.go:189` |
| R2 | MemberAddAsLearner with existing URL → ErrPeerURLExist | `api/v3rpc/rpctypes/error.go:186` |
| R3 | MemberPromote below threshold → ErrLearnerNotReady | `server/etcdserver/server.go:1599` |
| S1 | Status timeout indicates unreachability | `controlplane/kubeadm/internal/workload_cluster_conditions.go` (KCP-side) |
| S2 | Status.leader names the responding member's view | `api/etcdserverpb/rpc.proto::StatusResponse` |
| P1 | Partitioned-leader Status returns stale state | observed; not formally tested by etcd's own suite |
| P2 | Partitioned-leader MemberPromote fails | observed; modelled as fault `LearnerStuck` |
