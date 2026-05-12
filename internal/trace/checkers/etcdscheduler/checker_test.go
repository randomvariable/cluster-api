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

package etcdscheduler_test

import (
	"testing"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers/etcdscheduler"
)

func rec(seq uint64, action trace.Action, vars map[string]any) trace.TraceRecord {
	return trace.TraceRecord{Seq: seq, Spec: trace.SpecRemediation, Action: action, Vars: vars}
}

func TestChecker_PassesOnAbortedLearnerCommit(t *testing.T) {
	t.Parallel()

	tr := []trace.TraceRecord{
		rec(1, "ReadGate", map[string]any{"member": "m1", "result": true, "targetIsLearner": true, "admissionVoterCount": float64(3)}),
		rec(2, "CommitAdmissionAborted", map[string]any{"member": "m1", "reason": "learner still joining"}),
	}
	v := etcdscheduler.Checker{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected pass, got %s", v)
	}
}

func TestChecker_FailsOnStaleVoterCountCommit(t *testing.T) {
	t.Parallel()

	tr := []trace.TraceRecord{
		rec(1, "ReadGate", map[string]any{"member": "m1", "result": true, "targetIsLearner": false, "admissionVoterCount": float64(3)}),
		rec(2, "CommitAdmission", map[string]any{"member": "m1", "freshVoterSet": []any{"1", "2"}, "freshTargetIsLearner": false}),
	}
	v := etcdscheduler.Checker{}.Check(tr)
	if !v.IsFailure() || v.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState failure, got %s", v)
	}
}

func TestChecker_FailsOnLearnerPromotionMidFlight(t *testing.T) {
	t.Parallel()

	tr := []trace.TraceRecord{
		rec(1, "ReadGate", map[string]any{"member": "m1", "result": true, "targetIsLearner": true, "admissionVoterCount": float64(3)}),
		rec(2, "CommitAdmission", map[string]any{"member": "m1", "freshVoterSet": []any{"1", "2", "3"}, "freshTargetIsLearner": false}),
	}
	v := etcdscheduler.Checker{}.Check(tr)
	if !v.IsFailure() || v.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState failure, got %s", v)
	}
}

func TestChecker_PassesWhenAbortRecordedBeforeRPC(t *testing.T) {
	t.Parallel()

	tr := []trace.TraceRecord{
		rec(1, "ReadGate", map[string]any{"member": "m1", "result": true, "targetIsLearner": true, "admissionVoterCount": float64(3)}),
		rec(2, "CommitAdmissionAborted", map[string]any{"member": "m1", "reason": "promoted mid-flight"}),
	}
	v := etcdscheduler.Checker{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected pass, got %s", v)
	}
}

func TestChecker_FailsWhenRPCHasNoSuccessfulCommit(t *testing.T) {
	t.Parallel()

	tr := []trace.TraceRecord{
		rec(1, "ReadGate", map[string]any{"member": "m1", "result": true, "targetIsLearner": false, "admissionVoterCount": float64(3)}),
		rec(2, "CommitAdmissionAborted", map[string]any{"member": "m1", "reason": "stale voter count"}),
		rec(3, "RemoveMemberRPC", map[string]any{"member": "m1"}),
	}
	v := etcdscheduler.Checker{}.Check(tr)
	if !v.IsFailure() || v.Invariant != "EveryRemoveMemberHasMatchingValidCommitAdmission" {
		t.Fatalf("expected EveryRemoveMemberHasMatchingValidCommitAdmission failure, got %s", v)
	}
}
