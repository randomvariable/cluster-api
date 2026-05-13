# Probabilistic model checking — methodology (issue #29)

`formal/probabilistic/` holds PRISM models for the tail-risk dimension
of selected FMs. The Apalache and TLC verdicts in the rest of the
corpus answer *whether* a bad state is reachable; PRISM answers *how
likely* it is to be reached within a given time budget, given a
parameterised fault model.

## Scope

We model the following FMs as PRISM DTMCs / CTMCs:

| FM | File | Question answered |
| -- | ---- | ----------------- |
| FM-2 | `probabilistic/fm2-quorum-loss.prism` + `.props` | Probability the etcd cluster loses quorum within H steps, given per-node fault rate `p_fault` and recovery rate `p_recover`. |
| FM-23 | `probabilistic/fm23-drain-blocked.prism` + `.props` | Probability that drain force-deletes (PDB violation persists past the drain timeout). |
| FM-13 | (planned) | Probability that the apiserver LB heals within H steps given a Poisson LB-fault model. |
| FM-9 | (planned) | Probability of convergence within H steps under a tail-latency distribution. |

## Running

PRISM is required (not bundled in this repo). Install per
[prismmodelchecker.org](https://www.prismmodelchecker.org/) and add
`prism` to `PATH`. Then:

```
make verify-probabilistic
```

The Make target skips cleanly when PRISM is absent and prints the
expected output sketch from this doc.

## Methodology

1. **Identify the random variables.** Per-node fault rate, recovery
   rate, drain timeout horizon. These are the "rate parameters" the
   issue body asks for.
2. **Discretise time** as fixed-resolution DTMC ticks. A tick is
   roughly the controller's reconcile interval (~30 s for KCP). The
   horizon in the property files is in ticks.
3. **Parameterise.** Each property re-runs across a grid of
   `p_fault ∈ {0.001, 0.01, 0.05, 0.1}` and `p_recover ∈ {0.1, 0.5,
   0.9}`. PRISM's `--experiments` (or `-const`) sweeps the grid.
4. **Record the matrix** in `formal/probabilistic-results.md` (one
   row per (FM, p_fault, p_recover) tuple, columns for each
   property's verdict).
5. **Pull actionable findings.** If
   `P=? [ F<=horizon quorum_lost ] > 0.05` at a typical
   `p_fault=0.01, p_recover=0.5`, that's a tail-risk reading we want
   to surface in the KCP SLO documentation.

## Property syntax cheatsheet (PRISM PCTL)

- `P=? [ F<=H phi ]` — probability of `phi` becoming true within H
  steps (path-existential, time-bounded).
- `P=? [ F phi ]` — probability of `phi` ever holding.
- `P=? [ G<=H phi ]` — probability of `phi` always holding within H
  steps.
- `R{"reward"}=? [ F phi ]` — expected reward accumulated until
  `phi`.
- `P=? [ G phi ]` — probability of `phi` always holding (steady-state-like).

## Cross-references

- `formal/failure-modes.md` for the FM-2 / FM-9 / FM-13 / FM-23
  semantic descriptions; the PRISM models target a strict subset of
  what those FMs describe (probability of bad reachability), not the
  full semantic description.
- `formal/specs/Lifecycle.qnt` for the qualitative ("reachable / not
  reachable") model — the PRISM models below are the quantitative
  shadow.
- `formal/race-detection.md` for the orthogonal axis: probabilistic
  reachability says nothing about goroutine-level races, which the
  race-detection methodology covers.

## Limitations

- PRISM models are coarse — they collapse multi-machine state into
  per-node booleans. The Quint/TLA+ models keep the full per-machine
  state. We trade fidelity for compositional reasoning about fault
  rates.
- The rate parameters are notional. Real production rates depend on
  the workload and the hosting environment. The exercise quantifies
  the *shape* of the tail risk, not the precise probability.
- PRISM does not scale to the full Lifecycle.qnt state space. The
  models here are abstract sub-models, hand-mapped to the relevant
  failure shape.
