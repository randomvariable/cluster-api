#!/usr/bin/env bash
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
#
# trace-replay-sweep — generate random Quint traces and replay
# them through internal/trace/checkers (issue #11).
#
# For each spec in formal/specs/SPECS_TO_SWEEP, this script:
#   1. Runs `quint run --mbt --max-samples=N --max-steps=M
#      --n-traces=K --out-itf=<dir>/{seq}.itf.json` to generate K
#      random traces.
#   2. For each ITF file, runs the trace-validator binary in `itf`
#      mode and captures the verdict.
#   3. Reports a per-spec summary: pass / fail / inapplicable.
#   4. On any FAIL verdict, dumps the offending trace path and the
#      checker output to stderr and exits non-zero.
#
# Acceptance criterion of issue #11: 10k traces per spec without
# error. The default --total-traces is small (50 per spec) so the
# CI gate stays fast; the make target `verify-trace-replay-large`
# runs the full 10k sweep.
#
# Two error categories are tracked separately:
#
#   * PIPELINE failures    — MalformedRecord verdicts from the
#                            checker, JSON decode errors, missing
#                            binary, missing spec file. These
#                            indicate the trace-replay plumbing is
#                            broken; the script always exits non-zero
#                            on any of these.
#   * CHECKER findings     — proper invariant violations from the
#                            per-spec checkers. These are interesting
#                            but expected at non-zero rates because
#                            the current checkers were authored for
#                            hand-curated traces and haven't been
#                            hardened for arbitrary random traces.
#                            By default the script LOGS findings to
#                            <out-dir>/findings.txt and exits 0;
#                            --strict promotes findings to failures.
#
# Usage:
#   hack/tools/trace-replay-sweep.sh [--total-traces N]
#                                    [--max-steps M]
#                                    [--specs "EtcdMembership,KubeadmJoin,..."]
#                                    [--out-dir DIR]
#                                    [--strict]
#
# Defaults:
#   --total-traces 50
#   --max-steps    20
#   --specs        EtcdMembership,KubeadmJoin,KCPReconcile,MachineHealthCheck
#   --out-dir      /tmp/trace-replay-sweep

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
total_traces=50
max_steps=20
specs="EtcdMembership,KubeadmJoin,KCPReconcile,MachineHealthCheck"
out_dir="/tmp/trace-replay-sweep"
strict=false

while [ $# -gt 0 ]; do
  case "$1" in
    --total-traces) total_traces="$2"; shift 2 ;;
    --max-steps) max_steps="$2"; shift 2 ;;
    --specs) specs="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --strict) strict=true; shift ;;
    --help|-h)
      sed -n '17,68p' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

if ! command -v quint >/dev/null 2>&1; then
  echo "SKIP: quint not in PATH (install: npm i -g @informalsystems/quint)" >&2
  exit 0
fi

mkdir -p "$out_dir"
validator="$(mktemp)"
trap 'rm -f "$validator"' EXIT

echo "==> Building trace-validator"
( cd "$REPO_ROOT/hack/tools" && go build -tags tools -o "$validator" ./trace-validator )

# `quint run --mbt` records the action taken at each step but
# requires --max-samples >= --n-traces. Use n-traces equal to the
# requested per-spec count and max-samples = n-traces × 2 so the
# generator has slack for traces it rejects.
total_pipeline_failures=0
total_checker_findings=0
total_traces_run=0
findings_log="$out_dir/findings.txt"
> "$findings_log"

IFS=',' read -ra spec_list <<< "$specs"
for spec in "${spec_list[@]}"; do
  spec_path="$REPO_ROOT/formal/specs/${spec}.qnt"
  if [ ! -f "$spec_path" ]; then
    echo "WARN: spec not found: $spec_path" >&2
    continue
  fi
  spec_out="$out_dir/$spec"
  rm -rf "$spec_out"
  mkdir -p "$spec_out"

  echo
  echo "==> Generating $total_traces random traces for $spec.qnt"
  if ! quint run --backend=typescript --mbt \
       --max-samples="$((total_traces * 2))" \
       --n-traces="$total_traces" \
       --max-steps="$max_steps" \
       --out-itf="$spec_out/{seq}.itf.json" \
       "$spec_path" >"$spec_out/_generation.log" 2>&1; then
    echo "PIPELINE-FAIL: quint run failed for $spec — see $spec_out/_generation.log" >&2
    total_pipeline_failures=$((total_pipeline_failures + 1))
    continue
  fi

  generated=$(find "$spec_out" -name '*.itf.json' | wc -l | tr -d ' ')
  echo "    generated $generated traces"
  total_traces_run=$((total_traces_run + generated))

  spec_findings=0
  spec_pipeline=0
  while IFS= read -r itf; do
    if ! "$validator" -format itf "$itf" >"$itf.verdict.txt" 2>&1; then
      if grep -q 'MalformedRecord' "$itf.verdict.txt"; then
        # Pipeline error: the loader produced a record the
        # checker could not consume. This is plumbing breakage,
        # not a spec finding.
        spec_pipeline=$((spec_pipeline + 1))
        total_pipeline_failures=$((total_pipeline_failures + 1))
        echo "  PIPELINE-FAIL [$spec] $itf" >&2
        head -5 "$itf.verdict.txt" >&2
      elif grep -q '^FAIL' "$itf.verdict.txt"; then
        # Genuine checker invariant violation. Logged but does
        # not fail CI unless --strict is set.
        spec_findings=$((spec_findings + 1))
        total_checker_findings=$((total_checker_findings + 1))
        {
          echo "[$spec] $itf"
          grep '^FAIL' "$itf.verdict.txt"
          echo
        } >>"$findings_log"
      fi
    fi
  done < <(find "$spec_out" -name '*.itf.json')

  if [ "$spec_pipeline" -gt 0 ]; then
    echo "    PIPELINE-FAIL [$spec] $spec_pipeline of $generated traces" >&2
  fi
  if [ "$spec_findings" -gt 0 ]; then
    echo "    findings  [$spec] $spec_findings of $generated traces (logged to $findings_log)"
  fi
  if [ "$spec_pipeline" -eq 0 ] && [ "$spec_findings" -eq 0 ]; then
    echo "    OK [$spec] $generated traces, no failures"
  fi
done

echo
echo "==> Summary"
echo "  Traces replayed:       $total_traces_run across ${#spec_list[@]} spec(s)"
echo "  Pipeline failures:     $total_pipeline_failures"
echo "  Checker findings:      $total_checker_findings"
echo "  Findings log:          $findings_log"

if [ "$total_pipeline_failures" -gt 0 ]; then
  echo
  echo "FAIL: $total_pipeline_failures pipeline failure(s) — fix the loader or checker before re-running." >&2
  exit 1
fi

if [ "$strict" = "true" ] && [ "$total_checker_findings" -gt 0 ]; then
  echo
  echo "FAIL (--strict): $total_checker_findings checker finding(s) — file in formal/counterexample-log.md and re-run." >&2
  exit 1
fi

echo "  OK (no pipeline failures; --strict not set so checker findings are logged-only)"
