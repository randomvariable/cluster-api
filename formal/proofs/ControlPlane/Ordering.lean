/-
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

End-to-end cluster-lifecycle ordering invariants — deductive
proofs for FM-48, FM-49, FM-50.

These invariants are random-walk-verified at depth 4 by
`formal/specs/ClusterE2E.qnt`. This module discharges them
deductively for an unbounded state space, so the proofs hold
for any cluster topology — not just the 3-CP/2-worker bound the
model checker explores.

Each theorem refines a Quint state invariant; the abstract state
here is a smaller faithful subset of `ClusterE2E.qnt`'s state.

  FM-48 (`fm48_no_cp_before_infra_ready`)
    `cpMachineCount > 0 → infraProvisioned`. Refines
    `controlplane/kubeadm/internal/controllers/controller.go:296`.

  FM-49 (`fm49_no_workers_before_cp_init`)
    `workerCount > 0 → cpInitialised`. Refines the MD controller's
    gate on `Cluster.Status.Initialization.ControlPlaneInitialized`.

  FM-50 (`fm50_endpoint_monotonic`)
    Once `endpoint = some h`, every reachable successor still has
    `endpoint = some h`. Refines `cluster_controller_phases.go:219`
    and the absence of any clear-endpoint path.
-/

namespace ControlPlane.Ordering

/-- Abstract cluster state. -/
structure ClusterState where
  infraProvisioned : Bool
  endpoint         : Option String
  cpInitialised    : Bool
  cpMachineCount   : Nat
  workerCount      : Nat
  deriving Repr

/-- The initial state: nothing provisioned. -/
def initialState : ClusterState :=
  { infraProvisioned := false
    endpoint         := none
    cpInitialised    := false
    cpMachineCount   := 0
    workerCount      := 0
  }

/-- Step relation. Each constructor refines a CAPI controller
action; preconditions encode the ordering gates that must hold
for the action to fire. -/
inductive Step : ClusterState → ClusterState → Prop where
  | infraReady
      (s : ClusterState)
      (host : String)
      (h : s.infraProvisioned = false) :
      Step s
        { s with
          infraProvisioned := true
          endpoint         := some host }
  | createCpMachine
      (s : ClusterState)
      (h : s.infraProvisioned = true) :
      Step s { s with cpMachineCount := s.cpMachineCount + 1 }
  | cpInit
      (s : ClusterState)
      (hi : s.infraProvisioned = true)
      (hm : s.cpMachineCount > 0)
      (hc : s.cpInitialised = false) :
      Step s { s with cpInitialised := true }
  | createWorker
      (s : ClusterState)
      (h : s.cpInitialised = true) :
      Step s { s with workerCount := s.workerCount + 1 }

/-- Reflexive-transitive closure of `Step`. -/
inductive Reachable : ClusterState → ClusterState → Prop where
  | refl  (s : ClusterState) : Reachable s s
  | step  (s t u : ClusterState) (hst : Step s t) (htu : Reachable t u) :
          Reachable s u

/-- A state reachable from `initialState`. -/
abbrev IsReachable (s : ClusterState) : Prop :=
  Reachable initialState s

/-- A unary state predicate stable under `Step` lifts to one
stable under `Reachable`. -/
theorem reachable_preserves
    (P : ClusterState → Prop)
    (hpres : ∀ s t, P s → Step s t → P t) :
    ∀ {s t : ClusterState}, Reachable s t → P s → P t := by
  intro s t h
  induction h with
  | refl s => intro hs; exact hs
  | step s t u hst _ ih =>
    intro hs
    exact ih (hpres s t hs hst)

-- =============================================================
-- FM-48 — no CP Machine before InfraCluster is ready.
-- =============================================================

/-- Invariant: `cpMachineCount > 0` implies `infraProvisioned`. -/
def InvFM48 (s : ClusterState) : Prop :=
  s.cpMachineCount > 0 → s.infraProvisioned = true

theorem inv_FM48_initial : InvFM48 initialState := by
  intro h
  simp [initialState] at h

theorem inv_FM48_step
    {s t : ClusterState} (hs : InvFM48 s) (hst : Step s t) :
    InvFM48 t := by
  intro hcp
  cases hst with
  | infraReady host _ => rfl
  | createCpMachine h => exact h
  | cpInit hi _ _ => exact hi
  | createWorker _ => exact hs hcp

/-- FM-48: any reachable state has `cpMachineCount > 0 → infraProvisioned`. -/
theorem fm48_no_cp_before_infra_ready
    {s : ClusterState} (h : IsReachable s) : InvFM48 s :=
  reachable_preserves InvFM48 (fun _ _ => inv_FM48_step) h inv_FM48_initial

-- =============================================================
-- FM-49 — no workers before ControlPlaneInitialized.
-- =============================================================

/-- Invariant: `workerCount > 0` implies `cpInitialised`. -/
def InvFM49 (s : ClusterState) : Prop :=
  s.workerCount > 0 → s.cpInitialised = true

theorem inv_FM49_initial : InvFM49 initialState := by
  intro h
  simp [initialState] at h

theorem inv_FM49_step
    {s t : ClusterState} (hs : InvFM49 s) (hst : Step s t) :
    InvFM49 t := by
  intro hw
  cases hst with
  | infraReady host _ => exact hs hw
  | createCpMachine _ => exact hs hw
  | cpInit _ _ _ => rfl
  | createWorker h => exact h

/-- FM-49: any reachable state has `workerCount > 0 → cpInitialised`. -/
theorem fm49_no_workers_before_cp_init
    {s : ClusterState} (h : IsReachable s) : InvFM49 s :=
  reachable_preserves InvFM49 (fun _ _ => inv_FM49_step) h inv_FM49_initial

-- =============================================================
-- FM-50 — ControlPlaneEndpoint monotonicity.
-- =============================================================

/-- Strong endpoint invariant: if the endpoint is `some _`, the
infra is provisioned. Holds because only `infraReady` ever sets
the endpoint, and `infraReady` simultaneously sets
`infraProvisioned := true`; once true, no constructor clears it. -/
def InvEndpointImpliesInfra (s : ClusterState) : Prop :=
  ∀ host, s.endpoint = some host → s.infraProvisioned = true

theorem inv_endpoint_initial : InvEndpointImpliesInfra initialState := by
  intro host h
  simp [initialState] at h

theorem inv_endpoint_step
    {s t : ClusterState}
    (hs : InvEndpointImpliesInfra s) (hst : Step s t) :
    InvEndpointImpliesInfra t := by
  intro host hep
  cases hst with
  | infraReady host' _ => rfl
  | createCpMachine h => exact h
  | cpInit hi _ _ => exact hi
  | createWorker _ => exact hs host hep

theorem inv_endpoint_implies_infra
    {s : ClusterState} (h : IsReachable s) :
    InvEndpointImpliesInfra s :=
  reachable_preserves InvEndpointImpliesInfra
    (fun _ _ => inv_endpoint_step) h inv_endpoint_initial

/-- A conjunctive predicate: the endpoint equals `some host` AND
infra is provisioned. This is `Step`-stable on its own (no
external invariant needed), because the only constructor that
could clear the endpoint or mutate `infraProvisioned` is
`infraReady` — and its precondition `infraProvisioned = false`
contradicts the second conjunct. -/
def PEndpointHost (host : String) (s : ClusterState) : Prop :=
  s.endpoint = some host ∧ s.infraProvisioned = true

theorem PEndpointHost_step
    (host : String)
    {s t : ClusterState}
    (hs : PEndpointHost host s) (hst : Step s t) :
    PEndpointHost host t := by
  obtain ⟨hep, hinfra⟩ := hs
  cases hst with
  | infraReady host' h =>
    rw [h] at hinfra
    cases hinfra
  | createCpMachine _ =>
    exact ⟨hep, hinfra⟩
  | cpInit _ _ _ =>
    exact ⟨hep, hinfra⟩
  | createWorker _ =>
    exact ⟨hep, hinfra⟩

/-- FM-50: once the endpoint is `some host` in a reachable state,
every reachable successor still has `endpoint = some host`. -/
theorem fm50_endpoint_monotonic
    {s t : ClusterState} {host : String}
    (hsr : IsReachable s)
    (hep : s.endpoint = some host)
    (hst : Reachable s t) :
    t.endpoint = some host := by
  -- Step 1: from reachability + endpoint set, deduce infra is provisioned.
  have hinfra : s.infraProvisioned = true :=
    inv_endpoint_implies_infra hsr host hep
  have hps : PEndpointHost host s := ⟨hep, hinfra⟩
  -- Step 2: the conjunctive predicate is Step-stable, hence
  -- Reachable-stable.
  have hpt : PEndpointHost host t :=
    reachable_preserves (PEndpointHost host)
      (fun _ _ => PEndpointHost_step host) hst hps
  exact hpt.left

end ControlPlane.Ordering
