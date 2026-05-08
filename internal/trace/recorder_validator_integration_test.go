/*
Copyright 2026 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package trace_test

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

// TestRecorderValidatorRoundTrip exercises the full recorder →
// JSONL serialisation → loader → checker pipeline that the FM-2
// e2e (and any future FM-* e2e) relies on.
//
// The test mirrors the shape of an FM-2 trace: a single
// Bootstrap event with three voters, followed by silence (no
// RemoveMember while the cluster is in the FM-2 hopelessness
// window). Every checker MUST return either VerdictOK or
// VerdictInapplicable; none may return VerdictFailed.
//
// This is the acceptance criterion of issue #8 reduced to the
// CI-runnable plane: the recorder + validator pipeline produces
// a green verdict for the canonical FM-2 trace shape, even when
// CAPD is unavailable in the verify-formal.sh gate.
func TestRecorderValidatorRoundTrip_FM2Shape(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	now := func() time.Time { return time.Unix(0, 0) }
	r := trace.NewJSONLinesRecorder(&buf, now)

	// One Bootstrap with three voters — the canonical FM-2 init.
	if err := r.Record(
		trace.SpecEtcdMembership,
		"Bootstrap",
		"",
		map[string]any{
			"voters": []string{"1", "2", "3"},
		},
	); err != nil {
		t.Fatalf("record Bootstrap: %v", err)
	}

	// No further events — FM-2 hopelessness asserts that no
	// RemoveMember fires while two of three voters are paused.

	records, err := trace.LoadJSONLines(strings.NewReader(buf.String()))
	if err != nil {
		t.Fatalf("LoadJSONLines: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}

	// Every applicable checker MUST be either OK or
	// Inapplicable. Any Failed verdict is a regression.
	all := []trace.Checker{
		checkers.EtcdMembership{},
		checkers.KubeadmJoin{},
		checkers.KCPReconcile{},
		checkers.MHC{},
	}
	for _, c := range all {
		v := c.Check(records)
		if v.IsFailure() {
			t.Errorf("checker %s reported failure: %s", c.Spec(), v)
		}
	}
}

// TestRecorderValidatorRoundTrip_DetectsViolation verifies the
// negative path: a constructed trace that violates an invariant
// MUST produce VerdictFailed. This guards against the
// recorder/loader pipeline silently dropping records (which
// would mask real e2e failures behind green verdicts).
func TestRecorderValidatorRoundTrip_DetectsViolation(t *testing.T) {
	t.Parallel()

	var buf bytes.Buffer
	r := trace.NewJSONLinesRecorder(&buf, func() time.Time { return time.Unix(0, 0) })

	// PromoteLearner without a prior AddLearner is a
	// PromotionEligibility violation.
	if err := r.Record(
		trace.SpecEtcdMembership,
		"PromoteLearner",
		"",
		map[string]any{"id": uint64(42)},
	); err != nil {
		t.Fatalf("record PromoteLearner: %v", err)
	}

	records, err := trace.LoadJSONLines(strings.NewReader(buf.String()))
	if err != nil {
		t.Fatalf("LoadJSONLines: %v", err)
	}

	v := checkers.EtcdMembership{}.Check(records)
	if !v.IsFailure() {
		t.Fatalf("expected VerdictFailed for unauthorised PromoteLearner, got %s", v)
	}
	if v.Invariant != "PromotionEligibility" {
		t.Errorf("expected PromotionEligibility violation, got %q", v.Invariant)
	}
}
