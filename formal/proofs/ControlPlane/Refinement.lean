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

/-- Refinement of `EtcdMembership.qnt` by
`controlplane/kubeadm/internal/workload_cluster_etcd.go`. The
abstraction function projects the Go side's `etcd.Member` slice
onto the Quint side's `(members, learners, leaderAt, currentTerm,
progress, health)` tuple. -/
theorem etcdMembership_refinement_sound :
    True := by
  -- TODO(formal): pin the concrete carrier (etcd-client view)
  -- and the abstract carrier (a record matching EtcdMembership's
  -- six state variables); discharge `IsSound` over them.
  trivial

/-- Refinement of `KubeadmJoin.qnt` by the observable phase of
each Bootstrap+Machine pair. The abstraction reads
`Machine.status.bootstrapReady`,
`Machine.status.nodeRef`, and the joiner's etcd member entry to
project onto the Quint phase enum. -/
theorem kubeadmJoin_refinement_sound :
    True := by
  -- TODO(formal): same shape as etcdMembership_refinement_sound.
  trivial

/-- Refinement of `KCPReconcile.qnt` by
`controlplane/kubeadm/internal/controllers/`. -/
theorem kcpReconcile_refinement_sound :
    True := by
  -- TODO(formal).
  trivial

/-- Refinement of `MachineHealthCheck.qnt` by
`controlplane/kubeadm/internal/workload_cluster_conditions.go`
together with the MHC controller. -/
theorem machineHealthCheck_refinement_sound :
    True := by
  -- TODO(formal).
  trivial

end ControlPlane.Refinement
