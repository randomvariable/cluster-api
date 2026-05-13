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
	"testing"
	"time"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers/etcdscheduler"
)

func TestStreamingRecorder_FanOut(t *testing.T) {
	t.Parallel()

	rec := trace.NewStreamingRecorder(trace.Discard)
	ch, cancel := rec.Subscribe(8)
	defer cancel()

	go func() {
		defer rec.Close()
		_ = rec.Record(trace.SpecRemediation, "ReadGate",
			"cp-1", map[string]any{"member": "cp-1", "result": true,
				"targetIsLearner": false, "admissionVoterCount": uint64(3)})
		_ = rec.Record(trace.SpecRemediation, "CommitAdmission",
			"cp-1", map[string]any{"member": "cp-1",
				"freshVoterSet": []any{"1", "2", "3"}, "freshTargetIsLearner": false})
	}()

	var collected []trace.TraceRecord
	deadline := time.After(2 * time.Second)
	for done := false; !done; {
		select {
		case rec, ok := <-ch:
			if !ok {
				done = true
			} else {
				collected = append(collected, rec)
			}
		case <-deadline:
			t.Fatal("timed out waiting for stream records")
		}
	}
	if len(collected) != 2 {
		t.Fatalf("expected 2 records, got %d", len(collected))
	}
	if collected[0].Action != "ReadGate" || collected[1].Action != "CommitAdmission" {
		t.Fatalf("unexpected actions: %v %v", collected[0].Action, collected[1].Action)
	}
}

func TestStreamingCheck_DetectsViolation(t *testing.T) {
	t.Parallel()

	rec := trace.NewStreamingRecorder(trace.Discard)
	ch, _ := rec.Subscribe(8)

	verdicts := trace.StreamingCheck(t.Context(), ch, etcdscheduler.Checker{})

	// Inject a CAS-failing trace: admissionVoterCount=3 but
	// freshVoterSet=2 — checker MUST fail.
	go func() {
		_ = rec.Record(trace.SpecRemediation, "ReadGate", "cp-1",
			map[string]any{"member": "cp-1", "result": true,
				"targetIsLearner": false, "admissionVoterCount": uint64(3)})
		_ = rec.Record(trace.SpecRemediation, "CommitAdmission", "cp-1",
			map[string]any{"member": "cp-1",
				"freshVoterSet": []any{"1", "2"}, "freshTargetIsLearner": false})
		rec.Close()
	}()

	var failing trace.Verdict
	deadline := time.After(2 * time.Second)
	for done := false; !done; {
		select {
		case v, ok := <-verdicts:
			if !ok {
				done = true
			} else if v.IsFailure() {
				failing = v
			}
		case <-deadline:
			t.Fatal("timed out waiting for streaming verdict")
		}
	}
	if !failing.IsFailure() {
		t.Fatalf("expected at least one failure verdict, got none")
	}
	if failing.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState, got %q", failing.Invariant)
	}
}
