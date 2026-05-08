# Formal model of the Cluster API control-plane lifecycle

This subtree contains executable specifications and proofs for the
Kubeadm-Control-Plane-managed lifecycle of a Kubernetes cluster.
It is normative for *what should happen*; the Go controllers under
`controlplane/kubeadm/` are normative for *what does happen*.
Divergence between the two is resolved by the discipline documented
in [`abstraction-mapping.md`](./abstraction-mapping.md).

The full motivation, scope, and architecture are in
[`docs/proposals/20260507-formal-control-plane-lifecycle-model.md`](../docs/proposals/20260507-formal-control-plane-lifecycle-model.md).
Read that first.

## Layout

```text
formal/
├── README.md                ← you are here
├── Makefile                 ← quint / tlc / lean / verify targets
├── specs/                   ← Quint + TLA+ source of truth
├── proofs/                  ← Lean 4 lake project
├── contracts/               ← RFC-2119 contracts pinned to upstream commits
├── abstraction-mapping.md   ← Action ↔ Go file:line
└── counterexample-log.md    ← incident ledger
```

## Tooling

The formal artefacts are written in three public-domain or
permissively-licensed tools. None is required to build CAPI or run
its tests; the CI verification gate (`scripts/verify-formal.sh`)
reports `SKIP` rather than failing when a tool is absent.

| Tool | Version | Source | Purpose |
|---|---|---|---|
| [Quint](https://quint-lang.org) | v0.22+ | <https://github.com/informalsystems/quint> (Apache 2.0) | Core state machines |
| [TLA+ Toolbox / TLC](https://lamport.azurewebsites.net/tla/tla.html) | TLC 2.18+ | <https://github.com/tlaplus/tlaplus> (MIT) | Scheduler-shaped specs |
| [Lean 4 + Lake](https://leanprover.github.io) | v4.16.0 | <https://github.com/leanprover/lean4> (Apache 2.0) | Refinement proofs |

Install hints:

```sh
# Quint via npm
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

## Conventions

- Every spec module's first comment block names its purpose, the Go
  entry point it refines (when there is a single canonical one),
  and a one-paragraph English description of the modelled
  behaviour.
- Every action's name is `PascalCase`; every state variable is
  `camelCase`; every invariant or temporal property is
  `PascalCase`. This matches Quint and the TLA+ community style.
- Quint module names match their filename: `EtcdMembership.qnt`
  declares `module EtcdMembership`.
- Cross-spec composition lives in `Composition.qnt`. New
  composition obligations go there, not in the per-module specs.

## When you change a controller

1. If the change touches a modelled Go entry point (anything
   referenced from `abstraction-mapping.md`), update the
   row in the same commit. Stale rows fail the CI gate.
2. If the change adds new behaviour the model does not capture,
   either:
   - Add the action to the relevant Quint module, with an
     abstraction-mapping row pointing at the new entry point; or
   - Document in the PR why the behaviour is below the
     abstraction layer (e.g. a logging tweak, a metric label
     rename).
3. Run `make -C formal verify` locally before pushing.

## When the model finds a counterexample

1. Reproduce the counterexample as a regression test —
   either as a Quint `run` or as a Go-side trace fixture under
   `internal/trace/checkers/testdata/`.
2. File a row in [`counterexample-log.md`](./counterexample-log.md)
   with status `Reproduced-Test-Written`.
3. Fix the spec or the controller; advance the row to
   `Fixed-In-Implementation`.
4. After independent rerun (CI green, or a maintainer's local
   re-run), advance to `Closed-Verified`.
