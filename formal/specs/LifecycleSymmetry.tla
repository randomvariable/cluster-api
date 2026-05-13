---------------------------- MODULE LifecycleSymmetry ----------------------------
(*
  LifecycleSymmetry.tla — issue #23 (TLC symmetry reduction).

  The full Quint `Lifecycle.qnt` compiles to a TLA+ spec whose state
  variables are typed `Int` and whose `init` action embeds literal
  integer machine IDs ({1, 2, 3}, {4}, ...). TLC's `SYMMETRY` operator
  requires that the permuted set be made of model values (uninterpreted
  constants) — integers carry arithmetic, so they are not a sound
  symmetry domain.

  This module is a hand-crafted abstraction of the symmetric portion
  of `Lifecycle.qnt`: the per-Machine phase progression, the etcd
  member set, and the kubelet-ready flag. It uses model values for
  machine identifiers, so TLC's `Permutations(Machines)` is a valid
  symmetry group. The point of the exercise is to:

    1. Demonstrate the technique end-to-end (Quint -> abstracted TLA+
       -> TLC symmetry).
    2. Measure the state-space reduction factor against an
       identical-shape TLC run without `SYMMETRY`.
    3. Provide a cheap CI gate at depth ≥ 12 that captures the same
       AT-MOST-ONE / NO-QUORUM-LOSS invariants as the full Quint
       spec.

  The abstraction is NOT a verbatim refinement of Lifecycle.qnt — it
  drops every action that doesn't fan out across machines (drain,
  cordoning, conditioning) and keeps:

    * per-Machine `phase` ∈ {NotStarted, Bootstrapping, EtcdMember,
                            ControlPlaneReady, Remediating, Completed}
    * the etcd `members` set (a subset of `Machines`)
    * `inFlight` (a subset of `Machines`) — concurrent remediation
      bookkeeping
    * a `MaxConcurrent` cap on `inFlight`

  Apache 2.0 — Copyright 2026 The Kubernetes Authors.
*)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Machines,        \* finite set of model-value machine identifiers
    MaxConcurrent    \* per-step in-flight remediation cap

ASSUME
    /\ IsFiniteSet(Machines)
    /\ Cardinality(Machines) >= 1
    /\ MaxConcurrent \in 1..Cardinality(Machines)

\* -- Phases ----------------------------------------------------------------

Phases == {
    "NotStarted",        \* Machine declared, no bootstrap progress
    "Bootstrapping",     \* kubeadm join in flight
    "EtcdMember",        \* learner promoted to voter
    "ControlPlaneReady", \* apiserver readyz green
    "Remediating",       \* MHC flagged unhealthy + admitted by KCP
    "Completed"          \* terminal: removed and replaced
}

\* -- Variables -------------------------------------------------------------

VARIABLES
    phase,           \* Machines -> Phases
    members,         \* SUBSET Machines — current etcd voter set
    inFlight         \* SUBSET Machines — concurrent remediations

vars == << phase, members, inFlight >>

QuorumOf(S) == (Cardinality(S) \div 2) + 1

\* -- Initial state ---------------------------------------------------------

\* Every Machine starts NotStarted; etcd voter set is empty until the
\* first Machine joins.
Init ==
    /\ phase    = [m \in Machines |-> "NotStarted"]
    /\ members  = {}
    /\ inFlight = {}

\* -- Actions ---------------------------------------------------------------

BeginBootstrap(m) ==
    /\ phase[m] = "NotStarted"
    /\ phase'   = [phase EXCEPT ![m] = "Bootstrapping"]
    /\ UNCHANGED << members, inFlight >>

JoinEtcd(m) ==
    /\ phase[m] = "Bootstrapping"
    /\ phase'   = [phase EXCEPT ![m] = "EtcdMember"]
    /\ members' = members \cup {m}
    /\ UNCHANGED inFlight

ApiserverReady(m) ==
    /\ phase[m] = "EtcdMember"
    /\ phase'   = [phase EXCEPT ![m] = "ControlPlaneReady"]
    /\ UNCHANGED << members, inFlight >>

\* Admission is the symmetric-friendly counterpart to KCPReconcile's
\* `EvaluateRemediationAdmission`. We admit at most `MaxConcurrent`
\* remediations and never admit one that would break quorum
\* post-removal.
AdmitRemediation(m) ==
    /\ phase[m] = "ControlPlaneReady"
    /\ m \in members
    /\ Cardinality(inFlight) < MaxConcurrent
    /\ Cardinality(members \ (inFlight \cup {m})) >= QuorumOf(members)
    /\ phase'    = [phase EXCEPT ![m] = "Remediating"]
    /\ inFlight' = inFlight \cup {m}
    /\ UNCHANGED members

CompleteRemediation(m) ==
    /\ phase[m] = "Remediating"
    /\ m \in inFlight
    /\ phase'    = [phase EXCEPT ![m] = "Completed"]
    /\ inFlight' = inFlight \ {m}
    /\ members'  = members \ {m}

Next ==
    \/ \E m \in Machines : BeginBootstrap(m)
    \/ \E m \in Machines : JoinEtcd(m)
    \/ \E m \in Machines : ApiserverReady(m)
    \/ \E m \in Machines : AdmitRemediation(m)
    \/ \E m \in Machines : CompleteRemediation(m)

Spec == Init /\ [][Next]_vars

\* -- Symmetry --------------------------------------------------------------
\*
\* TLC's symmetry operator requires a permutation group over the model
\* values that index every state variable. All three variables index
\* by `Machines`, so `Permutations(Machines)` is a sound symmetry
\* group.

MachineSymmetry == Permutations(Machines)

\* -- Invariants ------------------------------------------------------------

InFlightBounded == Cardinality(inFlight) <= MaxConcurrent

NoConcurrentQuorumLoss ==
    Cardinality(members \ inFlight) >= QuorumOf(members) \/ members = {}

\* Every Machine's phase is the per-machine projection of the global
\* state. AT-MOST-ONE remediation per Machine is automatic because
\* `phase[m] = "Remediating"` is the only way `m \in inFlight`.
PhaseConsistent ==
    /\ \A m \in Machines :
         (phase[m] = "Remediating") <=> (m \in inFlight)
    /\ \A m \in Machines :
         (phase[m] \in {"EtcdMember", "ControlPlaneReady", "Remediating"}) <=> (m \in members)

AllSafetyInvariants ==
    /\ InFlightBounded
    /\ NoConcurrentQuorumLoss
    /\ PhaseConsistent

=============================================================================
\* Modification history:
\*   2026-05-13 — first version. Hand-crafted symmetry-friendly
\*                abstraction of Lifecycle.qnt to demonstrate TLC's
\*                Permutations() reduction (issue #23).
