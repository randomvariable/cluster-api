// Copyright 2026 The Kubernetes Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Composition.qnt — cross-module invariant statements for the
// four per-module specs in this directory. Authoritative for
// understanding the inter-module contracts; NOT authoritative for
// model checking. Lifecycle.qnt is the monolithic composition
// the model checker runs against, because Quint's effect system
// rejects `any` over disjoint variable sets across modules.
//
// This file imports the four per-module specs purely so that
// references like `KubeadmJoin::JoinFailed` resolve, and
// expresses the cross-module invariants the per-module files
// cannot. Each invariant has a counterpart in Lifecycle.qnt
// that is the one actually checked.
module Composition {

  import EtcdMembership     from "./EtcdMembership"
  import KubeadmJoin        from "./KubeadmJoin"
  import KCPReconcile       from "./KCPReconcile"
  import MachineHealthCheck from "./MachineHealthCheck"

  // -------------------------------------------------------------
  // Cross-module invariants
  // -------------------------------------------------------------

  // The composition layer redeclares MACHINES so the invariants
  // below can range over the same identifier set the underlying
  // modules use.
  pure val MACHINES_C: Set[int] = 1.to(5)

  // ── EtcdMemberSetMatchesMachineSet ────────────────────────────
  //
  // Every Machine that has an etcd member registered must have a
  // resolved NodeRef. The reverse is not required (a Machine can
  // have a NodeRef before its etcd member is added — in fact this
  // is what kubeadm-join does).
  val EtcdMemberSetMatchesMachineSet =
    MACHINES_C.forall(m =>
      (KubeadmJoin::etcdMemberRegistered.keys().contains(m)
        and KubeadmJoin::etcdMemberRegistered.get(m))
      implies (KCPReconcile::nodeRefSet.keys().contains(m)
                and KCPReconcile::nodeRefSet.get(m)))

  // ── IncidentWitness ───────────────────────────────────────────
  //
  // The user-reported incident: there is a Machine `m1` that has
  // started kubeadm-join, registered as an etcd learner, and is
  // currently stuck (LearnerStuckOnPromote); plus a Machine `m2`
  // that is reporting EtcdMemberHealthy=Unknown. Under those
  // circumstances, KCP MUST NOT remediate (canSafelyRemediate is
  // false) AND preflight MUST report blocked.
  //
  // This is the *positive* invariant the model holds — KCP's
  // refusal to remediate is the correct behaviour given the
  // inputs. The negative finding (the v1beta2 condition's
  // information loss) is the InformativenessObligation below.
  val IncidentWitness =
    MACHINES_C.forall(m1 =>
      MACHINES_C.forall(m2 =>
        ((KubeadmJoin::phase.keys().contains(m1)
            and KubeadmJoin::phase.get(m1) == KubeadmJoin::JoinFailed
            and KubeadmJoin::failureReason.keys().contains(m1)
            and KubeadmJoin::failureReason.get(m1) == KubeadmJoin::LearnerStuckOnPromote
            and not(KCPReconcile::nodeRefSet.get(m1)))
         and (MachineHealthCheck::observation.keys().contains(m2)
              and MachineHealthCheck::observation.get(m2) == MachineHealthCheck::UnreachableTimeout))
        implies
          (KCPReconcile::preflightBlocked
           or (KCPReconcile::decision.keys().contains(m1)
               and KCPReconcile::decision.get(m1) != KCPReconcile::RemediationInFlight))))

  // ── InformativenessObligation ─────────────────────────────────
  //
  // For every Machine and every diagnostic key carried by the
  // v1beta1 projection, the v1beta2 projection MUST carry the
  // same diagnostic key. The user-reported incident produces a
  // counterexample: under UnreachableTimeout, v1beta1 carries
  // "context deadline exceeded"; v1beta2 carries the generic
  // "Please check controller logs for errors".
  //
  // The counterexample is the inaugural row in
  // formal/counterexample-log.md.
  val InformativenessObligation =
    MACHINES_C.forall(m =>
      MachineHealthCheck::DIAGNOSTIC_KEYS.forall(k =>
        MachineHealthCheck::v1b1Carries(
          MachineHealthCheck::projectV1Beta1(
            MachineHealthCheck::observation.get(m)), k)
        implies
          MachineHealthCheck::v1b2Carries(
            MachineHealthCheck::projectV1Beta2(
              MachineHealthCheck::observation.get(m)), k)))

  // ── EtcdHealthAgreesWithMHC ───────────────────────────────────
  //
  // For every Machine that has both an etcd-side health view and
  // an MHC observation, the two MUST be consistent. Specifically,
  // an UnknownHealth from etcd's side must show up as an
  // observation that the v1beta1 projection labels with the
  // InspectionFailed reason.
  val EtcdHealthAgreesWithMHC =
    MACHINES_C.forall(m =>
      (EtcdMembership::health.keys().contains(m)
        and EtcdMembership::health.get(m) == EtcdMembership::UnknownHealth
        and MachineHealthCheck::observation.keys().contains(m))
      implies
        MachineHealthCheck::projectV1Beta1(
          MachineHealthCheck::observation.get(m)).reason == "InspectionFailed"
        or MachineHealthCheck::observation.get(m) == MachineHealthCheck::ReachableHealthy)

  // -------------------------------------------------------------
  // Aggregate
  // -------------------------------------------------------------

  val AllCompositionInvariants = all {
    EtcdMemberSetMatchesMachineSet,
    IncidentWitness,
    EtcdHealthAgreesWithMHC,
    // Note: InformativenessObligation is intentionally NOT in the
    // AllInvariants conjunction. The current v1beta2 projection
    // produces a counterexample to it; that counterexample is the
    // bug. Keeping it out of AllInvariants lets the rest of the
    // model check while the counterexample remains visible
    // through `quint run` of the incident scenario.
  }

}
