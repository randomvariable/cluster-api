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

P1 + P2 are the etcd-side shape of the modelled scenario.

### 5b. Out-of-band etcd-membership management is out of scope

The model excludes etcd-membership operations that bypass the
CAPI-provisioned Machine lifecycle. The legitimate path is:

```
KCP scaleUp → Machine created (AddMachine)
            → Bootstrap controller delivers cloud-init / ignition
            → kubeadm-join runs on the new Machine
            → kubeadm's etcd client calls Cluster.MemberAddAsLearner
            → etcd member registered
```

Kubeadm calls `MemberAddAsLearner` directly via its embedded
etcd v3 client — but it does so **as part of CAPI's
provisioning**, on a Machine CAPI created. The model collapses
the whole chain into `EtcdAddLearnerSucceeded(m)`, gated on
`phase[m] == EtcdJoinAddLearner`. The phase machine guarantees
the Machine was created by `AddMachine(m)` first, so kubeadm's
direct etcd call IS in scope.

What's **out of scope**: etcd-membership operations that don't
trace back to a CAPI-provisioned Machine. Examples:

- A separate etcd manager (etcd-operator, etcd-druid, etcdadm
  running outside CAPI) issuing `MemberAddAsLearner` for members
  that have no corresponding CAPI Machine.
- An operator running `etcdctl member add` against a CAPI-
  managed cluster.
- A workflow that bootstraps an etcd cluster external to CAPI
  and then asks CAPI to "adopt" the existing members.

**Why**: the abstraction is a refinement of *KCP's* behaviour;
the assumption that every etcd member corresponds to a CAPI
Machine (verifiable via the matchable-set check in
`compareMachinesAndMembers`) is load-bearing. The Phase 11b TLC
verification found a counterexample where allowing free
`AddLearner` permitted orphan etcd members faster than KCP's
reaper could drain them — a real-world problem if external
managers run alongside KCP, but not a KCP bug.

**Re-enabling**: a future verification round modelling external
etcd managers must (a) re-add `AddLearner(id)` to `step`, AND
(b) strengthen KCP's reaper (`RemoveStuckLearner` /
`ReconcileEtcdMembers`) with strong-fair fairness to break the
AddLearner-vs-Reaper race — OR add an explicit fault-budget
constraint capping the number of external AddLearner firings.

## 5a. Leadership transfer and step-down

Etcd's runtime refuses to remove the current leader. The
controller MUST either transfer leadership to a healthy follower
or wait for the leader's lease to lapse before issuing
`MemberRemove`.

- **R-LEAD-STEP-DOWN** — A voter MUST step down from leadership
  before being removed from the member set. Two paths:
  - `MoveLeader` RPC (atomic transfer): the source leader names a
    target follower; the cluster transitions to the new leader at
    a new term. Refines `TransferLeadership(src, dst)` in
    `EtcdMembership.qnt` and `Lifecycle.qnt`.
  - Lease-lapse (passive step-down): when the leader loses
    connectivity to a quorum, its lease lapses and the cluster
    advances the term with no leader assigned until a new
    election completes. Refines `LeaderStepDown(id)`.
- KCP's Go entry point: `Workload.ForwardEtcdLeadership` in
  `controlplane/kubeadm/internal/workload_cluster_etcd.go`.
  Called from `scaleDownControlPlane` before
  `RemoveEtcdMember(leader)`.
- Observable in the trace: between term `t` and `t+1` the
  `leaderAt` projection drops the entry for `t` and gains an
  entry for `t+1` (transfer) or no entry (step-down), and any
  subsequent `RemoveMember(id)` action where `id` was the
  leader at `t` is gated on the `leaderAt[currentTerm] != id`
  precondition.

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
| R-LEAD-STEP-DOWN | Leader MUST step down or transfer before removal | `controlplane/kubeadm/internal/workload_cluster_etcd.go::ForwardEtcdLeadership`; etcd `server/etcdserver/server.go::transferLeadership` |
