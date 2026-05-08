#!/usr/bin/env python3
# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""LLM-driven invariant discovery for Quint specs (issue #10).

Pipes a `.qnt` file plus a structured prompt to an LLM and parses
the response into a list of candidate state invariants. For each
candidate, prints:

    name        — Quint identifier
    quint_body  — predicate body, ready to copy as `val <name> = ...`
    rationale   — one-sentence justification
    confidence  — High | Medium | Low

The tool is bring-your-own-API-key:

    export ANTHROPIC_API_KEY=...
    python3 hack/tools/llm-invariant-discovery.py formal/specs/Lifecycle.qnt

Or run in fixture mode against a pre-canned response, useful for
deterministic CI runs and for environments without network egress:

    python3 hack/tools/llm-invariant-discovery.py \
        --fixture formal/llm-invariants/Lifecycle.cache.json \
        formal/specs/Lifecycle.qnt

The fixture file is a JSON document with the same schema the LLM
emits (see CANDIDATE_SCHEMA below). The discovery workflow is:

  1. Run with --fixture write-only against a fresh API call to
     populate the cache (or hand-author the cache for offline
     reproducibility).
  2. Iterate: for each candidate, paste it into the spec as a
     `val`, run `make verify-fmN` (or `quint run --invariant ...`),
     and either accept (it holds → it's a real invariant) or
     reject (counterexample → file an entry in
     `formal/counterexample-log.md`).
  3. Promoted invariants land alongside the existing ones in the
     spec's SafetyInvariants conjunction.

Exit codes:
  0  success — candidates printed (or written to --json-out)
  1  configuration / argument error
  2  spec file or fixture not found
  3  API call failed and no fixture available
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import textwrap
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

# JSON schema the LLM is asked to emit. Each candidate is one
# invariant. The fixture file is a JSON document of the form:
#   { "spec": "Lifecycle", "candidates": [ <candidate>, ... ] }
CANDIDATE_SCHEMA = {
    "spec": "string — name of the spec module the candidates apply to",
    "candidates": [
        {
            "name": "Quint identifier — CamelCase, descriptive",
            "quint_body": "Quint expression body (after `val NAME =`)",
            "rationale": "one-sentence justification grounded in the spec's actions",
            "confidence": "High | Medium | Low",
        }
    ],
}


# Default prompt. Designed to be terse, structured, and to push the
# LLM toward cross-state invariants the human authors might miss.
PROMPT_TEMPLATE = textwrap.dedent(
    """
    You are auditing the Quint specification below for state invariants
    that likely hold but are not yet asserted. The spec is part of a
    formal-modelling corpus for Cluster API. Existing invariants are
    declared with `val NAME = <predicate>` and aggregated under a
    `SafetyInvariants` (or similar) conjunction.

    Task. Enumerate up to 10 NEW state invariants likely to hold under
    every reachable state of the spec, that are NOT currently in the
    SafetyInvariants block. Prefer:

      * Cross-variable invariants ("if X is true then Y must hold").
      * Monotonicity / refinement invariants ("once V reaches state S
        it never leaves S").
      * Set-cardinality / role invariants ("worker machines are never
        in the CP set").
      * Phase-dependence invariants ("a machine in phase P implies
        condition C").

    Avoid:
      * Type invariants the Quint typechecker already enforces.
      * Tautologies.
      * Restating an existing invariant verbatim with different wording.

    For each candidate, emit a JSON object with fields:

    {schema}

    Output a single JSON document with key "spec" set to the module
    name and key "candidates" set to the list. No prose outside JSON.

    Spec ({spec}.qnt):
    ----- BEGIN SPEC -----
    {spec_body}
    ----- END SPEC -----
    """
).strip()


@dataclass
class Candidate:
    name: str
    quint_body: str
    rationale: str
    confidence: str

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> "Candidate":
        return cls(
            name=str(raw.get("name", "")).strip(),
            quint_body=str(raw.get("quint_body", "")).strip(),
            rationale=str(raw.get("rationale", "")).strip(),
            confidence=str(raw.get("confidence", "Medium")).strip().capitalize(),
        )


def load_fixture(path: Path) -> tuple[str, list[Candidate]]:
    raw = json.loads(path.read_text())
    spec = str(raw.get("spec", path.stem))
    cands = [Candidate.from_dict(c) for c in raw.get("candidates", [])]
    return spec, cands


def call_anthropic(prompt: str, model: str) -> dict[str, Any]:
    """Call the Anthropic API; return the parsed JSON response.

    Imports anthropic lazily so the script remains importable in
    environments where the package is not installed (fixture mode
    will still work). Raises RuntimeError on any failure.
    """
    try:
        import anthropic  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "anthropic package not installed. `pip install anthropic` or use --fixture."
        ) from exc

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        raise RuntimeError(
            "ANTHROPIC_API_KEY not set. Export it or use --fixture for offline runs."
        )

    client = anthropic.Anthropic(api_key=api_key)
    msg = client.messages.create(
        model=model,
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    )
    text = "".join(block.text for block in msg.content if hasattr(block, "text"))
    # The LLM is asked to emit a single JSON document. Trim leading
    # markdown fences if the model added them anyway.
    text = text.strip()
    if text.startswith("```"):
        # Drop the first fence line and any closing fence.
        text = "\n".join(line for line in text.splitlines() if not line.startswith("```"))
    return json.loads(text)


def call_openai(prompt: str, model: str) -> dict[str, Any]:
    """Call the OpenAI API; return parsed JSON. Lazy import."""
    try:
        from openai import OpenAI  # type: ignore
    except ImportError as exc:
        raise RuntimeError("openai package not installed.") from exc
    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY not set.")
    client = OpenAI(api_key=api_key)
    resp = client.chat.completions.create(
        model=model,
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
        response_format={"type": "json_object"},
    )
    return json.loads(resp.choices[0].message.content)


def render_quint(spec: str, candidates: list[Candidate]) -> str:
    """Render the candidates as a Quint snippet that can be pasted
    into the spec module body (between an existing `val ...` block
    and `SafetyInvariants`)."""
    out = [f"// LLM-discovered invariant candidates for {spec}.qnt"]
    out.append("// Reviewed and verified by quint run / Apalache before promotion.")
    out.append("// Counterexamples filed in formal/counterexample-log.md.")
    for c in candidates:
        out.append("")
        out.append(f"  // {c.rationale}")
        out.append(f"  // Confidence: {c.confidence}")
        out.append(f"  val {c.name} =")
        body_lines = c.quint_body.splitlines() or [c.quint_body]
        for line in body_lines:
            out.append("    " + line.lstrip())
    return "\n".join(out) + "\n"


def main() -> int:
    p = argparse.ArgumentParser(
        description="LLM-driven invariant discovery for Quint specs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("spec", type=Path, help="Path to a .qnt file")
    p.add_argument(
        "--provider",
        choices=("anthropic", "openai"),
        default="anthropic",
        help="LLM provider (default: anthropic).",
    )
    p.add_argument(
        "--model",
        default="claude-opus-4-7",
        help="Model identifier (provider-specific).",
    )
    p.add_argument(
        "--fixture",
        type=Path,
        help="Read candidates from a JSON fixture instead of calling the API.",
    )
    p.add_argument(
        "--write-fixture",
        type=Path,
        help="Write the API response to this path before printing.",
    )
    p.add_argument(
        "--json-out",
        type=Path,
        help="Write the candidate list as JSON to this path.",
    )
    p.add_argument(
        "--quint-out",
        type=Path,
        help="Render the candidates as a Quint snippet to this path.",
    )
    p.add_argument(
        "--min-confidence",
        choices=("Low", "Medium", "High"),
        default="Medium",
        help="Filter candidates by minimum confidence (default: Medium).",
    )
    args = p.parse_args()

    if not args.spec.is_file():
        print(f"error: spec file not found: {args.spec}", file=sys.stderr)
        return 2

    spec_name = args.spec.stem

    if args.fixture is not None:
        if not args.fixture.is_file():
            print(f"error: fixture not found: {args.fixture}", file=sys.stderr)
            return 2
        spec, candidates = load_fixture(args.fixture)
    else:
        spec_body = args.spec.read_text()
        prompt = PROMPT_TEMPLATE.format(
            spec=spec_name,
            spec_body=spec_body,
            schema=json.dumps(CANDIDATE_SCHEMA, indent=2),
        )
        try:
            if args.provider == "anthropic":
                doc = call_anthropic(prompt, args.model)
            else:
                doc = call_openai(prompt, args.model)
        except (RuntimeError, json.JSONDecodeError) as exc:
            print(f"error: API call failed: {exc}", file=sys.stderr)
            return 3
        spec = str(doc.get("spec", spec_name))
        candidates = [Candidate.from_dict(c) for c in doc.get("candidates", [])]
        if args.write_fixture is not None:
            args.write_fixture.parent.mkdir(parents=True, exist_ok=True)
            args.write_fixture.write_text(
                json.dumps(
                    {"spec": spec, "candidates": [asdict(c) for c in candidates]},
                    indent=2,
                )
            )

    confidence_rank = {"Low": 0, "Medium": 1, "High": 2}
    threshold = confidence_rank[args.min_confidence]
    filtered = [
        c for c in candidates
        if confidence_rank.get(c.confidence, 0) >= threshold
    ]

    print(f"# {spec}.qnt — {len(filtered)} candidate(s) at >= {args.min_confidence} confidence")
    print(f"#   ({len(candidates) - len(filtered)} dropped below threshold)")
    print()
    for c in filtered:
        print(f"## {c.name}  [{c.confidence}]")
        print(f"  {c.rationale}")
        print(f"  val {c.name} =")
        for line in c.quint_body.splitlines() or [c.quint_body]:
            print(f"    {line.lstrip()}")
        print()

    if args.json_out is not None:
        args.json_out.write_text(
            json.dumps(
                {"spec": spec, "candidates": [asdict(c) for c in filtered]},
                indent=2,
            )
        )

    if args.quint_out is not None:
        args.quint_out.write_text(render_quint(spec, filtered))

    return 0


if __name__ == "__main__":
    sys.exit(main())
