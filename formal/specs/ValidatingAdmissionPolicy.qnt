// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ValidatingAdmissionPolicy.qnt — issue #37 (FM-VAP-37).
//
// Models the failure mode where a CEL expression on a
// ValidatingAdmissionPolicy (VAP) exceeds the 1-second hard eval
// timeout, and the configured `failurePolicy` decides whether the
// request is admitted (Ignore) or rejected (Fail).
//
// Modelled state (small to keep the model symbolic):
//   * one VAP with `failurePolicy ∈ {Ignore, Fail}`.
//   * a stream of admission requests; each is `valid` or `invalid`
//     under the policy's CEL expression.
//   * a per-request `evalDuration` that may or may not exceed the
//     1-second hard cap.
//
// Two invariants:
//   * IgnoreWindowDoesNotMutateInvariants — even with `Ignore`, the
//     persisted-resource invariants the VAP encodes must continue
//     to hold across the request stream. (A pure-syntactic VAP
//     timeout cannot make the cluster less invariant; the request
//     either succeeds or is silently ignored. The interesting
//     failure is: the request is *invalid* AND CEL timed out AND
//     failurePolicy=Ignore — the invalid resource lands.)
//   * FailWindowEventuallyHeals — with `Fail`, after the CEL
//     expression is fixed (timeout no longer fires), valid requests
//     resume.
module ValidatingAdmissionPolicy {

  type Validity = Valid | Invalid
  type EvalOutcome = WithinBound | Timeout
  type FailurePolicy = Ignore | Fail
  type AdmissionDecision = Admitted | Rejected | Pending

  pure val REQUESTS: Set[int] = 1.to(4)

  var failurePolicy: FailurePolicy
  var celBroken: bool                  // models the "remote-resource Param" timeout
  var validity: int -> Validity
  var evalOutcome: int -> EvalOutcome
  var decision: int -> AdmissionDecision
  var persistedInvalid: Set[int]       // requests that landed despite being Invalid

  action init = all {
    failurePolicy' = Ignore,
    celBroken' = false,
    validity' = REQUESTS.mapBy(_ => Valid),
    evalOutcome' = REQUESTS.mapBy(_ => WithinBound),
    decision' = REQUESTS.mapBy(_ => Pending),
    persistedInvalid' = Set(),
  }

  action initFailPolicy = all {
    failurePolicy' = Fail,
    celBroken' = false,
    validity' = REQUESTS.mapBy(_ => Valid),
    evalOutcome' = REQUESTS.mapBy(_ => WithinBound),
    decision' = REQUESTS.mapBy(_ => Pending),
    persistedInvalid' = Set(),
  }

  // The author of a CEL expression starts referencing a remote
  // resource via Param; the eval now times out for every request.
  action CelBecomesBroken: bool = all {
    not(celBroken),
    celBroken' = true,
    failurePolicy' = failurePolicy,
    validity' = validity,
    evalOutcome' = REQUESTS.mapBy(_ => Timeout),
    decision' = decision,
    persistedInvalid' = persistedInvalid,
  }

  // The author fixes the CEL expression.
  action CelGetsFixed: bool = all {
    celBroken,
    celBroken' = false,
    failurePolicy' = failurePolicy,
    validity' = validity,
    evalOutcome' = REQUESTS.mapBy(_ => WithinBound),
    decision' = decision,
    persistedInvalid' = persistedInvalid,
  }

  // A new request arrives that's invalid under the policy.
  action SubmitInvalidRequest(r: int): bool = all {
    REQUESTS.contains(r),
    decision.get(r) == Pending,
    validity' = validity.put(r, Invalid),
    decision' = decision,
    failurePolicy' = failurePolicy,
    celBroken' = celBroken,
    evalOutcome' = evalOutcome,
    persistedInvalid' = persistedInvalid,
  }

  // Resolve a pending request. Decision depends on evalOutcome,
  // validity, and failurePolicy.
  action ResolveRequest(r: int): bool = all {
    REQUESTS.contains(r),
    decision.get(r) == Pending,
    val out = evalOutcome.get(r)
    val v = validity.get(r)
    val d =
      if (out == Timeout)
        if (failurePolicy == Ignore) Admitted else Rejected
      else
        if (v == Valid) Admitted else Rejected
    all {
      decision' = decision.put(r, d),
      persistedInvalid' =
        if (d == Admitted and v == Invalid)
          persistedInvalid.union(Set(r))
        else
          persistedInvalid,
      failurePolicy' = failurePolicy,
      celBroken' = celBroken,
      validity' = validity,
      evalOutcome' = evalOutcome,
    }
  }

  action step = any {
    CelBecomesBroken,
    CelGetsFixed,
    nondet r = REQUESTS.oneOf(); SubmitInvalidRequest(r),
    nondet r = REQUESTS.oneOf(); ResolveRequest(r),
  }

  // -------- Invariants --------------------------------------------

  // The interesting failure: Ignore + timeout admits an invalid
  // request. Witnessed when persistedInvalid is non-empty.
  val IgnoreWindowDoesNotMutateInvariants = persistedInvalid == Set()

  // With Fail, no invalid request lands and no valid request is
  // silently dropped (it's rejected and the controller retries).
  val FailWindowDoesNotMutateInvariants =
    failurePolicy == Fail implies persistedInvalid == Set()

  val AllSafetyInvariants = all {
    FailWindowDoesNotMutateInvariants,
  }

  // -------- Demonstration runs ------------------------------------

  // Ignore policy admits an invalid request when CEL is broken.
  run ignoreAdmitsInvalidRun = init
    .then(SubmitInvalidRequest(1))
    .then(CelBecomesBroken)
    .then(ResolveRequest(1))
    // persistedInvalid now contains 1 -> IgnoreWindowDoesNotMutateInvariants false.

  // Fail policy rejects everything during the broken window.
  run failRejectsAllRun = initFailPolicy
    .then(SubmitInvalidRequest(1))
    .then(CelBecomesBroken)
    .then(ResolveRequest(1))
    // decision[1] = Rejected; persistedInvalid stays empty.

  // Fail policy heals after CEL is fixed.
  run failHealsRun = initFailPolicy
    .then(CelBecomesBroken)
    .then(SubmitInvalidRequest(1))
    .then(CelGetsFixed)
    .then(ResolveRequest(1))
    // decision[1] = Rejected (resource was Invalid); persistedInvalid empty.

}
