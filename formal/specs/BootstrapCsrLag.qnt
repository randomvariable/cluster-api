module BootstrapCsrLag {

  type CSR = int

  pure val FIRST_CSR: CSR = 1
  pure val RETRY_CSR: CSR = 2
  pure val APPROVAL_DELAY_BOUND: int = 4

  var csrQueue: List[CSR]
  var approvalRate: int
  var submitTime: CSR -> int
  var approved: Set[CSR]
  var bootstrapTime: int
  var bootstrapFailed: bool
  var kubeletHasClientCert: bool

  action init: bool = all {
    csrQueue' = List(),
    approvalRate' = 1,
    submitTime' = Set(FIRST_CSR, RETRY_CSR).mapBy(_ => -1),
    approved' = Set(),
    bootstrapTime' = 0,
    bootstrapFailed' = false,
    kubeletHasClientCert' = false,
  }

  action Tick: bool = all {
    bootstrapTime' = bootstrapTime + 1,
    csrQueue' = csrQueue,
    approvalRate' = approvalRate,
    submitTime' = submitTime,
    approved' = approved,
    bootstrapFailed' = bootstrapFailed,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action KubeletSubmitCSR(c: CSR): bool = all {
    Set(FIRST_CSR, RETRY_CSR).contains(c),
    submitTime.get(c) == -1,
    csrQueue' = csrQueue.append(c),
    submitTime' = submitTime.put(c, bootstrapTime),
    approvalRate' = approvalRate,
    approved' = approved,
    bootstrapTime' = bootstrapTime,
    bootstrapFailed' = bootstrapFailed,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action ApprovalControllerProcess: bool = all {
    csrQueue.length() > 0,
    approvalRate > 0,
    approved' = approved.union(Set(csrQueue.head())),
    csrQueue' = csrQueue.tail(),
    kubeletHasClientCert' = true,
    approvalRate' = approvalRate,
    submitTime' = submitTime,
    bootstrapTime' = bootstrapTime,
    bootstrapFailed' = bootstrapFailed,
  }

  action KubeletRetry: bool = all {
    submitTime.get(FIRST_CSR) != -1,
    not(kubeletHasClientCert),
    submitTime.get(RETRY_CSR) == -1,
    csrQueue' = csrQueue.append(RETRY_CSR),
    submitTime' = submitTime.put(RETRY_CSR, bootstrapTime),
    approvalRate' = approvalRate,
    approved' = approved,
    bootstrapTime' = bootstrapTime,
    bootstrapFailed' = bootstrapFailed,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action BootstrapTimeout: bool = all {
    bootstrapTime >= APPROVAL_DELAY_BOUND,
    not(kubeletHasClientCert),
    bootstrapFailed' = true,
    csrQueue' = csrQueue,
    approvalRate' = approvalRate,
    submitTime' = submitTime,
    approved' = approved,
    bootstrapTime' = bootstrapTime,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action SlowApproval: bool = all {
    approvalRate > 0,
    approvalRate' = approvalRate - 1,
    csrQueue' = csrQueue,
    submitTime' = submitTime,
    approved' = approved,
    bootstrapTime' = bootstrapTime,
    bootstrapFailed' = bootstrapFailed,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action Stutter: bool = all {
    csrQueue' = csrQueue,
    approvalRate' = approvalRate,
    submitTime' = submitTime,
    approved' = approved,
    bootstrapTime' = bootstrapTime,
    bootstrapFailed' = bootstrapFailed,
    kubeletHasClientCert' = kubeletHasClientCert,
  }

  action step: bool = any {
    Tick,
    KubeletSubmitCSR(FIRST_CSR),
    KubeletSubmitCSR(RETRY_CSR),
    ApprovalControllerProcess,
    KubeletRetry,
    BootstrapTimeout,
    SlowApproval,
    Stutter,
  }

  action stepApalache: bool = any {
    Tick,
    BootstrapTimeout,
    Stutter,
  }

  val QueueMonotone = csrQueue.length() >= 0

  val SubmitTimeRecorded =
    Set(FIRST_CSR, RETRY_CSR).forall(c => submitTime.get(c) == -1 or submitTime.get(c) <= bootstrapTime)

  val StableSafetyInvariants = all {
    QueueMonotone,
    SubmitTimeRecorded,
  }

  val BootstrapTimeoutCoversCsrLatency =
    not(bootstrapFailed) or kubeletHasClientCert

  val NoStrandedKubelet =
    kubeletHasClientCert or csrQueue.length() > 0

  val allVars = (csrQueue, approvalRate, submitTime, approved, bootstrapTime, bootstrapFailed, kubeletHasClientCert)

  run eventualApprovalRun = init
    .then(KubeletSubmitCSR(FIRST_CSR))
    .then(Tick)
    .then(ApprovalControllerProcess)

  run approvalTimeoutRun = init
    .then(KubeletSubmitCSR(FIRST_CSR))
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(Tick)
    .then(BootstrapTimeout)

  run strandedKubeletRun = init
    .then(KubeletSubmitCSR(FIRST_CSR))
    .then(ApprovalControllerProcess)
    .then(Stutter)
    .then(Stutter)
    .then(Stutter)
    .then(BootstrapTimeout)

  action approvalTimeoutInit: bool = all {
    csrQueue' = List(FIRST_CSR),
    approvalRate' = 0,
    submitTime' = Set(FIRST_CSR, RETRY_CSR).mapBy(c => if (c == FIRST_CSR) 0 else -1),
    approved' = Set(),
    bootstrapTime' = APPROVAL_DELAY_BOUND,
    bootstrapFailed' = false,
    kubeletHasClientCert' = false,
  }
}
