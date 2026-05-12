module EndpointSwapKubeconfig {

  // Standalone endpoint-swap / stale kubeconfig model for issue #61.
  //
  // Grounding:
  //   * util/kubeconfig/kubeconfig.go:111
  //   * internal/controllers/cluster/cluster_controller_phases.go:217-356
  //   * test/infrastructure/docker/internal/controllers/backends/docker/dockercluster_backend.go:100-128
  //   * test/infrastructure/docker/internal/controllers/backends/inmemory/inmemorycluster_backend.go:101-157

  pure val OLD_EP = "old-endpoint"
  pure val NEW_EP = "new-endpoint"

  var clusterEndpoint: str
  var referencedEndpoint: str
  var kubeconfigRegenerated: bool
  var oldEndpointAttempted: bool
  var converged: bool

  action init = all {
    clusterEndpoint' = OLD_EP,
    referencedEndpoint' = OLD_EP,
    kubeconfigRegenerated' = false,
    oldEndpointAttempted' = false,
    converged' = false,
  }

  action SwapEndpoint: bool = all {
    clusterEndpoint == OLD_EP,
    clusterEndpoint' = NEW_EP,
    referencedEndpoint' = referencedEndpoint,
    kubeconfigRegenerated' = kubeconfigRegenerated,
    oldEndpointAttempted' = oldEndpointAttempted,
    converged' = false,
  }

  action RegenerateKubeconfig: bool = all {
    referencedEndpoint' = clusterEndpoint,
    kubeconfigRegenerated' = true,
    clusterEndpoint' = clusterEndpoint,
    oldEndpointAttempted' = oldEndpointAttempted,
    converged' = referencedEndpoint == clusterEndpoint,
  }

  action KubeletAttemptsOldEndpoint: bool = all {
    referencedEndpoint == OLD_EP,
    clusterEndpoint == NEW_EP,
    oldEndpointAttempted' = true,
    clusterEndpoint' = clusterEndpoint,
    referencedEndpoint' = referencedEndpoint,
    kubeconfigRegenerated' = kubeconfigRegenerated,
    converged' = false,
  }

  action ObserveConverged: bool = all {
    referencedEndpoint == clusterEndpoint,
    converged' = true,
    clusterEndpoint' = clusterEndpoint,
    referencedEndpoint' = referencedEndpoint,
    kubeconfigRegenerated' = kubeconfigRegenerated,
    oldEndpointAttempted' = oldEndpointAttempted,
  }

  action step = any {
    SwapEndpoint,
    RegenerateKubeconfig,
    KubeletAttemptsOldEndpoint,
    ObserveConverged,
  }

  action stepApalache = any {
    SwapEndpoint,
    KubeletAttemptsOldEndpoint,
  }

  val ReferencedEndpointIsKnown =
    referencedEndpoint == OLD_EP or referencedEndpoint == NEW_EP

  val CurrentEndpointKnown =
    clusterEndpoint == OLD_EP or clusterEndpoint == NEW_EP

  val StableSafetyInvariants = all {
    ReferencedEndpointIsKnown,
    CurrentEndpointKnown,
  }

  val AllKubeconfigsConvergeToCurrent =
    converged

  run coordinatedSwapRun =
    init
      .then(SwapEndpoint)
      .then(RegenerateKubeconfig)
      .then(ObserveConverged)

  run staleKubeconfigRun =
    init
      .then(SwapEndpoint)
      .then(KubeletAttemptsOldEndpoint)

  action staleEndpointInit = all {
    clusterEndpoint' = NEW_EP,
    referencedEndpoint' = OLD_EP,
    kubeconfigRegenerated' = false,
    oldEndpointAttempted' = true,
    converged' = false,
  }
}
