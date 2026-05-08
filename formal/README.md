# Cluster API formal corpus

This subtree is a layered formal-modelling corpus for Cluster API.
It pairs Quint specifications with TLC / Apalache verification,
LSP-grounded refinement anchors into the Go controllers, RFC-2119
contracts pinned to upstream commits, Lean 4 deductive proofs for
properties beyond the model checkers' reach, and a working CAPD
e2e reproducer for the canonical scenario shape.

The corpus is normative for *what should happen*; the Go
controllers under `controlplane/kubeadm/`, `internal/controllers/`,
and `exp/topology/` are normative for *what does happen*.
Divergence between the two is resolved by the discipline
documented in [`abstraction-mapping.md`](./abstraction-mapping.md).

## Scope

The corpus is layered around Cluster API's controller architecture:

```text
                         ┌────────────────────────────────────┐
       Layer 3 (E2E)     │ ClusterE2E.qnt                     │
                         │   bring-up + topology + upgrade    │
                         └────────────────────────────────────┘
                                          ▲
                                          │ uses
                         ┌────────────────────────────────────┐
       Layer 2 (refine)  │ TopologyRefined / InPlaceRefined   │
                         │   / MachineSetPreflightRefined     │
                         └────────────────────────────────────┘
                                          ▲
                                          │ refines onto
                         ┌────────────────────────────────────┐
       Layer 0 (subtr.)  │ ControllerRuntime.qnt              │
                         │   workqueue + worker pool + leader │
                         │   election + cache vs APIReader    │
                         └────────────────────────────────────┘
                                          ▲
                                          │ underpins
   Layer 1 (per-component abstract specs):
   ┌──────────────────┬──────────────────┬──────────────────┬──────────────────┐
   │ Lifecycle.qnt    │ Topology.qnt     │ MachineSet…      │ InPlaceUpdate    │
   │ (KCP + etcd +    │ (ClusterClass +  │ Preflight.qnt    │ .qnt             │
   │  kubeadm-join +  │  runtime hooks)  │ (worker MS gate) │ (machine in-     │
   │  MHC)            │                  │                  │  place updates)  │
   └──────────────────┴──────────────────┴──────────────────┴──────────────────┘
```

This corpus models all four major CAPI controller domains plus
the controller-runtime substrate they share. Every Quint action
is anchored to a Go entry point in
[`abstraction-mapping.md`](./abstraction-mapping.md); the CI gate
in [`scripts/verify-formal.sh`](../scripts/verify-formal.sh)
refuses changes where any anchor breaks.

The full motivation, scope, and architecture are in
[`docs/proposals/20260507-formal-control-plane-lifecycle-model.md`](../docs/proposals/20260507-formal-control-plane-lifecycle-model.md)
(written when the corpus was KCP-only; the present scope is
broader). Read that for the original framing, then
[`overview.md`](./overview.md) for the current reading order.

## Layout

```text
formal/
├── README.md                ← you are here
├── Makefile                 ← quint / tlc / lean / verify targets
├── overview.md              ← reading order
├── failure-modes.md         ← FM-1..FM-50 catalogue
├── test-corpus-spec.md      ← MoSCoW prioritisation
├── verify-runbook.md        ← copy-paste verification commands
├── abstraction-mapping.md   ← every action ↔ Go file:line
├── lsp-grounding.md         ← refinement-anchor methodology
├── counterexample-log.md    ← spec-violation ledger
├── issue-corpus.md          ← model-found issues
├── upstream-issues-research.md ← github issue mining
├── dst-methodology.md       ← fault catalogue → docker primitives
├── e2e-blueprints.md        ← CAPD e2e sketches
├── specs/                   ← Quint + TLA+ source of truth
├── proofs/                  ← Lean 4 lake project
├── contracts/               ← RFC-2119 contracts pinned to upstream commits
└── docs/                    ← Diataxis-style human docs (tutorial / how-to / reference / explanation / AGENTS)
```

## Tooling

The formal artefacts are written in three permissively-licensed
tools. None is required to build CAPI or run its tests; the CI
verification gate (`scripts/verify-formal.sh`) reports `SKIP`
rather than failing when a tool is absent.

| Tool | Version | Source | Purpose |
|---|---|---|---|
| [Quint](https://quint-lang.org) | 0.32+ | <https://github.com/informalsystems/quint> (Apache 2.0) | Core state machines |
| [TLA+ Toolbox / TLC](https://lamport.azurewebsites.net/tla/tla.html) | TLC 2.18+ | <https://github.com/tlaplus/tlaplus> (MIT) | Scheduler-shaped specs |
| [Apalache](https://apalache.informal.systems) | latest | <https://github.com/informalsystems/apalache> (Apache 2.0) | Symbolic hopelessness proofs (via Quint) |
| [Lean 4 + Lake](https://leanprover.github.io) | v4.16.0 | <https://github.com/leanprover/lean4> (Apache 2.0) | Deductive proofs (FM-9 fairness recurrence) |
| [gopls (MCP)](https://github.com/golang/tools/tree/master/gopls) | latest | included with Go | LSP-grounded refinement anchors |

Install hints:

```sh
# Quint via npm (pulls Apalache too)
npm install -g @informalsystems/quint

# Lean via elan
curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh

# TLC: download the latest release JAR from the tlaplus/tlaplus releases page
```

## Day-to-day commands

```sh
make -C formal typecheck   # quint typecheck on every spec
make -C formal test        # quint run on every module that defines runs
make -C formal proofs      # lake build in formal/proofs/
make -C formal verify      # everything above + abstraction-mapping drift check
```

Layer-specific aggregates (also in `make help`):

```sh
make -C formal verify-cr            # controller-runtime substrate suite
make -C formal verify-refinements   # 3 refinement modules
make -C formal verify-topology      # ClusterTopology + runtime hooks
make -C formal verify-inplace       # in-place machine updates
make -C formal verify-fm33          # MachineSet preflight (FM-33)
make -C formal verify-e2e           # end-to-end cluster lifecycle
```

## Conventions

- Every spec module's first comment block names its purpose, the
  Go entry points it refines (with file:line LSP anchors), and a
  one-paragraph English description of the modelled behaviour.
- Every action's name is `PascalCase`; every state variable is
  `camelCase`; every invariant or temporal property is
  `PascalCase`. This matches Quint and the TLA+ community style.
- Quint module names match their filename: `EtcdMembership.qnt`
  declares `module EtcdMembership`. Refinement modules are
  named `<Abstract>Refined.qnt`.
- New cross-spec composition lives in a dedicated file (e.g.
  `Composition.qnt` for KCP+MHC+Etcd, `ClusterE2E.qnt` for the
  full lifecycle), not embedded inside per-component specs.

## When you change a controller

1. If the change touches a modelled Go entry point (anything
   referenced from `abstraction-mapping.md`), update the row in
   the same commit. Stale rows fail the CI gate.
2. If the change adds new behaviour the model does not capture,
   either:
   - Add the action to the relevant Quint module, with an
     abstraction-mapping row pointing at the new entry point; or
   - Document in the PR why the behaviour is below the
     abstraction layer (e.g. a logging tweak, a metric label
     rename).
3. Run `make -C formal verify` locally before pushing.

## When the model finds a counterexample

1. Reproduce the counterexample as a regression test — either as
   a Quint `run` or as a Go-side trace fixture under
   `internal/trace/checkers/testdata/`.
2. File a row in [`counterexample-log.md`](./counterexample-log.md)
   with status `Reproduced-Test-Written`.
3. Fix the spec or the controller; advance the row to
   `Fixed-In-Implementation`.
4. After independent rerun (CI green, or a maintainer's local
   re-run), advance to `Closed-Verified`.

## Branch

The corpus lives on the `formality` branch in the user's fork.
No upstream push, no PR.
