---------------------------- MODULE RemediationCAS ----------------------------
(*
  RemediationCAS.tla — issue #110.

  Sibling refinement property for Remediation.tla. Where
  Remediation.tla models "every CommitAdmission is a valid
  AdmitOrBlock", this module enforces the strictly tighter
  property:

    "the state observed at commit must match the state observed
     at admission."

  The Go production code added a CAS-style check in
  RemoveEtcdMember / RemoveEtcdMemberByID
  (controlplane/kubeadm/internal/workload_cluster_etcd.go) that
  takes an EtcdRemovalExpectation{AdmissionVoterCount,
  TargetWasLearner}, observes the live MemberList inside the
  removal RPC, and aborts if either of these conjuncts fail:

      live voter count >= admissionVoterCount
   /\ (admission saw target as learner) => live target is still learner

  This module is the formal counterpart: it pairs every admission
  event with a commit event, records the live state at commit, and
  asserts that the conjunction above held when the RPC fired.

  The model is intentionally minimal — it does not re-model the
  scheduler/queue (that is Remediation.tla's job). It only models
  the per-Machine handshake:

      ReadGate(m, vsAtAdmission, learnerAtAdmission)
        -> CommitAdmission(m, vsAtCommit, learnerAtCommit)
        -> RemoveMemberRPC(m)

  or, equivalently, the abort path:

      ReadGate(m, ...) -> CommitAdmissionAborted(m)

  Apache 2.0 — Copyright 2026 The Kubernetes Authors.
*)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    Machines,            \* finite set of machine identifiers
    MaxVoters            \* upper bound on |voterSet|; bounds the model

ASSUME
    /\ IsFiniteSet(Machines)
    /\ Cardinality(Machines) >= 1
    /\ MaxVoters \in 1..(Cardinality(Machines) + 1)

\* -- Variables -------------------------------------------------------------

\* The four per-Machine sets model where each Machine sits in the
\* CAS handshake. A Machine moves admission -> committed -> rpcDone
\* on the happy path, or admission -> aborted on the CAS-fail path.

VARIABLES
    admission,    \* m -> [voterCount: Nat, isLearner: BOOLEAN] for ReadGate-fired
    committed,    \* m -> [freshVoterCount: Nat, freshIsLearner: BOOLEAN]
    aborted,      \* SUBSET Machines — admission saw a CAS abort at commit time
    rpcDone,      \* SUBSET Machines — RemoveMemberRPC has fired
    voterCount,   \* current live voter count (0..MaxVoters)
    learners      \* SUBSET Machines — currently learners (not voters)

vars == << admission, committed, aborted, rpcDone, voterCount, learners >>

\* -- Helpers ---------------------------------------------------------------

\* A Machine has a pending admission record iff its key is in
\* `admission`. We model `admission` as a partial function via
\* DOMAIN-membership checks.
HasAdmission(m) == m \in DOMAIN admission
HasCommit(m)    == m \in DOMAIN committed

\* The CAS pairing predicate from the Go-side check.
GateAndCommitConsistent(adm, com) ==
    /\ com.freshVoterCount >= adm.voterCount
    /\ (adm.isLearner => com.freshIsLearner)

\* -- Initial state ---------------------------------------------------------

Init ==
    /\ admission  = << >>
    /\ committed  = << >>
    /\ aborted    = {}
    /\ rpcDone    = {}
    /\ voterCount = MaxVoters
    /\ learners   = {}

\* -- Live-state perturbations ----------------------------------------------
\*
\* These mirror the real-world events the Go CAS guards against:
\* a concurrent removal (voterCount decreases) and a learner
\* promotion (m leaves `learners`).

VoterRemoved ==
    /\ voterCount > 1
    /\ voterCount' = voterCount - 1
    /\ UNCHANGED << admission, committed, aborted, rpcDone, learners >>

LearnerPromoted(m) ==
    /\ m \in learners
    /\ learners' = learners \ {m}
    /\ UNCHANGED << admission, committed, aborted, rpcDone, voterCount >>

LearnerAdded(m) ==
    /\ m \notin learners
    /\ learners' = learners \cup {m}
    /\ UNCHANGED << admission, committed, aborted, rpcDone, voterCount >>

\* -- Admission/commit handshake -------------------------------------------

ReadGate(m) ==
    /\ ~HasAdmission(m)
    /\ m \notin rpcDone
    /\ m \notin aborted
    /\ LET adm == [voterCount |-> voterCount,
                   isLearner  |-> (m \in learners)]
       IN admission' = (m :> adm) @@ admission
    /\ UNCHANGED << committed, aborted, rpcDone, voterCount, learners >>

\* CommitAdmission fires only if the CAS predicate holds. This is
\* the spec contract: the Go side MUST abort if the predicate
\* fails, and that abort is the CommitAdmissionAborted action.
CommitAdmission(m) ==
    /\ HasAdmission(m)
    /\ ~HasCommit(m)
    /\ m \notin aborted
    /\ LET adm == admission[m]
           com == [freshVoterCount |-> voterCount,
                   freshIsLearner  |-> (m \in learners)]
       IN /\ GateAndCommitConsistent(adm, com)
          /\ committed' = (m :> com) @@ committed
    /\ UNCHANGED << admission, aborted, rpcDone, voterCount, learners >>

CommitAdmissionAborted(m) ==
    /\ HasAdmission(m)
    /\ ~HasCommit(m)
    /\ m \notin aborted
    /\ LET adm == admission[m]
           com == [freshVoterCount |-> voterCount,
                   freshIsLearner  |-> (m \in learners)]
       IN ~GateAndCommitConsistent(adm, com)
    /\ aborted' = aborted \cup {m}
    /\ UNCHANGED << admission, committed, rpcDone, voterCount, learners >>

RemoveMemberRPC(m) ==
    /\ HasCommit(m)
    /\ m \notin rpcDone
    /\ m \notin aborted
    /\ rpcDone' = rpcDone \cup {m}
    /\ UNCHANGED << admission, committed, aborted, voterCount, learners >>

\* -- Next-state relation ---------------------------------------------------

Next ==
    \/ \E m \in Machines : ReadGate(m)
    \/ \E m \in Machines : CommitAdmission(m)
    \/ \E m \in Machines : CommitAdmissionAborted(m)
    \/ \E m \in Machines : RemoveMemberRPC(m)
    \/ VoterRemoved
    \/ \E m \in Machines : LearnerPromoted(m)
    \/ \E m \in Machines : LearnerAdded(m)

Spec == Init /\ [][Next]_vars

\* -- Invariants -------------------------------------------------------------

\* Domain bookkeeping: no Machine is both committed and aborted.
DomainsDisjoint ==
    /\ DOMAIN committed \cap aborted = {}
    /\ rpcDone \subseteq DOMAIN committed
    /\ DOMAIN committed \subseteq DOMAIN admission
    /\ aborted \subseteq DOMAIN admission

\* The CAS refinement: any Machine with a successful commit had
\* a CAS-consistent (admission, commit) pair. This is the
\* admission/commit refinement property #110 wants enforced.
GateAndCommitObserveConsistentState ==
    \A m \in DOMAIN committed :
        GateAndCommitConsistent(admission[m], committed[m])

\* Every RPC was preceded by a non-aborted commit for the same
\* Machine. This is "EveryRemoveMemberHasMatchingValidCommitAdmission"
\* from the issue.
EveryRemoveMemberHasMatchingValidCommitAdmission ==
    \A m \in rpcDone :
        /\ HasCommit(m)
        /\ m \notin aborted

\* Aborts are not failures: a Machine can sit in `aborted` and
\* the spec stays well-formed. Re-admission requires a fresh
\* reconcile in the real system; we model that as the same
\* Machine re-entering DOMAIN admission later — but to keep TLC
\* finite, this spec treats abort as terminal per Machine.

\* The combined refinement obligation.
AllRefinementInvariants ==
    /\ DomainsDisjoint
    /\ GateAndCommitObserveConsistentState
    /\ EveryRemoveMemberHasMatchingValidCommitAdmission

=============================================================================
\* Modification history:
\*   2026-05-13 — first version. Companion to Remediation.tla;
\*                models the admission/commit CAS pairing the Go
\*                EtcdRemovalExpectation enforces at runtime.
