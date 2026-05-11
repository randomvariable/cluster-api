module StaticPodMemPressure {

  type Pod = str
  type Priority = str

  pure val API_SERVER: Pod = "kube-apiserver"
  pure val CONTROLLER_MANAGER: Pod = "kube-controller-manager"
  pure val SCHEDULER: Pod = "kube-scheduler"
  pure val WORKLOAD: Pod = "workload"

  pure val SYSTEM_NODE_CRITICAL: Priority = "system-node-critical"
  pure val SYSTEM_CLUSTER_CRITICAL: Priority = "system-cluster-critical"
  pure val NORMAL: Priority = "normal"

  pure val PODS = Set(API_SERVER, CONTROLLER_MANAGER, SCHEDULER, WORKLOAD)
  pure val STATIC_PODS = Set(API_SERVER, CONTROLLER_MANAGER, SCHEDULER)

  var priorityClass: Pod -> Priority
  var nodeMemPressure: bool
  var evictionCandidates: Set[Pod]
  var evicted: Set[Pod]

  action init: bool = all {
    priorityClass' = PODS.mapBy(p =>
      if (STATIC_PODS.contains(p)) SYSTEM_NODE_CRITICAL else NORMAL),
    nodeMemPressure' = false,
    evictionCandidates' = Set(),
    evicted' = Set(),
  }

  action MisconfigureApiServerPriority: bool = all {
    priorityClass' = priorityClass.put(API_SERVER, NORMAL),
    nodeMemPressure' = nodeMemPressure,
    evictionCandidates' = evictionCandidates,
    evicted' = evicted,
  }

  action EnterMemPressure: bool = all {
    not(nodeMemPressure),
    nodeMemPressure' = true,
    priorityClass' = priorityClass,
    evictionCandidates' = evictionCandidates,
    evicted' = evicted,
  }

  action BuildEvictionCandidates: bool = all {
    nodeMemPressure,
    evictionCandidates' = PODS.filter(p => not(evicted.contains(p))),
    priorityClass' = priorityClass,
    nodeMemPressure' = nodeMemPressure,
    evicted' = evicted,
  }

  action EvictWorkload: bool = all {
    nodeMemPressure,
    evictionCandidates.contains(WORKLOAD),
    evicted' = evicted.union(Set(WORKLOAD)),
    evictionCandidates' = evictionCandidates.exclude(Set(WORKLOAD)),
    priorityClass' = priorityClass,
    nodeMemPressure' = nodeMemPressure,
  }

  action EvictApiServer: bool = all {
    nodeMemPressure,
    evictionCandidates.contains(API_SERVER),
    priorityClass.get(API_SERVER) == NORMAL,
    evicted' = evicted.union(Set(API_SERVER)),
    evictionCandidates' = evictionCandidates.exclude(Set(API_SERVER)),
    priorityClass' = priorityClass,
    nodeMemPressure' = nodeMemPressure,
  }

  action ClearMemPressure: bool = all {
    nodeMemPressure,
    nodeMemPressure' = false,
    priorityClass' = priorityClass,
    evictionCandidates' = Set(),
    evicted' = evicted,
  }

  action step: bool = any {
    MisconfigureApiServerPriority,
    EnterMemPressure,
    BuildEvictionCandidates,
    EvictWorkload,
    EvictApiServer,
    ClearMemPressure,
    all {
      priorityClass' = priorityClass,
      nodeMemPressure' = nodeMemPressure,
      evictionCandidates' = evictionCandidates,
      evicted' = evicted,
    },
  }

  action stepApalache: bool = any {
    EnterMemPressure,
    BuildEvictionCandidates,
    EvictApiServer,
    all {
      priorityClass' = priorityClass,
      nodeMemPressure' = nodeMemPressure,
      evictionCandidates' = evictionCandidates,
      evicted' = evicted,
    },
  }

  val KcpOutputsCorrectPriority =
    STATIC_PODS.forall(p =>
      priorityClass.get(p) == SYSTEM_NODE_CRITICAL or priorityClass.get(p) == SYSTEM_CLUSTER_CRITICAL)

  val EvictionChoiceNeedsPressure =
    evictionCandidates.size() > 0 implies nodeMemPressure

  val StableSafetyInvariants = all {
    EvictionChoiceNeedsPressure,
  }

  val CriticalStaticPodsImmuneFromEviction =
    evicted.intersect(STATIC_PODS).size() == 0

  val allVars = (priorityClass, nodeMemPressure, evictionCandidates, evicted)

  run correctPriorityRun = init
    .then(EnterMemPressure)
    .then(BuildEvictionCandidates)
    .then(EvictWorkload)
    .then(ClearMemPressure)

  run misPriorityEvictionRun = init
    .then(MisconfigureApiServerPriority)
    .then(EnterMemPressure)
    .then(BuildEvictionCandidates)
    .then(EvictApiServer)

  action misPriorityInit: bool = all {
    priorityClass' = PODS.mapBy(p =>
      if (p == API_SERVER) NORMAL
      else if (STATIC_PODS.contains(p)) SYSTEM_NODE_CRITICAL
      else NORMAL),
    nodeMemPressure' = false,
    evictionCandidates' = Set(),
    evicted' = Set(),
  }
}
