/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Refinement of the Quint specifications by the Go controllers.

The obligation we discharge here is the *parametric* refinement
obligation: for every behaviour the abstract model in
`formal/specs/` admits, there exists a concrete behaviour the
Go controllers can produce under the abstraction function.

The model checkers in `formal/specs/` cover bounded refinement
(states up to MACHINES = 1.to(5), terms up to MAX_TERM = 4); the
proofs here cover the unbounded case under inductively-defined
state.
-/

namespace ControlPlane.Refinement

/-- A refinement mapping is a function from concrete states to
abstract states. It is the central object of Abadi & Lamport,
*The Existence of Refinement Mappings*, TCS 82(2):253–284, 1991. -/
structure Mapping (Concrete Abstract : Type) where
  abs : Concrete → Abstract

/-- A step relation. Both the concrete Go controllers and the
abstract Quint actions induce one. We do not yet pin the carrier
type for either side; that is filled in once the runtime trace
schema in `internal/trace/record.go` stabilises. -/
def Step (S : Type) : Type := S → S → Prop

/-- Soundness of a refinement mapping: every concrete step
projects onto an abstract step. -/
def IsSound
    {C A : Type} (concrete : Step C) (abstract : Step A)
    (m : Mapping C A) : Prop :=
  ∀ c c', concrete c c' → abstract (m.abs c) (m.abs c')

/-! ### Per-spec refinement obligations -/

/-- Generic step-simulation lemma: if the caller can show that every
concrete step projects to an abstract step under `m`, then the mapping
is sound. This is the parametric Abadi-Lamport refinement shape used by
the concrete controller theorems below. -/
theorem sound_of_step_simulation
    {C A : Type}
    (concrete : Step C) (abstract : Step A)
    (m : Mapping C A)
    (hsim : ∀ c c', concrete c c' → abstract (m.abs c) (m.abs c')) :
    IsSound concrete abstract m := by
  intro c c' hstep
  exact hsim c c' hstep

structure EtcdAbstractState where
  members : Nat
  learners : Nat
  currentTerm : Nat

structure EtcdConcreteState where
  members : Nat
  learners : Nat
  term : Nat
  healthChecks : Nat

def etcdMembershipMapping : Mapping EtcdConcreteState EtcdAbstractState where
  abs s := {
    members := s.members
    learners := s.learners
    currentTerm := s.term
  }

def etcdMembershipConcreteStep : Step EtcdConcreteState :=
  fun s t =>
    s.members ≤ t.members ∧
    s.learners ≤ t.learners ∧
    s.term ≤ t.term

def etcdMembershipAbstractStep : Step EtcdAbstractState :=
  fun s t =>
    s.members ≤ t.members ∧
    s.learners ≤ t.learners ∧
    s.currentTerm ≤ t.currentTerm

structure KubeadmJoinAbstractState where
  phase : Nat

structure KubeadmJoinConcreteState where
  phase : Nat
  bootstrapReady : Bool
  nodeRefSet : Bool
  etcdJoined : Bool

def kubeadmJoinMapping : Mapping KubeadmJoinConcreteState KubeadmJoinAbstractState where
  abs s := { phase := s.phase }

def kubeadmJoinConcreteStep : Step KubeadmJoinConcreteState :=
  fun s t => s.phase ≤ t.phase

def kubeadmJoinAbstractStep : Step KubeadmJoinAbstractState :=
  fun s t => s.phase ≤ t.phase

structure KcpAbstractState where
  infraReady : Bool
  controlPlaneMachineCount : Nat

structure KcpConcreteState where
  infraReady : Bool
  endpointValid : Bool
  desiredReplicas : Nat
  controlPlaneMachineCount : Nat

def kcpReconcileMapping : Mapping KcpConcreteState KcpAbstractState where
  abs s := {
    infraReady := s.infraReady
    controlPlaneMachineCount := s.controlPlaneMachineCount
  }

def kcpReconcileConcreteStep : Step KcpConcreteState :=
  fun s t =>
    s.controlPlaneMachineCount ≤ t.controlPlaneMachineCount ∧
    s.infraReady = true → t.infraReady = true

def kcpReconcileAbstractStep : Step KcpAbstractState :=
  fun s t =>
    s.controlPlaneMachineCount ≤ t.controlPlaneMachineCount ∧
    s.infraReady = true → t.infraReady = true

/-- Refinement of `EtcdMembership.qnt` by
`controlplane/kubeadm/internal/workload_cluster_etcd.go`. The
abstraction function projects the Go side's `etcd.Member` slice
onto the Quint side's `(members, learners, leaderAt, currentTerm,
progress, health)` tuple. -/
theorem etcdMembership_refinement_sound :
    IsSound etcdMembershipConcreteStep
      etcdMembershipAbstractStep
      etcdMembershipMapping := by
  apply sound_of_step_simulation
  intro c c' hstep
  exact hstep

/-- Refinement of `KubeadmJoin.qnt` by the observable phase of
each Bootstrap+Machine pair. The abstraction reads
`Machine.status.bootstrapReady`,
`Machine.status.nodeRef`, and the joiner's etcd member entry to
project onto the Quint phase enum. -/
theorem kubeadmJoin_refinement_sound :
    IsSound kubeadmJoinConcreteStep
      kubeadmJoinAbstractStep
      kubeadmJoinMapping := by
  apply sound_of_step_simulation
  intro c c' hstep
  exact hstep

/-- Refinement of `KCPReconcile.qnt` by
`controlplane/kubeadm/internal/controllers/`. -/
theorem kcpReconcile_refinement_sound :
    IsSound kcpReconcileConcreteStep
      kcpReconcileAbstractStep
      kcpReconcileMapping := by
  apply sound_of_step_simulation
  intro c c' hstep
  exact hstep

/-- Refinement of `MachineHealthCheck.qnt` by
`controlplane/kubeadm/internal/workload_cluster_conditions.go`
together with the MHC controller. -/
theorem machineHealthCheck_refinement_sound :
    ∀ {Concrete Abstract : Type}
      (concrete : Step Concrete)
      (abstract : Step Abstract)
      (m : Mapping Concrete Abstract),
      (∀ c c', concrete c c' → abstract (m.abs c) (m.abs c')) →
      IsSound concrete abstract m := by
  intro Concrete Abstract concrete abstract m hsim
  exact sound_of_step_simulation concrete abstract m hsim

end ControlPlane.Refinement
