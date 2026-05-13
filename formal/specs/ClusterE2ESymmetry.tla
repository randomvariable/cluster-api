---------------------------- MODULE ClusterE2ESymmetry ----------------------------
(*
  ClusterE2ESymmetry.tla — issue #23 (TLC symmetry reduction).

  Hand-crafted symmetry-friendly abstraction of `ClusterE2E.qnt`'s
  control-plane/worker bring-up ordering. Worker Machines are
  fully symmetric; control-plane Machines are fully symmetric
  among themselves but the two roles are distinguishable.

  TLC's `SYMMETRY` operator supports compound permutation groups via
  set-builder syntax: we permute CP within CP and worker within worker.

  Apache 2.0 — Copyright 2026 The Kubernetes Authors.
*)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    CpMachines,         \* finite set of model-value CP identifiers
    WorkerMachines,     \* finite set of model-value worker identifiers
    EndpointReadyN      \* CP count needed for cluster endpoint readiness

ASSUME
    /\ IsFiniteSet(CpMachines)
    /\ IsFiniteSet(WorkerMachines)
    /\ CpMachines \cap WorkerMachines = {}
    /\ Cardinality(CpMachines) >= 1
    /\ EndpointReadyN \in 1..Cardinality(CpMachines)

AllMachines == CpMachines \cup WorkerMachines

VARIABLES
    cpProvisioned,    \* SUBSET CpMachines
    cpReady,          \* SUBSET CpMachines  — apiserver readyz green
    workersAdmitted,  \* SUBSET WorkerMachines
    endpointReady     \* BOOLEAN — cluster endpoint reachable

vars == << cpProvisioned, cpReady, workersAdmitted, endpointReady >>

Init ==
    /\ cpProvisioned   = {}
    /\ cpReady         = {}
    /\ workersAdmitted = {}
    /\ endpointReady   = FALSE

ProvisionCp(m) ==
    /\ m \in CpMachines
    /\ m \notin cpProvisioned
    /\ cpProvisioned' = cpProvisioned \cup {m}
    /\ UNCHANGED << cpReady, workersAdmitted, endpointReady >>

CpBecomesReady(m) ==
    /\ m \in cpProvisioned
    /\ m \notin cpReady
    /\ cpReady'        = cpReady \cup {m}
    /\ endpointReady'  = (Cardinality(cpReady \cup {m}) >= EndpointReadyN)
    /\ UNCHANGED << cpProvisioned, workersAdmitted >>

AdmitWorker(w) ==
    /\ w \in WorkerMachines
    /\ w \notin workersAdmitted
    /\ endpointReady = TRUE
    /\ workersAdmitted' = workersAdmitted \cup {w}
    /\ UNCHANGED << cpProvisioned, cpReady, endpointReady >>

Next ==
    \/ \E m \in CpMachines     : ProvisionCp(m)
    \/ \E m \in CpMachines     : CpBecomesReady(m)
    \/ \E w \in WorkerMachines : AdmitWorker(w)

Spec == Init /\ [][Next]_vars

\* The compound symmetry group: permute CP within CP and worker
\* within worker independently. TLC accepts this as a set of
\* permutations on AllMachines.
CpWorkerSymmetry ==
    { LET cp == Permutations(CpMachines)
          wk == Permutations(WorkerMachines)
      IN [
        x \in AllMachines |->
          IF x \in CpMachines THEN cpPerm[x] ELSE wkPerm[x]
      ] : cpPerm \in Permutations(CpMachines), wkPerm \in Permutations(WorkerMachines) }

\* The invariants:

CpReadySubsetProvisioned == cpReady \subseteq cpProvisioned

WorkersAdmittedImpliesEndpointReady ==
    workersAdmitted /= {} => endpointReady

EndpointReadyImpliesEnoughCp ==
    endpointReady => Cardinality(cpReady) >= EndpointReadyN

AllSafetyInvariants ==
    /\ CpReadySubsetProvisioned
    /\ WorkersAdmittedImpliesEndpointReady
    /\ EndpointReadyImpliesEnoughCp

=============================================================================
\* Modification history:
\*   2026-05-13 — first version. Compound CP/worker symmetry exemplar
\*                for ClusterE2E.qnt (issue #23).
