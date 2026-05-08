# How-to guides

Goal-oriented recipes. Each section answers "I want to <X>; how do I
do it?". For background see [`explanation.md`](./explanation.md); for
the exhaustive list of state vars / actions / make targets see
[`reference.md`](./reference.md).

## Verify a single FM

```sh
cd formal
make verify-fm<N>             # e.g. verify-fm2, verify-fm17, verify-fm23
```

Per-FM `make` targets exist for FM-1, FM-2, FM-3, FM-13, FM-16,
FM-17, FM-23, plus IC-11, the FM-9 fairness pair, and the two
self-hosted traces. `make help` lists them.

For FMs without a dedicated target (FM-11, FM-14, FM-15, FM-18..22,
FM-24, FM-31, FM-32, FM-34, FM-37), use the `quint verify` invocation
template in [`reference.md` §Per-FM commands](./reference.md#per-fm-commands)
substituting the right `--init`.

## Add a new failure mode

1. **Define the init action** in `formal/specs/Lifecycle.qnt`. Use
   one of the existing inits as a template (e.g. `incidentInit` for a
   Machine-level fault, `lbBrokenInit` for a network fault). Bind
   every state variable — Quint requires it.
2. **Add an entry in `formal/failure-modes.md`** with: trigger,
   recovery, classification (TRANSIENT / EXOGENOUS / KCP-BUG /
   MODEL-INCOMPLETE), TLC verdict.
3. **Add an issue-corpus row in `formal/issue-corpus.md`** if there's
   a corresponding upstream gap.
4. **Run `quint typecheck`**:
   ```sh
   make typecheck
   ```
5. **Verify reachability under `step`** (recovery enabled):
   ```sh
   quint verify --main=Lifecycle --init=<your-init> --step=step \
                --max-steps=8 --backend=tlc \
                --invariant='not(HealthyControlPlane)' \
                formal/specs/Lifecycle.qnt
   # Expected: [violation] (HealthyControlPlane reached).
   ```
6. **Verify hopelessness under `stepNoRecovery`** (Apalache):
   ```sh
   echo y | quint verify --main=Lifecycle --init=<your-init> \
                          --step=stepNoRecovery --max-steps=4 \
                          --backend=apalache \
                          --invariant='not(HealthyControlPlane)' \
                          formal/specs/Lifecycle.qnt
   # Expected: [ok] No violation found (FM is EXOGENOUS or KCP-BUG-latent).
   ```
7. **Add abstraction-mapping rows** in `formal/abstraction-mapping.md`
   for any new actions. The CI gate (`scripts/verify-formal.sh`)
   refuses to merge changes with unmapped actions.
8. **Add a `make verify-fm<N>` target** in `formal/Makefile`.

## Add a new state variable

1. **Declare the var** in the State section of `Lifecycle.qnt`, near
   the other vars. Add a docstring including the LSP anchor (a Go
   line in `kube-apiserver`, `kubelet`, `kubeadm`, `controlplane/`,
   or `internal/controllers/`).
2. **Bind the var in every `*Init` action** — there are ~24. The
   `hack/tools/extend_*.py` scripts in `/tmp` (auto-generated each
   pass; commit them to `hack/tools/` if you want them durable) show
   how to do this programmatically.
3. **Add identity bindings (`var' = var`) to every action that
   doesn't change the var**. Quint's `all { ... }` requires every
   state variable have a primed binding in every action.
4. **Update the `allVars` tuple** in `Lifecycle.qnt` (used by
   `ConvergenceFair` and `ConvergenceRecurrentFair`).
5. **Update the fairness generator** at
   `hack/tools/quint-fairness-gen.py` (the `ALL_VARS` list).
6. **Run `quint typecheck`** — Quint will tell you which actions miss
   the new binding.

## Refactor an action signature

Adding a new parameter to an existing action requires updating every
caller (existing runs, scenario inits that fire it deterministically).
Use `grep -rn '<ActionName>(' formal/specs/`.

## Rerun the fairness generator

```sh
cd formal
make fairness-gen
# Generated /tmp/fairness-snippet.qnt — paste into Lifecycle.qnt's ConvergenceFair body.
```

The generator reads its action catalogue from
`hack/tools/quint-fairness-gen.py`'s `STRONG` / `WEAK` lists. To
classify a new action, edit those lists and rerun.

## Re-bind a stale Go LSP anchor

If a referenced Go function moved or renamed:

1. **Find the new line/symbol** with `mcp__gopls__go_search '<symbol>'`
   (or `git log -G <symbol> -- '*.go'` if working without LSP).
2. **Update the row** in `formal/abstraction-mapping.md` and any
   matching row in `formal/lsp-grounding.md`.
3. **Run `make lsp-list`** to print every cited Go anchor for cross-
   referencing.

## Run the full Apalache battery

```sh
cd formal
make verify-all-apalache       # FM-2, 3, 13, 16, 17, 23 — ~10 minutes total
```

Add `JAVA_OPTS='-Xmx16g'` if Apalache OOMs. Reduce
`MAX_STEPS_APALACHE` if it doesn't terminate.

## Debug a TLC counterexample

When TLC reports `[violation] Found an issue`, it prints the looping
state plus a `Back to state N: <ActionName>` marker. To trace the
prefix:

```sh
quint verify --main=Lifecycle --init=<init> --step=step \
             --temporal=<property> --backend=tlc \
             --max-steps=<N> --verbosity=4 \
             --out-itf=/tmp/cex.itf.json \
             formal/specs/Lifecycle.qnt
```

The `out-itf` file is the full trace in Informal Trace Format. Open
it in your editor; `internal/trace/itf.go` parses ITF for the Go
trace runtime, which can replay against a live workload cluster.

## Run the FM-2 e2e on a CAPD cluster

The model has one e2e reproducer that passes against a real CAPD
cluster. From the repo root:

```sh
make generate-e2e-templates
GINKGO_FOCUS='FM-2 quorum loss' make test-e2e
```

See `test/e2e/fm2_quorum_loss.go`. The test docker-pauses two of
three CP nodes and `Consistently`-asserts no Machine churn. Reproduces
the exact event line `ControlPlaneUnhealthy: Waiting for control
plane to pass preflight checks` you'll see in production.

## Bump the verification depth

```sh
make verify-fm17 MAX_STEPS_APALACHE=6
make verify-fm9-fair MAX_STEPS_TLC=12
```

Apalache scales roughly cubically in depth; bumping from 4 to 6 may
take 10× longer. TLC's tableau construction may overflow on the
65-conjunct ConvergenceFair at higher depths — see
[`explanation.md` §Phase 11c](./explanation.md#phase-11c-tlc-tautology).
