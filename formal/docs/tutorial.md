# Tutorial — Verify a Cluster API cluster end-to-end

This tutorial walks a first-time reviewer from a fresh checkout
through three increasingly broad verifications:

1. The controller-runtime substrate (`make verify-cr`).
2. The end-to-end cluster lifecycle (`make verify-e2e-bringup`).
3. The canonical FM-2 hopelessness verdict (`make verify-fm2`).

After this you'll have run the typecheck gate, watched a worker
pool dispatch, walked through a full cluster bring-up with
topology hooks, and read an Apalache hopelessness proof.

The tutorial assumes Linux or macOS, ~10 minutes, and admin
rights to install npm/Java if absent.

## What you need

| Tool | Why | Install hint |
|---|---|---|
| `quint` | Quint type-checker and runner | `npm install -g @informalsystems/quint` |
| `tlc` | TLC + Apalache use TLA+ as a lingua franca | included with the Apalache distro |
| `apalache` | SMT-based bounded model checker | bundled when installing Quint via npm; or download from <https://github.com/informalsystems/apalache/releases> |
| `make` | drives the targets in `formal/Makefile` | usually pre-installed |

If you don't yet have any of these, run `cd formal && make help`
to see which targets will skip cleanly versus require a tool.

## Step 1 — list the targets

From the repository root:

```sh
cd formal
make help
```

You'll see grouped sections: **sanity**, **failure-modes**,
**fairness**, **self-hosted**, **multicluster**,
**machineset-preflight**, **topology**, **in-place-updates**,
**controller-runtime**, **refinements**, **end-to-end**, **meta**.

## Step 2 — sanity check

Run the four sanity gates:

```sh
make verify
```

This runs `quint typecheck`, `quint run`, `tlc`, `lake build`
(Lean 4 proofs), the Go build/test, and the abstraction-mapping
drift check. End-state: "All formal-subtree checks passed."

If you see `SKIP: quint not in PATH`, install Quint first. The
typecheck step is the load-bearing one.

## Step 3 — verify the controller-runtime substrate

Every CAPI controller is built on `sigs.k8s.io/controller-runtime`.
Run the substrate suite:

```sh
make verify-cr
```

This drives six demonstration runs covering Manager start, leader
acquire, multi-worker dispatch, dedup-during-inflight,
RequeueAfter, TerminalError, and leader loss. Plus a 500×60
random walk over every substrate invariant
(`FM45_PerKeySerialisation`, `FM46_TerminalErrorNoRequeue`,
`FM47_CacheBehindAPI`, leader-election gate).

Expected end-state: every line ends with `[ok] No violation found`.

What you've just verified:
- A given reconcile key is never processed by two workers
  concurrently (FM-45).
- A `reconcile.TerminalError` does NOT trigger requeue (FM-46).
- The cache version never exceeds the API server version (FM-47).

## Step 4 — verify a full cluster bring-up

Now the end-to-end:

```sh
make verify-e2e-bringup
```

This drives `happyBringUpRun` from `ClusterE2E.qnt` — a 36-step
trace covering:

1. Topology fires `BeforeClusterCreate`.
2. InfrastructureCluster controller provisions the LB + endpoint.
3. Cluster controller observes InfraCluster.status, copies
   `controlPlaneEndpoint`, sets
   `cluster.Status.Initialization.InfrastructureProvisioned=true`.
4. KCP creates the first CP Machine (gated on the previous step).
5. Per-Machine bootstrap config + InfraMachine provisioning;
   kubelet registers the Node; CP Machine joins etcd; KCP marks
   it ready.
6. KCP scales to 3 CP Machines via `scaleUpControlPlane`.
7. KCP marks `ControlPlaneInitialized`; Cluster controller
   propagates; Topology fires `AfterControlPlaneInitialized`;
   MachineDeployment is enabled.
8. MD creates worker Machines (same provision chain).

Every action is LSP-grounded against
`internal/controllers/cluster/cluster_controller_phases.go`,
`controlplane/kubeadm/internal/controllers/scale.go`,
`internal/controllers/topology/cluster/`, etc. — see
[`abstraction-mapping.md`](../abstraction-mapping.md) §ClusterE2E.

Expected: `[ok] No violation found` for `AllSafetyInvariants`,
which includes FM-48 (no CP before InfraReady), FM-49 (no
workers before CPInitialized), FM-50 (endpoint monotonic), plus
seven cross-cutting ordering invariants.

## Step 5 — verify a hopelessness proof

FM-2 is the canonical case where Apalache *proves*
`HealthyControlPlane` is unreachable without operator
intervention. Run:

```sh
make verify-fm2
```

This invokes Apalache via Quint's `verify` driver. Apalache's
preprocessing prompts for permission ("temporal property
support is experimental"); the Make target answers `y`
automatically.

Expected output (truncated):

```
PASS #0: SanyParser
PASS #1: TypeCheckerSnowcat
…
The outcome is: NoError
[ok] No violation found (≈80 s)
```

`[ok] No violation found` against the invariant
`not(HealthyControlPlane)` under `--step=stepNoRecovery` is the
proof: there is no path of length ≤ 4 from
`twoMachineBothUnhealthyInit` to `HealthyControlPlane` without
invoking a recovery action. Recovery requires
`HealEtcdReachability` (the operator restores etcd).

## What you've just verified

After three Make invocations:

- **Substrate (Layer 0)** — controller-runtime worker-pool
  dispatch is per-key-serialised; TerminalError suppresses
  requeue; cache lags API server.
- **End-to-end (Layer 3)** — full cluster bring-up respects
  ten cross-cutting ordering invariants.
- **Hopelessness (KCP / Lifecycle.qnt)** — FM-2 quorum loss is
  Apalache-proven unrecoverable without operator intervention.

## Step 6 — what to read next

- **You want to add a new failure mode** — pick the right spec
  domain (KCP, Topology, MachineSet, InPlace, E2E,
  controller-runtime) and follow [`how-to.md` §Add a new
  FM](./how-to.md#add-a-new-failure-mode).
- **You're reviewing the corpus design** — start with
  [`explanation.md`](./explanation.md) for design rationale,
  then [`reference.md`](./reference.md) for the exhaustive
  listing.
- **You want to wire your own controller into the model** —
  [`reference.md` §Contract obligations](./reference.md#contract-obligations).
- **You're an LLM agent driving the corpus** —
  [`AGENTS.md`](./AGENTS.md).

## Per-domain quick verification

Each Layer-1 spec has its own aggregate target. Pick one:

```sh
make verify-topology       # ClusterTopology + runtime extensions (FM-39/40/41)
make verify-inplace        # in-place machine updates (FM-42/43/44)
make verify-fm33           # MachineSet preflight (FM-33)
make verify-refinements    # 3 refined modules onto controller-runtime
```

Each runs deterministic demos plus random walks. Total wall
time for all of the above is ~10 minutes on a modern laptop.

## Troubleshooting

- **`SKIP: quint not in PATH`** — `npm install -g @informalsystems/quint`.
- **Apalache prompt loops** — the Make target is supposed to
  pipe `y`; if your `make` quotes `echo y |` differently, run
  the underlying command in
  [`reference.md` §Per-FM commands](./reference.md#per-fm-commands)
  manually.
- **Out of memory / TLC heap exhaustion** — bump TLC's heap with
  `JAVA_OPTS='-Xmx16g'` or reduce `MAX_STEPS_TLC` in the Make
  invocation: `make verify-fm9-fair MAX_STEPS_TLC=4`.
- **A demo run fails with `[error] Runtime error`** — check that
  the run name in the Make target matches one declared in the
  spec; spec evolution may rename runs.
