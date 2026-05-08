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

package checkers

import (
	"fmt"

	"sigs.k8s.io/cluster-api/internal/trace"
)

// KCPReconcile is a trace.Checker for formal/specs/KCPReconcile.qnt.
//
// Invariants enforced:
//
//   - RemediationOnlyWhenSafe — every Machine in
//     RemediationInFlight had matchableMachines == machines and
//     quorumPreservedAfterDelete at the moment of admission.
//   - PreflightBlocksRemediationWhenUnhealthy — at least one
//     Machine in RemediationBlocked implies preflightBlocked=true.
type KCPReconcile struct{}

// Spec returns trace.SpecKCPReconcile.
func (KCPReconcile) Spec() trace.SpecModule { return trace.SpecKCPReconcile }

// Check enforces the per-step invariants.
func (KCPReconcile) Check(records []trace.TraceRecord) trace.Verdict {
	machines := map[uint64]bool{}
	nodeRefSet := map[uint64]bool{}
	decision := map[uint64]string{}
	preflightBlocked := false
	saw := false

	quorumOf := func(n int) int { return n/2 + 1 }
	matchableEqMachines := func() bool {
		for m := range machines {
			if !nodeRefSet[m] {
				return false
			}
		}
		return true
	}
	quorumPreservedAfterDelete := func(_ uint64) bool {
		// Removing one Machine; check the post-delete cardinality.
		return len(machines)-1 >= quorumOf(len(machines))
	}

	for _, r := range records {
		if r.Spec != trace.SpecKCPReconcile {
			continue
		}
		saw = true

		switch r.Action {
		case "AddMachine":
			mid, ok := r.AsUint64("machine")
			if !ok {
				return malformed(r, "AddMachine missing machine")
			}
			machines[mid] = true
			nodeRefSet[mid] = false
			decision[mid] = "NoRemediationNeeded"
		case "ResolveNodeRef":
			mid, ok := r.AsUint64("machine")
			if !ok {
				return malformed(r, "ResolveNodeRef missing machine")
			}
			nodeRefSet[mid] = true
		case "HealthChange":
			// Health changes don't directly drive invariants here;
			// they're cross-checked through Composition.
		case "RequestRemediation":
			mid, ok := r.AsUint64("machine")
			if !ok {
				return malformed(r, "RequestRemediation missing machine")
			}
			decision[mid] = "RemediationRequested"
		case "EvaluateCanSafelyRemediate":
			mid, ok := r.AsUint64("machine")
			if !ok {
				return malformed(r, "EvaluateCanSafelyRemediate missing machine")
			}
			safe := matchableEqMachines() && quorumPreservedAfterDelete(mid)
			if safe {
				decision[mid] = "RemediationInFlight"
			} else {
				decision[mid] = "RemediationBlocked"
				preflightBlocked = true
			}
		case "CompleteRemediation":
			mid, ok := r.AsUint64("machine")
			if !ok {
				return malformed(r, "CompleteRemediation missing machine")
			}
			if decision[mid] != "RemediationInFlight" {
				return failed(r, "RemediationOnlyWhenSafe",
					fmt.Sprintf("CompleteRemediation(%d) but decision=%q", mid, decision[mid]))
			}
			delete(machines, mid)
			delete(nodeRefSet, mid)
			decision[mid] = "NoRemediationNeeded"
			preflightBlocked = false
		}

		// Cross-cutting: any Machine in RemediationBlocked implies preflightBlocked.
		anyBlocked := false
		for _, d := range decision {
			if d == "RemediationBlocked" {
				anyBlocked = true
				break
			}
		}
		if anyBlocked && !preflightBlocked {
			return failed(r, "PreflightBlocksRemediationWhenUnhealthy",
				"a Machine is RemediationBlocked but preflightBlocked=false")
		}
	}

	if !saw {
		return trace.Verdict{Kind: trace.VerdictInapplicable, Spec: trace.SpecKCPReconcile}
	}
	return trace.Verdict{Kind: trace.VerdictOK, Spec: trace.SpecKCPReconcile}
}
