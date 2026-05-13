// Copyright 2026 The Kubernetes Authors.
//
// SpotPoolDrain.qnt — issue #88 (FM-88).
//
// Cloud provider sends spot-termination notice to ALL spot Nodes
// in a pool (provider rebalancing). Drain begins on all
// simultaneously; CP/etcd resilience exceeded; cluster
// operationally lost.

module SpotPoolDrain {

  type NodeState = Healthy | Notified | Draining | Terminated

  pure val POOL_NODES: Set[int] = 1.to(5)
  pure val POOL_BUDGET: int = 2          // max nodes that may be Terminated concurrently

  var nodeState: int -> NodeState
  var notificationGeneration: int

  action init = all {
    nodeState' = POOL_NODES.mapBy(_ => Healthy),
    notificationGeneration' = 0,
  }

  action PoolWideNotice: bool = all {
    POOL_NODES.forall(n => nodeState.get(n) == Healthy),
    notificationGeneration' = notificationGeneration + 1,
    nodeState' = POOL_NODES.mapBy(_ => Notified),
  }

  action BeginDrain(n: int): bool = all {
    POOL_NODES.contains(n),
    nodeState.get(n) == Notified,
    nodeState' = nodeState.put(n, Draining),
    notificationGeneration' = notificationGeneration,
  }

  action CompleteDrain(n: int): bool = all {
    POOL_NODES.contains(n),
    nodeState.get(n) == Draining,
    nodeState' = nodeState.put(n, Terminated),
    notificationGeneration' = notificationGeneration,
  }

  action step = any {
    PoolWideNotice,
    nondet n = POOL_NODES.oneOf(); BeginDrain(n),
    nondet n = POOL_NODES.oneOf(); CompleteDrain(n),
  }

  pure def terminatedCount(ns: int -> NodeState): int =
    POOL_NODES.filter(n => ns.get(n) == Terminated).size()

  // The bad case: more than POOL_BUDGET nodes have been
  // Terminated concurrently — cascading failure beyond the pool's
  // declared resilience.
  val NoCascadingFailureBeyondPoolSize =
    terminatedCount(nodeState) <= POOL_BUDGET

  // Counterexample: pool-wide notice fires, every node drains and
  // terminates without respecting the POOL_BUDGET cap.
  run poolWideCascadeRun = init
    .then(PoolWideNotice)
    .then(BeginDrain(1)).then(BeginDrain(2)).then(BeginDrain(3))
    .then(BeginDrain(4)).then(BeginDrain(5))
    .then(CompleteDrain(1)).then(CompleteDrain(2)).then(CompleteDrain(3))
    .then(CompleteDrain(4)).then(CompleteDrain(5))
    // terminatedCount = 5 > POOL_BUDGET = 2.

  // Recovery: KCP enforces the budget by gating BeginDrain.
  // Modelled by simply not driving more than POOL_BUDGET drains.
  run budgetedDrainRun = init
    .then(PoolWideNotice)
    .then(BeginDrain(1)).then(BeginDrain(2))
    .then(CompleteDrain(1)).then(CompleteDrain(2))
    // terminatedCount = 2; remaining nodes stay Notified.
}
