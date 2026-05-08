# Tutorial — Reproduce the FM-2 hopelessness verdict end-to-end

This tutorial walks a first-time reviewer from a fresh checkout to a
TLC verdict on FM-2 (the two-machine quorum-loss failure mode). You
will learn enough about the corpus to navigate the rest of the docs.

The tutorial assumes Linux or macOS, ~5 minutes, and admin rights to
install npm/Java if absent.

## What you need

| Tool | Why | Install hint |
|---|---|---|
| `quint` | Quint type-checker and runner | `npm install -g @informalsystems/quint` |
| `tlc` | Apalache uses TLC's TLA+ as a lingua franca | included with the Apalache distro |
| `apalache` | SMT-based bounded model checker | `npm install -g @informalsystems/quint` pulls it; or `https://github.com/informalsystems/apalache/releases` |
| `make` | drives the targets in `formal/Makefile` | usually pre-installed |

If you don't yet have any of these, run `cd formal && make help` to
see which targets will skip cleanly versus require a tool.

## Step 1 — list the targets

From the repository root:

```sh
cd formal
make help
```

You'll see grouped sections: **sanity**, **failure-modes**,
**fairness**, **self-hosted**, **meta**.

## Step 2 — sanity check

Run the four sanity gates:

```sh
make verify
```

This runs `quint typecheck`, `quint run`, `tlc`, `lake build` (Lean 4
proofs), and the abstraction-mapping drift check. Each step prints
`OK` or `SKIP` (if the underlying tool isn't installed). End-state:
"All formal-subtree checks passed."

If you see `SKIP: quint not in PATH`, install Quint first. The
typecheck step is the load-bearing one.

## Step 3 — verify FM-2

FM-2 is the canonical case where Apalache *proves* `HealthyControlPlane`
is unreachable without operator intervention. Run:

```sh
make verify-fm2
```

This invokes Apalache via Quint's `verify` driver. Apalache's
preprocessing prompts for permission ("temporal property support is
experimental"); the Make target answers `y` automatically.

Expected output (truncated):

```
PASS #0: SanyParser
PASS #1: TypeCheckerSnowcat
…
The outcome is: NoError
[ok] No violation found (≈80 s)
```

`[ok] No violation found` against the invariant `not(HealthyControlPlane)`
under `--step=stepNoRecovery` is the proof: there is no path of length
≤ 4 from `twoMachineBothUnhealthyInit` to `HealthyControlPlane`
without invoking a recovery action. Recovery requires
`HealEtcdReachability` (the operator restores etcd).

## Step 4 — read the surrounding context

You've just verified one failure mode. The corpus has:

- 24 catalogued failure modes (FM-1..FM-24) plus 4 from upstream-
  issue research (FM-31, 32, 34, 37) — see
  [`failure-modes.md`](../failure-modes.md).
- 15 issue-corpus rows (IC-01..IC-15) — see [`issue-corpus.md`](../issue-corpus.md).
- 70+ Quint actions, 47 LSP-grounded against upstream Go code
  (kube-apiserver / kubelet / kubeadm / containerd-CRI / etcd / KCP /
  Machine controller) — see [`abstraction-mapping.md`](../abstraction-mapping.md).
- 5 Apalache hopelessness proofs (FM-2, 3, 13, 16, 17) plus FM-23's
  safety-invariant verdict.
- 1 e2e CAPD reproducer (FM-2; passes against a real CAPD cluster) —
  `test/e2e/fm2_quorum_loss.go`.

## Step 5 — what to read next

- **You want to add a new failure mode.** → [`how-to.md` §Add a new
  FM](./how-to.md#add-a-new-failure-mode).
- **You're reviewing the formal model.** → [`explanation.md`](./explanation.md)
  for design rationale, then [`reference.md`](./reference.md) for the
  exhaustive listing.
- **You want to wire your own controller into the model.** → [`reference.md`
  §Contract obligations](./reference.md#contract-obligations).
- **You're an LLM agent driving the corpus.** → [`AGENTS.md`](./AGENTS.md).

## Troubleshooting

- **`SKIP: quint not in PATH`** — `npm install -g @informalsystems/quint`.
- **Apalache prompt loops** — the Make target is supposed to pipe `y`;
  if your `make` quotes `echo y |` differently, run the underlying
  command in [`reference.md` §Per-FM commands](./reference.md#per-fm-commands)
  manually.
- **Out of memory / TLC heap exhaustion** — bump TLC's heap with
  `JAVA_OPTS='-Xmx16g'` or reduce `MAX_STEPS_TLC` in the Make
  invocation: `make verify-fm9-fair MAX_STEPS_TLC=4`.
