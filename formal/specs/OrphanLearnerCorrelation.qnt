module OrphanLearnerCorrelation {

  // Post-#13680 correlation-chain model for issue #105.
  //
  // Grounding:
  //   * controlplane/kubeadm/internal/controllers/remediation.go:638-671
  //   * controlplane/kubeadm/internal/controllers/controller.go:1433-1460
  //   * controlplane/kubeadm/internal/etcd/etcd.go

  pure val ABSENT = "absent"
  pure val JOINING = "joining"
  pure val JOINED = "joined"
  pure val REMOVED = "removed"

  pure val PRESENT = "present"
  pure val PROVISIONING = "provisioning"
  pure val DELETING = "deleting"
  pure val DELETED = "deleted"

  pure val NONE = "none"
  pure val STEP1_ID = "step1-id"
  pure val STEP2_NAME = "step2-name"
  pure val STEP3_NODEREF = "step3-noderef"
  pure val STEP4_ADDR = "step4-address"
  pure val STEP5_PAIR = "step5-pair"
  pure val STEP6_ORPHAN = "step6-orphan"

  var memberState: str
  var memberNameVisible: bool
  var machineState: str
  var infraGone: bool

  // Correlation inputs in priority order.
  var annotationIDSet: bool
  var annotationNameSet: bool
  var nodeRefVisible: bool
  var peerUrlAddressMatch: bool
  var addressCollision: bool
  var startupTimedOut: bool

  // What the current reconcile observed.
  var resolutionMethod: str
  var orphanCandidatesSurfaced: bool
  var orphanCorrelationFailed: bool

  // Removal path outcome.
  var removeByIDUsed: bool
  var removeByNameUsed: bool
  var memberRemoved: bool

  // Exactly-one-joining / exactly-one-machine-without-NodeRef is implicit in
  // this 1-member / 1-machine model. Step 5 is therefore gated by the timeout.

  action init = all {
    memberState' = ABSENT,
    memberNameVisible' = false,
    machineState' = PRESENT,
    infraGone' = false,
    annotationIDSet' = false,
    annotationNameSet' = false,
    nodeRefVisible' = false,
    peerUrlAddressMatch' = false,
    addressCollision' = false,
    startupTimedOut' = false,
    resolutionMethod' = NONE,
    orphanCandidatesSurfaced' = false,
    orphanCorrelationFailed' = false,
    removeByIDUsed' = false,
    removeByNameUsed' = false,
    memberRemoved' = false,
  }

  action MemberAddReturnsJoining: bool = all {
    memberState == ABSENT,
    memberState' = JOINING,
    memberNameVisible' = false,
    machineState' = PROVISIONING,
    infraGone' = false,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action PublishMemberName: bool = all {
    memberState == JOINING,
    memberState' = JOINED,
    memberNameVisible' = true,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action SurfaceNodeRef: bool = all {
    machineState == PROVISIONING or machineState == PRESENT,
    nodeRefVisible' = true,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = PRESENT,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action SurfacePeerAddress: bool = all {
    machineState != DELETED,
    peerUrlAddressMatch' = true,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action MarkAddressCollision: bool = all {
    peerUrlAddressMatch,
    addressCollision' = true,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = if (resolutionMethod == STEP4_ADDR) NONE else resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action NodeStartupTimeoutExpires: bool = all {
    memberState == JOINING,
    startupTimedOut' = true,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action DeleteMachine: bool = all {
    machineState == PROVISIONING or machineState == PRESENT,
    machineState' = DELETING,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action SetEtcdMemberIDAnnotation: bool = all {
    machineState == DELETING,
    annotationIDSet' = true,
    annotationNameSet' = annotationNameSet,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = machineState,
    infraGone' = infraGone,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action SetEtcdMemberNameAnnotation: bool = all {
    machineState == DELETING,
    annotationNameSet' = true,
    annotationIDSet' = annotationIDSet,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    machineState' = machineState,
    infraGone' = infraGone,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  // Six-step monotonic correlation chain.
  action RunCorrelationChain: bool = any {
    all {
      machineState == DELETING,
      annotationIDSet,
      memberState != REMOVED,
      resolutionMethod' = STEP1_ID,
      orphanCandidatesSurfaced' = false,
      orphanCorrelationFailed' = false,
      memberState' = memberState,
      memberNameVisible' = memberNameVisible,
      machineState' = machineState,
      infraGone' = infraGone,
      annotationIDSet' = annotationIDSet,
      annotationNameSet' = annotationNameSet,
      nodeRefVisible' = nodeRefVisible,
      peerUrlAddressMatch' = peerUrlAddressMatch,
      addressCollision' = addressCollision,
      startupTimedOut' = startupTimedOut,
      removeByIDUsed' = removeByIDUsed,
      removeByNameUsed' = removeByNameUsed,
      memberRemoved' = memberRemoved,
    },
    all {
      machineState == DELETING,
      not(annotationIDSet),
      annotationNameSet,
      memberState != REMOVED,
      resolutionMethod' = STEP2_NAME,
      orphanCandidatesSurfaced' = false,
      orphanCorrelationFailed' = false,
      memberState' = memberState,
      memberNameVisible' = memberNameVisible,
      machineState' = machineState,
      infraGone' = infraGone,
      annotationIDSet' = annotationIDSet,
      annotationNameSet' = annotationNameSet,
      nodeRefVisible' = nodeRefVisible,
      peerUrlAddressMatch' = peerUrlAddressMatch,
      addressCollision' = addressCollision,
      startupTimedOut' = startupTimedOut,
      removeByIDUsed' = removeByIDUsed,
      removeByNameUsed' = removeByNameUsed,
      memberRemoved' = memberRemoved,
    },
    all {
      machineState == DELETING,
      not(annotationIDSet),
      not(annotationNameSet),
      nodeRefVisible,
      memberNameVisible,
      memberState == JOINED,
      resolutionMethod' = STEP3_NODEREF,
      orphanCandidatesSurfaced' = false,
      orphanCorrelationFailed' = false,
      memberState' = memberState,
      memberNameVisible' = memberNameVisible,
      machineState' = machineState,
      infraGone' = infraGone,
      annotationIDSet' = annotationIDSet,
      annotationNameSet' = annotationNameSet,
      nodeRefVisible' = nodeRefVisible,
      peerUrlAddressMatch' = peerUrlAddressMatch,
      addressCollision' = addressCollision,
      startupTimedOut' = startupTimedOut,
      removeByIDUsed' = removeByIDUsed,
      removeByNameUsed' = removeByNameUsed,
      memberRemoved' = memberRemoved,
    },
    all {
      machineState == DELETING,
      not(annotationIDSet),
      not(annotationNameSet),
      not(nodeRefVisible or memberNameVisible),
      peerUrlAddressMatch,
      not(addressCollision),
      memberState != REMOVED,
      resolutionMethod' = STEP4_ADDR,
      orphanCandidatesSurfaced' = false,
      orphanCorrelationFailed' = false,
      memberState' = memberState,
      memberNameVisible' = memberNameVisible,
      machineState' = machineState,
      infraGone' = infraGone,
      annotationIDSet' = annotationIDSet,
      annotationNameSet' = annotationNameSet,
      nodeRefVisible' = nodeRefVisible,
      peerUrlAddressMatch' = peerUrlAddressMatch,
      addressCollision' = addressCollision,
      startupTimedOut' = startupTimedOut,
      removeByIDUsed' = removeByIDUsed,
      removeByNameUsed' = removeByNameUsed,
      memberRemoved' = memberRemoved,
    },
    all {
      machineState == DELETING,
      not(annotationIDSet),
      not(annotationNameSet),
      not(nodeRefVisible),
      memberState == JOINING,
      startupTimedOut,
      resolutionMethod' = STEP5_PAIR,
      orphanCandidatesSurfaced' = true,
      orphanCorrelationFailed' = true,
      memberState' = memberState,
      memberNameVisible' = memberNameVisible,
      machineState' = machineState,
      infraGone' = infraGone,
      annotationIDSet' = annotationIDSet,
      annotationNameSet' = annotationNameSet,
      nodeRefVisible' = nodeRefVisible,
      peerUrlAddressMatch' = peerUrlAddressMatch,
      addressCollision' = addressCollision,
      startupTimedOut' = startupTimedOut,
      removeByIDUsed' = removeByIDUsed,
      removeByNameUsed' = removeByNameUsed,
      memberRemoved' = memberRemoved,
    }
  }

  action RemoveEtcdMemberByID: bool = all {
    machineState == DELETING,
    resolutionMethod == STEP1_ID,
    memberState != REMOVED,
    memberState' = REMOVED,
    memberRemoved' = true,
    removeByIDUsed' = true,
    removeByNameUsed' = removeByNameUsed,
    memberNameVisible' = false,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = false,
    orphanCorrelationFailed' = false,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
  }

  action RemoveEtcdMemberByName: bool = all {
    machineState == DELETING,
    resolutionMethod == STEP2_NAME or resolutionMethod == STEP3_NODEREF or resolutionMethod == STEP4_ADDR,
    memberState != REMOVED,
    memberState' = REMOVED,
    memberRemoved' = true,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = true,
    memberNameVisible' = false,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = false,
    orphanCorrelationFailed' = false,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
  }

  action ExternalRemoveOrphanMember: bool = all {
    orphanCorrelationFailed,
    memberState != REMOVED,
    memberState' = REMOVED,
    memberRemoved' = true,
    memberNameVisible' = false,
    machineState' = machineState,
    infraGone' = infraGone,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = STEP6_ORPHAN,
    orphanCandidatesSurfaced' = false,
    orphanCorrelationFailed' = false,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
  }

  action MachineFinalizeDelete: bool = all {
    machineState == DELETING,
    memberState == REMOVED or memberState == ABSENT,
    not(orphanCandidatesSurfaced),
    machineState' = DELETED,
    infraGone' = true,
    memberState' = memberState,
    memberNameVisible' = memberNameVisible,
    annotationIDSet' = annotationIDSet,
    annotationNameSet' = annotationNameSet,
    nodeRefVisible' = nodeRefVisible,
    peerUrlAddressMatch' = peerUrlAddressMatch,
    addressCollision' = addressCollision,
    startupTimedOut' = startupTimedOut,
    resolutionMethod' = resolutionMethod,
    orphanCandidatesSurfaced' = orphanCandidatesSurfaced,
    orphanCorrelationFailed' = orphanCorrelationFailed,
    removeByIDUsed' = removeByIDUsed,
    removeByNameUsed' = removeByNameUsed,
    memberRemoved' = memberRemoved,
  }

  action step: bool = any {
    MemberAddReturnsJoining,
    PublishMemberName,
    SurfaceNodeRef,
    SurfacePeerAddress,
    MarkAddressCollision,
    NodeStartupTimeoutExpires,
    DeleteMachine,
    SetEtcdMemberIDAnnotation,
    SetEtcdMemberNameAnnotation,
    RunCorrelationChain,
    RemoveEtcdMemberByID,
    RemoveEtcdMemberByName,
    ExternalRemoveOrphanMember,
    MachineFinalizeDelete,
  }

  action stepApalache: bool = any {
    MemberAddReturnsJoining,
    DeleteMachine,
    NodeStartupTimeoutExpires,
    RunCorrelationChain,
    SetEtcdMemberIDAnnotation,
    RemoveEtcdMemberByID,
    ExternalRemoveOrphanMember,
    MachineFinalizeDelete,
  }

  val JoinedImpliesNameVisible =
    memberState != JOINED or memberNameVisible

  val MachineGoneKnown =
    machineState == DELETED implies infraGone

  val NoOrphanMemberAfterDelete =
    not(machineState == DELETED and memberState == JOINING) and
    not(machineState == DELETED and memberState == JOINED)

  val Step5RequiresStartupTimeout =
    resolutionMethod != STEP5_PAIR or startupTimedOut

  val AddressCollisionBlocksStep4 =
    not(resolutionMethod == STEP4_ADDR and addressCollision)

  val CorrelationFailureHasExitPath =
    not(orphanCorrelationFailed) or
      (machineState == DELETING and (memberState == JOINING or memberState == JOINED))

  val AnnotationUnblockClearsOrphanCondition =
    not(orphanCorrelationFailed)

  val ExternalRemovalClearsOrphanCondition =
    not(orphanCorrelationFailed)

  val StableSafetyInvariants = all {
    JoinedImpliesNameVisible,
    MachineGoneKnown,
  }

  run joinedBeforeDeleteRun = init
    .then(MemberAddReturnsJoining)
    .then(PublishMemberName)
    .then(SurfaceNodeRef)
    .then(DeleteMachine)
    .then(RunCorrelationChain)
    .then(RemoveEtcdMemberByName)
    .then(MachineFinalizeDelete)

  run annotationUnblockRun = init
    .then(MemberAddReturnsJoining)
    .then(DeleteMachine)
    .then(NodeStartupTimeoutExpires)
    .then(RunCorrelationChain)
    .then(SetEtcdMemberIDAnnotation)
    .then(RunCorrelationChain)
    .then(RemoveEtcdMemberByID)
    .then(MachineFinalizeDelete)

  run externalRemovalRun = init
    .then(MemberAddReturnsJoining)
    .then(DeleteMachine)
    .then(NodeStartupTimeoutExpires)
    .then(RunCorrelationChain)
    .then(ExternalRemoveOrphanMember)
    .then(MachineFinalizeDelete)
}
