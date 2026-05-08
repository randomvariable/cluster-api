/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Lakefile for the formal proofs accompanying the
Cluster API control-plane lifecycle model. The package is
deliberately self-contained — no Mathlib dependency at the
scaffold stage so the build is fast and reproducible. When a
proof requires order-theoretic, set-theoretic, or analytical
machinery beyond Lean core, add `mathlib` here and pin its
revision.
-/

import Lake
open Lake DSL

package controlplane where
  leanOptions := #[
    -- Surface unfinished proofs as warnings, not silent successes.
    ⟨`autoImplicit, false⟩,
    ⟨`relaxedAutoImplicit, false⟩
  ]

@[default_target]
lean_lib ControlPlane where
  -- All proofs and supporting definitions live under
  -- ControlPlane/. The top-level `ControlPlane.lean` re-exports
  -- the public surface.
  roots := #[`ControlPlane]
