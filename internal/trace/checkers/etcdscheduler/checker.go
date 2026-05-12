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

package etcdscheduler

import (
	"fmt"

	"sigs.k8s.io/cluster-api/internal/trace"
)

const (
	aReadGate               trace.Action = "ReadGate"
	aCommitAdmission        trace.Action = "CommitAdmission"
	aCommitAdmissionAborted trace.Action = "CommitAdmissionAborted"
	aRemoveMemberRPC        trace.Action = "RemoveMemberRPC"
)

type gateRead struct {
	member               string
	seq                  uint64
	result               bool
	targetIsLearner      bool
	admissionVoterCount  uint64
	admissionReconcileID string
}

// Checker validates remediation gate traces against the Remediation.tla
// admission/commit pairing rules.
type Checker struct{}

func (Checker) Spec() trace.SpecModule { return trace.SpecRemediation }

func (Checker) Check(records []trace.TraceRecord) trace.Verdict {
	reads := map[string]gateRead{}
	aborted := map[string]uint64{}
	committed := map[string]uint64{}
	saw := false

	for _, r := range records {
		if r.Spec != trace.SpecRemediation {
			continue
		}
		saw = true
		switch r.Action {
		case aReadGate:
			member, ok := r.AsString("member")
			if !ok || member == "" {
				return malformed(r, "ReadGate missing member")
			}
			result, ok := r.AsBool("result")
			if !ok {
				return malformed(r, "ReadGate missing result")
			}
			targetIsLearner, ok := r.AsBool("targetIsLearner")
			if !ok {
				return malformed(r, "ReadGate missing targetIsLearner")
			}
			admissionVoterCount, ok := r.AsUint64("admissionVoterCount")
			if !ok {
				return malformed(r, "ReadGate missing admissionVoterCount")
			}
			reconcileID, _ := r.AsString("reconcileID")
			reads[member] = gateRead{
				member:               member,
				seq:                  r.Seq,
				result:               result,
				targetIsLearner:      targetIsLearner,
				admissionVoterCount:  admissionVoterCount,
				admissionReconcileID: reconcileID,
			}

		case aCommitAdmission:
			member, ok := r.AsString("member")
			if !ok || member == "" {
				return malformed(r, "CommitAdmission missing member")
			}
			gr, ok := reads[member]
			if !ok {
				return failed(r, "EveryRemoveMemberHasMatchingValidCommitAdmission", "CommitAdmission has no matching ReadGate")
			}
			if !gr.result {
				return failed(r, "EveryRemoveMemberHasMatchingValidCommitAdmission", "CommitAdmission proceeded after a failed gate read")
			}
			freshVoters, ok := r.AsStringSet("freshVoterSet")
			if !ok {
				return malformed(r, "CommitAdmission missing freshVoterSet")
			}
			freshTargetIsLearner, ok := r.AsBool("freshTargetIsLearner")
			if !ok {
				return malformed(r, "CommitAdmission missing freshTargetIsLearner")
			}
			if uint64(len(freshVoters)) < gr.admissionVoterCount {
				return failed(r, "GateAndCommitObserveConsistentState",
					fmt.Sprintf("freshVoterSet.size=%d < admissionVoterCount=%d", len(freshVoters), gr.admissionVoterCount))
			}
			if gr.targetIsLearner && !freshTargetIsLearner {
				return failed(r, "GateAndCommitObserveConsistentState", "target was learner at admission but became voter by commit")
			}
			delete(aborted, member)
			committed[member] = r.Seq

		case aCommitAdmissionAborted:
			member, ok := r.AsString("member")
			if !ok || member == "" {
				return malformed(r, "CommitAdmissionAborted missing member")
			}
			if _, ok := reads[member]; !ok {
				return failed(r, "EveryRemoveMemberHasMatchingValidCommitAdmission", "CommitAdmissionAborted has no matching ReadGate")
			}
			aborted[member] = r.Seq

		case aRemoveMemberRPC:
			member, ok := r.AsString("member")
			if !ok || member == "" {
				return malformed(r, "RemoveMemberRPC missing member")
			}
			commitSeq, ok := committed[member]
			if !ok {
				return failed(r, "EveryRemoveMemberHasMatchingValidCommitAdmission", "RemoveMemberRPC has no successful CommitAdmission")
			}
			if abortSeq, abortedEarlier := aborted[member]; abortedEarlier && abortSeq > commitSeq && abortSeq < r.Seq {
				return failed(r, "EveryRemoveMemberHasMatchingValidCommitAdmission", "RemoveMemberRPC followed an aborted commit for the same member")
			}
		}
	}

	if !saw {
		return trace.Verdict{Kind: trace.VerdictInapplicable, Spec: trace.SpecRemediation}
	}
	return trace.Verdict{Kind: trace.VerdictOK, Spec: trace.SpecRemediation}
}

func failed(r trace.TraceRecord, inv, reason string) trace.Verdict {
	return trace.Verdict{Kind: trace.VerdictFailed, Spec: r.Spec, Invariant: inv, Reason: reason, OffendingSeq: r.Seq}
}

func malformed(r trace.TraceRecord, why string) trace.Verdict {
	return trace.Verdict{Kind: trace.VerdictFailed, Spec: r.Spec, Invariant: "MalformedRecord", Reason: why, OffendingSeq: r.Seq}
}
