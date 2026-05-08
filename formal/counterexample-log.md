# Counterexample log

This ledger records every spec violation surfaced by a model
checker, fuzz run, formal proof attempt, or modelled trace. Each
row is owned by an issue or a contributor and progresses
monotonically through the status workflow until closure.

## Schema

| Field | Required | Description |
| ----- | -------- | ----------- |
| Date | yes | UTC date the counterexample was first observed, formatted `YYYY-MM-DD`. |
| Spec | yes | Spec module, invariant, or proof obligation violated. |
| Action | yes | Spec action or transition that produced the counterexample. |
| Classification | yes | `quint`, `tlc`, `lean`, `runtime-checker`, `modelled-trace`, or `manual-review`. |
| Severity | yes | `Critical`, `Major`, `Minor`, or `Nitpick`, matching CAPI review severity vocabulary. |
| Status | yes | One of `Open`, `Reproduced-Test-Written`, `Fixed-In-Implementation`, or `Closed-Verified`. |
| Fix link | yes | GitHub issue/PR reference once triaged, or `none`. |
| Evidence | yes | Repository path or stable URL for the trace, model output, proof obligation, CI artefact, or verification rerun. |
| Notes | yes | Closure evidence, next action, or accepted rationale. |

## Status workflow

| Status | Meaning | Allowed next |
| ------ | ------- | ------------ |
| Open | Newly recorded, not yet triaged. | Reproduced-Test-Written |
| Reproduced-Test-Written | A failing regression, model run, checker, or proof case reproduces the counterexample. | Fixed-In-Implementation |
| Fixed-In-Implementation | The code, spec, or proof has been changed; independent verification has not yet completed. | Closed-Verified, Reproduced-Test-Written |
| Closed-Verified | Independent rerun confirms the counterexample no longer reproduces. | Open (only on regression) |

Rows are append-only. Closure does not delete; it advances the
status and adds notes.

## Maintenance rules

1. Add a row when a checker, model-fuzz run, formal trace
   validator, model checker, or proof attempt produces a new
   violation.
2. Use one row per independent counterexample. If a single run
   surfaces multiple unrelated failures, split them.
3. Keep `Fix link` as a GitHub issue or PR reference once triage
   creates one.
4. Move `Status` monotonically through the allowed values; never
   delete historical rows after closure.

## Counterexamples

| Date       | Spec                          | Action                | Classification | Severity | Status | Fix link | Evidence                                                       | Notes |
| ---------- | ----------------------------- | --------------------- | -------------- | -------- | ------ | -------- | -------------------------------------------------------------- | ----- |
| (modelling pass) | Composition.InformativenessObligation | MachineHealthCheck::DeriveCondition | modelled-trace | Major | Open | none | Reported as `example-cluster` MHC events; the v1beta1 condition on the leader's Machine carries `failed to get etcdStatus for workload cluster ...: failed to get etcd status: context deadline exceeded`, while the v1beta2 condition on the same Machine drops the diagnostic key the v1beta1 message carries.
| 2026-05-08 | (mutation testing across 9 specs) | (60 surviving mutations) | mutation-tester | Minor | Open | randomvariable/cluster-api#4 | 696 mutations attempted across 9 specs; 131 killed; 60 survived. Breakdown: 35 ForallToExists (random-walk coverage; Apalache closes most), 11 AndToOr (bound-induced conjunct redundancy), 8 DropImpliesLhs (precondition rarely activated), 3 NegateRhs, 2 ExistsToForall, 1 FlipLeToLt. See `formal/mutation-findings.md`. | Cohort tracked here; per-survivor analysis in mutation-findings.md. Run `make mutation-test` to reproduce. Survivor .qnt files in `/tmp/quint-mutations/`. |
| 2026-05-08 | Lifecycle.ConvergenceFair16 | (multiple — see notes) | tlc | Minor | Open | randomvariable/cluster-api#5 | Depth bump 8 → 12 surfaced two fairness-scope gaps in `Lifecycle.qnt`: (1) ConvergenceFair16 lassos via `EtcdCompactionStart` (the action sets etcdCompactionInProgress=true; no fair-scheduled `EtcdCompactionDone` to clear it). (2) Adding EtcdCompactionDone (ConvergenceFair17) lassos via `MachineHealthChange` flip-flop — the per-(m,h) fairness conjunct treats "some MachineHealthChange fires" as fair, but the lasso has m=1 oscillating Healthy/Unhealthy infinitely. Phase 11d's bisection found this already; depth 12 re-surfaces it. | Both findings are fairness-scope gaps, not safety bugs. The full 65-conjunct ConvergenceFair would close them but tableaus to 0 branches at 16GB heap. Closing properly requires per-(m,h) fairness conjuncts. Documented as known-limitation; depth-8 verdict still stands. |
| 2026-05-08 | ClusterE2E.EtcdJoinedRequiresKcpInit (LLM candidate) | KcpMarkInitialized | quint | Minor | Closed-Verified | randomvariable/cluster-api#10 | LLM-discovered candidate `EtcdJoinedRequiresKcpInit` (∀m: machinePhase=MachineJoinedEtcd ⇒ kcpInitialized) failed at 200×60 random walk on `formal/specs/ClusterE2E.qnt`. Counterexample: the first CP enters MachineJoinedEtcd via `CpMachineJoinsEtcd` (line ~558), but the `kcpInitialized` flip happens in a separate `KcpMarkInitialized` transition (line 666) gated on `cpMachinesReady ≥ 1`. The model permits a transient where the first CP is JoinedEtcd-but-not-yet-Ready and KCP has not yet observed the trigger. | Candidate dropped — neither a spec bug nor a model gap, just an under-stated ordering. Documented in `formal/llm-invariants.md` § ClusterE2E.qnt. The 5 surviving candidates were promoted into AllSafetyInvariants. |
