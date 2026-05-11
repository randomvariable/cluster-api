module StaticPodHashReloadRace {

  type Intent = str

  pure val APISERVER_A: Intent = "apiserver-intent-a"
  pure val APISERVER_B: Intent = "apiserver-intent-b"

  var intendedIdentity: Set[Intent]
  var manifestHash: Intent -> int
  var desiredConfigGen: int
  var kubeletReloadGen: int
  var observedIntent: Set[Intent]

  action init: bool = all {
    intendedIdentity' = Set(APISERVER_A),
    manifestHash' = Set(APISERVER_A, APISERVER_B).mapBy(i => if (i == APISERVER_A) 1 else 2),
    desiredConfigGen' = 0,
    kubeletReloadGen' = 0,
    observedIntent' = Set(APISERVER_A),
  }

  action WriteStaticPodManifest(intent: Intent, hash: int): bool = all {
    Set(APISERVER_A, APISERVER_B).contains(intent),
    intendedIdentity' = intendedIdentity.union(Set(intent)),
    manifestHash' = manifestHash.put(intent, hash),
    desiredConfigGen' = desiredConfigGen,
    kubeletReloadGen' = kubeletReloadGen,
    observedIntent' = observedIntent,
  }

  action KubeadmRotate: bool = all {
    desiredConfigGen' = desiredConfigGen + 1,
    intendedIdentity' = intendedIdentity,
    manifestHash' = manifestHash,
    kubeletReloadGen' = kubeletReloadGen,
    observedIntent' = observedIntent,
  }

  action KubeletReload: bool = all {
    kubeletReloadGen < desiredConfigGen,
    kubeletReloadGen' = desiredConfigGen,
    observedIntent' = intendedIdentity,
    intendedIdentity' = intendedIdentity,
    manifestHash' = manifestHash,
    desiredConfigGen' = desiredConfigGen,
  }

  action ObserveHashCollision: bool = all {
    intendedIdentity.contains(APISERVER_A),
    intendedIdentity.contains(APISERVER_B),
    manifestHash.get(APISERVER_A) == manifestHash.get(APISERVER_B),
    observedIntent' = Set(APISERVER_A),
    intendedIdentity' = intendedIdentity,
    manifestHash' = manifestHash,
    desiredConfigGen' = desiredConfigGen,
    kubeletReloadGen' = kubeletReloadGen,
  }

  action Stutter: bool = all {
    intendedIdentity' = intendedIdentity,
    manifestHash' = manifestHash,
    desiredConfigGen' = desiredConfigGen,
    kubeletReloadGen' = kubeletReloadGen,
    observedIntent' = observedIntent,
  }

  action step: bool = any {
    nondet h = Set(1, 2).oneOf(); WriteStaticPodManifest(APISERVER_A, h),
    nondet h = Set(1, 2).oneOf(); WriteStaticPodManifest(APISERVER_B, h),
    KubeadmRotate,
    KubeletReload,
    ObserveHashCollision,
    Stutter,
  }

  action stepApalache: bool = any {
    WriteStaticPodManifest(APISERVER_B, 1),
    ObserveHashCollision,
    Stutter,
  }

  val ManifestHashDeterministic =
    Set(APISERVER_A, APISERVER_B).forall(i => manifestHash.get(i) == manifestHash.get(i))

  val DesiredConfigGenMonotone =
    desiredConfigGen >= kubeletReloadGen

  val StableSafetyInvariants = all {
    ManifestHashDeterministic,
    DesiredConfigGenMonotone,
  }

  val NoHashCollisionAcrossDistinctIntents =
    not(intendedIdentity.contains(APISERVER_A) and intendedIdentity.contains(APISERVER_B) and
      manifestHash.get(APISERVER_A) == manifestHash.get(APISERVER_B))

  val ReloadEventuallyConverges =
    kubeletReloadGen == desiredConfigGen and observedIntent == intendedIdentity

  val allVars = (intendedIdentity, manifestHash, desiredConfigGen, kubeletReloadGen, observedIntent)

  run eventualReloadRun = init
    .then(KubeadmRotate)
    .then(KubeletReload)

  run hashCollisionRun = init
    .then(WriteStaticPodManifest(APISERVER_B, 1))
    .then(ObserveHashCollision)

  run staleReloadRun = init
    .then(KubeadmRotate)
    .then(Stutter)

  action collisionInit: bool = all {
    intendedIdentity' = Set(APISERVER_A, APISERVER_B),
    manifestHash' = Set(APISERVER_A, APISERVER_B).mapBy(_ => 1),
    desiredConfigGen' = 0,
    kubeletReloadGen' = 0,
    observedIntent' = Set(APISERVER_A),
  }
}
