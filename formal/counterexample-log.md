# Counterexample log

This ledger records every spec violation surfaced by a model
checker, fuzz run, formal proof attempt, or production trace. Each
row is owned by an issue or a contributor and progresses
monotonically through the status workflow until closure.

## Schema

| Field | Required | Description |
| ----- | -------- | ----------- |
| Date | yes | UTC date the counterexample was first observed, formatted `YYYY-MM-DD`. |
| Spec | yes | Spec module, invariant, or proof obligation violated. |
| Action | yes | Spec action or transition that produced the counterexample. |
| Classification | yes | `quint`, `tlc`, `lean`, `runtime-checker`, `production-trace`, or `manual-review`. |
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
| 2026-04-28 | Composition.InformativenessObligation | MachineHealthCheck::DeriveCondition | production-trace | Major | Open | none | Reported as `kvp22096-98cda1-fpx9t` MHC events; the v1beta1 condition on the leader's Machine carries `failed to get etcdStatus for workload cluster ...: failed to get etcd status: context deadline exceeded`, while the v1beta2 condition on the same Machine reports `reason=InternalError, message="Please check controller logs for errors"`. The diagnostic key `context deadline exceeded` is present in v1beta1 and absent from v1beta2. | The model produces a counterexample to the InformativenessObligation invariant in `formal/specs/Composition.qnt` whenever an `UnreachableTimeout` observation passes through `MachineHealthCheck::DeriveCondition`. The invariant is intentionally excluded from `AllCompositionInvariants` so the rest of the model checks while this row remains open. Triage: file an upstream issue against the v1beta2 EtcdMemberHealthy projection in `controlplane/kubeadm/internal/workload_cluster_conditions.go:66`. |
