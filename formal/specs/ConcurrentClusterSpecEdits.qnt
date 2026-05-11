module ConcurrentClusterSpecEdits {

  // Standalone concurrent Cluster.spec edit model for issue #65.
  //
  // Grounding:
  //   * internal/controllers/topology/cluster/structuredmerge/serversidepathhelper.go
  //   * internal/controllers/topology/cluster/structuredmerge/serversidepathhelper_test.go
  //   * controlplane/kubeadm/internal/controllers/scale.go
  //
  // We model two concurrent user edits against the same Cluster spec:
  //   A: version 1.29 -> 1.30
  //   B: replicas 3 -> 5
  //
  // The safe regime preserves both edits. The bad regime is a stale
  // full-spec apply that overwrites operator A's version change, or a
  // rollout/scale concurrency window that temporarily exceeds the surge
  // bound.

  pure val OLD_VERSION: int = 129
  pure val NEW_VERSION: int = 130
  pure val OLD_REPLICAS: int = 3
  pure val NEW_REPLICAS: int = 5
  pure val MAX_SURGE: int = 1

  var desiredVersion: int
  var desiredReplicas: int
  var intentVersion130: bool
  var intentReplicas5: bool
  var staleOverwriteObserved: bool
  var oldVersionReplicas: int
  var newVersionReplicas: int

  def actualReplicas: int = oldVersionReplicas + newVersionReplicas

  action init: bool = all {
    desiredVersion' = OLD_VERSION,
    desiredReplicas' = OLD_REPLICAS,
    intentVersion130' = false,
    intentReplicas5' = false,
    staleOverwriteObserved' = false,
    oldVersionReplicas' = OLD_REPLICAS,
    newVersionReplicas' = 0,
  }

  action OperatorEditVersion: bool = all {
    not(intentVersion130),
    desiredVersion' = NEW_VERSION,
    intentVersion130' = true,
    desiredReplicas' = desiredReplicas,
    intentReplicas5' = intentReplicas5,
    staleOverwriteObserved' = staleOverwriteObserved,
    oldVersionReplicas' = oldVersionReplicas,
    newVersionReplicas' = newVersionReplicas,
  }

  action FreshApplyReplicaEdit: bool = all {
    not(intentReplicas5),
    desiredReplicas' = NEW_REPLICAS,
    intentReplicas5' = true,
    desiredVersion' = desiredVersion,
    intentVersion130' = intentVersion130,
    staleOverwriteObserved' = staleOverwriteObserved,
    oldVersionReplicas' = oldVersionReplicas,
    newVersionReplicas' = newVersionReplicas,
  }

  // Stale full-object apply from operator B based on the pre-upgrade
  // object: replicas are updated, but version is reset to the stale base.
  action StaleApplyReplicaEdit: bool = all {
    intentVersion130,
    not(intentReplicas5),
    desiredVersion' = OLD_VERSION,
    desiredReplicas' = NEW_REPLICAS,
    intentVersion130' = intentVersion130,
    intentReplicas5' = true,
    staleOverwriteObserved' = true,
    oldVersionReplicas' = oldVersionReplicas,
    newVersionReplicas' = newVersionReplicas,
  }

  // Rollout creates a new-version replica while old-version replicas are
  // still present.
  action AddSurgeReplica: bool = all {
    desiredVersion == NEW_VERSION,
    oldVersionReplicas > 0,
    newVersionReplicas < NEW_REPLICAS,
    newVersionReplicas' = newVersionReplicas + 1,
    desiredVersion' = desiredVersion,
    desiredReplicas' = desiredReplicas,
    intentVersion130' = intentVersion130,
    intentReplicas5' = intentReplicas5,
    staleOverwriteObserved' = staleOverwriteObserved,
    oldVersionReplicas' = oldVersionReplicas,
  }

  // Scale-up can still target the old-version replica pool while the
  // rollout is also surging, which is the source of the temporary bound
  // violation explored here.
  action AddScaleReplica: bool = all {
    desiredReplicas == NEW_REPLICAS,
    actualReplicas < 7,
    oldVersionReplicas' = if (oldVersionReplicas > 0) oldVersionReplicas + 1 else oldVersionReplicas,
    newVersionReplicas' = if (oldVersionReplicas == 0) newVersionReplicas + 1 else newVersionReplicas,
    desiredVersion' = desiredVersion,
    desiredReplicas' = desiredReplicas,
    intentVersion130' = intentVersion130,
    intentReplicas5' = intentReplicas5,
    staleOverwriteObserved' = staleOverwriteObserved,
  }

  action DeleteOldReplica: bool = all {
    oldVersionReplicas > 0,
    newVersionReplicas > 0,
    oldVersionReplicas' = oldVersionReplicas - 1,
    desiredVersion' = desiredVersion,
    desiredReplicas' = desiredReplicas,
    intentVersion130' = intentVersion130,
    intentReplicas5' = intentReplicas5,
    staleOverwriteObserved' = staleOverwriteObserved,
    newVersionReplicas' = newVersionReplicas,
  }

  action step: bool = any {
    init,
    OperatorEditVersion,
    FreshApplyReplicaEdit,
    StaleApplyReplicaEdit,
    AddSurgeReplica,
    AddScaleReplica,
    DeleteOldReplica,
  }

  action stepApalache: bool = any {
    OperatorEditVersion,
    StaleApplyReplicaEdit,
    FreshApplyReplicaEdit,
    AddSurgeReplica,
  }

  val ReplicaAccountingConsistent =
    oldVersionReplicas >= 0 and newVersionReplicas >= 0 and actualReplicas == oldVersionReplicas + newVersionReplicas

  val AppliedSpecWithinDomain =
    (desiredVersion == OLD_VERSION or desiredVersion == NEW_VERSION) and
    (desiredReplicas == OLD_REPLICAS or desiredReplicas == NEW_REPLICAS)

  val StableSafetyInvariants = all {
    ReplicaAccountingConsistent,
    AppliedSpecWithinDomain,
  }

  val AppliedSpecSubsetOfPending =
    (desiredVersion == NEW_VERSION implies intentVersion130) and
    (desiredReplicas == NEW_REPLICAS implies intentReplicas5)

  val LastWriterPreservesFieldDomain =
    not(staleOverwriteObserved) or desiredVersion == OLD_VERSION

  val NoLostEdit =
    (intentVersion130 and intentReplicas5) implies
      (desiredVersion == NEW_VERSION and desiredReplicas == NEW_REPLICAS)

  val NoSurgeBoundViolation =
    actualReplicas <= desiredReplicas + MAX_SURGE

  val EventualConvergenceToFinalSpec =
    desiredVersion == NEW_VERSION and desiredReplicas == NEW_REPLICAS and actualReplicas == NEW_REPLICAS

  run serialEditsRun = init
    .then(OperatorEditVersion)
    .then(AddSurgeReplica)
    .then(DeleteOldReplica)
    .then(DeleteOldReplica)
    .then(DeleteOldReplica)
    .then(FreshApplyReplicaEdit)
    .then(AddScaleReplica)
    .then(AddScaleReplica)
    .then(AddScaleReplica)
    .then(AddScaleReplica)

  run lostEditRun = init
    .then(OperatorEditVersion)
    .then(StaleApplyReplicaEdit)

  run surgeRaceRun = init
    .then(OperatorEditVersion)
    .then(FreshApplyReplicaEdit)
    .then(AddSurgeReplica)
    .then(AddScaleReplica)
    .then(AddSurgeReplica)
    .then(AddScaleReplica)

  action lostEditInit: bool = all {
    desiredVersion' = OLD_VERSION,
    desiredReplicas' = NEW_REPLICAS,
    intentVersion130' = true,
    intentReplicas5' = true,
    staleOverwriteObserved' = true,
    oldVersionReplicas' = OLD_REPLICAS,
    newVersionReplicas' = 0,
  }
}
