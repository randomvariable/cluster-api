#!/usr/bin/env bash
# verify-envelope.sh — issue #102.
#
# Measures the practical depth × time envelope of every Quint spec
# under verify-* Make targets. Records (spec, depth, seconds) to
# stdout as TSV; the Make target redirects to
# formal/scalability-envelope.tsv for CI tracking.
#
# Apalache backend is preferred (symbolic, better scaling); TLC
# fallback when Apalache absent.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
SPECS_DIR="$REPO_ROOT/formal/specs"
TIMEOUT_BIN="${TIMEOUT_BIN:-timeout}"
PER_RUN_TIMEOUT="${PER_RUN_TIMEOUT:-300}"   # 5 minutes
DEPTHS=(4 6 8 10 12)

if command -v apalache-mc >/dev/null 2>&1 || command -v apalache >/dev/null 2>&1; then
    BACKEND=apalache
else
    BACKEND=tlc
fi

echo -e "spec\tinvariant\tdepth\tbackend\telapsed_sec\toutcome"

run_one() {
    local spec="$1" invariant="$2" depth="$3"
    local start end elapsed outcome
    start=$(date +%s)
    if "$TIMEOUT_BIN" "$PER_RUN_TIMEOUT" \
        quint verify --main="$(basename "$spec" .qnt)" \
        --invariant="$invariant" --max-steps="$depth" \
        --backend="$BACKEND" "$spec" >/dev/null 2>&1; then
        outcome=ok
    else
        outcome=fail-or-timeout
    fi
    end=$(date +%s)
    elapsed=$((end - start))
    echo -e "$(basename "$spec")\t$invariant\t$depth\t$BACKEND\t$elapsed\t$outcome"
}

# The harness spec — sanity check.
for d in "${DEPTHS[@]}"; do
    run_one "$SPECS_DIR/ScalabilityEnvelope.qnt" CounterBounded "$d"
done

# Light spec — should fit any depth.
for d in "${DEPTHS[@]}"; do
    run_one "$SPECS_DIR/GoalDirectedTemplates.qnt" 'not(BadStateReachable)' "$d"
done

# Mid-weight spec — should track linearly.
for d in "${DEPTHS[@]}"; do
    run_one "$SPECS_DIR/ConcurrentRemediationGate.qnt" NoConcurrentQuorumLoss "$d"
done

# Heavy spec — expect timeout at higher depths under TLC.
for d in "${DEPTHS[@]}"; do
    run_one "$SPECS_DIR/Lifecycle.qnt" AllSafetyInvariants "$d"
done
