// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// MachineHealthCheck.qnt — observation→event→condition pipeline
// for the MHC controller, narrowed to the EtcdMemberHealthy and
// MachineOwnerRemediated conditions.
//
// The model exposes the v1beta1 and v1beta2 condition projections
// as separate maps so the InformativenessObligation invariant in
// Composition.qnt can compare them. The point of this module is
// not to model every condition CAPI emits — it is to make the
// information loss between v1beta1's severity-and-message form and
// v1beta2's reason-and-message form observable to the model
// checker.
//
// Refines: internal/controllers/machinehealthcheck/* and
//          controlplane/kubeadm/internal/controllers/status.go
//          (entry points enumerated in formal/abstraction-mapping.md).
// Contract: formal/contracts/kcp-machine-contract.md
module MachineHealthCheck {

  // -------------------------------------------------------------
  // Domain types
  // -------------------------------------------------------------

  type MachineId = int

  // The underlying observation MHC makes by polling the workload
  // cluster's etcd. The model retains the Stuck case explicitly
  // because that is the case the v1beta2 projection drops.
  type Observation =
    | ReachableHealthy
    | ReachableUnhealthy
    | UnreachableTimeout
    | UnreachableNoRoute
    | NoCorrespondingMember     // no etcd member for this Machine

  // v1beta1 carried (status, reason, severity, message). The
  // model abstracts (status,severity) into a tri-state and keeps
  // a free-form messageTag so the projection's content can be
  // compared.
  type V1Beta1Condition = {
    status:    str,            // "True" | "False" | "Unknown"
    severity:  str,            // "Info" | "Warning" | "Error"
    reason:    str,
    messageTag: str,
  }

  // v1beta2 carries (status, reason, message). No severity.
  type V1Beta2Condition = {
    status:     str,            // "True" | "False" | "Unknown"
    reason:     str,
    messageTag: str,
  }

  // -------------------------------------------------------------
  // Bounds
  // -------------------------------------------------------------

  pure val MACHINES: Set[MachineId] = 1.to(5)

  // -------------------------------------------------------------
  // State
  // -------------------------------------------------------------

  // Per-Machine current observation.
  var observation: MachineId -> Observation
  // Per-Machine v1beta1 EtcdMemberHealthy condition.
  var v1beta1: MachineId -> V1Beta1Condition
  // Per-Machine v1beta2 EtcdMemberHealthy condition.
  var v1beta2: MachineId -> V1Beta2Condition

  // -------------------------------------------------------------
  // Initial state
  // -------------------------------------------------------------

  pure val emptyV1B1: V1Beta1Condition = {
    status: "Unknown", severity: "Info", reason: "", messageTag: "",
  }
  pure val emptyV1B2: V1Beta2Condition = {
    status: "Unknown", reason: "", messageTag: "",
  }

  action init = all {
    observation' = MACHINES.mapBy(_ => ReachableHealthy),
    v1beta1'     = MACHINES.mapBy(_ => emptyV1B1),
    v1beta2'     = MACHINES.mapBy(_ => emptyV1B2),
  }

  // -------------------------------------------------------------
  // Projections — π_v1beta1 and π_v1beta2
  // -------------------------------------------------------------

  // The v1beta1 projection preserves the full upstream gRPC error
  // chain in messageTag and tags severity=Error on the failure
  // branch.
  pure def projectV1Beta1(o: Observation): V1Beta1Condition =
    if (o == ReachableHealthy) {
      status: "True", severity: "Info", reason: "Healthy", messageTag: "",
    } else if (o == ReachableUnhealthy) {
      status: "False", severity: "Warning",
      reason: "Unhealthy",
      messageTag: "etcd reports member unhealthy",
    } else if (o == UnreachableTimeout) {
      status: "False", severity: "Error",
      reason: "RemediationFailed",
      messageTag: "failed to get etcdStatus: context deadline exceeded",
    } else if (o == UnreachableNoRoute) {
      status: "False", severity: "Error",
      reason: "RemediationFailed",
      messageTag: "failed to connect to etcd node: no route to host",
    } else {
      status: "Unknown", severity: "Warning",
      reason: "InspectionFailed",
      messageTag: "no corresponding etcd member for machine",
    }

  // The v1beta2 projection drops severity and collapses the
  // unreachable-flavoured failures into reason=InternalError with
  // a generic messageTag. THIS IS THE INFORMATION LOSS the
  // InformativenessObligation invariant detects.
  pure def projectV1Beta2(o: Observation): V1Beta2Condition =
    if (o == ReachableHealthy) {
      status: "True", reason: "Healthy", messageTag: "",
    } else if (o == ReachableUnhealthy) {
      status: "False", reason: "Unhealthy",
      messageTag: "etcd reports member unhealthy",
    } else if (o == UnreachableTimeout or o == UnreachableNoRoute) {
      status: "False", reason: "InternalError",
      messageTag: "Please check controller logs for errors",
    } else {
      status: "Unknown", reason: "InspectionFailed",
      messageTag: "Failed to connect to etcd",
    }

  // -------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------

  // ── Observe ───────────────────────────────────────────────────
  // MHC polls the workload cluster's etcd and records a fresh
  // observation for `m`.
  action Observe(m: MachineId, o: Observation): bool = all {
    MACHINES.contains(m),
    observation' = observation.put(m, o),
    v1beta1' = v1beta1,
    v1beta2' = v1beta2,
  }

  // ── DeriveCondition ───────────────────────────────────────────
  // The controller transforms the observation into both condition
  // projections in a single reconcile pass. Modelling the two
  // projections as a single action ensures the model never sees
  // an interleaving where v1beta1 is fresh and v1beta2 is stale
  // (or vice versa) — which matches CAPI's reconcile guarantee.
  action DeriveCondition(m: MachineId): bool = all {
    MACHINES.contains(m),
    v1beta1' = v1beta1.put(m, projectV1Beta1(observation.get(m))),
    v1beta2' = v1beta2.put(m, projectV1Beta2(observation.get(m))),
    observation' = observation,
  }

  // -------------------------------------------------------------
  // Step relation
  // -------------------------------------------------------------

  action step = any {
    nondet m = MACHINES.oneOf();
      nondet o = Set(ReachableHealthy, ReachableUnhealthy,
                     UnreachableTimeout, UnreachableNoRoute,
                     NoCorrespondingMember).oneOf();
      Observe(m, o),
    nondet m = MACHINES.oneOf(); DeriveCondition(m),
  }

  // -------------------------------------------------------------
  // Informativeness predicate
  // -------------------------------------------------------------

  // The diagnostic content of a condition is the (reason,
  // messageTag) pair, with severity included for v1beta1. Two
  // operators interpret the condition: one extracts a
  // failure-class label (`reason`), the other extracts a free-form
  // diagnostic string (`messageTag`). A projection is "as
  // informative as another" iff for every observation, both the
  // failure-class label and the diagnostic string can be recovered
  // from at least as fine a partition.
  //
  // We model "recoverable" as a whitelist of upstream-error
  // substrings. A condition's diagnostic content recovers a
  // substring if the substring is present in messageTag.
  pure val DIAGNOSTIC_KEYS: Set[str] = Set(
    "context deadline exceeded",
    "no route to host",
    "no corresponding etcd member"
  )

  pure def v1b1Carries(c: V1Beta1Condition, k: str): bool =
    // The v1beta1 messageTag preserves the upstream chain.
    c.messageTag == k or
    (c.messageTag == "failed to get etcdStatus: context deadline exceeded"
       and k == "context deadline exceeded") or
    (c.messageTag == "failed to connect to etcd node: no route to host"
       and k == "no route to host") or
    (c.messageTag == "no corresponding etcd member for machine"
       and k == "no corresponding etcd member")

  pure def v1b2Carries(c: V1Beta2Condition, k: str): bool =
    c.messageTag == k or
    (c.messageTag == "etcd reports member unhealthy" and k == c.messageTag)

  // -------------------------------------------------------------
  // Invariants
  // -------------------------------------------------------------

  // For every Machine and every diagnostic key the v1beta1
  // projection carries on the current observation, the v1beta2
  // projection MUST carry the same key. This is the local form of
  // the InformativenessObligation; Composition.qnt re-states it
  // over composed system state.
  val InformativenessLocal =
    MACHINES.forall(m =>
      DIAGNOSTIC_KEYS.forall(k =>
        v1b1Carries(projectV1Beta1(observation.get(m)), k)
          implies v1b2Carries(projectV1Beta2(observation.get(m)), k)))

  val AllInvariants = all {
    InformativenessLocal,
  }

  // -------------------------------------------------------------
  // Example runs
  // -------------------------------------------------------------

  // The incident's MHC trace: a machine becomes unreachable on
  // timeout. v1beta1 carries `context deadline exceeded`; v1beta2
  // does not.
  run incidentObservation = init
    .then(Observe(2, UnreachableTimeout))
    .then(DeriveCondition(2))

}
