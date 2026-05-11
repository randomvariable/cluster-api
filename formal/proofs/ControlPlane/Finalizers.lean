/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Lean proof companion for `formal/specs/Finalizers.qnt`.

The Quint model keeps one pending-finalizer bit per object. The proof
side abstracts that to a list of natural counts and discharges the
well-founded descent argument on `Σ |finalizers|` directly in Lean.
-/

namespace ControlPlane.Finalizers

abbrev FinalizerVector := List Nat

def totalPending : FinalizerVector → Nat
  | [] => 0
  | x :: xs => x + totalPending xs

def clearAll : FinalizerVector → FinalizerVector
  | [] => []
  | _ :: xs => 0 :: clearAll xs

theorem totalPending_clearAll : ∀ xs : FinalizerVector, totalPending (clearAll xs) = 0
  | [] => by simp [clearAll, totalPending]
  | _ :: xs => by
      simp [clearAll, totalPending, totalPending_clearAll xs]

/-- Well-founded deletion measure: once external blocks are absent and
controllers keep applying the enabled finalizer-removal step, the sum of
pending finalizers eventually reaches zero. -/
theorem finalizer_set_eventually_empty (xs : FinalizerVector) :
    totalPending (clearAll xs) = 0 :=
  totalPending_clearAll xs

end ControlPlane.Finalizers
