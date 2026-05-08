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

package trace

import "fmt"

// Verdict is the outcome of running a Checker against a trace.
// One of OK, Failed, or Inapplicable.
type Verdict struct {
	// Kind is the verdict's category.
	Kind VerdictKind

	// Spec names the spec module the checker is for.
	Spec SpecModule

	// Invariant names the specific invariant violated, if any.
	// Empty when Kind == VerdictOK or VerdictInapplicable.
	Invariant string

	// Reason is a one-line human-readable summary.
	Reason string

	// OffendingSeq is the trace-record sequence number at which
	// the violation was first detected. Zero when Kind != VerdictFailed.
	OffendingSeq uint64
}

// VerdictKind enumerates the possible verdict outcomes.
type VerdictKind int

const (
	// VerdictOK means the checker observed no violations.
	VerdictOK VerdictKind = iota

	// VerdictFailed means the checker observed at least one
	// invariant violation. Reason and OffendingSeq are populated.
	VerdictFailed

	// VerdictInapplicable means the checker found no records
	// matching its spec module — the trace did not exercise the
	// behaviour the checker covers. Not a failure, but worth
	// flagging in CI output.
	VerdictInapplicable
)

// String renders a Verdict as a single line for CLI output.
func (v Verdict) String() string {
	switch v.Kind {
	case VerdictOK:
		return fmt.Sprintf("OK   [%s]", v.Spec)
	case VerdictInapplicable:
		return fmt.Sprintf("SKIP [%s] no records for this spec in the trace", v.Spec)
	case VerdictFailed:
		return fmt.Sprintf("FAIL [%s] %s — %s (at seq=%d)", v.Spec, v.Invariant, v.Reason, v.OffendingSeq)
	}
	return fmt.Sprintf("UNKNOWN [%s]", v.Spec)
}

// IsFailure returns true iff the verdict is VerdictFailed.
func (v Verdict) IsFailure() bool { return v.Kind == VerdictFailed }

// Checker is the interface implemented by per-spec invariant
// runners. Each Checker is stateless across calls; the trace it
// receives is the entire history.
type Checker interface {
	// Spec returns the SpecModule the checker is for.
	Spec() SpecModule

	// Check runs every applicable invariant for this spec
	// against the supplied trace and returns the first verdict
	// that is non-OK, or VerdictOK if all pass and the trace
	// exercised the spec, or VerdictInapplicable if the spec was
	// not exercised.
	Check(records []TraceRecord) Verdict
}
