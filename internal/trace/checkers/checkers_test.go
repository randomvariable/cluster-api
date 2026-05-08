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

package checkers_test

import (
	"testing"

	"sigs.k8s.io/cluster-api/internal/trace"
	"sigs.k8s.io/cluster-api/internal/trace/checkers"
)

func rec(seq uint64, spec trace.SpecModule, action trace.Action, vars map[string]any) trace.TraceRecord {
	return trace.TraceRecord{Seq: seq, Spec: spec, Action: action, Vars: vars}
}

func TestEtcdMembership_HappyPromote(t *testing.T) {
	tr := []trace.TraceRecord{
		rec(1, trace.SpecEtcdMembership, "ElectLeader", map[string]any{"candidate": float64(1), "term": float64(1)}),
		rec(2, trace.SpecEtcdMembership, "AddLearner", map[string]any{"id": float64(4)}),
		rec(3, trace.SpecEtcdMembership, "ObserveLearnerProgress", map[string]any{"id": float64(4), "progress": "Eligible"}),
		rec(4, trace.SpecEtcdMembership, "PromoteLearner", map[string]any{"id": float64(4)}),
	}
	v := checkers.EtcdMembership{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected OK, got %s", v)
	}
}

func TestEtcdMembership_PromoteWithoutEligibleFails(t *testing.T) {
	tr := []trace.TraceRecord{
		rec(1, trace.SpecEtcdMembership, "ElectLeader", map[string]any{"candidate": float64(1), "term": float64(1)}),
		rec(2, trace.SpecEtcdMembership, "AddLearner", map[string]any{"id": float64(4)}),
		// progress remains LaggingFar — promote is illegal.
		rec(3, trace.SpecEtcdMembership, "PromoteLearner", map[string]any{"id": float64(4)}),
	}
	v := checkers.EtcdMembership{}.Check(tr)
	if !v.IsFailure() {
		t.Fatalf("expected failure, got %s", v)
	}
	if v.Invariant != "PromotionEligibility" {
		t.Fatalf("expected PromotionEligibility, got %q", v.Invariant)
	}
}

func TestKubeadmJoin_StuckLearnerRequiresEtcdRegistered(t *testing.T) {
	tr := []trace.TraceRecord{
		rec(1, trace.SpecKubeadmJoin, "BeginJoin", map[string]any{"machine": float64(2)}),
		rec(2, trace.SpecKubeadmJoin, "PreflightPass", map[string]any{"machine": float64(2)}),
		rec(3, trace.SpecKubeadmJoin, "KubeletStarted", map[string]any{"machine": float64(2)}),
		// Note: no EtcdAddLearnerSucceeded.
		rec(4, trace.SpecKubeadmJoin, "JoinFailedAt", map[string]any{"machine": float64(2), "reason": "LearnerStuckOnPromote"}),
	}
	v := checkers.KubeadmJoin{}.Check(tr)
	if !v.IsFailure() {
		t.Fatalf("expected failure (stuck-learner without etcd registration), got %s", v)
	}
}

func TestKubeadmJoin_IncidentShapeOK(t *testing.T) {
	// The actual incident: kubelet starts, etcd learner registers,
	// then promotion stalls and join fails. The checker should
	// accept this as well-formed (the bug is elsewhere — the
	// fact that the trace records this transition correctly is
	// itself OK).
	tr := []trace.TraceRecord{
		rec(1, trace.SpecKubeadmJoin, "BeginJoin", map[string]any{"machine": float64(2)}),
		rec(2, trace.SpecKubeadmJoin, "PreflightPass", map[string]any{"machine": float64(2)}),
		rec(3, trace.SpecKubeadmJoin, "KubeletStarted", map[string]any{"machine": float64(2)}),
		rec(4, trace.SpecKubeadmJoin, "EtcdAddLearnerSucceeded", map[string]any{"machine": float64(2)}),
		rec(5, trace.SpecKubeadmJoin, "JoinFailedAt", map[string]any{"machine": float64(2), "reason": "LearnerStuckOnPromote"}),
	}
	v := checkers.KubeadmJoin{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected OK, got %s", v)
	}
}

func TestKCPReconcile_BlockedByMatchOK(t *testing.T) {
	// A new Machine joins without a NodeRef; remediation is
	// requested; evaluation blocks it. The checker accepts.
	tr := []trace.TraceRecord{
		rec(1, trace.SpecKCPReconcile, "AddMachine", map[string]any{"machine": float64(1)}),
		rec(2, trace.SpecKCPReconcile, "AddMachine", map[string]any{"machine": float64(2)}),
		rec(3, trace.SpecKCPReconcile, "AddMachine", map[string]any{"machine": float64(3)}),
		rec(4, trace.SpecKCPReconcile, "ResolveNodeRef", map[string]any{"machine": float64(1)}),
		rec(5, trace.SpecKCPReconcile, "ResolveNodeRef", map[string]any{"machine": float64(2)}),
		// Machine 3 deliberately has no NodeRef.
		rec(6, trace.SpecKCPReconcile, "AddMachine", map[string]any{"machine": float64(4)}),
		rec(7, trace.SpecKCPReconcile, "RequestRemediation", map[string]any{"machine": float64(4)}),
		rec(8, trace.SpecKCPReconcile, "EvaluateCanSafelyRemediate", map[string]any{"machine": float64(4)}),
	}
	v := checkers.KCPReconcile{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected OK, got %s", v)
	}
}

func TestMHC_IncidentInformativenessFails(t *testing.T) {
	tr := []trace.TraceRecord{
		rec(1, trace.SpecMachineHealthCheck, "Observe", map[string]any{
			"machine": float64(2), "observation": "UnreachableTimeout",
		}),
		rec(2, trace.SpecMachineHealthCheck, "DeriveCondition", map[string]any{
			"machine":           float64(2),
			"v1beta1MessageTag": "failed to get etcdStatus: context deadline exceeded",
			"v1beta2MessageTag": "Please check controller logs for errors",
		}),
	}
	v := checkers.MHC{}.Check(tr)
	if !v.IsFailure() {
		t.Fatalf("expected InformativenessLocal failure, got %s", v)
	}
	if v.Invariant != "InformativenessLocal" {
		t.Fatalf("expected InformativenessLocal, got %q", v.Invariant)
	}
}

func TestMHC_HappyPathOK(t *testing.T) {
	tr := []trace.TraceRecord{
		rec(1, trace.SpecMachineHealthCheck, "Observe", map[string]any{
			"machine": float64(2), "observation": "ReachableHealthy",
		}),
		rec(2, trace.SpecMachineHealthCheck, "DeriveCondition", map[string]any{
			"machine":           float64(2),
			"v1beta1MessageTag": "",
			"v1beta2MessageTag": "",
		}),
	}
	v := checkers.MHC{}.Check(tr)
	if v.IsFailure() {
		t.Fatalf("expected OK, got %s", v)
	}
}
