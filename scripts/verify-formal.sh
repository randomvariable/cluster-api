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
# verify-formal.sh — CI gate for the formal/ subtree.
#
# Six checks run in order:
#
#   1. quint typecheck on every formal/specs/*.qnt
#   2. quint run on every Quint module that declares a `run`
#   3. lake build in formal/proofs/
#   4. tlc on every formal/specs/*.tla that has a matching .cfg
#   5. go build/test of internal/trace/... and the
#      hack/tools/trace-validator command
#   6. drift check: every action declared in any Quint module
#      has at least one row in formal/abstraction-mapping.md
#
# When a tool is absent the script reports SKIP — never silent
# success. The drift check requires only python3 and grep.
#
# Use --drift-only to run check 6 alone.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAL_DIR="${REPO_ROOT}/formal"

drift_only=false
case "${1:-}" in
  --drift-only) drift_only=true ;;
  --help|-h)
    sed -n '17,32p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

red()    { printf '\033[31m%s\033[0m\n' "$*" 1>&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*" 1>&2; }
green()  { printf '\033[32m%s\033[0m\n' "$*" 1>&2; }

step()    { echo; echo "==> $*"; }
skip()    { yellow "SKIP: $*"; }
fail()    { red "FAIL: $*"; exit 1; }

# -- 1. quint typecheck ------------------------------------------------

run_quint_typecheck() {
  step "Quint typecheck"
  if ! command -v quint >/dev/null 2>&1; then
    skip "quint not in PATH (install: npm install -g @informalsystems/quint)"
    return 0
  fi
  local f
  for f in "${FORMAL_DIR}/specs/"*.qnt; do
    [ -e "$f" ] || continue
    echo "  $f"
    if ! quint typecheck "$f" >/dev/null; then
      fail "quint typecheck failed for $f"
    fi
  done
  green "OK quint typecheck"
}

# -- 2. quint run ------------------------------------------------------

run_quint_runs() {
  step "Quint runs"
  if ! command -v quint >/dev/null 2>&1; then
    skip "quint not in PATH"
    return 0
  fi
  local f
  for f in "${FORMAL_DIR}/specs/"*.qnt; do
    [ -e "$f" ] || continue
    if grep -qE '^[[:space:]]*run[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$f"; then
      echo "  $f"
      # Use the typescript backend: the rust evaluator hits a
      # recursion limit on Lifecycle.qnt's per-action ConvergenceFair
      # temporal expression (Phase 11b's 70-conjunct fairness).
      if ! quint run --backend=typescript --max-samples 100 "$f" >/dev/null; then
        fail "quint run failed for $f"
      fi
    fi
  done
  green "OK quint runs"
}

# -- 3. lake build -----------------------------------------------------

run_lake_build() {
  step "Lean lake build"
  if ! command -v lake >/dev/null 2>&1; then
    skip "lake not in PATH (install via elan)"
    return 0
  fi
  ( cd "${FORMAL_DIR}/proofs" && lake build )
  green "OK lake build"
}

# -- 4. tlc ------------------------------------------------------------

run_tlc() {
  step "TLC model check"
  if ! command -v tlc >/dev/null 2>&1; then
    skip "tlc not in PATH"
    return 0
  fi
  local cfg
  for cfg in "${FORMAL_DIR}/specs/"*.cfg; do
    [ -e "$cfg" ] || continue
    local tla="${cfg%.cfg}.tla"
    if [ ! -f "$tla" ]; then
      fail "$cfg has no companion .tla file"
    fi
    echo "  $tla"
    ( cd "${FORMAL_DIR}/specs" && tlc -config "$(basename "$cfg")" "$(basename "$tla")" )
  done
  green "OK tlc"
}

# -- 5. go build + test ------------------------------------------------

run_go() {
  step "Go build/test (internal/trace + trace-validator)"
  if ! command -v go >/dev/null 2>&1; then
    skip "go not in PATH"
    return 0
  fi
  ( cd "${REPO_ROOT}" && go build ./internal/trace/... ./internal/chaos/... ./internal/refinement/... )
  ( cd "${REPO_ROOT}" && go test  ./internal/trace/... ./internal/chaos/... ./internal/refinement/... )
  # The trace-validator command shares its directory name with
  # the binary it produces, so `go build ./trace-validator/...`
  # collides with the source directory. Use `go vet` for type
  # checking and an explicit `-o /dev/null` build to verify
  # linkage without writing artefacts.
  ( cd "${REPO_ROOT}/hack/tools" && go vet -tags tools ./trace-validator/... )
  ( cd "${REPO_ROOT}/hack/tools" && go build -tags tools -o /dev/null ./trace-validator )
  ( cd "${REPO_ROOT}/hack/tools" && go vet -tags tools ./capd-log-to-trace/... )
  ( cd "${REPO_ROOT}/hack/tools" && go build -tags tools -o /dev/null ./capd-log-to-trace )

  if [ "${FORMAL_VERIFY_CAPD_DIFFERENTIAL:-0}" = "1" ]; then
    step "Real-trace differential fixtures (optional)"
    local validator
    validator="$(mktemp)"
    trap 'rm -f "$validator"' EXIT
    ( cd "${REPO_ROOT}/hack/tools" && go build -tags tools -o "$validator" ./trace-validator )
    for fixture in "${REPO_ROOT}"/internal/trace/testdata/capd_*.jsonl; do
      [ -e "$fixture" ] || continue
      "$validator" -format capdlog -differential "$fixture" >/dev/null
    done
    green "OK differential fixtures"
  fi
  green "OK go"
}

# -- 6. drift check ----------------------------------------------------

run_drift_check() {
  step "Abstraction-mapping drift check"
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 not in PATH"
    return 0
  fi
  python3 - <<'PYEOF'
import os, re, sys, pathlib
formal = pathlib.Path("formal")
mapping = (formal / "abstraction-mapping.md").read_text()

# 1. Collect (spec, action) pairs from every Quint module.
# Lifecycle.qnt is the monolithic model used for checking; its
# actions are duplicates of the per-module specs and the
# abstraction-mapping rows live under the per-module names.
quint_actions = set()
for qnt in (formal / "specs").glob("*.qnt"):
    if qnt.name == "Lifecycle.qnt":
        continue
    spec_match = re.search(r"^module\s+(\w+)", qnt.read_text(), re.M)
    if not spec_match:
        continue
    spec = spec_match.group(1)
    for m in re.finditer(r"^\s*action\s+(\w+)", qnt.read_text(), re.M):
        action = m.group(1)
        # Skip the master step relation and the init action: they
        # are not refinement targets, they orchestrate the others.
        if action in {"step", "init", "compositeStep"}:
            continue
        quint_actions.add((spec, action))

# 2. Collect (spec, action) pairs already documented in
# abstraction-mapping.md as table rows. Rows are pipe-separated:
#   | Spec | Action | Go reference | Purpose |
mapping_rows = set()
for line in mapping.splitlines():
    if not line.startswith("|") or line.startswith("| --"):
        continue
    parts = [p.strip() for p in line.strip().strip("|").split("|")]
    if len(parts) < 2:
        continue
    spec, action = parts[0], parts[1]
    if spec in {"Spec", ""}:
        continue
    mapping_rows.add((spec, action))

missing = sorted(quint_actions - mapping_rows)
if missing:
    print("DRIFT: actions declared in formal/specs/ but missing from abstraction-mapping.md:")
    for spec, act in missing:
        print(f"  {spec}.{act}")
    sys.exit(1)
print(f"OK drift check ({len(quint_actions)} actions covered)")
PYEOF
  green "OK drift check"
}

if "$drift_only"; then
  cd "${REPO_ROOT}"
  run_drift_check
  exit 0
fi

cd "${REPO_ROOT}"
run_quint_typecheck
run_quint_runs
run_lake_build
run_tlc
run_go
run_drift_check
green "All formal-subtree checks passed."
