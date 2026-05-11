// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// RuntimeSDK.qnt — Runtime extension discovery / registration /
// partial-failure lifecycle.
//
// Grounding anchors (see abstraction-mapping.md for the pinned rows):
//   * internal/controllers/extensionconfig/extensionconfig_controller.go
//   * exp/runtime/client/client.go
//   * exp/runtime/server/server.go
//   * exp/runtime/catalog/catalog.go

module RuntimeSDK {

  pure val EXTENSIONS: Set[str] = Set("ext-a", "ext-b")

  var registered: str -> bool
  var available: str -> bool
  var supportedHook: str -> bool
  var versionCompatible: str -> bool
  var invokable: str -> bool
  var lastSeen: str -> int

  var discoveryGen: int
  var cacheStaleAfterRestart: bool
  var restartObserved: bool
  var responseCacheGen: int
  var hookGeneration: int

  // Transport-level retries can happen more than once; effect-level
  // application must remain idempotent.
  var rawHookCallCount: int
  var hookEffectCount: int

  var retryPending: bool
  var partialFailureSeen: bool
  var successfulPrefixCount: int
  var prefixCountAtFailure: int

  def discoverable(e: str): bool =
    registered.get(e) and available.get(e) and supportedHook.get(e) and lastSeen.get(e) == discoveryGen

  def activeExtensionCount: int =
    EXTENSIONS.filter(e => invokable.get(e)).size()

  action init = all {
    registered'            = EXTENSIONS.mapBy(_ => false),
    available'             = EXTENSIONS.mapBy(_ => false),
    supportedHook'         = EXTENSIONS.mapBy(_ => true),
    versionCompatible'     = EXTENSIONS.mapBy(_ => true),
    invokable'             = EXTENSIONS.mapBy(_ => false),
    lastSeen'              = EXTENSIONS.mapBy(_ => 0),
    discoveryGen'          = 1,
    cacheStaleAfterRestart' = false,
    restartObserved'       = false,
    responseCacheGen'      = 0,
    hookGeneration'        = 1,
    rawHookCallCount'      = 0,
    hookEffectCount'       = 0,
    retryPending'          = false,
    partialFailureSeen'    = false,
    successfulPrefixCount' = 0,
    prefixCountAtFailure'  = 0,
  }

  action happyRuntimeRun = all {
    registered'            = EXTENSIONS.mapBy(_ => true),
    available'             = EXTENSIONS.mapBy(_ => true),
    supportedHook'         = EXTENSIONS.mapBy(_ => true),
    versionCompatible'     = EXTENSIONS.mapBy(_ => true),
    invokable'             = EXTENSIONS.mapBy(_ => true),
    lastSeen'              = EXTENSIONS.mapBy(_ => 1),
    discoveryGen'          = 1,
    cacheStaleAfterRestart' = false,
    restartObserved'       = false,
    responseCacheGen'      = 0,
    hookGeneration'        = 1,
    rawHookCallCount'      = 0,
    hookEffectCount'       = 0,
    retryPending'          = false,
    partialFailureSeen'    = false,
    successfulPrefixCount' = 0,
    prefixCountAtFailure'  = 0,
  }

  action partialFailureRetryRun = all {
    registered'            = EXTENSIONS.mapBy(_ => true),
    available'             = EXTENSIONS.mapBy(_ => true),
    supportedHook'         = EXTENSIONS.mapBy(_ => true),
    versionCompatible'     = EXTENSIONS.mapBy(_ => true),
    invokable'             = EXTENSIONS.mapBy(_ => true),
    lastSeen'              = EXTENSIONS.mapBy(_ => 1),
    discoveryGen'          = 1,
    cacheStaleAfterRestart' = false,
    restartObserved'       = false,
    responseCacheGen'      = 0,
    hookGeneration'        = 1,
    rawHookCallCount'      = 1,
    hookEffectCount'       = 1,
    retryPending'          = true,
    partialFailureSeen'    = true,
    successfulPrefixCount' = 1,
    prefixCountAtFailure'  = 1,
  }

  action restartCacheReplayRun = all {
    registered'            = EXTENSIONS.mapBy(_ => true),
    available'             = EXTENSIONS.mapBy(_ => true),
    supportedHook'         = EXTENSIONS.mapBy(_ => true),
    versionCompatible'     = EXTENSIONS.mapBy(_ => true),
    invokable'             = EXTENSIONS.mapBy(_ => true),
    lastSeen'              = EXTENSIONS.mapBy(_ => 1),
    discoveryGen'          = 1,
    cacheStaleAfterRestart' = true,
    restartObserved'       = true,
    responseCacheGen'      = 0,
    hookGeneration'        = 1,
    rawHookCallCount'      = 1,
    hookEffectCount'       = 1,
    retryPending'          = true,
    partialFailureSeen'    = false,
    successfulPrefixCount' = 2,
    prefixCountAtFailure'  = 0,
  }

  action RegisterExtension(e: str): bool = all {
    not(registered.get(e)),
    registered'            = registered.put(e, true),
    available'             = available.put(e, true),
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable.put(e, false),
    lastSeen'              = lastSeen.put(e, 0),
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action WithdrawExtension(e: str): bool = all {
    registered.get(e),
    registered'            = registered.put(e, false),
    available'             = available.put(e, false),
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible.put(e, false),
    invokable'             = invokable.put(e, false),
    lastSeen'              = lastSeen.put(e, 0),
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = if (responseCacheGen == hookGeneration) 0 else responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action DiscoveryReconcile(e: str): bool = all {
    registered.get(e) and available.get(e),
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable.put(e, false),
    lastSeen'              = lastSeen.put(e, discoveryGen),
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action VersionNegotiate(e: str): bool = all {
    discoverable(e) and versionCompatible.get(e),
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable.put(e, true),
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action ExtensionVersionMismatch(e: str): bool = all {
    registered.get(e),
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible.put(e, false),
    invokable'             = invokable.put(e, false),
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action InvokeHook: bool = all {
    activeExtensionCount > 0,
    responseCacheGen != hookGeneration,
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = false,
    restartObserved'       = restartObserved,
    responseCacheGen'      = hookGeneration,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount + 1,
    hookEffectCount'       = if (hookEffectCount == 0) 1 else hookEffectCount,
    retryPending'          = false,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = activeExtensionCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action ConcurrentInvocation: bool = all {
    responseCacheGen == hookGeneration,
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action ExtensionTimeout: bool = all {
    activeExtensionCount > 0,
    not(retryPending),
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = 0,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = true,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action ExtensionPartialFailure: bool = all {
    activeExtensionCount >= 2,
    not(partialFailureSeen),
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = false,
    restartObserved'       = restartObserved,
    responseCacheGen'      = 0,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount + 1,
    hookEffectCount'       = if (hookEffectCount == 0) 1 else hookEffectCount,
    retryPending'          = true,
    partialFailureSeen'    = true,
    successfulPrefixCount' = 1,
    prefixCountAtFailure'  = 1,
  }

  action CacheStaleAfterRestartAction: bool = all {
    rawHookCallCount > 0,
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = true,
    restartObserved'       = true,
    responseCacheGen'      = 0,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = true,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action DiscoveryGenerationBump: bool = all {
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = EXTENSIONS.mapBy(_ => false),
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen + 1,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = false,
    responseCacheGen'      = 0,
    hookGeneration'        = hookGeneration + 1,
    rawHookCallCount'      = 0,
    hookEffectCount'       = 0,
    retryPending'          = false,
    partialFailureSeen'    = false,
    successfulPrefixCount' = 0,
    prefixCountAtFailure'  = 0,
  }

  action Stutter: bool = all {
    registered'            = registered,
    available'             = available,
    supportedHook'         = supportedHook,
    versionCompatible'     = versionCompatible,
    invokable'             = invokable,
    lastSeen'              = lastSeen,
    discoveryGen'          = discoveryGen,
    cacheStaleAfterRestart' = cacheStaleAfterRestart,
    restartObserved'       = restartObserved,
    responseCacheGen'      = responseCacheGen,
    hookGeneration'        = hookGeneration,
    rawHookCallCount'      = rawHookCallCount,
    hookEffectCount'       = hookEffectCount,
    retryPending'          = retryPending,
    partialFailureSeen'    = partialFailureSeen,
    successfulPrefixCount' = successfulPrefixCount,
    prefixCountAtFailure'  = prefixCountAtFailure,
  }

  action randomStep: bool = any {
    RegisterExtension("ext-a"),
    RegisterExtension("ext-b"),
    WithdrawExtension("ext-a"),
    WithdrawExtension("ext-b"),
    DiscoveryReconcile("ext-a"),
    DiscoveryReconcile("ext-b"),
    VersionNegotiate("ext-a"),
    VersionNegotiate("ext-b"),
    ExtensionVersionMismatch("ext-a"),
    ExtensionVersionMismatch("ext-b"),
    InvokeHook,
    ConcurrentInvocation,
    ExtensionTimeout,
    ExtensionPartialFailure,
    CacheStaleAfterRestartAction,
    DiscoveryGenerationBump,
    Stutter,
  }

  // Small symbolic relation for Apalache.
  action step: bool = any {
    RegisterExtension("ext-a"),
    DiscoveryReconcile("ext-a"),
    VersionNegotiate("ext-a"),
    InvokeHook,
    CacheStaleAfterRestartAction,
    Stutter,
  }

  val idempotentHookUnderRetry =
    hookEffectCount <= 1 and hookEffectCount <= rawHookCallCount + 1

  val noDoubleFire =
    retryPending implies hookEffectCount <= 1

  val discoveryConsistent =
    EXTENSIONS.forall(e =>
      invokable.get(e) implies
        (registered.get(e) and available.get(e) and supportedHook.get(e) and
          lastSeen.get(e) == discoveryGen and versionCompatible.get(e)))

  val cacheInvalidatedOnRestart =
    cacheStaleAfterRestart implies responseCacheGen == 0

  val partialFailureRecoverable =
    partialFailureSeen implies
      (successfulPrefixCount >= prefixCountAtFailure and hookEffectCount <= 1)

  val StableSafetyInvariants = all {
    idempotentHookUnderRetry,
    noDoubleFire,
    discoveryConsistent,
    cacheInvalidatedOnRestart,
    partialFailureRecoverable,
  }

  val restartCacheReuseCandidate =
    restartObserved implies rawHookCallCount <= 1

  val partialFailureSingleTransportCandidate =
    partialFailureSeen implies rawHookCallCount <= 1
}
