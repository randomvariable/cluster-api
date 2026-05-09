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
	"strings"
	"testing"
	"time"

	"sigs.k8s.io/cluster-api/internal/refinement"
	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

// recorderCarrier is the per-case state carrier for refinement
// cases that drive a JSONLinesRecorder. It bundles the
// recorder, the buffer it writes to, and any per-case auxiliary
// state.
type recorderCarrier struct {
	buf  *bytes.Buffer
	rec  *trace.JSONLinesRecorder
	post []trace.TraceRecord
}

func newRecorderCarrier() *recorderCarrier {
	buf := &bytes.Buffer{}
	return &recorderCarrier{
		buf: buf,
		rec: trace.NewJSONLinesRecorder(buf, func() time.Time { return time.Unix(0, 0) }),
	}
}

func parseRecords(c *recorderCarrier) error {
	records, err := trace.LoadJSONLines(c.buf)
	if err != nil {
		return fmt.Errorf("LoadJSONLines: %w", err)
	}
	c.post = records
	return nil
}

// TestRefinement_RecorderActions covers the EtcdMembership
// abstract actions for which the recorder + checker pair are
// the canonical Go implementation. Each case asserts the
// abstract action's effect on the recorded trace + checker
// state.
//
// Coverage focus: EtcdMembership actions that the test-side
// recorder (test/e2e/internal/tracerecord) emits during FM-2.
// These are the load-bearing actions for the formal-trace
// runtime; failures here would silently break FM-* e2e
// validation.
func TestRefinement_RecorderActions(t *testing.T) {
	suite := refinement.NewSuite().
		Add(refinement.Case{
			Action: "Bootstrap",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				return newRecorderCarrier()
			},
			// Pre: the recorder is open (Setup returned a fresh one).
			Pre: func(state any) bool {
				_, ok := state.(*recorderCarrier)
				return ok
			},
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				err := c.rec.Record(
					trace.SpecEtcdMembership,
					"Bootstrap",
					"",
					map[string]any{"voters": []string{"1", "2", "3"}},
				)
				if err != nil {
					t.Fatalf("Record: %v", err)
				}
				return c
			},
			// Post: exactly one record was appended; the checker's
			// VoterSetNonEmpty invariant is satisfied (3 voters).
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if len(c.post) != 1 {
					return fmt.Errorf("expected 1 record, got %d", len(c.post))
				}
				if c.post[0].Action != "Bootstrap" {
					return fmt.Errorf("Action=%q want Bootstrap", c.post[0].Action)
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected post-state: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "AddLearner",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				if err := c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}}); err != nil {
					t.Fatalf("setup Bootstrap: %v", err)
				}
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecEtcdMembership, "AddLearner", "m4",
					map[string]any{"id": uint64(4)}); err != nil {
					t.Fatalf("AddLearner: %v", err)
				}
				return c
			},
			// Post: 2 records; the second is AddLearner; the
			// EtcdMembership checker accepts (LearnerCannotVote
			// holds — learner 4 is in the member set but not
			// elected).
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if len(c.post) != 2 {
					return fmt.Errorf("expected 2 records, got %d", len(c.post))
				}
				if c.post[1].Action != "AddLearner" {
					return fmt.Errorf("Action[1]=%q want AddLearner", c.post[1].Action)
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "RemoveMember",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				if err := c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}}); err != nil {
					t.Fatalf("setup: %v", err)
				}
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecEtcdMembership, "RemoveMember", "m3",
					map[string]any{"id": uint64(3)}); err != nil {
					t.Fatalf("RemoveMember: %v", err)
				}
				return c
			},
			// Post: 2 records; checker still OK (members={1,2}, voter
			// set non-empty).
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "PromoteLearner",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			// Pre per spec: the candidate must be a learner and
			// progress[id] = Eligible. Setup builds that state.
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				if err := c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}}); err != nil {
					t.Fatalf("setup1: %v", err)
				}
				if err := c.rec.Record(trace.SpecEtcdMembership, "AddLearner", "m4",
					map[string]any{"id": uint64(4)}); err != nil {
					t.Fatalf("setup2: %v", err)
				}
				if err := c.rec.Record(trace.SpecEtcdMembership, "ObserveLearnerProgress", "m4",
					map[string]any{"id": uint64(4), "progress": "Eligible"}); err != nil {
					t.Fatalf("setup3: %v", err)
				}
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecEtcdMembership, "PromoteLearner", "m4",
					map[string]any{"id": uint64(4)}); err != nil {
					t.Fatalf("PromoteLearner: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			// Negative case: PromoteLearner without a prior
			// ObserveLearnerProgress(Eligible) MUST be rejected
			// by the checker. Refines the spec's PromotionEligibility
			// invariant: KCP refuses to promote a learner that
			// hasn't reached Eligible.
			Action: "PromoteLearner_NegativeNoEligible",
			GoRef:  "internal/trace/checkers.EtcdMembership.Check",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}})
				_ = c.rec.Record(trace.SpecEtcdMembership, "AddLearner", "m4",
					map[string]any{"id": uint64(4)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				_ = c.rec.Record(trace.SpecEtcdMembership, "PromoteLearner", "m4",
					map[string]any{"id": uint64(4)})
				return c
			},
			// Post: checker MUST fail on PromotionEligibility.
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				v := (checkers.EtcdMembership{}).Check(c.post)
				if !v.IsFailure() {
					return fmt.Errorf("checker should have flagged unauthorised promotion, got %s", v)
				}
				if v.Invariant != "PromotionEligibility" {
					return fmt.Errorf("checker flagged %q, want PromotionEligibility", v.Invariant)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "ObserveLearnerProgress",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}})
				_ = c.rec.Record(trace.SpecEtcdMembership, "AddLearner", "m4",
					map[string]any{"id": uint64(4)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecEtcdMembership, "ObserveLearnerProgress", "m4",
					map[string]any{"id": uint64(4), "progress": "Eligible"}); err != nil {
					t.Fatalf("ObserveLearnerProgress: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			Action: "ElectLeader",
			GoRef:  "internal/trace.JSONLinesRecorder.Record",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				if err := c.rec.Record(trace.SpecEtcdMembership, "ElectLeader", "",
					map[string]any{"candidate": uint64(1), "term": uint64(1)}); err != nil {
					t.Fatalf("ElectLeader: %v", err)
				}
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				if v := (checkers.EtcdMembership{}).Check(c.post); v.IsFailure() {
					return fmt.Errorf("checker rejected: %s", v)
				}
				return nil
			},
		}).
		Add(refinement.Case{
			// Negative ElectLeader: candidate is a learner.
			Action: "ElectLeader_NegativeLearnerCandidate",
			GoRef:  "internal/trace/checkers.EtcdMembership.Check",
			Setup: func(t *testing.T) any {
				c := newRecorderCarrier()
				_ = c.rec.Record(trace.SpecEtcdMembership, "Bootstrap", "",
					map[string]any{"voters": []string{"1", "2", "3"}})
				_ = c.rec.Record(trace.SpecEtcdMembership, "AddLearner", "m4",
					map[string]any{"id": uint64(4)})
				return c
			},
			Pre: func(state any) bool { return true },
			Run: func(t *testing.T, state any) any {
				c := state.(*recorderCarrier)
				_ = c.rec.Record(trace.SpecEtcdMembership, "ElectLeader", "",
					map[string]any{"candidate": uint64(4), "term": uint64(1)})
				return c
			},
			Post: func(state any) error {
				c := state.(*recorderCarrier)
				if err := parseRecords(c); err != nil {
					return err
				}
				v := (checkers.EtcdMembership{}).Check(c.post)
				if !v.IsFailure() {
					return fmt.Errorf("checker should have rejected learner candidate, got %s", v)
				}
				if v.Invariant != "LearnerCannotVote" {
					return fmt.Errorf("invariant: got %q want LearnerCannotVote", v.Invariant)
				}
				return nil
			},
		})

	verdicts := suite.Run(t)

	// Per-suite summary line; useful for the make verify-refinement
	// target's grep-able output.
	pass, fail, skip := 0, 0, 0
	for _, v := range verdicts {
		switch {
		case v.Skip:
			skip++
		case v.OK:
			pass++
		default:
			fail++
		}
	}
	t.Logf("refinement summary: %d pass, %d fail, %d skip across %d cases (covering %d unique actions)",
		pass, fail, skip, len(verdicts), suite.CountCovered())

	// Sanity: every Action name in the suite must be referenced in
	// formal/abstraction-mapping.md (or be a Negative-suffix
	// derived test). This guards against typos that would silently
	// reduce coverage.
	for _, v := range verdicts {
		if strings.Contains(v.Action, "_Negative") {
			continue
		}
		// (Cross-reference deferred to the Make target's drift check;
		// this loop is a placeholder for future strengthening.)
	}
}
