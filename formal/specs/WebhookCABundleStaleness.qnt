module WebhookCABundleStaleness {

  type CertGen = Gen1 | Gen2

  var webhookServingCert: CertGen
  var injectedCABundle: CertGen
  var apiserverTrustBundle: CertGen
  var apiserverCacheRefreshPending: bool
  var admissionFailedX509: bool
  var outageTicks: int

  action init = all {
    webhookServingCert' = Gen1,
    injectedCABundle' = Gen1,
    apiserverTrustBundle' = Gen1,
    apiserverCacheRefreshPending' = false,
    admissionFailedX509' = false,
    outageTicks' = 0,
  }

  action RotateWebhookCert: bool = all {
    webhookServingCert == Gen1,
    webhookServingCert' = Gen2,
    injectedCABundle' = injectedCABundle,
    apiserverTrustBundle' = apiserverTrustBundle,
    apiserverCacheRefreshPending' = true,
    admissionFailedX509' = admissionFailedX509,
    outageTicks' = outageTicks,
  }

  action InjectCABundle: bool = all {
    injectedCABundle != webhookServingCert,
    injectedCABundle' = webhookServingCert,
    webhookServingCert' = webhookServingCert,
    apiserverTrustBundle' = apiserverTrustBundle,
    apiserverCacheRefreshPending' = true,
    admissionFailedX509' = admissionFailedX509,
    outageTicks' = outageTicks,
  }

  action ApiserverRefreshCache: bool = all {
    apiserverCacheRefreshPending,
    apiserverTrustBundle' = injectedCABundle,
    apiserverCacheRefreshPending' = false,
    webhookServingCert' = webhookServingCert,
    injectedCABundle' = injectedCABundle,
    admissionFailedX509' = false,
    outageTicks' = 0,
  }

  action AdmissionAttempt: bool = all {
    admissionFailedX509' = webhookServingCert != apiserverTrustBundle,
    outageTicks' = if (webhookServingCert != apiserverTrustBundle) outageTicks + 1 else outageTicks,
    webhookServingCert' = webhookServingCert,
    injectedCABundle' = injectedCABundle,
    apiserverTrustBundle' = apiserverTrustBundle,
    apiserverCacheRefreshPending' = apiserverCacheRefreshPending,
  }

  action Stutter: bool = all {
    webhookServingCert' = webhookServingCert,
    injectedCABundle' = injectedCABundle,
    apiserverTrustBundle' = apiserverTrustBundle,
    apiserverCacheRefreshPending' = apiserverCacheRefreshPending,
    admissionFailedX509' = admissionFailedX509,
    outageTicks' = outageTicks,
  }

  action step: bool = any {
    RotateWebhookCert,
    InjectCABundle,
    ApiserverRefreshCache,
    AdmissionAttempt,
    Stutter,
  }

  val CacheRefreshMonotonic =
    apiserverTrustBundle == Gen2 implies injectedCABundle == Gen2

  val InjectedBundleMatchesServingCA =
    injectedCABundle == webhookServingCert or apiserverCacheRefreshPending

  val CurrentlyTrusted =
    webhookServingCert == apiserverTrustBundle

  val NoLongOutage =
    outageTicks < 2

  val StableSafetyInvariants = all {
    CacheRefreshMonotonic,
  }

  run refreshRecoveryRun = init
    .then(RotateWebhookCert)
    .then(InjectCABundle)
    .then(AdmissionAttempt)
    .then(ApiserverRefreshCache)
    .then(AdmissionAttempt)

  run staleTrustOutageRun = init
    .then(RotateWebhookCert)
    .then(AdmissionAttempt)
}
