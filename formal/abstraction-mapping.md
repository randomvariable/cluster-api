# Abstraction mapping — Quint/TLA+ actions ↔ Go entry points

This table is the contract between the formal model in
[`formal/specs/`](./specs/) and the Go controllers under
[`controlplane/kubeadm/`](../controlplane/kubeadm/) and
[`internal/controllers/machinehealthcheck/`](../internal/controllers/machinehealthcheck/).
Every action in every Quint module or TLA+ specification has a row
here naming the Go entry point that refines it.

The discipline follows
[Abadi & Lamport, *The Existence of Refinement Mappings*, Theoretical Computer Science 82(2):253–284, 1991](https://doi.org/10.1016/0304-3975(91)90224-P)
and the seL4 functional-correctness convention
([Klein et al., SOSP 2009](https://doi.org/10.1145/1629575.1629596)).

## Maintenance rules

1. Add a row when a new action appears in any spec.
2. Update a row whenever the Go entry point moves; treat a stale
   row as a correctness bug, not as documentation debt.
3. The CI gate in [`scripts/verify-formal.sh`](../scripts/verify-formal.sh)
   refuses changes where any Go reference fails to resolve.
4. When a single action is jointly refined by more than one Go
   entry point, add multiple rows.
5. Rows are ordered first by spec module, then by action name.

## Rows

### EtcdMembership.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| EtcdMembership | AddLearner | controlplane/kubeadm/internal/workload_cluster_etcd.go (TBD: function refining AddLearner; current code reaches etcd via `etcd.Client.MoveLeader` paths but the AddLearner side is exercised by kubeadm-join, not by KCP. The refinement landing site is `internal/etcd/etcd.go` once Stage 4 lands the trace tap.) | Adds an etcd member as a learner. Refined indirectly through kubeadm-join. |
| EtcdMembership | AdvanceTerm | (stub) — etcd-side, not directly invoked from CAPI; the trace checker observes AdvanceTerm via the leader change in `etcd_member_status.go`. | Term advances on leader change. |
| EtcdMembership | ElectLeader | (stub) — etcd-side, observed in the `etcd.Member.IsLearner` projection. | Leader election. |
| EtcdMembership | HealthChange | controlplane/kubeadm/internal/workload_cluster_conditions.go:66 (`updateManagedEtcdConditions`) | KCP polls each member's Status; the action records the resulting health flip. |
| EtcdMembership | LearnerStuck | (stub) — surfaced by `tryGetEtcdMemberName` returning empty when a learner is unmatched. | Learner promotion stuck — fault action used by IncidentWitness. |
| EtcdMembership | ObserveLearnerProgress | (stub) — observed through `etcd.Member.RaftAppliedIndex` (not yet wired). | Leader observes a learner's progress. |
| EtcdMembership | PromoteLearner | controlplane/kubeadm/internal/workload_cluster_etcd.go (TBD: not currently invoked from KCP — promotion is performed by kubeadm-join. The trace checker observes the side-effect through MemberList.) | Promotes a learner to voter. |
| EtcdMembership | RemoveMember | controlplane/kubeadm/internal/workload_cluster_etcd.go:56 (`RemoveEtcdMember`) | Removes an etcd member. |

### KubeadmJoin.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| KubeadmJoin | BeginJoin | (stub) — observed indirectly through `Machine.status.bootstrapReady` flipping true. | Bootstrap controller signals join start. |
| KubeadmJoin | EtcdAddLearnerSucceeded | (stub) — observed when `MemberList` first reports the new member. | kubeadm-join called Cluster.MemberAddAsLearner. |
| KubeadmJoin | EtcdQuorumReady | (stub) — observed when `is_learner` flips false on `MemberList`. | Learner promoted, quorum reached. |
| KubeadmJoin | JoinFailedAt | (stub) — observed through `Machine.status.failureMessage`. | Join failed at some phase. |
| KubeadmJoin | KubeletStarted | (stub) — observed via Node Ready condition. | NewKubeletStartPhase complete. |
| KubeadmJoin | MarkReady | (stub) — observed via `KubeadmControlPlane.status.ready`. | Final phase: KCP marks the new control plane ready. |
| KubeadmJoin | PreflightPass | (stub) — kubeadm-internal; observed only by the absence of a JoinFailedAt(PreflightCheckFailed) transition. | kubeadm preflight passed. |

### KCPReconcile.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| KCPReconcile | AddMachine | controlplane/kubeadm/internal/controllers/scale.go (`scaleUpControlPlane` — function-level; line numbers move; refinement is logical, not textual) | KCP creates a new control-plane Machine. |
| KCPReconcile | CompleteRemediation | controlplane/kubeadm/internal/controllers/remediation.go:54 (`reconcileUnhealthyMachines` post-deletion branch) | Remediation completed, replacement Machine takes over. |
| KCPReconcile | EvaluateCanSafelyRemediate | controlplane/kubeadm/internal/controllers/remediation.go:595 (`canSafelyRemediateMachine`) | The decision predicate for whether a Machine may be remediated. |
| KCPReconcile | HealthChange | controlplane/kubeadm/internal/controllers/status.go (`updateStatus` — coarse health rollup) | KCP re-projects per-Machine health. |
| KCPReconcile | RequestRemediation | controlplane/kubeadm/internal/controllers/remediation.go:54 (`reconcileUnhealthyMachines` entry) | KCP flips a Machine into remediation-requested. |
| KCPReconcile | ResolveNodeRef | internal/controllers/machine/machine_controller_noderef.go (Machine controller; refinement is upstream of KCP) | Machine controller sets `Machine.status.nodeRef`. |

### MachineHealthCheck.qnt

| Spec | Action | Go reference | Purpose |
| ---- | ------ | -------------- | ------- |
| MachineHealthCheck | DeriveCondition | controlplane/kubeadm/internal/workload_cluster_conditions.go:66 (`updateManagedEtcdConditions`) | Derives both v1beta1 and v1beta2 conditions from the latest observation. |
| MachineHealthCheck | Observe | controlplane/kubeadm/internal/workload_cluster_etcd.go (etcd client probe path) | MHC polls workload-cluster etcd. |

### Composition.qnt

Composition does not declare new actions; it imports the four
modules above and adds cross-module invariants. Each invariant is
checked by the Go runtime as documented in the trace runtime's
checker tests.

### Remediation.tla

To be populated when `Remediation.tla` lands in Phase 5 of the
proposal.

## Drift policy

The CI gate requires that every Go reference of the form
`path/to/file.go:LINE` resolves to an extant function declaration.
References that name a function symbolically (without a
`:LINE` suffix) are graded as TBD until a deterministic refinement
landing site is identified. TBD rows are reviewed at every CAEP
status promotion and may not persist past `status:
implementable`.
