// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ConversionWebhook.qnt — v1beta1 ↔ v1beta2 conversion round-trips,
// default-fill reads, and webhook outage fallback.
//
// Grounding anchors (see abstraction-mapping.md for the pinned rows):
//   * api/core/v1beta1/conversion.go
//   * api/core/v1beta1/conversion_test.go
//   * util/conversion/conversion.go

module ConversionWebhook {

  pure val V1BETA1: str = "v1beta1"
  pure val V1BETA2: str = "v1beta2"

  var storedVersion: str
  var requestedVersion: str

  var storedSpecToken: bool
  var projectedSpecV1Beta1: bool
  var projectedSpecV1Beta2: bool

  var webhookAvailable: bool
  var webhookTimeout: bool
  var noneConverter: bool
  var fallbackServed: bool
  var cleanError: bool

  var defaultsApplied: bool
  var readCount: int
  var storedObjectUntouched: bool

  var statusLegacyTagV1Beta1: bool
  var statusLegacyTagV1Beta2: bool

  var statusFieldOnlyInV1Beta1: bool
  var statusFieldOnlyInV1Beta2: bool
  var documentedDropFromV1Beta1: bool
  var documentedDropFromV1Beta2: bool

  def requestedProjectionMatchesStore: bool =
    if (requestedVersion == V1BETA1) projectedSpecV1Beta1 == storedSpecToken else projectedSpecV1Beta2 == storedSpecToken

  val roundTripSpec =
    projectedSpecV1Beta1 == storedSpecToken and projectedSpecV1Beta2 == storedSpecToken

  val roundTripStatusInformative =
    not(statusLegacyTagV1Beta1) or statusLegacyTagV1Beta2

  val webhookFailureSafe =
    webhookAvailable or requestedVersion == storedVersion or (storedObjectUntouched and cleanError)

  val defaultsIdempotent =
    storedObjectUntouched and requestedProjectionMatchesStore and (readCount >= 0)

  val informationLossDocumented =
    (not(statusFieldOnlyInV1Beta1) or documentedDropFromV1Beta1) and
      (not(statusFieldOnlyInV1Beta2) or documentedDropFromV1Beta2)

  val StableSafetyInvariants = all {
    roundTripSpec,
    roundTripStatusInformative,
    webhookFailureSafe,
    defaultsIdempotent,
    informationLossDocumented,
  }

  action init = all {
    storedVersion'            = V1BETA1,
    requestedVersion'         = V1BETA1,
    storedSpecToken'          = true,
    projectedSpecV1Beta1'     = true,
    projectedSpecV1Beta2'     = true,
    webhookAvailable'         = true,
    webhookTimeout'           = false,
    noneConverter'            = false,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = 0,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = true,
    statusLegacyTagV1Beta2'   = true,
    statusFieldOnlyInV1Beta1' = false,
    statusFieldOnlyInV1Beta2' = false,
    documentedDropFromV1Beta1' = true,
    documentedDropFromV1Beta2' = true,
  }

  action happyRoundTripRun = all {
    storedVersion'            = V1BETA1,
    requestedVersion'         = V1BETA1,
    storedSpecToken'          = true,
    projectedSpecV1Beta1'     = true,
    projectedSpecV1Beta2'     = true,
    webhookAvailable'         = true,
    webhookTimeout'           = false,
    noneConverter'            = false,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = 0,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = true,
    statusLegacyTagV1Beta2'   = true,
    statusFieldOnlyInV1Beta1' = false,
    statusFieldOnlyInV1Beta2' = false,
    documentedDropFromV1Beta1' = true,
    documentedDropFromV1Beta2' = true,
  }

  action statusProjectionLossRun = all {
    storedVersion'            = V1BETA1,
    requestedVersion'         = V1BETA2,
    storedSpecToken'          = true,
    projectedSpecV1Beta1'     = true,
    projectedSpecV1Beta2'     = true,
    webhookAvailable'         = true,
    webhookTimeout'           = false,
    noneConverter'            = false,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = 0,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = true,
    statusLegacyTagV1Beta2'   = false,
    statusFieldOnlyInV1Beta1' = false,
    statusFieldOnlyInV1Beta2' = false,
    documentedDropFromV1Beta1' = true,
    documentedDropFromV1Beta2' = true,
  }

  action undocumentedFieldLossRun = all {
    storedVersion'            = V1BETA1,
    requestedVersion'         = V1BETA2,
    storedSpecToken'          = true,
    projectedSpecV1Beta1'     = true,
    projectedSpecV1Beta2'     = true,
    webhookAvailable'         = true,
    webhookTimeout'           = false,
    noneConverter'            = false,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = 0,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = true,
    statusLegacyTagV1Beta2'   = true,
    statusFieldOnlyInV1Beta1' = true,
    statusFieldOnlyInV1Beta2' = false,
    documentedDropFromV1Beta1' = false,
    documentedDropFromV1Beta2' = true,
  }

  action outageFallbackRun = all {
    storedVersion'            = V1BETA1,
    requestedVersion'         = V1BETA2,
    storedSpecToken'          = true,
    projectedSpecV1Beta1'     = true,
    projectedSpecV1Beta2'     = true,
    webhookAvailable'         = false,
    webhookTimeout'           = false,
    noneConverter'            = true,
    fallbackServed'           = true,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = 0,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = true,
    statusLegacyTagV1Beta2'   = true,
    statusFieldOnlyInV1Beta1' = false,
    statusFieldOnlyInV1Beta2' = false,
    documentedDropFromV1Beta1' = true,
    documentedDropFromV1Beta2' = true,
  }

  action ConvertToV1Beta2: bool = all {
    requestedVersion != V1BETA2,
    webhookAvailable and not(webhookTimeout),
    storedVersion'            = storedVersion,
    requestedVersion'         = V1BETA2,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = projectedSpecV1Beta1,
    projectedSpecV1Beta2'     = storedSpecToken,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = false,
    noneConverter'            = noneConverter,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = readCount,
    storedObjectUntouched'    = storedObjectUntouched,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta1,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action ConvertToV1Beta1: bool = all {
    requestedVersion != V1BETA1,
    webhookAvailable and not(webhookTimeout),
    storedVersion'            = storedVersion,
    requestedVersion'         = V1BETA1,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = storedSpecToken,
    projectedSpecV1Beta2'     = projectedSpecV1Beta2,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = false,
    noneConverter'            = noneConverter,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = readCount,
    storedObjectUntouched'    = storedObjectUntouched,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta2,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action RoundTripV1Beta1ToV1Beta2ToV1Beta1: bool = all {
    storedVersion == V1BETA1,
    webhookAvailable and not(webhookTimeout),
    storedVersion'            = storedVersion,
    requestedVersion'         = V1BETA1,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = storedSpecToken,
    projectedSpecV1Beta2'     = storedSpecToken,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = false,
    noneConverter'            = noneConverter,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = false,
    readCount'                = readCount,
    storedObjectUntouched'    = storedObjectUntouched,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta1,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action WebhookTimeout: bool = all {
    requestedVersion != storedVersion,
    webhookAvailable,
    storedVersion'            = storedVersion,
    requestedVersion'         = requestedVersion,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = projectedSpecV1Beta1,
    projectedSpecV1Beta2'     = projectedSpecV1Beta2,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = true,
    noneConverter'            = noneConverter,
    fallbackServed'           = false,
    cleanError'               = true,
    defaultsApplied'          = false,
    readCount'                = readCount,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta2,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action WebhookOutageFallbackToNoneConverter: bool = all {
    requestedVersion != storedVersion,
    not(webhookAvailable) and noneConverter,
    storedVersion'            = storedVersion,
    requestedVersion'         = requestedVersion,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = projectedSpecV1Beta1,
    projectedSpecV1Beta2'     = projectedSpecV1Beta2,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = webhookTimeout,
    noneConverter'            = noneConverter,
    fallbackServed'           = true,
    cleanError'               = true,
    defaultsApplied'          = false,
    readCount'                = readCount,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta2,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action DefaultsAppliedDuringRead: bool = all {
    requestedVersion == storedVersion,
    storedVersion'            = storedVersion,
    requestedVersion'         = requestedVersion,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = projectedSpecV1Beta1,
    projectedSpecV1Beta2'     = projectedSpecV1Beta2,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = false,
    noneConverter'            = noneConverter,
    fallbackServed'           = false,
    cleanError'               = false,
    defaultsApplied'          = true,
    readCount'                = readCount + 1,
    storedObjectUntouched'    = true,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta2,
    statusFieldOnlyInV1Beta1' = statusFieldOnlyInV1Beta1,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = documentedDropFromV1Beta1,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action StatusFieldOnlyInOneVersion: bool = all {
    statusFieldOnlyInV1Beta1,
    storedVersion'            = storedVersion,
    requestedVersion'         = requestedVersion,
    storedSpecToken'          = storedSpecToken,
    projectedSpecV1Beta1'     = projectedSpecV1Beta1,
    projectedSpecV1Beta2'     = projectedSpecV1Beta2,
    webhookAvailable'         = webhookAvailable,
    webhookTimeout'           = webhookTimeout,
    noneConverter'            = noneConverter,
    fallbackServed'           = fallbackServed,
    cleanError'               = cleanError,
    defaultsApplied'          = defaultsApplied,
    readCount'                = readCount,
    storedObjectUntouched'    = storedObjectUntouched,
    statusLegacyTagV1Beta1'   = statusLegacyTagV1Beta1,
    statusLegacyTagV1Beta2'   = statusLegacyTagV1Beta2,
    statusFieldOnlyInV1Beta1' = true,
    statusFieldOnlyInV1Beta2' = statusFieldOnlyInV1Beta2,
    documentedDropFromV1Beta1' = false,
    documentedDropFromV1Beta2' = documentedDropFromV1Beta2,
  }

  action randomStep = any {
    ConvertToV1Beta2,
    ConvertToV1Beta1,
    RoundTripV1Beta1ToV1Beta2ToV1Beta1,
    WebhookTimeout,
    WebhookOutageFallbackToNoneConverter,
    DefaultsAppliedDuringRead,
  }

  action step = any {
    randomStep,
    StatusFieldOnlyInOneVersion,
  }

  val noneConverterCrossVersionCandidate =
    not(fallbackServed and requestedVersion != storedVersion and noneConverter)
}
