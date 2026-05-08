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
	"os"
	"strings"
	"testing"

	"sigs.k8s.io/cluster-api/internal/trace"
)

// TestLoadITF_QuintMBTFormat verifies that LoadITF correctly
// parses a real ITF trace produced by `quint run --mbt
// --out-itf=...`. Property-based trace replay (issue #11)
// depends on this — every random trace from the sweep is
// loaded via this path before being handed to the checkers.
func TestLoadITF_QuintMBTFormat(t *testing.T) {
	t.Parallel()

	f, err := os.Open("testdata/etcd_membership.mbt.itf.json")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	records, err := trace.LoadITF(f)
	if err != nil {
		t.Fatalf("LoadITF: %v", err)
	}
	if len(records) == 0 {
		t.Fatal("expected at least one record")
	}

	// The first record is the init state — its action is "init"
	// and inferring SpecModule from it is unknown (returns "").
	first := records[0]
	if first.Action != "init" {
		t.Errorf("expected first action=init, got %q", first.Action)
	}
	if first.Spec != "" {
		t.Errorf("expected init record to have unknown spec, got %q", first.Spec)
	}

	// At least one record should carry an EtcdMembership action.
	var sawEtcd bool
	for _, r := range records {
		if r.Spec == trace.SpecEtcdMembership {
			sawEtcd = true
			break
		}
	}
	if !sawEtcd {
		t.Error("expected at least one record with Spec=EtcdMembership")
	}

	// Action names should be non-empty for non-init steps.
	for i, r := range records[1:] {
		if r.Action == "" {
			t.Errorf("record %d (seq=%d): empty action — MBT mode should populate this", i+1, r.Seq)
		}
	}
}

// TestUnwrapITFValue exercises the value-unwrapping helper
// against the ITF wrapper objects Quint emits. This is the
// load-bearing primitive the checkers depend on; if `#bigint`
// or `#set` decoding regresses, every replay verdict turns
// into spurious noise.
func TestLoadITF_VarsAreUnwrapped(t *testing.T) {
	t.Parallel()

	doc := `{
		"vars": ["currentTerm", "members", "leaderAt"],
		"states": [{
			"#meta": {"index": 0},
			"currentTerm": {"#bigint": "7"},
			"members": {"#set": [{"#bigint":"1"},{"#bigint":"2"}]},
			"leaderAt": {"#map": [[{"#bigint":"7"},{"#bigint":"1"}]]},
			"mbt::actionTaken": "ElectLeader",
			"mbt::nondetPicks": {
				"candidate": {"tag":"Some","value":{"#bigint":"1"}},
				"term":      {"tag":"Some","value":{"#bigint":"7"}}
			}
		}]
	}`
	records, err := trace.LoadITF(strings.NewReader(doc))
	if err != nil {
		t.Fatalf("LoadITF: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("expected 1 record, got %d", len(records))
	}
	r := records[0]
	if r.Action != "ElectLeader" {
		t.Errorf("Action: got %q want ElectLeader", r.Action)
	}
	if r.Spec != trace.SpecEtcdMembership {
		t.Errorf("Spec: got %q want EtcdMembership", r.Spec)
	}
	if v, ok := r.AsUint64("candidate"); !ok || v != 1 {
		t.Errorf("candidate: got (%d, %v) want (1, true)", v, ok)
	}
	if v, ok := r.AsUint64("term"); !ok || v != 7 {
		t.Errorf("term: got (%d, %v) want (7, true)", v, ok)
	}
	// State variables flow through. Note: for ElectLeader the
	// `currentTerm` key is renamed to `term` by the
	// per-action alias table, so the original key is gone.
	if _, ok := r.AsUint64("currentTerm"); ok {
		t.Errorf("currentTerm key should have been renamed to term for ElectLeader records")
	}
}
