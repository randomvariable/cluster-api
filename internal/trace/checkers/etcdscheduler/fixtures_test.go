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
	"os"
	"path/filepath"
	"testing"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers/etcdscheduler"
)

// fixtureDir resolves the shared testdata directory at
// internal/trace/testdata so fixtures co-locate with the other
// per-spec traces.
func fixtureDir(t *testing.T) string {
	t.Helper()
	// checker_test.go lives at internal/trace/checkers/etcdscheduler/
	// — testdata lives at internal/trace/testdata/.
	return filepath.Join("..", "..", "testdata")
}

func loadFixture(t *testing.T, name string) []trace.TraceRecord {
	t.Helper()
	path := filepath.Join(fixtureDir(t), name)
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open fixture %s: %v", path, err)
	}
	defer f.Close()
	recs, err := trace.LoadJSONLines(f)
	if err != nil {
		t.Fatalf("parse fixture %s: %v", path, err)
	}
	return recs
}

func TestFixture_OrphanEtcdLearner_Passes(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_orphan_etcd_learner.jsonl"))
	if v.IsFailure() {
		t.Fatalf("expected pass, got %s", v)
	}
}

func TestFixture_ConcurrentCpRemediation_Passes(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_concurrent_cp_remediation.jsonl"))
	if v.IsFailure() {
		t.Fatalf("expected pass, got %s", v)
	}
}

func TestFixture_StaleVoterCount_Fails(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_cas_stale_voter_count_fail.jsonl"))
	if !v.IsFailure() {
		t.Fatalf("expected failure, got %s", v)
	}
	if v.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState, got %q", v.Invariant)
	}
}

func TestFixture_LearnerPromotedMidFlight_Fails(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_cas_learner_promoted_fail.jsonl"))
	if !v.IsFailure() {
		t.Fatalf("expected failure, got %s", v)
	}
	if v.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState, got %q", v.Invariant)
	}
}

func TestFixture_StaleVoterCountAborted_Passes(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_cas_stale_voter_count_aborted_pass.jsonl"))
	if v.IsFailure() {
		t.Fatalf("expected pass (abort recorded), got %s", v)
	}
}

func TestFixture_LearnerPromotedAborted_Passes(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_cas_learner_promoted_aborted_pass.jsonl"))
	if v.IsFailure() {
		t.Fatalf("expected pass (abort recorded), got %s", v)
	}
}

func TestFixture_ConcurrentCpRemediation_StaleVoterCount_Fails(t *testing.T) {
	t.Parallel()
	v := etcdscheduler.Checker{}.Check(loadFixture(t, "remediation_cas_concurrent_cp_remediation_fail.jsonl"))
	if !v.IsFailure() {
		t.Fatalf("expected failure, got %s", v)
	}
	if v.Invariant != "GateAndCommitObserveConsistentState" {
		t.Fatalf("expected GateAndCommitObserveConsistentState, got %q", v.Invariant)
	}
}
