module SsaFieldManagerConflict {

  // Standalone SSA field-manager conflict model for issue #66.
  //
  // Grounding:
  //   * internal/controllers/topology/cluster/structuredmerge/dryrun.go:220-281
  //   * internal/controllers/topology/cluster/reconcile_state.go:450-505
  //   * internal/util/ssa/managedfields.go:49-197
  //
  // The model keeps one contested field, its current owner, the last value
  // each manager believes is current, and whether a force apply happened.

  pure val OWNER_NONE = "none"
  pure val OWNER_KUBECTL = "kubectl"
  pure val OWNER_CAPI = "capi-cli"

  var fieldValue: int
  var owner: str
  var kubectlLastValue: int
  var capiLastValue: int
  var forceApplied: bool
  var conflictSeen: bool

  action init = all {
    fieldValue' = 3,
    owner' = OWNER_KUBECTL,
    kubectlLastValue' = 3,
    capiLastValue' = 3,
    forceApplied' = false,
    conflictSeen' = false,
  }

  action KubectlApply3NoForce: bool = all {
    fieldValue' = 3,
    owner' = OWNER_KUBECTL,
    kubectlLastValue' = 3,
    capiLastValue' = capiLastValue,
    forceApplied' = false,
    conflictSeen' = conflictSeen,
  }

  action CapiApply5NoForceConflict: bool = all {
    owner == OWNER_KUBECTL,
    fieldValue == 3,
    // write is rejected, but capi still remembers its desired value
    fieldValue' = fieldValue,
    owner' = owner,
    kubectlLastValue' = kubectlLastValue,
    capiLastValue' = 5,
    forceApplied' = forceApplied,
    conflictSeen' = true,
  }

  action CapiApply5Force: bool = all {
    fieldValue' = 5,
    owner' = OWNER_CAPI,
    kubectlLastValue' = kubectlLastValue,
    capiLastValue' = 5,
    forceApplied' = true,
    conflictSeen' = conflictSeen,
  }

  action KubectlReapplyStale3: bool = all {
    kubectlLastValue == 3,
    // stale client reverts without understanding that capi won ownership
    fieldValue' = 3,
    owner' = OWNER_KUBECTL,
    kubectlLastValue' = 3,
    capiLastValue' = capiLastValue,
    forceApplied' = forceApplied,
    conflictSeen' = conflictSeen,
  }

  action step = any {
    KubectlApply3NoForce,
    CapiApply5NoForceConflict,
    CapiApply5Force,
    KubectlReapplyStale3,
  }

  action stepApalache = any {
    CapiApply5NoForceConflict,
    CapiApply5Force,
    KubectlReapplyStale3,
  }

  val OwnerAlwaysKnown =
    owner == OWNER_NONE or owner == OWNER_KUBECTL or owner == OWNER_CAPI

  val LastWriterMatchesValue =
    (owner == OWNER_KUBECTL implies fieldValue == kubectlLastValue) and
    (owner == OWNER_CAPI implies fieldValue == capiLastValue)

  val StableSafetyInvariants = all {
    OwnerAlwaysKnown,
    LastWriterMatchesValue,
  }

  val ForcedApplyTransfersOwnership =
    forceApplied and fieldValue == 5 implies owner == OWNER_CAPI

  val NoSilentRevertAfterConflict =
    not(conflictSeen and forceApplied and owner == OWNER_KUBECTL and fieldValue == 3)

  run forceHandoffRun =
    init
      .then(CapiApply5NoForceConflict)
      .then(CapiApply5Force)

  run staleManagerRevertRun =
    init
      .then(CapiApply5NoForceConflict)
      .then(CapiApply5Force)
      .then(KubectlReapplyStale3)

  action staleRevertInit = all {
    fieldValue' = 5,
    owner' = OWNER_CAPI,
    kubectlLastValue' = 3,
    capiLastValue' = 5,
    forceApplied' = true,
    conflictSeen' = true,
  }
}
