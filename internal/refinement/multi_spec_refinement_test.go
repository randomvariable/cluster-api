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

package refinement_test

import (
	"bytes"
	"fmt"
	"testing"
	"time"

	"sigs.k8s.io/cluster-api/internal/refinement"
	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

// TestRefinement_KubeadmJoinActions covers KubeadmJoin.qnt
// actions whose canonical Go implementation is the recorder
// + checker pair. The KubeadmJoin checker enforces the join-
// phase ordering (NotStarted → Preflight → KubeletStart →
// EtcdJoin → ...); these refinement cases exercise the
// transitions one Go-side function call at a time.
func TestRefinement_KubeadmJoinActions(t *testing.T) {
	suite := refinement.NewSuite().
		Add(refinement.Case{
			Action: "BeginJoin",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				return newRecorderCarrier()
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecKubeadmJoin, "BeginJoin", "m1",
					map[string]any{"machine": uint64(1)}); err != nil {
					t.Fatalf("BeginJoin: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.KubeadmJoin{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "PreflightPass",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecKubeadmJoin, "BeginJoin", "m1",
					map[string]any{"machine": uint64(1)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecKubeadmJoin, "PreflightPass", "m1",
					map[string]any{"machine": uint64(1)}); err != nil {
					t.Fatalf("PreflightPass: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.KubeadmJoin{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "KubeletStarted",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecKubeadmJoin, "BeginJoin", "m1",
					map[string]any{"machine": uint64(1)})
				_ = c.rec.Record(trace.SpecKubeadmJoin, "PreflightPass", "m1",
					map[string]any{"machine": uint64(1)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecKubeadmJoin, "KubeletStarted", "m1",
					map[string]any{"machine": uint64(1)}); err != nil {
					t.Fatalf("KubeletStarted: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.KubeadmJoin{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "EtcdAddLearnerSucceeded",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecKubeadmJoin, "BeginJoin", "m1",
					map[string]any{"machine": uint64(1)})
				_ = c.rec.Record(trace.SpecKubeadmJoin, "PreflightPass", "m1",
					map[string]any{"machine": uint64(1)})
				_ = c.rec.Record(trace.SpecKubeadmJoin, "KubeletStarted", "m1",
					map[string]any{"machine": uint64(1)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecKubeadmJoin, "EtcdAddLearnerSucceeded", "m1",
					map[string]any{"machine": uint64(1)}); err != nil {
					t.Fatalf("EtcdAddLearnerSucceeded: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.KubeadmJoin{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "JoinComplete",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				for _, action := range []trace.Action{
					"BeginJoin", "PreflightPass", "KubeletStarted",
					"EtcdAddLearnerSucceeded", "WaitForEtcdQuorum",
					"MarkControlPlaneReady",
				} {
					_ = c.rec.Record(trace.SpecKubeadmJoin, action, "m1",
						map[string]any{"machine": uint64(1)})
				}
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecKubeadmJoin, "JoinComplete", "m1",
					map[string]any{"machine": uint64(1)}); err != nil {
					t.Fatalf("JoinComplete: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.KubeadmJoin{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		})

	verdicts := suite.Run(t)
	t.Logf("KubeadmJoin refinement: %d cases, %d unique actions covered",
		len(verdicts), suite.CountCovered())
}

// TestRefinement_LoaderIdentities covers the LoadJSONLines /
// LoadITF round-trip identities. These aren't single Quint
// actions — they're the loader contract that every checker
// depends on. Refines the abstraction-mapping rows that
// reference `internal/trace.LoadJSONLines` and `LoadITF`.
func TestRefinement_LoaderIdentities(t *testing.T) {
	t.Parallel()

	t.Run("JSONLines/round-trip", func(t *testing.T) {
		var buf bytes.Buffer
		r := trace.NewJSONLinesRecorder(&buf, func() time.Time { return time.Unix(0, 0) })
		for i := 0; i < 5; i++ {
			if err := r.Record(trace.SpecEtcdMembership, "AddLearner", "",
				map[string]any{"id": uint64(i)}); err != nil {
				t.Fatalf("Record[%d]: %v", i, err)
			}
		}
		records, err := trace.LoadJSONLines(&buf)
		if err != nil {
			t.Fatalf("LoadJSONLines: %v", err)
		}
		if len(records) != 5 {
			t.Fatalf("len: got %d want 5", len(records))
		}
		// Refinement post-condition: Seq is 1..N strictly
		// monotonic.
		for i, rec := range records {
			if rec.Seq != uint64(i+1) {
				t.Errorf("records[%d].Seq=%d want %d", i, rec.Seq, i+1)
			}
		}
	})
}
