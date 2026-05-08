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

// Package checkers implements one Checker per Quint module under
// formal/specs/. See ../verdict.go for the Checker interface.
package checkers

import (
	"fmt"

	"sigs.k8s.io/cluster-api/internal/trace"
)

// EtcdMembership is a trace.Checker for formal/specs/EtcdMembership.qnt.
//
// Invariants enforced (all from the Quint AllInvariants
// conjunction):
//
//   - LearnerCannotVote     — every learner is a member; no
//     learner appears in the voter projection.
//   - VoterSetNonEmpty      — at least one voter exists.
//   - SingleLeaderPerTerm   — at most one leader per term.
//   - PromotionEligibility  — PromoteLearner records carry
//     `progress=Eligible` for the promoted id.
type EtcdMembership struct{}

// Spec returns trace.SpecEtcdMembership.
func (EtcdMembership) Spec() trace.SpecModule { return trace.SpecEtcdMembership }

// Check runs the per-record invariant pass. The checker
// reconstructs (members, learners, leaderAt) from the trace as
// it goes; record schema follows formal/abstraction-mapping.md
// rows for EtcdMembership.qnt.
func (EtcdMembership) Check(records []trace.TraceRecord) trace.Verdict {
	members := map[uint64]bool{}
	learners := map[uint64]bool{}
	leaderAt := map[uint64]uint64{} // term -> memberID
	progress := map[uint64]string{} // memberID -> progress label
	saw := false

	for _, r := range records {
		if r.Spec != trace.SpecEtcdMembership {
			continue
		}
		saw = true
		switch r.Action {
		case "Bootstrap":
			// Initial voter seed; vars carry a `voters` set.
			vs, ok := r.AsStringSet("voters")
			if !ok {
				return malformed(r, "Bootstrap missing voters set")
			}
			for _, s := range vs {
				var id uint64
				if _, err := fmt.Sscan(s, &id); err != nil {
					return malformed(r, "Bootstrap voters element not numeric")
				}
				members[id] = true
			}
		case "AddLearner":
			id, ok := r.AsUint64("id")
			if !ok {
				return malformed(r, "AddLearner missing id")
			}
			members[id] = true
			learners[id] = true
			progress[id] = "LaggingFar"
		case "PromoteLearner":
			id, ok := r.AsUint64("id")
			if !ok {
				return malformed(r, "PromoteLearner missing id")
			}
			if !learners[id] {
				return failed(r, "PromotionEligibility",
					fmt.Sprintf("PromoteLearner(%d) but member is not a learner", id))
			}
			if progress[id] != "Eligible" {
				return failed(r, "PromotionEligibility",
					fmt.Sprintf("PromoteLearner(%d) but progress=%q (need Eligible)", id, progress[id]))
			}
			delete(learners, id)
		case "RemoveMember":
			id, ok := r.AsUint64("id")
			if !ok {
				return malformed(r, "RemoveMember missing id")
			}
			delete(members, id)
			delete(learners, id)
		case "ObserveLearnerProgress":
			id, idOK := r.AsUint64("id")
			p, pOK := r.AsString("progress")
			if !idOK || !pOK {
				return malformed(r, "ObserveLearnerProgress missing id or progress")
			}
			progress[id] = p
		case "LearnerStuck":
			id, ok := r.AsUint64("id")
			if !ok {
				return malformed(r, "LearnerStuck missing id")
			}
			progress[id] = "Stuck"
		case "ElectLeader":
			c, cOK := r.AsUint64("candidate")
			term, tOK := r.AsUint64("term")
			if !cOK || !tOK {
				return malformed(r, "ElectLeader missing candidate or term")
			}
			if existing, set := leaderAt[term]; set && existing != c {
				return failed(r, "SingleLeaderPerTerm",
					fmt.Sprintf("term=%d already has leader=%d, attempted leader=%d", term, existing, c))
			}
			if learners[c] {
				return failed(r, "LearnerCannotVote",
					fmt.Sprintf("ElectLeader candidate=%d is a learner", c))
			}
			// A candidate that wins an election was already a
			// voter. If the trace did not include a Bootstrap
			// for this voter, register it implicitly here.
			members[c] = true
			leaderAt[term] = c
		}

		// Cross-cutting invariant: every learner is a member.
		for l := range learners {
			if !members[l] {
				return failed(r, "LearnerCannotVote",
					fmt.Sprintf("learner=%d is not in member set", l))
			}
		}
		// Cross-cutting invariant: voter set non-empty.
		voters := 0
		for m := range members {
			if !learners[m] {
				voters++
			}
		}
		if len(members) > 0 && voters == 0 {
			return failed(r, "VoterSetNonEmpty",
				"all members are learners; no voter remains")
		}
	}

	if !saw {
		return trace.Verdict{Kind: trace.VerdictInapplicable, Spec: trace.SpecEtcdMembership}
	}
	return trace.Verdict{Kind: trace.VerdictOK, Spec: trace.SpecEtcdMembership}
}

func failed(r trace.TraceRecord, inv, reason string) trace.Verdict {
	return trace.Verdict{
		Kind:         trace.VerdictFailed,
		Spec:         r.Spec,
		Invariant:    inv,
		Reason:       reason,
		OffendingSeq: r.Seq,
	}
}

func malformed(r trace.TraceRecord, why string) trace.Verdict {
	return trace.Verdict{
		Kind:         trace.VerdictFailed,
		Spec:         r.Spec,
		Invariant:    "MalformedRecord",
		Reason:       why,
		OffendingSeq: r.Seq,
	}
}
