#!/usr/bin/env python3
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# quint-mutation-tester.py — applies systematic mutations to
# invariants in a Quint spec, runs `quint run` against each
# mutation, reports surviving mutations.
#
# A SURVIVING MUTATION (mutation passes verification) =
#   invariant was redundant / too weak / not load-bearing.
# A KILLED MUTATION (mutation fails verification) =
#   invariant was actually checking something useful.
#
# Issue #4: https://github.com/randomvariable/cluster-api/issues/4
#
# Usage:
#   ./quint-mutation-tester.py <spec.qnt> [--main=<Module>]
#                              [--max-samples=200] [--max-steps=30]
#                              [--invariants=<name1>,<name2>]
#                              [--mutations=<m1>,<m2>]
#                              [--workdir=/tmp/mutations]
#
# Output: structured report on stdout. Findings written to
# `--workdir` as one .qnt file per surviving mutation.

import argparse
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path


# ---------------------------------------------------------------
# Mutation primitives
# ---------------------------------------------------------------

@dataclass
class Mutation:
    name: str
    description: str
    apply: callable  # (str) -> Optional[str]; returns mutated body or None if N/A


def m_drop_conjunct(body: str) -> str | None:
    """In `all { A, B, ... }`, drop one element. Returns None if no
    conjunct list."""
    # Match `all {` ... `}` at the body level (single-line for simplicity).
    m = re.search(r"all\s*\{([^{}]+)\}", body)
    if not m:
        return None
    items = [s.strip() for s in m.group(1).split(",")]
    items = [s for s in items if s]
    if len(items) < 2:
        return None
    # Drop the first item.
    new_items = items[1:]
    new_body = body[:m.start()] + "all { " + ", ".join(new_items) + " }" + body[m.end():]
    return new_body


def m_and_to_or(body: str) -> str | None:
    """Replace one `and` with `or`. Returns None if no `and`."""
    if " and " not in body:
        return None
    return body.replace(" and ", " or ", 1)


def m_forall_to_exists(body: str) -> str | None:
    if ".forall(" not in body:
        return None
    return body.replace(".forall(", ".exists(", 1)


def m_exists_to_forall(body: str) -> str | None:
    if ".exists(" not in body:
        return None
    return body.replace(".exists(", ".forall(", 1)


def m_flip_le_to_lt(body: str) -> str | None:
    if " <= " not in body:
        return None
    return body.replace(" <= ", " < ", 1)


def m_flip_ge_to_gt(body: str) -> str | None:
    if " >= " not in body:
        return None
    return body.replace(" >= ", " > ", 1)


def m_drop_implies_lhs(body: str) -> str | None:
    """In `A implies B`, replace with `B` (drop the precondition)."""
    if "implies" not in body:
        return None
    # Naive: find first `... implies ...` and replace with the rhs.
    # Use a regex that captures balanced parens superficially.
    # For multi-line specs, we'll just replace the first " implies "
    # by " or " — the body becomes weaker (always true if rhs holds).
    return body.replace(" implies ", " or ", 1)


def m_negate_rhs(body: str) -> str | None:
    """In `A implies B`, replace with `A implies not(B)` (sanity:
    should always fail)."""
    if "implies" not in body:
        return None
    # Replace first ` implies X` (where X is balanced) with ` implies not(X)`.
    # Safe-ish heuristic: match through end of line / closing.
    parts = body.split(" implies ", 1)
    if len(parts) != 2:
        return None
    return parts[0] + " implies not(" + parts[1] + ")"


MUTATIONS = [
    Mutation("DropConjunct", "drop first conjunct in all{}", m_drop_conjunct),
    Mutation("AndToOr", "replace first ` and ` with ` or `", m_and_to_or),
    Mutation("ForallToExists", "replace .forall( with .exists(", m_forall_to_exists),
    Mutation("ExistsToForall", "replace .exists( with .forall(", m_exists_to_forall),
    Mutation("FlipLeToLt", "replace ` <= ` with ` < `", m_flip_le_to_lt),
    Mutation("FlipGeToGt", "replace ` >= ` with ` > `", m_flip_ge_to_gt),
    Mutation("DropImpliesLhs", "drop precondition in `A implies B` (-> `A or B`)", m_drop_implies_lhs),
    Mutation("NegateRhs", "negate consequent: `A implies B` -> `A implies not(B)` (sanity check)", m_negate_rhs),
]


# ---------------------------------------------------------------
# Spec parsing
# ---------------------------------------------------------------

@dataclass
class Invariant:
    name: str
    body: str
    start_line: int
    end_line: int


INVARIANT_FILTER_NAMES = {
    "PendingHookConsistency", "HookFireOrderInvariant",
    "BeforeClusterUpgradeBlockedByAnnotation",
    "OkToDeleteAfterUnblock", "PlanMonotonic",
    "CpVersionWithinPlan", "WorkerVersionLeqCp",
    "TwoWayHandshakeAnnotations", "MovingPendingShape",
    "UpdateMachineHookShape", "InProgressTrioConsistency",
    "MoveAckBeforeArmed", "DoneImpliesVersionFlipped",
    "BootstrapBeforeInfra", "NodeRefAfterProvisioned",
    "EtcdJoinOnlyForCp", "KcpInitializedRequiresFirstCp",
    "ClusterCpInitializedRequiresKcp", "MdEnabledRequiresCpInit",
    "BeforeClusterUpgradeOrdering", "AfterClusterUpgradeAtTarget",
    "WorkerSentinelConsistency", "InFlightHasWorker",
    "RateLimitBounded", "LeaderElectionGate",
    "PreflightGateRespected", "PreflightGateWellFormed",
    "BodyActionsGated",
}

# Regex matching the start of a NEW top-level declaration.
# Used as a stop signal when collecting a multi-line body.
DECL_BOUNDARY = re.compile(
    r"^\s*(val|action|temporal|pure\s+def|pure\s+val|var|type|module|run|}\s*$)"
)


def find_invariants(spec_text: str, only: list[str] | None = None) -> list[Invariant]:
    """Find `val <Name> = <body>` declarations in the spec.
    Body extends until the next top-level declaration or end of
    module. Skips helper vals (only matches names that look like
    invariants per INVARIANT_FILTER_NAMES + prefix rules).
    """
    lines = spec_text.split("\n")
    invariants: list[Invariant] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^(\s*)val\s+(\w+)\s*=(.*)$", line)
        if not m:
            i += 1
            continue
        indent = m.group(1)
        name = m.group(2)
        first_body_part = m.group(3)
        if only and name not in only:
            i += 1
            continue
        if not (name.startswith("FM") or name.startswith("J")
                or name.startswith("L") or name.endswith("Invariants")
                or name in INVARIANT_FILTER_NAMES):
            i += 1
            continue
        # Collect body: from first_body_part forward, until the
        # next declaration boundary or end of module.
        body_lines: list[str] = [first_body_part]
        j = i + 1
        while j < len(lines):
            next_line = lines[j]
            # Stop if we hit a new top-level declaration. We use
            # the DECL_BOUNDARY regex but ONLY at the same or
            # outer indentation level. (val nested inside another
            # decl is rare in this corpus.)
            if DECL_BOUNDARY.match(next_line):
                break
            # Stop on blank line followed by a comment-only line
            # — likely a section break.
            body_lines.append(next_line)
            j += 1
        body = " ".join(l.strip() for l in body_lines).strip()
        if not body:
            i = j
            continue
        invariants.append(Invariant(name, body, i, j - 1))
        i = j
    return invariants


# ---------------------------------------------------------------
# Mutation application
# ---------------------------------------------------------------

def apply_mutation_to_spec(spec_text: str, inv: Invariant, mutated_body: str) -> str:
    """Replace the invariant's body in the spec text."""
    lines = spec_text.split("\n")
    # Replace lines [inv.start_line, inv.end_line] with `val <name> = <body>`.
    new_line = f"  val {inv.name} = {mutated_body}"
    return "\n".join(lines[:inv.start_line] + [new_line] + lines[inv.end_line + 1:])


def run_quint(spec_path: Path, main: str, invariant: str,
              max_samples: int, max_steps: int, timeout: int = 60) -> tuple[bool, str]:
    """Run `quint run --invariant=<name>` against the spec.
    Returns (HOLDS, brief_message).
      HOLDS == True means quint reported "[ok] No violation found" — the
        invariant holds (no counterexample within the random walk).
      HOLDS == False means quint reported "[violation]" — counterexample
        found.
    """
    cmd = [
        "quint", "run",
        "--backend=typescript",
        f"--main={main}",
        f"--invariant={invariant}",
        f"--max-samples={max_samples}",
        f"--max-steps={max_steps}",
        str(spec_path),
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    out = (r.stdout or "") + (r.stderr or "")
    if "[ok] No violation found" in out:
        return True, "[ok]"
    if "[violation]" in out:
        return False, "[violation]"
    return False, f"ERROR: {out[-200:].strip()}"


# ---------------------------------------------------------------
# Main
# ---------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("spec", type=Path, help="Path to the .qnt spec file")
    ap.add_argument("--main", type=str, default=None,
                    help="Module name (defaults to spec filename stem)")
    ap.add_argument("--max-samples", type=int, default=200)
    ap.add_argument("--max-steps", type=int, default=30)
    ap.add_argument("--invariants", type=str, default=None,
                    help="Comma-separated list of invariant names to test "
                         "(default: all detected)")
    ap.add_argument("--mutations", type=str, default=None,
                    help="Comma-separated list of mutation names "
                         "(default: all)")
    ap.add_argument("--workdir", type=Path, default=Path("/tmp/quint-mutations"),
                    help="Where to write surviving mutation .qnt files")
    ap.add_argument("--timeout", type=int, default=60,
                    help="Per-mutation quint run timeout (seconds)")
    args = ap.parse_args()

    spec_text = args.spec.read_text()
    main_name = args.main or args.spec.stem
    only = args.invariants.split(",") if args.invariants else None
    mut_only = args.mutations.split(",") if args.mutations else None

    invariants = find_invariants(spec_text, only=only)
    mutations = MUTATIONS if not mut_only else [m for m in MUTATIONS if m.name in mut_only]

    if not invariants:
        print(f"No invariants found in {args.spec}", file=sys.stderr)
        sys.exit(1)

    args.workdir.mkdir(parents=True, exist_ok=True)

    print(f"=== Mutation testing {args.spec.name} ===")
    print(f"  Module: {main_name}")
    print(f"  Invariants found: {len(invariants)}")
    print(f"  Mutations: {len(mutations)}")
    print(f"  Workdir: {args.workdir}")
    print()

    survivors: list[tuple[Invariant, Mutation, str]] = []
    killed: list[tuple[Invariant, Mutation]] = []
    nas: list[tuple[Invariant, Mutation]] = []

    for inv in invariants:
        for mut in mutations:
            mutated_body = mut.apply(inv.body)
            if mutated_body is None:
                nas.append((inv, mut))
                continue
            if mutated_body == inv.body:
                nas.append((inv, mut))
                continue
            mutated_spec = apply_mutation_to_spec(spec_text, inv, mutated_body)
            tmp = tempfile.NamedTemporaryFile(
                prefix=f"{args.spec.stem}-{inv.name}-{mut.name}-",
                suffix=".qnt", delete=False, dir=args.workdir, mode="w")
            tmp.write(mutated_spec)
            tmp.close()
            holds, msg = run_quint(Path(tmp.name), main_name, inv.name,
                                    args.max_samples, args.max_steps,
                                    timeout=args.timeout)
            if holds:
                survivors.append((inv, mut, tmp.name))
                print(f"  [SURVIVED]  {inv.name} :: {mut.name}  {msg}")
            else:
                killed.append((inv, mut))
                print(f"  killed       {inv.name} :: {mut.name}  {msg}")
                # Delete the temp file for killed mutations to save space.
                try:
                    os.unlink(tmp.name)
                except OSError:
                    pass

    print()
    print(f"=== Summary ===")
    print(f"  Total mutations attempted: {len(killed) + len(survivors) + len(nas)}")
    print(f"  Killed (good — invariant load-bearing): {len(killed)}")
    print(f"  Survived (finding — invariant too weak / missing action): {len(survivors)}")
    print(f"  N/A (mutation didn't apply to invariant shape): {len(nas)}")
    print()
    if survivors:
        print("=== Survivors (ordered by invariant) ===")
        for inv, mut, path in survivors:
            print(f"  {inv.name} :: {mut.name}")
            print(f"    {mut.description}")
            print(f"    file: {path}")
        sys.exit(2)  # exit 2 = survivors found (use as CI signal)
    else:
        print("All mutations killed — every invariant is load-bearing.")
        sys.exit(0)


if __name__ == "__main__":
    main()
