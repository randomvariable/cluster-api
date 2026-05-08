# LLM-driven invariant discovery (issue #10)

This document records the workflow and outcomes of the
LLM-driven invariant-discovery pass. The tool lives at
`hack/tools/llm-invariant-discovery.py`; per-spec fixtures live
in `formal/llm-invariants/<spec>.cache.json`. Each candidate
is verified with a 300×60 random walk via
`quint run --invariant=<NAME>` BEFORE being promoted into the
spec's `AllSafetyInvariants` block.

## Why a separate pass

The corpus has ~30 named invariants written by hand. Humans miss
cross-state invariants — particularly conjunctive properties of
the form "if X is true and Y is true, then Z must hold". An LLM
asked to enumerate such invariants surfaces candidates the
authors didn't think to assert. Every yes-answer is either:

  - a real invariant the model already enforces but didn't
    document (most common — strengthens the corpus's
    self-description);
  - a spurious candidate (the model permits a counterexample) —
    interesting because it points at an under-asserted boundary
    or a genuine model gap.

## Tool

```sh
# Live API call (requires ANTHROPIC_API_KEY):
python3 hack/tools/llm-invariant-discovery.py formal/specs/Lifecycle.qnt

# Offline replay against a fixture (deterministic, runs in CI):
python3 hack/tools/llm-invariant-discovery.py \
    --fixture formal/llm-invariants/Lifecycle.cache.json \
    formal/specs/Lifecycle.qnt

# Render the candidates as a Quint snippet ready to paste:
python3 hack/tools/llm-invariant-discovery.py \
    --fixture formal/llm-invariants/InPlaceUpdate.cache.json \
    --quint-out /tmp/candidates.qnt \
    formal/specs/InPlaceUpdate.qnt
```

The default model is `claude-opus-4-7`; OpenAI is supported via
`--provider openai`. Both API calls require the relevant
`*_API_KEY` environment variable.

## Verification protocol

Per candidate:

1. Add the `val` definition to the spec's invariant block.
2. Run `quint typecheck <spec.qnt>` — clean.
3. Run `quint run --backend=typescript --max-samples 300
   --max-steps 60 --invariant=<NAME> <spec.qnt>` —
   `[ok] No violation found` is the acceptance gate.
4. If the candidate holds: include it in
   `LLMCandidateInvariants` and (where appropriate) in the
   spec's master `AllSafetyInvariants` conjunction.
5. If it doesn't: file the trace in
   `formal/counterexample-log.md` and document the reason.

## Outcomes

### ClusterE2E.qnt

Five candidates verified at 300×60. One spurious — surfaced an
under-asserted ordering between `MachineJoinedEtcd` and
`KcpMarkInitialized`.

| Candidate | Verdict | Notes |
|-----------|---------|-------|
| `CpRoleAssignmentStable` | OK | CP_MACHINES partition is fixed by construction. |
| `WorkerRoleAssignmentStable` | OK | Symmetric to above. |
| `EtcdJoinedRequiresKcpInit` | **DROPPED — counterexample** | The first CP enters MachineJoinedEtcd via `CpMachineJoinsEtcd`, but `KcpMarkInitialized` is a separate transition that fires only AFTER `cpMachinesReady ≥ 1`. The model permits a transient where the first CP is in `MachineJoinedEtcd` but `kcpInitialized = false`. See `formal/counterexample-log.md` row dated 2026-05-08. |
| `InfraProvisionedRequiresInfraClusterReady` | OK | Refines Cluster controller observation. |
| `EndpointSetRequiresInfraClusterReady` | OK | Endpoint sourced from InfraCluster status. |
| `StableImpliesStepIdle` | OK | Topology step machine is idle in Stable. |

Promoted: 5/6. Acceptance criterion (≥5 verified per spec) met.

### InPlaceUpdate.qnt

Six candidates, all verified at 300×60.

| Candidate | Verdict | Notes |
|-----------|---------|-------|
| `LLM_AckOnlyForMovedMachines` | OK | AcknowledgedMove follows ownership flip. |
| `LLM_DoneImpliesOnNewMs` | OK | Completion implies prior move. |
| `LLM_OnOldMsImpliesNoAck` | OK | OnOldMS is pre-handshake. |
| `LLM_DoneNoHookPending` | OK | Completes the UpdateMachineHookShape partition. |
| `LLM_OldMsImpliesAtOldVersion` | OK | Version flip is a CompleteInPlaceUpdate post-condition. |
| `LLM_NoInProgressOnOldMs` | OK | Cleanup clears the trio before returning to OnOldMS. |

Promoted: 6/6. Acceptance criterion met.

### Other specs (deferred)

Lifecycle.qnt (5991 lines) and Topology.qnt (1446 lines) are
the obvious next targets. Both are large enough that a single
candidate batch fills a ~4 KB context window; a multi-pass
strategy (one batch per state-variable cluster) gives better
coverage and is the natural follow-up to this issue.

The tool is generic — it accepts any `.qnt` file. Future
contributors:

```sh
python3 hack/tools/llm-invariant-discovery.py \
    --write-fixture formal/llm-invariants/Lifecycle.cache.json \
    formal/specs/Lifecycle.qnt
```

writes the API response to disk; subsequent runs without an
API key replay the fixture deterministically. Adding fresh
candidates to the corpus is a one-PR loop:

  1. Run the tool live; capture the fixture.
  2. Verify each candidate via the protocol above.
  3. Promote survivors; document drops.

## Reproducibility

The fixtures committed to `formal/llm-invariants/` represent
the candidate sets that produced the verdicts in this document.
An LLM call may produce different candidates on a new run —
that's expected. The tool's `--fixture` mode pins the candidate
set so subsequent verifications are reproducible.
