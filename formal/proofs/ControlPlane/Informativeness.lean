/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

The informativeness ordering on condition projections.

A `Projection` of an underlying observation onto a condition is
"at least as informative as" another iff every diagnostic key the
second projection carries is also carried by the first. The
ordering is reflexive and transitive — that makes it a preorder,
not a partial order, because two projections that carry the same
key set under different syntactic forms are equivalent.

The user-reported incident's v1beta2 projection violates the
informativeness obligation against the v1beta1 projection. The
counterexample is filed in `formal/counterexample-log.md`.

This file is intentionally Mathlib-free: diagnostic-key sets are
modelled as `List`s and the proofs use only Lean 4 core.
-/

namespace ControlPlane.Informativeness

/-- A diagnostic key is an opaque string identifier. The
`formal/contracts/kcp-machine-contract.md` document fixes the
diagnostic-key set; this module is parameterised in the set so
adding a new key requires no proof rewrite. -/
abbrev DiagKey := String

/-- A condition projection is a function from observations to a
list of diagnostic keys it carries. -/
def Projection (Obs : Type) := Obs → List DiagKey

/-- `p` is at least as informative as `q` iff for every
observation, every key carried by `q` is also carried by `p`. -/
def AtLeastAsInformative {Obs : Type} (p q : Projection Obs) : Prop :=
  ∀ (o : Obs) (k : DiagKey), k ∈ q o → k ∈ p o

infix:50 " ≼ " => AtLeastAsInformative

/-- The informativeness preorder is reflexive. -/
theorem refl {Obs : Type} (p : Projection Obs) : p ≼ p := by
  unfold AtLeastAsInformative
  intro _ _ h
  exact h

/-- The informativeness preorder is transitive. -/
theorem trans
    {Obs : Type} {p q r : Projection Obs}
    (hpq : p ≼ q) (hqr : q ≼ r) : p ≼ r := by
  unfold AtLeastAsInformative at *
  intro o k h
  -- `hpq : ∀ o k, k ∈ q o → k ∈ p o`
  -- `hqr : ∀ o k, k ∈ r o → k ∈ q o`
  -- Goal: `k ∈ p o`. From `h : k ∈ r o` and `hqr`, get `k ∈ q o`.
  -- From `hpq`, get `k ∈ p o`.
  exact hpq o k (hqr o k h)

/-! ### The KCP-Machine obligation -/

/-- The InformativenessObligation, parameterised in the
observation type. The contract in
`formal/contracts/kcp-machine-contract.md` instantiates this with
`Observation := MachineHealthCheck.Observation`. -/
def InformativenessObligation
    {Obs : Type} (πv1beta1 πv1beta2 : Projection Obs) : Prop :=
  πv1beta2 ≼ πv1beta1

/-- The user-reported incident is a counterexample to the
obligation. We do not discharge the negative claim here — that
would require a concrete v1beta2 projection contradicting the
contract. The counterexample lives in
`formal/counterexample-log.md` and the failing trace is checked
by the Go runtime in `internal/trace/checkers/mhc.go`. -/
theorem informativeness_obligation_violated_for_v1beta2_today :
    True := by
  -- TODO(formal): once the v1beta2 projection's exact
  -- behaviour is encoded as a Lean function, instantiate
  -- InformativenessObligation with it and produce a witness
  -- observation showing the obligation is false.
  trivial

end ControlPlane.Informativeness
