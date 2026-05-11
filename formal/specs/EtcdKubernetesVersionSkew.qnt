module EtcdKubernetesVersionSkew {

  // Standalone mid-rollout etcd-version × Kubernetes-version dependency
  // model for issue #81.
  //
  // Grounding:
  //   * test/framework/controlplane_helpers.go (EtcdImageTag override)
  //   * test/framework/cluster_topology_helpers.go (EtcdImageTag variable)
  //   * internal/controllers/machineset/machineset_preflight.go
  //
  // The real system exposes Kubernetes version and etcd image tag as
  // separate upgrade knobs. Mid-rollout, an etcd image bump can become
  // incompatible with the Kubernetes version / kubeadm state currently
  // running on the control plane, trapping the rollout until versions are
  // re-aligned.

  pure val V129: str = "v1.29"
  pure val V130: str = "v1.30"
  pure val ETCD129: str = "3.5.9"
  pure val ETCD130: str = "3.6.0"

  var kubernetesVersion: str
  var etcdImageTag: str
  var oldReplicas: int
  var newReplicas: int
  var midRollout: bool
  var preflightOk: bool
  var dependencyTrap: bool

  def totalReplicas: int = oldReplicas + newReplicas

  action init: bool = all {
    kubernetesVersion' = V129,
    etcdImageTag' = ETCD129,
    oldReplicas' = 3,
    newReplicas' = 0,
    midRollout' = false,
    preflightOk' = true,
    dependencyTrap' = false,
  }

  action StartKubernetesUpgrade: bool = all {
    kubernetesVersion' = V130,
    newReplicas' = newReplicas + 1,
    oldReplicas' = oldReplicas,
    etcdImageTag' = etcdImageTag,
    midRollout' = true,
    preflightOk' = preflightOk,
    dependencyTrap' = dependencyTrap,
  }

  action FinishKubernetesRoll: bool = all {
    midRollout,
    oldReplicas > 0,
    oldReplicas' = oldReplicas - 1,
    kubernetesVersion' = kubernetesVersion,
    etcdImageTag' = etcdImageTag,
    newReplicas' = newReplicas,
    midRollout' = oldReplicas - 1 > 0,
    preflightOk' = preflightOk,
    dependencyTrap' = dependencyTrap,
  }

  action BumpEtcdTagOrdered: bool = all {
    kubernetesVersion == V130,
    not(midRollout),
    etcdImageTag' = ETCD130,
    kubernetesVersion' = kubernetesVersion,
    oldReplicas' = oldReplicas,
    newReplicas' = newReplicas,
    midRollout' = midRollout,
    preflightOk' = true,
    dependencyTrap' = false,
  }

  action BumpEtcdTagMidRollout: bool = all {
    kubernetesVersion == V130,
    midRollout,
    etcdImageTag' = ETCD130,
    kubernetesVersion' = kubernetesVersion,
    oldReplicas' = oldReplicas,
    newReplicas' = newReplicas,
    midRollout' = midRollout,
    preflightOk' = false,
    dependencyTrap' = true,
  }

  action ClearTrapAfterAlignment: bool = all {
    dependencyTrap,
    not(midRollout),
    preflightOk' = true,
    dependencyTrap' = false,
    kubernetesVersion' = kubernetesVersion,
    etcdImageTag' = etcdImageTag,
    oldReplicas' = oldReplicas,
    newReplicas' = newReplicas,
    midRollout' = midRollout,
  }

  action step: bool = any {
    init,
    StartKubernetesUpgrade,
    FinishKubernetesRoll,
    BumpEtcdTagOrdered,
    BumpEtcdTagMidRollout,
    ClearTrapAfterAlignment,
  }

  action stepApalache: bool = any {
    StartKubernetesUpgrade,
    BumpEtcdTagMidRollout,
  }

  val VersionStringsKnown =
    (kubernetesVersion == V129 or kubernetesVersion == V130) and
      (etcdImageTag == ETCD129 or etcdImageTag == ETCD130)

  val PreflightBlocksUnsupportedOrder =
    dependencyTrap implies not(preflightOk)

  val StableSafetyInvariants = all {
    VersionStringsKnown,
    PreflightBlocksUnsupportedOrder,
  }

  val EtcdUpgradeAfterControlPlaneGate =
    kubernetesVersion == V130 and etcdImageTag == ETCD130 and not(midRollout) and preflightOk

  val NoMidRolloutDependencyTrap =
    not(dependencyTrap)

  run orderedUpgradeRun = init
    .then(StartKubernetesUpgrade)
    .then(FinishKubernetesRoll)
    .then(FinishKubernetesRoll)
    .then(FinishKubernetesRoll)
    .then(BumpEtcdTagOrdered)

  run midRolloutEtcdBumpRun = init
    .then(StartKubernetesUpgrade)
    .then(BumpEtcdTagMidRollout)

  action dependencyTrapInit: bool = all {
    kubernetesVersion' = V130,
    etcdImageTag' = ETCD129,
    oldReplicas' = 2,
    newReplicas' = 1,
    midRollout' = true,
    preflightOk' = true,
    dependencyTrap' = false,
  }
}
