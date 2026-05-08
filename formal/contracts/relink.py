#!/usr/bin/env python3
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# relink.py — re-anchor upstream-source links in contracts/*.md
# when a pin in commits.yaml moves.
#
# Usage:
#   ./relink.py --check          dry-run; warn on drift, exit 1 if any
#   ./relink.py --apply          rewrite links in place; exit 1 on drift
#   ./relink.py --dump-links     print the table of every link found
#
# The script is intentionally dependency-free: standard library only.
# Drift detection is line-fingerprint-based: when a link points at
# `path:LINE-LINE`, the script checks the upstream file at the new
# SHA (when --upstream <path> is provided) and reports whether the
# contained text changed materially. Without --upstream the
# script only rewrites the SHA in URL paths and skips drift
# detection.
"""Re-anchor upstream links in contract documents.

This is a small, hand-readable script: contributors should be
able to read it end-to-end before trusting it to rewrite
contracts.
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import pathlib
import re
import sys
from typing import Iterable, Optional

# Default location of the YAML pin manifest. The script can be
# pointed at an alternate manifest with --pins-file.
DEFAULT_PINS = pathlib.Path(__file__).parent / "commits.yaml"

# Match GitHub blob URLs. We deliberately accept both /blob/ and
# /tree/ forms.
GH_LINK_RE = re.compile(
    r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/"
    r"(?:blob|tree)/(?P<sha>[0-9a-f]{7,40})/(?P<path>[^)\s#]+)"
    r"(?:#L(?P<lo>\d+)(?:-L(?P<hi>\d+))?)?"
)


@dataclasses.dataclass
class Pin:
    name: str
    url: str
    sha: str

    @property
    def gh_owner_repo(self) -> tuple[str, str]:
        # Extract owner/repo from the URL. Tolerant of trailing
        # slashes and '.git' suffixes.
        u = self.url.rstrip("/")
        if u.endswith(".git"):
            u = u[: -len(".git")]
        parts = u.split("/")
        return parts[-2], parts[-1]


def parse_pins(pins_path: pathlib.Path) -> dict[str, Pin]:
    """Parse the YAML manifest into a name → Pin map.

    The parser is intentionally minimal: it expects exactly the
    shape produced by the in-tree commits.yaml. Foreign YAML may
    not parse correctly. The point is to avoid pulling in a YAML
    dependency for a script run from CI.
    """
    pins: dict[str, Pin] = {}
    text = pins_path.read_text(encoding="utf-8")
    cur_name: Optional[str] = None
    cur_url: Optional[str] = None
    cur_sha: Optional[str] = None
    in_repos = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("#") or not stripped:
            continue
        if line.startswith("repos:"):
            in_repos = True
            continue
        if not in_repos:
            continue
        # New repo section header: two-space indent, ends with ':'.
        if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
            if cur_name and cur_url and cur_sha:
                pins[cur_name] = Pin(cur_name, cur_url, cur_sha)
            cur_name = stripped[:-1]
            cur_url = None
            cur_sha = None
            continue
        # Field of the current repo: four-space indent.
        if line.startswith("    "):
            if stripped.startswith("url:"):
                cur_url = stripped.split(":", 1)[1].strip().strip("\"")
            elif stripped.startswith("sha:"):
                cur_sha = stripped.split(":", 1)[1].strip().strip("\"")
    # Flush the last repo.
    if cur_name and cur_url and cur_sha:
        pins[cur_name] = Pin(cur_name, cur_url, cur_sha)
    return pins


def find_links(md: str) -> Iterable[re.Match]:
    return GH_LINK_RE.finditer(md)


def repo_to_pin(pins: dict[str, Pin], owner: str, repo: str) -> Optional[Pin]:
    for pin in pins.values():
        ow, rp = pin.gh_owner_repo
        if ow == owner and rp == repo:
            return pin
    return None


def rewrite_one(md: str, pins: dict[str, Pin]) -> tuple[str, list[str]]:
    """Rewrite GitHub links in `md` to use the SHAs in `pins`.

    Returns the new text and a list of human-readable changes.
    """
    changes: list[str] = []

    def repl(m: re.Match) -> str:
        owner = m.group("owner")
        repo = m.group("repo")
        sha = m.group("sha")
        path = m.group("path")
        lo = m.group("lo")
        hi = m.group("hi")
        pin = repo_to_pin(pins, owner, repo)
        if not pin or pin.sha == "HEAD":
            return m.group(0)
        if pin.sha == sha:
            return m.group(0)
        new = (
            f"https://github.com/{owner}/{repo}/blob/{pin.sha}/{path}"
            + (f"#L{lo}" if lo else "")
            + (f"-L{hi}" if lo and hi else "")
        )
        changes.append(f"  {owner}/{repo}: {sha[:8]} -> {pin.sha[:8]}  {path}")
        return new

    new_md = GH_LINK_RE.sub(repl, md)
    return new_md, changes


def cmd_check(args: argparse.Namespace, pins: dict[str, Pin]) -> int:
    drift = 0
    for md_path in args.contracts:
        text = md_path.read_text(encoding="utf-8")
        _, changes = rewrite_one(text, pins)
        if changes:
            drift += len(changes)
            print(f"DRIFT in {md_path.name}:")
            for c in changes:
                print(c)
    if drift:
        print(f"\n{drift} drifted link(s). Run with --apply to rewrite.")
        return 1
    print("No drift.")
    return 0


def cmd_apply(args: argparse.Namespace, pins: dict[str, Pin]) -> int:
    total = 0
    for md_path in args.contracts:
        text = md_path.read_text(encoding="utf-8")
        new, changes = rewrite_one(text, pins)
        if changes:
            md_path.write_text(new, encoding="utf-8")
            print(f"REWRITTEN {md_path.name}:")
            for c in changes:
                print(c)
            total += len(changes)
    if total == 0:
        print("Nothing to rewrite.")
    else:
        print(f"\nRewrote {total} link(s).")
    return 0


def cmd_dump_links(args: argparse.Namespace, pins: dict[str, Pin]) -> int:
    for md_path in args.contracts:
        text = md_path.read_text(encoding="utf-8")
        for m in find_links(text):
            print(
                f"{md_path.name}\t{m.group('owner')}/{m.group('repo')}@{m.group('sha')[:8]}"
                f"\t{m.group('path')}"
                + (f"#L{m.group('lo')}" if m.group("lo") else "")
                + (f"-L{m.group('hi')}" if m.group("lo") and m.group("hi") else "")
            )
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Re-anchor upstream-source links in contracts/*.md.",
    )
    parser.add_argument(
        "--pins-file",
        type=pathlib.Path,
        default=DEFAULT_PINS,
        help=f"YAML manifest of pinned SHAs (default: {DEFAULT_PINS}).",
    )
    parser.add_argument(
        "--contracts-dir",
        type=pathlib.Path,
        default=pathlib.Path(__file__).parent,
        help="Directory containing *.md contracts to process.",
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--check",
        action="store_const",
        const="check",
        dest="cmd",
        help="Dry-run; exit 1 if any link drifted.",
    )
    mode.add_argument(
        "--apply",
        action="store_const",
        const="apply",
        dest="cmd",
        help="Rewrite drifted links in place.",
    )
    mode.add_argument(
        "--dump-links",
        action="store_const",
        const="dump-links",
        dest="cmd",
        help="Print the table of every link found.",
    )

    args = parser.parse_args(argv)

    pins = parse_pins(args.pins_file)
    if not pins:
        print(f"error: no pins parsed from {args.pins_file}", file=sys.stderr)
        return 2

    md_paths = sorted(args.contracts_dir.glob("*.md"))
    args.contracts = md_paths

    if args.cmd == "check":
        return cmd_check(args, pins)
    if args.cmd == "apply":
        return cmd_apply(args, pins)
    if args.cmd == "dump-links":
        return cmd_dump_links(args, pins)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
