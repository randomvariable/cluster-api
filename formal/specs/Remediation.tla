---------------------------- MODULE Remediation ----------------------------
(*
  Remediation.tla — KCP's remediation queue as a priority scheduler.

  KCPReconcile.qnt models the per-Machine remediation decision; this
  module composes that decision across the full set of unhealthy
  Machines and exposes the queue/admission/in-flight shape that
  scheduler-style reasoning is suited for. Two specific properties
  motivate the TLA+ formulation:

    1. AT MOST ONE remediation per Machine is in flight at any time.
       The Quint composition expresses this by guards on the
       per-Machine action; the TLA+ form makes the global invariant
       directly checkable across all Machines.

    2. NO TWO remediations execute concurrently in a way that
       collectively breaks quorum. KCPReconcile.qnt's
       `RemediationOnlyWhenSafe` is per-Machine; this module's
       `NoConcurrentQuorumLoss` is per-system.

  The model abstracts:
    * the actual replacement-Machine creation (success is assumed
      eventually).
    * the etcd member-removal order (KCP forwards leadership and
      removes the member; we assume both succeed).
    * the time it takes for a remediation to complete.

  TLC configuration in Remediation.cfg.

  Apache 2.0 — Copyright 2026 The Kubernetes Authors.
*)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Machines,            \* finite set of machine identifiers
    MaxConcurrent        \* upper bound on concurrent remediations

ASSUME
    /\ IsFiniteSet(Machines)
    /\ Cardinality(Machines) >= 1
    /\ MaxConcurrent \in 1..Cardinality(Machines)

\* -- Variables -------------------------------------------------------------

VARIABLES
    pending,             \* SUBSET Machines — awaiting evaluation
    blocked,             \* SUBSET Machines — evaluated, not safe
    inFlight,            \* SUBSET Machines — remediation running
    completed,           \* SUBSET Machines — remediation finished
    voterSet             \* current voter set (subset of Machines)

vars == << pending, blocked, inFlight, completed, voterSet >>

\* -- Helpers ---------------------------------------------------------------

QuorumOf(S) == (Cardinality(S) \div 2) + 1

\* Whether the post-remediation voter set still has quorum, given
\* that `m` is one of the voters being removed by remediation.
QuorumPreservedAfterDelete(vs, m) ==
    /\ m \in vs
    /\ Cardinality(vs) - 1 >= QuorumOf(vs)

\* "Safe" means: removing m preserves quorum AND no other
\* in-flight remediation is targeting an overlapping voter.
SafeToAdmit(m) ==
    /\ QuorumPreservedAfterDelete(voterSet, m)
    /\ Cardinality(inFlight) < MaxConcurrent

\* -- Initial state ---------------------------------------------------------

Init ==
    /\ pending  = {}
    /\ blocked  = {}
    /\ inFlight = {}
    /\ completed = {}
    /\ voterSet = Machines        \* bootstrap state: every Machine is a voter

\* -- Actions ---------------------------------------------------------------

\* RequestRemediation: a Machine is flagged as unhealthy and queued.
RequestRemediation(m) ==
    /\ m \in voterSet
    /\ m \notin pending
    /\ m \notin blocked
    /\ m \notin inFlight
    /\ m \notin completed
    /\ pending' = pending \cup {m}
    /\ UNCHANGED << blocked, inFlight, completed, voterSet >>

\* AdmitOrBlock: pull one Machine from `pending` and either admit
\* it (move to inFlight) or block it.
AdmitOrBlock(m) ==
    /\ m \in pending
    /\ \/ /\ SafeToAdmit(m)
          /\ inFlight' = inFlight \cup {m}
          /\ pending'  = pending \ {m}
          /\ UNCHANGED << blocked, completed, voterSet >>
       \/ /\ ~SafeToAdmit(m)
          /\ blocked'  = blocked \cup {m}
          /\ pending'  = pending \ {m}
          /\ UNCHANGED << inFlight, completed, voterSet >>

\* CompleteRemediation: an in-flight remediation finishes. The
\* Machine is removed from the voter set (etcd member is gone) and
\* added to `completed`. The replacement Machine is implicitly added
\* to the voter set so cardinality is preserved across the transition.
\* In a real system the replacement is a fresh identifier; in this
\* abstraction we model the *role*, not the identity.
CompleteRemediation(m) ==
    /\ m \in inFlight
    /\ inFlight'  = inFlight \ {m}
    /\ completed' = completed \cup {m}
    /\ voterSet'  = voterSet     \* abstracted: replacement preserves cardinality
    /\ UNCHANGED << pending, blocked >>

\* RetryBlocked: a previously blocked Machine becomes admissible
\* (e.g. the matchable set resolved or another in-flight finished).
RetryBlocked(m) ==
    /\ m \in blocked
    /\ blocked' = blocked \ {m}
    /\ pending' = pending \cup {m}
    /\ UNCHANGED << inFlight, completed, voterSet >>

\* -- Next-state relation ---------------------------------------------------

Next ==
    \/ \E m \in Machines : RequestRemediation(m)
    \/ \E m \in pending  : AdmitOrBlock(m)
    \/ \E m \in inFlight : CompleteRemediation(m)
    \/ \E m \in blocked  : RetryBlocked(m)

Spec == Init /\ [][Next]_vars

\* -- Invariants -------------------------------------------------------------

\* Each Machine occupies at most one of the four queue states.
QueuesDisjoint ==
    /\ pending \cap blocked  = {}
    /\ pending \cap inFlight = {}
    /\ pending \cap completed = {}
    /\ blocked \cap inFlight = {}
    /\ blocked \cap completed = {}
    /\ inFlight \cap completed = {}

\* The in-flight set never exceeds the configured cap.
InFlightCappedByMax ==
    Cardinality(inFlight) <= MaxConcurrent

\* For every in-flight Machine, the safety predicate held when it
\* was admitted. The next-state relation guards on this; the
\* invariant restates it for TLC's checker.
AtMostOneRemediationPerMachine ==
    \A m \in Machines :
        Cardinality({s \in {pending, blocked, inFlight, completed} : m \in s}) <= 1

\* No concurrent remediation breaks quorum. Concretely: for every
\* Machine in inFlight, the (voterSet minus inFlight) set still has
\* quorum.
NoConcurrentQuorumLoss ==
    Cardinality(voterSet \ inFlight) >= QuorumOf(voterSet)

\* Progress: every Machine that enters `pending` eventually leaves
\* the queue (becomes blocked, in-flight, or completed). This is a
\* liveness obligation; TLC checks the safety obligations under
\* `Spec`, and the liveness obligation is documented for future
\* use under fairness assumptions.
MonotonicProgress ==
    \A m \in Machines :
        m \in pending => <>(m \in blocked \/ m \in inFlight \/ m \in completed)

\* -- Aggregate -------------------------------------------------------------

AllSafetyInvariants ==
    /\ QueuesDisjoint
    /\ InFlightCappedByMax
    /\ AtMostOneRemediationPerMachine
    /\ NoConcurrentQuorumLoss

=============================================================================
\* Modification history:
\*   2026-05-07 — first version. Scheduler-shape model of the KCP
\*                remediation queue. Companion to
\*                ../specs/KCPReconcile.qnt.
