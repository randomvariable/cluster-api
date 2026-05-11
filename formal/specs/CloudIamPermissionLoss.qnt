module CloudIamPermissionLoss {

  // Standalone IAM revocation / partial cloud-call 403 model for issue #60.
  //
  // Grounding:
  //   * controllers/clustercache/cluster_accessor.go:345-371
  //   * controllers/clustercache/cluster_cache.go:531-545
  //   * internal/runtime/client/client_test.go:933
  //
  // This keeps one in-flight provisioning operation, a role-policy bit,
  // the last cloud call's authorization result, and whether the machine
  // has been left in a zombie partially-provisioned state.

  pure val POLICY_ACTIVE = "active"
  pure val POLICY_REVOKED = "revoked"

  pure val CALL_NONE = "none"
  pure val CALL_OK = "ok"
  pure val CALL_403 = "403"

  pure val PROV_NONE = "none"
  pure val PROV_INFLIGHT = "inflight"
  pure val PROV_ABORTED = "aborted"
  pure val PROV_ZOMBIE = "zombie"

  var iamRolePolicy: str
  var lastCallAuth: str
  var lastCallObserved: bool
  var provisioningState: str
  var machineExists: bool
  var machineReady: bool
  var zombieMachine: bool
  var consecutive403: int

  action init = all {
    iamRolePolicy' = POLICY_ACTIVE,
    lastCallAuth' = CALL_NONE,
    lastCallObserved' = false,
    provisioningState' = PROV_NONE,
    machineExists' = false,
    machineReady' = false,
    zombieMachine' = false,
    consecutive403' = 0,
  }

  action StartProvisioning: bool = all {
    provisioningState == PROV_NONE,
    provisioningState' = PROV_INFLIGHT,
    machineExists' = true,
    machineReady' = false,
    zombieMachine' = false,
    // frame
    iamRolePolicy' = iamRolePolicy,
    lastCallAuth' = lastCallAuth,
    lastCallObserved' = lastCallObserved,
    consecutive403' = consecutive403,
  }

  action RevokeIamPolicy: bool = all {
    iamRolePolicy == POLICY_ACTIVE,
    iamRolePolicy' = POLICY_REVOKED,
    // frame
    lastCallAuth' = lastCallAuth,
    lastCallObserved' = lastCallObserved,
    provisioningState' = provisioningState,
    machineExists' = machineExists,
    machineReady' = machineReady,
    zombieMachine' = zombieMachine,
    consecutive403' = consecutive403,
  }

  action CloudCallReturnsOK: bool = all {
    provisioningState == PROV_INFLIGHT,
    iamRolePolicy == POLICY_ACTIVE,
    lastCallAuth' = CALL_OK,
    lastCallObserved' = true,
    consecutive403' = 0,
    // frame
    iamRolePolicy' = iamRolePolicy,
    provisioningState' = provisioningState,
    machineExists' = machineExists,
    machineReady' = machineReady,
    zombieMachine' = zombieMachine,
  }

  action CloudCallReturns403: bool = all {
    provisioningState == PROV_INFLIGHT,
    iamRolePolicy == POLICY_REVOKED,
    lastCallAuth' = CALL_403,
    lastCallObserved' = true,
    consecutive403' = consecutive403 + 1,
    // frame
    iamRolePolicy' = iamRolePolicy,
    provisioningState' = provisioningState,
    machineExists' = machineExists,
    machineReady' = machineReady,
    zombieMachine' = zombieMachine,
  }

  action PartialProvisionSucceeds: bool = all {
    provisioningState == PROV_INFLIGHT,
    lastCallAuth == CALL_OK,
    // frame all state; this just records that some provisioning step landed
    iamRolePolicy' = iamRolePolicy,
    lastCallAuth' = lastCallAuth,
    lastCallObserved' = lastCallObserved,
    provisioningState' = provisioningState,
    machineExists' = machineExists,
    machineReady' = machineReady,
    zombieMachine' = zombieMachine,
    consecutive403' = consecutive403,
  }

  action AbortProvisioningOn403: bool = all {
    provisioningState == PROV_INFLIGHT,
    consecutive403 >= 2,
    provisioningState' = PROV_ABORTED,
    machineReady' = false,
    zombieMachine' = false,
    // frame
    iamRolePolicy' = iamRolePolicy,
    lastCallAuth' = lastCallAuth,
    lastCallObserved' = lastCallObserved,
    machineExists' = machineExists,
    consecutive403' = consecutive403,
  }

  action LeaveZombieMachine: bool = all {
    provisioningState == PROV_INFLIGHT,
    lastCallAuth == CALL_403,
    provisioningState' = PROV_ZOMBIE,
    machineExists' = true,
    machineReady' = false,
    zombieMachine' = true,
    // frame
    iamRolePolicy' = iamRolePolicy,
    lastCallAuth' = lastCallAuth,
    lastCallObserved' = lastCallObserved,
    consecutive403' = consecutive403,
  }

  action step = any {
    StartProvisioning,
    RevokeIamPolicy,
    CloudCallReturnsOK,
    CloudCallReturns403,
    PartialProvisionSucceeds,
    AbortProvisioningOn403,
    LeaveZombieMachine,
  }

  action stepApalache = any {
    CloudCallReturns403,
    LeaveZombieMachine,
  }

  val Observed403ImpliesRevokedPolicy =
    lastCallAuth == CALL_403 implies iamRolePolicy == POLICY_REVOKED

  val LastCallAuthKnown =
    Set(CALL_NONE, CALL_OK, CALL_403).contains(lastCallAuth)

  val StableSafetyInvariants = all {
    Observed403ImpliesRevokedPolicy,
    LastCallAuthKnown,
  }

  val InFlightProvisioningEventuallyAborts =
    provisioningState == PROV_ABORTED and not(zombieMachine)

  val NoZombieMachine =
    not(zombieMachine)

  run abortAfterPersistent403Run =
    init
      .then(StartProvisioning)
      .then(RevokeIamPolicy)
      .then(CloudCallReturns403)
      .then(CloudCallReturns403)
      .then(AbortProvisioningOn403)

  run zombieMachineRun =
    init
      .then(StartProvisioning)
      .then(CloudCallReturnsOK)
      .then(PartialProvisionSucceeds)
      .then(RevokeIamPolicy)
      .then(CloudCallReturns403)
      .then(LeaveZombieMachine)

  action zombieMachineInit = all {
    iamRolePolicy' = POLICY_REVOKED,
    lastCallAuth' = CALL_403,
    lastCallObserved' = true,
    provisioningState' = PROV_INFLIGHT,
    machineExists' = true,
    machineReady' = false,
    zombieMachine' = false,
    consecutive403' = 1,
  }
}
