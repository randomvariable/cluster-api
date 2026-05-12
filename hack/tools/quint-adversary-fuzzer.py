#!/usr/bin/env python3

"""Seeded adversarial fuzzing harness for Quint composed specs.

Runs `quint run` repeatedly with deterministic seeds so a composed spec
that imports `formal/specs/Adversary.qnt` can be stress-tested under many
fault schedules. The harness reports seeds that reach a counterexample
for the requested invariant.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def run_once(spec: Path, main: str, invariant: str, seed: int, max_samples: int, max_steps: int, timeout: int) -> tuple[bool, str]:
    cmd = [
        "quint", "run",
        "--backend=typescript",
        f"--main={main}",
        f"--invariant={invariant}",
        f"--seed={seed}",
        f"--max-samples={max_samples}",
        f"--max-steps={max_steps}",
        str(spec),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    out = (r.stdout or "") + (r.stderr or "")
    if "[ok] No violation found" in out:
        return True, "[ok]"
    if "[violation]" in out or "Invariant violated" in out:
        return False, "[violation]"
    return False, out[-200:].strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("spec", type=Path)
    ap.add_argument("--main", required=True)
    ap.add_argument("--invariant", required=True)
    ap.add_argument("--seeds", type=int, default=50)
    ap.add_argument("--seed-start", type=int, default=1)
    ap.add_argument("--max-samples", type=int, default=200)
    ap.add_argument("--max-steps", type=int, default=30)
    ap.add_argument("--timeout", type=int, default=60)
    args = ap.parse_args()

    print(f"=== adversary fuzz {args.spec.name} :: {args.invariant} ===")
    failures = []
    for seed in range(args.seed_start, args.seed_start + args.seeds):
        ok, msg = run_once(args.spec, args.main, args.invariant, seed, args.max_samples, args.max_steps, args.timeout)
        if ok:
            print(f"  ok      seed={seed} {msg}")
            continue
        failures.append((seed, msg))
        print(f"  failure seed={seed} {msg}")

    print()
    print(f"seeds checked: {args.seeds}")
    print(f"counterexample seeds: {len(failures)}")
    if failures:
        for seed, msg in failures[:20]:
            print(f"  seed={seed} {msg}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
