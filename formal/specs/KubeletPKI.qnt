// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// KubeletPKI.qnt — kubeconfig client-cert rotation and cluster-CA
// availability across KCP reconcile.
//
// Grounding anchors (see abstraction-mapping.md for the pinned rows):
//   * controlplane/kubeadm/internal/controllers/helpers.go
//   * controlplane/kubeadm/internal/controllers/controller.go
//   * util/kubeconfig/kubeconfig.go

module KubeletPKI {

  var initialized: bool
  var caAvailable: bool
  var kubeconfigExists: bool
  var ownedSecret: bool
  var userProvidedSecret: bool

  var expirySoon: bool
  var clientCertFresh: bool
  var endpointStable: bool
  var requeuePending: bool

  var rotationObserved: bool
  var lastRotationOwned: bool
  var lastRotationThresholdGated: bool
  var caRegeneratedAfterInit: bool

  val ownedSecretOnlyRotates =
    not(rotationObserved) or lastRotationOwned

  val caNotRecreatedAfterInit =
    not(caRegeneratedAfterInit)

  val rotationRequiresThreshold =
    not(rotationObserved) or lastRotationThresholdGated

  val rotationPreservesEndpoint =
    endpointStable

  val missingCARequeues =
    not(not(caAvailable) and not(kubeconfigExists)) or requeuePending

  val StableSafetyInvariants = all {
    ownedSecretOnlyRotates,
    caNotRecreatedAfterInit,
    rotationRequiresThreshold,
    rotationPreservesEndpoint,
    missingCARequeues,
  }

  action init = all {
    initialized'               = false,
    caAvailable'               = true,
    kubeconfigExists'          = false,
    ownedSecret'               = false,
    userProvidedSecret'        = false,
    expirySoon'                = false,
    clientCertFresh'           = false,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = false,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = false,
  }

  action happyRotationRun = all {
    initialized'               = true,
    caAvailable'               = true,
    kubeconfigExists'          = true,
    ownedSecret'               = true,
    userProvidedSecret'        = false,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = true,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = false,
  }

  action blockedRotationRun = all {
    initialized'               = true,
    caAvailable'               = false,
    kubeconfigExists'          = false,
    ownedSecret'               = false,
    userProvidedSecret'        = false,
    expirySoon'                = true,
    clientCertFresh'           = false,
    endpointStable'            = true,
    requeuePending'            = true,
    rotationObserved'          = false,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = false,
  }

  action userSecretRotationRun = all {
    initialized'               = true,
    caAvailable'               = true,
    kubeconfigExists'          = true,
    ownedSecret'               = false,
    userProvidedSecret'        = true,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = true,
    lastRotationOwned'         = false,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = false,
  }

  action postInitCARegenRun = all {
    initialized'               = true,
    caAvailable'               = true,
    kubeconfigExists'          = true,
    ownedSecret'               = true,
    userProvidedSecret'        = false,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = false,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = true,
  }

  action endpointRewriteRun = all {
    initialized'               = true,
    caAvailable'               = true,
    kubeconfigExists'          = true,
    ownedSecret'               = true,
    userProvidedSecret'        = false,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = false,
    requeuePending'            = false,
    rotationObserved'          = true,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = false,
  }

  action GenerateInitialCA: bool = all {
    not(initialized) and not(caAvailable),
    initialized'               = initialized,
    caAvailable'               = true,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = false,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = false,
  }

  action MarkInitialized: bool = all {
    not(initialized) and caAvailable,
    initialized'               = true,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = requeuePending,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = false,
  }

  action CreateOwnedKubeconfig: bool = all {
    caAvailable and not(kubeconfigExists),
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = true,
    ownedSecret'               = true,
    userProvidedSecret'        = false,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action CreateUserSecret: bool = all {
    not(kubeconfigExists),
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = true,
    ownedSecret'               = false,
    userProvidedSecret'        = true,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action AgeClientCertificate: bool = all {
    kubeconfigExists and clientCertFresh,
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = true,
    clientCertFresh'           = false,
    endpointStable'            = endpointStable,
    requeuePending'            = requeuePending,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action RotateOwnedKubeconfig: bool = all {
    kubeconfigExists and ownedSecret and expirySoon and caAvailable,
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = false,
    clientCertFresh'           = true,
    endpointStable'            = true,
    requeuePending'            = false,
    rotationObserved'          = true,
    lastRotationOwned'         = true,
    lastRotationThresholdGated' = true,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action ObserveMissingCARequeue: bool = all {
    not(caAvailable) and not(kubeconfigExists),
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = true,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action LoseCA: bool = all {
    caAvailable,
    initialized'               = initialized,
    caAvailable'               = false,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = if (not(kubeconfigExists)) true else requeuePending,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action ClearRequeueAfterRecovery: bool = all {
    caAvailable and requeuePending,
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = false,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action ObserveUserProvidedSecret: bool = all {
    kubeconfigExists and userProvidedSecret,
    initialized'               = initialized,
    caAvailable'               = caAvailable,
    kubeconfigExists'          = kubeconfigExists,
    ownedSecret'               = ownedSecret,
    userProvidedSecret'        = userProvidedSecret,
    expirySoon'                = expirySoon,
    clientCertFresh'           = clientCertFresh,
    endpointStable'            = endpointStable,
    requeuePending'            = requeuePending,
    rotationObserved'          = rotationObserved,
    lastRotationOwned'         = lastRotationOwned,
    lastRotationThresholdGated' = lastRotationThresholdGated,
    caRegeneratedAfterInit'    = caRegeneratedAfterInit,
  }

  action randomStep = any {
    GenerateInitialCA,
    MarkInitialized,
    CreateOwnedKubeconfig,
    CreateUserSecret,
    AgeClientCertificate,
    RotateOwnedKubeconfig,
    ObserveMissingCARequeue,
    LoseCA,
    ClearRequeueAfterRecovery,
    ObserveUserProvidedSecret,
  }

  action step = any {
    randomStep,
  }
}
