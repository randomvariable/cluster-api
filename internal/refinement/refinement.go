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

// Package refinement provides the Phase-1 (pragmatic) framework
// for issue #13: per-action refinement tests asserting that Go
// functions implement the semantics of their abstract Quint
// counterparts.
//
// The framework is deliberately thin — refinement testing is
// per-action work that doesn't fit a single shape. A Case
// captures four bits of the abstraction-mapping contract:
//
//   * Action — the Quint action name (matches a row in
//     formal/abstraction-mapping.md).
//   * GoRef — the canonical Go entry point as "pkg.Func".
//   * Pre — abstract precondition: a predicate over a setup
//     state. Returning false skips the case (the test would
//     have nothing meaningful to check).
//   * Run / Post — drive the Go function and assert the
//     post-state matches the abstract action's effect.
//
// The framework's value is consistency: every refinement test
// reads the same way and the runner reports a uniform
// per-Action verdict line. The acceptance criterion of 50%
// action coverage is achieved by adding more Cases — the
// framework imposes no per-action wiring beyond what each
// action specifically needs.
//
// Phase 2 (research): a Go-to-Lean translator that proves
// refinement statically. Aeneas-style MIR-to-Lean, but for Go.
// Out of scope for this package; see formal/refinement-verification.md.
package refinement

import (
	"fmt"
	"testing"
)

// Verdict captures the outcome of running a single Case.
type Verdict struct {
	Action string
	GoRef  string
	OK     bool
	Skip   bool
	Reason string
}

// String renders the verdict as a one-line CI-friendly summary.
func (v Verdict) String() string {
	switch {
	case v.Skip:
		return fmt.Sprintf("SKIP [%s -> %s] %s", v.Action, v.GoRef, v.Reason)
	case v.OK:
		return fmt.Sprintf("OK   [%s -> %s]", v.Action, v.GoRef)
	default:
		return fmt.Sprintf("FAIL [%s -> %s] %s", v.Action, v.GoRef, v.Reason)
	}
}

// Case is one refinement obligation: a Quint action and its Go
// implementation, plus the pre/run/post triple needed to
// execute the obligation against a representative state.
//
// The State type parameter is per-Case: a recorder Case carries
// a *bytes.Buffer; a checker Case carries a slice of TraceRecord;
// etc. A Case[any] is the type-erased entry point used by the
// Suite runner; concrete generic Cases are built via Of[State].
type Case struct {
	// Action names the Quint action being refined.
	Action string

	// GoRef is the Go entry point under test, formatted as
	// "import/path.Func" for grep-friendly cross-reference.
	GoRef string

	// Setup builds a representative pre-state for the test.
	// The returned value is opaque to the framework; the Pre,
	// Run, and Post closures consume it directly.
	Setup func(t *testing.T) any

	// Pre is the abstract precondition. Returning false makes
	// the case a SKIP (the precondition isn't met by the setup
	// state — the case has nothing to assert about).
	Pre func(state any) bool

	// Run executes the Go function under test. The returned
	// value is the post-state passed to Post.
	Run func(t *testing.T, state any) any

	// Post is the abstract postcondition. Returning a non-nil
	// error makes the case a FAIL.
	Post func(state any) error
}

// Suite is a set of refinement cases bundled for execution.
// Use NewSuite to construct one and Add to append cases.
type Suite struct {
	cases []Case
}

// NewSuite returns an empty Suite.
func NewSuite() *Suite { return &Suite{} }

// Add appends a Case to the Suite.
func (s *Suite) Add(c Case) *Suite {
	s.cases = append(s.cases, c)
	return s
}

// Run executes every Case in the Suite as a sub-test of `t`.
// Each sub-test is named after the Case's Action so failures
// are grep-friendly. Returns the per-case verdicts in the
// order they ran.
func (s *Suite) Run(t *testing.T) []Verdict {
	t.Helper()
	verdicts := make([]Verdict, 0, len(s.cases))
	for _, c := range s.cases {
		v := s.runCase(t, c)
		verdicts = append(verdicts, v)
	}
	return verdicts
}

func (s *Suite) runCase(t *testing.T, c Case) Verdict {
	v := Verdict{Action: c.Action, GoRef: c.GoRef}
	t.Run(c.Action, func(t *testing.T) {
		state := c.Setup(t)
		if !c.Pre(state) {
			v.Skip = true
			v.Reason = "precondition not satisfied"
			t.Skip(v.Reason)
			return
		}
		post := c.Run(t, state)
		if err := c.Post(post); err != nil {
			v.Reason = err.Error()
			t.Errorf("postcondition violated: %v", err)
			return
		}
		v.OK = true
	})
	return v
}

// Coverage returns a per-spec coverage summary: how many
// actions in `total` have a Case in the Suite. Used by the
// `verify-refinement` make target to report overall progress
// against the issue #13 acceptance bar (≥50%).
type Coverage struct {
	Total   int
	Covered int
}

// Pct returns the coverage percentage as an int [0..100].
func (c Coverage) Pct() int {
	if c.Total == 0 {
		return 0
	}
	return (c.Covered * 100) / c.Total
}

// String renders the coverage summary one-line.
func (c Coverage) String() string {
	return fmt.Sprintf("%d/%d actions covered (%d%%)", c.Covered, c.Total, c.Pct())
}

// CountCovered returns the unique set of action names covered
// by this Suite — useful for cross-referencing against the
// abstraction-mapping action list.
func (s *Suite) CountCovered() int {
	seen := map[string]struct{}{}
	for _, c := range s.cases {
		seen[c.Action] = struct{}{}
	}
	return len(seen)
}
