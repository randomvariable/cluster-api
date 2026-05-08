/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Top-level import for the control-plane lifecycle proofs. Each
submodule states a distinct obligation that exceeds the reach of
the model checkers in `../specs/`:

  * Refinement.lean      — every Quint trace concretises to a Go
                           controller trace under the abstraction
                           function (Abadi-Lamport refinement).
  * Informativeness.lean — the v1beta2 condition projection is at
                           least as informative as the v1beta1
                           projection. (Currently has an open
                           counterexample; see counterexample-log.)
  * Safety.lean          — `canSafelyRemediate ⇒ post-remediation
                           voter quorum is preserved`.
  * Convergence.lean     — FM-9 fairness recurrence: under per-
                           action fairness, P is visited
                           infinitely often. Closes the gap that
                           TLC's tableau and Apalache's temporal
                           pass cannot reach.
  * Ordering.lean        — FM-48/49/50: end-to-end cluster
                           bring-up ordering invariants. Refines
                           ClusterE2E.qnt's bounded random-walk
                           verdicts to an unbounded state space.

The submodules expose definitions, lemmas, and theorems but do
NOT auto-discharge proofs at the scaffold stage. Open obligations
are marked `sorry` and tracked as TBD rows in the
abstraction-mapping table.
-/

import ControlPlane.Refinement
import ControlPlane.Informativeness
import ControlPlane.Safety
import ControlPlane.Convergence
import ControlPlane.Ordering
