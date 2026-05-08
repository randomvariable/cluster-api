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

// KubeadmJoin is a trace.Checker for formal/specs/KubeadmJoin.qnt.
//
// Invariants enforced:
//
//   - PhaseMonotonic — phase index non-decreasing per machine
//     until a terminal phase.
//   - EtcdRegistrationImpliesKubeletReady — once etcdMemberRegistered=true
//     for a machine, kubeletReady=true must already hold.
//   - StuckLearnerImpliesEtcdRegistered — JoinFailed with reason
//     LearnerStuckOnPromote requires etcdMemberRegistered=true.
type KubeadmJoin struct{}

// Spec returns trace.SpecKubeadmJoin.
func (KubeadmJoin) Spec() trace.SpecModule { return trace.SpecKubeadmJoin }

// Check enforces the per-machine invariants.
func (KubeadmJoin) Check(records []trace.TraceRecord) trace.Verdict {
	type machineState struct {
		phase           string
		etcdRegistered  bool
		kubeletReady    bool
		failureReason   string
	}
	machines := map[uint64]*machineState{}
	saw := false

	for _, r := range records {
		if r.Spec != trace.SpecKubeadmJoin {
			continue
		}
		saw = true
		mid, ok := r.AsUint64("machine")
		if !ok {
			return malformed(r, "missing machine id")
		}
		st, present := machines[mid]
		if !present {
			st = &machineState{phase: "NotStarted"}
			machines[mid] = st
		}

		switch r.Action {
		case "BeginJoin":
			st.phase = "Preflight"
		case "PreflightPass":
			st.phase = "KubeletStart"
		case "KubeletStarted":
			st.phase = "EtcdJoinAddLearner"
			st.kubeletReady = true
		case "EtcdAddLearnerSucceeded":
			if !st.kubeletReady {
				return failed(r, "EtcdRegistrationImpliesKubeletReady",
					fmt.Sprintf("EtcdAddLearnerSucceeded(%d) before kubelet ready", mid))
			}
			st.etcdRegistered = true
			st.phase = "WaitForEtcdQuorum"
		case "EtcdQuorumReady":
			st.phase = "MarkControlPlaneReady"
		case "MarkReady":
			st.phase = "JoinComplete"
		case "JoinFailedAt":
			reason, _ := r.AsString("reason")
			if reason == "LearnerStuckOnPromote" && !st.etcdRegistered {
				return failed(r, "StuckLearnerImpliesEtcdRegistered",
					fmt.Sprintf("JoinFailedAt(LearnerStuckOnPromote) on machine=%d but etcd not registered", mid))
			}
			st.phase = "JoinFailed"
			st.failureReason = reason
		}
	}

	if !saw {
		return trace.Verdict{Kind: trace.VerdictInapplicable, Spec: trace.SpecKubeadmJoin}
	}
	return trace.Verdict{Kind: trace.VerdictOK, Spec: trace.SpecKubeadmJoin}
}
