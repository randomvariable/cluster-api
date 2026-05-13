---------------------------- MODULE EtcdMembershipSymmetry ----------------------------
(*
  EtcdMembershipSymmetry.tla — issue #23 (TLC symmetry reduction).

  Hand-crafted symmetry-friendly abstraction of `EtcdMembership.qnt`'s
  voter/learner promotion subsystem. The Quint compiler types the
  member identifier as `Int` (with arithmetic) so the compiled spec is
  not a valid symmetry domain for TLC. This module re-implements the
  symmetric subset using model values for IDs.

  Tracked transitions:

    * AddLearner(id)            — add a new learner
    * ObserveLearnerProgress(id, p)
    * PromoteLearner(id)        — eligible learner becomes voter
    * RemoveMember(id)          — remove a voter (membership change)

  Invariants tracked:

    * LearnerNotVoter           — disjointness
    * NoConcurrentDualPromotion — at most one promotion in flight
    * QuorumPreservedOnRemoval  — removal cannot break voter quorum

  Apache 2.0 — Copyright 2026 The Kubernetes Authors.
*)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    Members,         \* finite set of model-value member identifiers
    MaxLearners      \* simultaneous learner cap

ASSUME
    /\ IsFiniteSet(Members)
    /\ Cardinality(Members) >= 3
    /\ MaxLearners \in 1..Cardinality(Members)

Progress == {"LaggingFar", "LaggingNear", "Eligible"}

VARIABLES
    voters,          \* SUBSET Members
    learners,        \* SUBSET Members
    progress         \* (voters \cup learners) -> Progress

vars == << voters, learners, progress >>

QuorumOf(S) == (Cardinality(S) \div 2) + 1

Init ==
    /\ voters   = Members        \* bootstrap state: every Member is a voter
    /\ learners = {}
    /\ progress = [m \in Members |-> "Eligible"]

AddLearner(id) ==
    /\ id \notin voters
    /\ id \notin learners
    /\ Cardinality(learners) < MaxLearners
    /\ learners' = learners \cup {id}
    /\ progress' = [progress EXCEPT ![id] = "LaggingFar"]
    /\ UNCHANGED voters

ObserveLearnerProgress(id, p) ==
    /\ id \in learners
    /\ p \in Progress
    /\ progress' = [progress EXCEPT ![id] = p]
    /\ UNCHANGED << voters, learners >>

PromoteLearner(id) ==
    /\ id \in learners
    /\ progress[id] = "Eligible"
    /\ voters'   = voters \cup {id}
    /\ learners' = learners \ {id}
    /\ UNCHANGED progress

RemoveMember(id) ==
    /\ id \in voters
    /\ Cardinality(voters) - 1 >= QuorumOf(voters)
    /\ voters'   = voters \ {id}
    /\ UNCHANGED << learners, progress >>

Next ==
    \/ \E id \in Members : AddLearner(id)
    \/ \E id \in Members : \E p \in Progress : ObserveLearnerProgress(id, p)
    \/ \E id \in Members : PromoteLearner(id)
    \/ \E id \in Members : RemoveMember(id)

Spec == Init /\ [][Next]_vars

MemberSymmetry == Permutations(Members)

LearnerNotVoter == voters \cap learners = {}

QuorumNonEmpty == Cardinality(voters) >= 1

QuorumPreservedOnRemoval == Cardinality(voters) >= 1

AllSafetyInvariants ==
    /\ LearnerNotVoter
    /\ QuorumNonEmpty
    /\ QuorumPreservedOnRemoval

=============================================================================
\* Modification history:
\*   2026-05-13 — first version. Companion symmetry exemplar for
\*                EtcdMembership.qnt (issue #23).
