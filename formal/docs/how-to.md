# How-to guides

Goal-oriented recipes. Each section answers "I want to <X>; how
do I do it?". For background see [`explanation.md`](./explanation.md);
for the exhaustive list of state vars / actions / make targets
see [`reference.md`](./reference.md).

## Verify a single FM

```sh
cd formal
make verify-fm<N>             # e.g. verify-fm2, verify-fm17, verify-fm23
```

Per-FM `make` targets exist for FM-1, FM-2, FM-3, FM-13, FM-16,
FM-17, FM-23, FM-33, plus IC-11, the FM-9 fairness pair, and the
two self-hosted traces. Aggregate domain targets cover the
remaining FMs:

```sh
make verify-topology       # FM-39/40/41
make verify-inplace        # FM-42/43/44
make verify-cr             # FM-45/46/47
make verify-e2e            # FM-48/49/50
make verify-refinements    # 3 refinement modules
```

`make help` lists every target. For FMs without a dedicated
target, use the `quint verify` invocation template in
[`reference.md` §Per-FM commands](./reference.md#per-fm-commands)
substituting the right `--init` and `--main`.

## Pick the right spec for a new failure mode

Before adding an action, identify the controller domain:

| Domain | Spec | When to use |
|---|---|---|
| KCP membership / etcd / kubeadm-join / MHC | `Lifecycle.qnt` | Anything touching CP machine creation, etcd quorum, drain, MHC remediation |
| ClusterTopology + runtime hooks | `Topology.qnt` | Lifecycle hooks (BeforeClusterCreate, BeforeClusterUpgrade, AfterClusterUpgrade, etc.); ClusterClass; managed-topology controller behaviour |
| Worker MachineSet preflight | `MachineSetPreflight.qnt` | Worker MS preflight gating (control-plane stable, version skew) |
| In-place machine updates | `InPlaceUpdate.qnt` | The CanUpdateMachine / CanUpdateMachineSet / UpdateMachine hook flow + per-Machine in-place transitions |
| controller-runtime substrate | `ControllerRuntime.qnt` | Workqueue dedup, leader election, cache-vs-APIReader, RequeueAfter, multi-worker semantics |
| End-to-end ordering | `ClusterE2E.qnt` | Cross-controller invariants (e.g. KCP-must-not-create-CP-before-InfraReady) |

If the FM crosses two domains, it probably belongs in
`ClusterE2E.qnt` (or a new refinement module).

## Add a new failure mode

1. **Define the init action** in the right spec module (see
   table above). Use existing inits as templates.
2. **Add an entry in `formal/failure-modes.md`** with:
   trigger, recovery, classification (TRANSIENT / EXOGENOUS /
   KCP-BUG / MODELLING / MODEL-INCOMPLETE), TLC verdict, and
   LSP grounding (file:line citations recovered via gopls).
3. **Add an issue-corpus row in `formal/issue-corpus.md`** if
   there's a corresponding upstream gap.
4. **Run `quint typecheck`**:
   ```sh
   make typecheck
   ```
5. **Verify reachability under `step`** (recovery enabled):
   ```sh
   quint verify --main=<Module> --init=<your-init> --step=step \
                --max-steps=8 --backend=tlc \
                --invariant='not(SomeReachableState)' \
                formal/specs/<Module>.qnt
   ```
6. **Verify hopelessness under `stepNoRecovery`** (Apalache,
   when applicable):
   ```sh
   echo y | quint verify --main=<Module> --init=<your-init> \
                          --step=stepNoRecovery --max-steps=4 \
                          --backend=apalache \
                          --invariant='not(SomeReachableState)' \
                          formal/specs/<Module>.qnt
   ```
7. **Add abstraction-mapping rows** in
   `formal/abstraction-mapping.md` for every new action. The CI
   gate (`scripts/verify-formal.sh`) refuses changes with
   unmapped actions.
8. **Add a `make verify-fm<N>` target** in `formal/Makefile`.

## Add a new state variable

1. **Declare the var** in the State section of the right spec
   module, near the other vars. Add a docstring including the
   LSP anchor (a Go file:line — use `mcp__gopls__go_search`).
2. **Bind the var in every `*Init` action**. Quint requires
   every state variable have a primed binding in every action.
3. **Add identity bindings (`var' = var`) to every action that
   doesn't change the var**.
4. **For `Lifecycle.qnt` only**: update the `allVars` tuple
   (used by `ConvergenceFair` / `ConvergenceRecurrentFair`)
   and the fairness generator at
   `hack/tools/quint-fairness-gen.py` (the `ALL_VARS` list).
5. **Run `quint typecheck`** — Quint will tell you which
   actions miss the new binding.

## Refactor an action signature

Adding a new parameter to an existing action requires updating
every caller (existing runs, scenario inits that fire it
deterministically). Use:

```sh
grep -rn '<ActionName>(' formal/specs/
```

## Rerun the fairness generator (Lifecycle.qnt only)

```sh
cd formal
make fairness-gen
# Generated /tmp/fairness-snippet.qnt — paste into
# Lifecycle.qnt's ConvergenceFair body.
```

The generator reads its action catalogue from
`hack/tools/quint-fairness-gen.py`'s `STRONG` / `WEAK` lists.
To classify a new action, edit those lists and rerun.

## Re-bind a stale Go LSP anchor

If a referenced Go function moved or renamed:

1. **Find the new line/symbol** with
   `mcp__gopls__go_search '<symbol>'` (or
   `git log -G <symbol> -- '*.go'` if working without LSP).
2. **Update the row** in `formal/abstraction-mapping.md` and
   any matching row in `formal/lsp-grounding.md`.
3. **Run `make lsp-list`** to print every cited Go anchor for
   cross-referencing.

## Run the full Apalache battery

```sh
cd formal
make verify-all-apalache       # FM-2, 3, 13, 16, 17, 23 — ~10 minutes total
```

Add `JAVA_OPTS='-Xmx16g'` if Apalache OOMs. Reduce
`MAX_STEPS_APALACHE` if it doesn't terminate.

## Debug a TLC counterexample

When TLC reports `[violation] Found an issue`, it prints the
looping state plus a `Back to state N: <ActionName>` marker. To
trace the prefix:

```sh
quint verify --main=<Module> --init=<init> --step=step \
             --temporal=<property> --backend=tlc \
             --max-steps=<N> --verbosity=4 \
             --out-itf=/tmp/cex.itf.json \
             formal/specs/<Module>.qnt
```

The `out-itf` file is the full trace in Informal Trace Format.
Open it in your editor; `internal/trace/itf.go` parses ITF for
the Go trace runtime, which can replay against a live workload
cluster.

## Add a refinement onto the controller-runtime substrate

If you've written a new abstract spec (say `MyController.qnt`)
and want to verify its safety invariants survive multi-worker
substrate semantics:

1. Create `MyControllerRefined.qnt` with both substrate state
   vars (`queuePos`, `workerOnKey`, `requeueWhileInFlight`,
   `leaderRunnablesStarted`, etc.) AND your abstract state vars.
2. Wrap each abstract action's precondition with
   `reconcileInFlightOn(k, workerOnKey, queuePos)` so it can
   only fire while a worker holds the relevant key.
3. Add a `step` relation that combines substrate-only events
   (ProcessNextWorkItem, TimerExpires, ReconcileFinish*) with
   the gated abstract actions.
4. Re-state the abstract invariants and run a 300×40 random
   walk:
   ```sh
   quint run --main=MyControllerRefined --invariant=AllSafetyInvariants \
             --max-samples=300 --max-steps=40 \
             formal/specs/MyControllerRefined.qnt
   ```
5. Add `verify-mycontroller-refined` Make target plus rows in
   `abstraction-mapping.md` and `verify-runbook.md`.

See `TopologyRefined.qnt` / `InPlaceUpdateRefined.qnt` /
`MachineSetPreflightRefined.qnt` for templates.

## Run the FM-2 e2e on a CAPD cluster

The model has one e2e reproducer that passes against a real
CAPD cluster. From the repo root:

```sh
make generate-e2e-templates
GINKGO_FOCUS='FM-2 quorum loss' make test-e2e
```

See `test/e2e/fm2_quorum_loss.go`. The test docker-pauses two
of three CP nodes and `Consistently`-asserts no Machine churn.
Reproduces the exact event line `ControlPlaneUnhealthy: Waiting
for control plane to pass preflight checks` you'll see in
production.

## Bump the verification depth

```sh
make verify-fm17 MAX_STEPS_APALACHE=6
make verify-fm9-fair MAX_STEPS_TLC=12
```

## Tweak the multi-worker substrate scope

The default `WORKERS = 1.to(2)` in `ControllerRuntime.qnt` and
the refinement modules. To collapse to single-worker (faster
TLC sweeps) or expand to higher concurrency, edit `WORKERS` in
the spec module. The state space grows as `O(W^K)` where K is
the number of keys — keeping `WORKERS = 1.to(N)` and `KEYS` to
`{1, 2}` is the practical sweet spot.
