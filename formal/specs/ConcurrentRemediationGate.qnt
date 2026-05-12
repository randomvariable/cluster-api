// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// ConcurrentRemediationGate.qnt — issue #106.
//
// Models the real non-atomic KCP remediation gate as two separate phases:
//  1. ReadGate(m) snapshots the current safety predicate into gateResult[m]
//  2. CommitAdmission(m) later moves m into inFlight if gateResult[m] == true
//
// The fixed variant fuses those two phases into AdmitOrBlockAtomic(m), which
// is exposed through stepFixed.
module ConcurrentRemediationGate {

  type Machine = int

  pure val MACHINES: Set[Machine] = Set(1, 2, 3)
  pure val MaxConcurrent: int = 2

  pure val UNKNOWN = "unknown"
  pure val PASS = "pass"
  pure val FAIL = "fail"

  var pending: Set[Machine]
  var blocked: Set[Machine]
  var inFlight: Set[Machine]
  var completed: Set[Machine]
  var voterSet: Set[Machine]
  var gateResult: Machine -> str

  action init = all {
    pending' = Set(1, 2),
    blocked' = Set(),
    inFlight' = Set(),
    completed' = Set(),
    voterSet' = MACHINES,
    gateResult' = MACHINES.mapBy(_ => UNKNOWN),
  }

  pure def quorumOf(s: Set[Machine]): int = s.size() / 2 + 1

  pure def quorumPreservedAfterDelete(vs: Set[Machine], m: Machine): bool =
    vs.contains(m) and (vs.size() - 1) >= quorumOf(vs)

  def safeToAdmitNow(m: Machine): bool =
    quorumPreservedAfterDelete(voterSet, m) and inFlight.size() < MaxConcurrent

  def safeToAdmitAtomic(m: Machine): bool =
    voterSet.exclude(inFlight.union(Set(m))).size() >= quorumOf(voterSet) and
      inFlight.size() < MaxConcurrent

  action ReadGate(m: Machine): bool = all {
    pending.contains(m),
    gateResult' = gateResult.put(m, if (safeToAdmitNow(m)) PASS else FAIL),
    pending' = pending,
    blocked' = blocked,
    inFlight' = inFlight,
    completed' = completed,
    voterSet' = voterSet,
  }

  action CommitAdmission(m: Machine): bool = all {
    pending.contains(m),
    gateResult.get(m) == PASS,
    inFlight' = inFlight.union(Set(m)),
    pending' = pending.exclude(Set(m)),
    blocked' = blocked,
    completed' = completed,
    voterSet' = voterSet,
    gateResult' = gateResult,
  }

  action BlockAfterRead(m: Machine): bool = all {
    pending.contains(m),
    gateResult.get(m) == FAIL,
    blocked' = blocked.union(Set(m)),
    pending' = pending.exclude(Set(m)),
    inFlight' = inFlight,
    completed' = completed,
    voterSet' = voterSet,
    gateResult' = gateResult,
  }

  action AdmitOrBlockAtomic(m: Machine): bool = all {
    pending.contains(m),
    pending' = pending.exclude(Set(m)),
    gateResult' = gateResult.put(m, if (safeToAdmitAtomic(m)) PASS else FAIL),
    inFlight' = if (safeToAdmitAtomic(m)) inFlight.union(Set(m)) else inFlight,
    blocked' = if (safeToAdmitAtomic(m)) blocked else blocked.union(Set(m)),
    completed' = completed,
    voterSet' = voterSet,
  }

  action CompleteRemediation(m: Machine): bool = all {
    inFlight.contains(m),
    inFlight' = inFlight.exclude(Set(m)),
    completed' = completed.union(Set(m)),
    voterSet' = voterSet,
    pending' = pending,
    blocked' = blocked,
    gateResult' = gateResult,
  }

  action RetryBlocked(m: Machine): bool = all {
    blocked.contains(m),
    blocked' = blocked.exclude(Set(m)),
    pending' = pending.union(Set(m)),
    inFlight' = inFlight,
    completed' = completed,
    voterSet' = voterSet,
    gateResult' = gateResult.put(m, UNKNOWN),
  }

  action step = any {
    nondet m = MACHINES.oneOf(); ReadGate(m),
    nondet m = MACHINES.oneOf(); CommitAdmission(m),
    nondet m = MACHINES.oneOf(); BlockAfterRead(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
    nondet m = MACHINES.oneOf(); RetryBlocked(m),
  }

  action stepFixed = any {
    nondet m = MACHINES.oneOf(); AdmitOrBlockAtomic(m),
    nondet m = MACHINES.oneOf(); CompleteRemediation(m),
    nondet m = MACHINES.oneOf(); RetryBlocked(m),
  }

  val QueuesDisjoint =
    pending.forall(m => not(blocked.contains(m))) and
    pending.forall(m => not(inFlight.contains(m))) and
    pending.forall(m => not(completed.contains(m))) and
    blocked.forall(m => not(inFlight.contains(m))) and
    blocked.forall(m => not(completed.contains(m))) and
    inFlight.forall(m => not(completed.contains(m)))

  val InFlightBounded = inFlight.size() <= MaxConcurrent

  val AtMostOneQueuePerMachine = MACHINES.forall(m =>
    (if (pending.contains(m)) 1 else 0) +
    (if (blocked.contains(m)) 1 else 0) +
    (if (inFlight.contains(m)) 1 else 0) +
    (if (completed.contains(m)) 1 else 0) <= 1)

  val NoConcurrentQuorumLoss = voterSet.exclude(inFlight).size() >= quorumOf(voterSet)

  // Expected to fail on the non-atomic model: a read can pass and become stale
  // before commit.
  val GateReadStalenessBound = MACHINES.forall(m =>
    gateResult.get(m) != PASS or safeToAdmitNow(m))

  val AdmissionRaceCounterExample =
    gateResult.get(1) == PASS and gateResult.get(2) == PASS and inFlight == Set(1, 2) and not(NoConcurrentQuorumLoss)

  // Fixed-variant property: once admission is atomic, any in-flight set still
  // preserves quorum.
  val FixedVariantPreservesQuorum = NoConcurrentQuorumLoss

  val StableSafetyInvariants = all {
    QueuesDisjoint,
    InFlightBounded,
    AtMostOneQueuePerMachine,
  }

  run admissionRaceRun = init
    .then(ReadGate(1))
    .then(ReadGate(2))
    .then(CommitAdmission(1))
    .then(CommitAdmission(2))

  run atomicGateRun = init
    .then(AdmitOrBlockAtomic(1))
    .then(AdmitOrBlockAtomic(2))

  run staleReadThenBlockRun = init
    .then(ReadGate(1))
    .then(ReadGate(2))
    .then(CommitAdmission(1))
    .then(BlockAfterRead(2))
}
