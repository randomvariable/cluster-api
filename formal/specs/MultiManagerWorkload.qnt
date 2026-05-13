// Copyright 2026 The Kubernetes Authors.
//
// MultiManagerWorkload.qnt — issue #95 (FM-95).
//
// Two management clusters (A, B) both have a Cluster CR pointing
// at the same workload cluster. A's KCP issues `kubeadm join`;
// B's KCP also issues. Workload's etcd membership becomes chaotic.

module MultiManagerWorkload {

  type ManagerId = ManagerA | ManagerB
  type Action = JoinedByMgr | RemovedByMgr | None

  pure val MANAGERS: Set[ManagerId] = Set(ManagerA, ManagerB)

  var workloadEtcdMembers: Set[int]
  var managerActions: ManagerId -> Action
  var workloadLeaseHeldBy: ManagerId
  var workloadLeaseGranted: bool

  action init = all {
    workloadEtcdMembers' = Set(1, 2, 3),
    managerActions' = MANAGERS.mapBy(_ => None),
    workloadLeaseHeldBy' = ManagerA,
    workloadLeaseGranted' = false,
  }

  action GrantLeaseToA: bool = all {
    not(workloadLeaseGranted),
    workloadLeaseHeldBy' = ManagerA,
    workloadLeaseGranted' = true,
    workloadEtcdMembers' = workloadEtcdMembers,
    managerActions' = managerActions,
  }

  action ManagerJoinsMember(mgr: ManagerId, member: int): bool = all {
    MANAGERS.contains(mgr),
    not(workloadEtcdMembers.contains(member)),
    workloadEtcdMembers' = workloadEtcdMembers.union(Set(member)),
    managerActions' = managerActions.put(mgr, JoinedByMgr),
    workloadLeaseHeldBy' = workloadLeaseHeldBy,
    workloadLeaseGranted' = workloadLeaseGranted,
  }

  action ManagerRemovesMember(mgr: ManagerId, member: int): bool = all {
    MANAGERS.contains(mgr),
    workloadEtcdMembers.contains(member),
    workloadEtcdMembers' = workloadEtcdMembers.exclude(Set(member)),
    managerActions' = managerActions.put(mgr, RemovedByMgr),
    workloadLeaseHeldBy' = workloadLeaseHeldBy,
    workloadLeaseGranted' = workloadLeaseGranted,
  }

  action step = any {
    GrantLeaseToA,
    nondet mgr = MANAGERS.oneOf(); nondet m = 4.to(6).oneOf(); ManagerJoinsMember(mgr, m),
    nondet mgr = MANAGERS.oneOf(); nondet m = 1.to(3).oneOf(); ManagerRemovesMember(mgr, m),
  }

  // Positive invariant: only the lease-holding manager has made
  // changes to membership.
  val WorkloadHasUniqueAuthoritativeManager =
    workloadLeaseGranted implies
      MANAGERS.forall(mgr =>
        mgr == workloadLeaseHeldBy or managerActions.get(mgr) == None)

  // Counterexample: lease granted to A but B also acts.
  run rogueManagerRun = init
    .then(GrantLeaseToA)
    .then(ManagerJoinsMember(ManagerA, 4))
    .then(ManagerJoinsMember(ManagerB, 5))
    // managerActions[ManagerB] = JoinedByMgr while lease is with A.

  // Recovery: no lease granted; both managers are blocked by an
  // explicit gate. Modelled by NOT firing GrantLeaseToA — but the
  // invariant says when lease is granted, only the lease holder
  // acts. The fix is upstream: gate on the lease.
  run singleManagerRun = init
    .then(GrantLeaseToA)
    .then(ManagerJoinsMember(ManagerA, 4))
}
