module ClusterClassTopologyRace {

  type DefinitionState = StableOld | Updating | StableNew

  var clusterClassVersion: int
  var topologyReadVersion: int
  var definitionState: DefinitionState
  var tornViewObserved: bool
  var invalidTemplateProduced: bool

  action init = all {
    clusterClassVersion' = 1,
    topologyReadVersion' = 1,
    definitionState' = StableOld,
    tornViewObserved' = false,
    invalidTemplateProduced' = false,
  }

  action UpdateClusterClass: bool = all {
    definitionState == StableOld,
    clusterClassVersion' = 2,
    definitionState' = Updating,
    topologyReadVersion' = topologyReadVersion,
    tornViewObserved' = tornViewObserved,
    invalidTemplateProduced' = invalidTemplateProduced,
  }

  action FinishClusterClassUpdate: bool = all {
    definitionState == Updating,
    definitionState' = StableNew,
    tornViewObserved' = false,
    clusterClassVersion' = clusterClassVersion,
    topologyReadVersion' = topologyReadVersion,
    invalidTemplateProduced' = invalidTemplateProduced,
  }

  action TopologyReadsPinnedVersion: bool = all {
    topologyReadVersion' = clusterClassVersion,
    tornViewObserved' = false,
    clusterClassVersion' = clusterClassVersion,
    definitionState' = definitionState,
    invalidTemplateProduced' = invalidTemplateProduced,
  }

  action TopologyReadsMidUpdate: bool = all {
    definitionState == Updating,
    topologyReadVersion' = 1,
    tornViewObserved' = true,
    clusterClassVersion' = clusterClassVersion,
    definitionState' = definitionState,
    invalidTemplateProduced' = invalidTemplateProduced,
  }

  action ResolveVariablesConsistently: bool = all {
    topologyReadVersion == clusterClassVersion,
    invalidTemplateProduced' = false,
    tornViewObserved' = false,
    clusterClassVersion' = clusterClassVersion,
    topologyReadVersion' = topologyReadVersion,
    definitionState' = definitionState,
  }

  action ResolveVariablesFromTornView: bool = all {
    tornViewObserved,
    invalidTemplateProduced' = true,
    clusterClassVersion' = clusterClassVersion,
    topologyReadVersion' = topologyReadVersion,
    definitionState' = definitionState,
    tornViewObserved' = tornViewObserved,
  }

  action Stutter: bool = all {
    clusterClassVersion' = clusterClassVersion,
    topologyReadVersion' = topologyReadVersion,
    definitionState' = definitionState,
    tornViewObserved' = tornViewObserved,
    invalidTemplateProduced' = invalidTemplateProduced,
  }

  action step = any {
    UpdateClusterClass,
    FinishClusterClassUpdate,
    TopologyReadsPinnedVersion,
    TopologyReadsMidUpdate,
    ResolveVariablesConsistently,
    ResolveVariablesFromTornView,
    Stutter,
  }

  action stepApalache = any {
    UpdateClusterClass,
    TopologyReadsMidUpdate,
    ResolveVariablesFromTornView,
    Stutter,
  }

  val DefinitionStateWellFormed =
    clusterClassVersion >= 1 and topologyReadVersion >= 1

  val MidUpdateRequiresVersionSkew =
    tornViewObserved implies definitionState == Updating

  val StableSafetyInvariants = all {
    DefinitionStateWellFormed,
    MidUpdateRequiresVersionSkew,
  }

  val ConsistentCCViewPerReconcile =
    not(invalidTemplateProduced)

  run versionPinnedReadRun = init
    .then(UpdateClusterClass)
    .then(FinishClusterClassUpdate)
    .then(TopologyReadsPinnedVersion)
    .then(ResolveVariablesConsistently)

  run tornReadRun = init
    .then(UpdateClusterClass)
    .then(TopologyReadsMidUpdate)
    .then(ResolveVariablesFromTornView)

  action tornReadInit = all {
    clusterClassVersion' = 2,
    topologyReadVersion' = 1,
    definitionState' = Updating,
    tornViewObserved' = true,
    invalidTemplateProduced' = true,
  }
}
