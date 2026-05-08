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
	"strings"

	"sigs.k8s.io/cluster-api/internal/trace"
)

// MHC is a trace.Checker for formal/specs/MachineHealthCheck.qnt.
//
// Invariants enforced:
//
//   - InformativenessLocal — for every diagnostic key carried by
//     the v1beta1 message, the v1beta2 message MUST carry the
//     same key. The current v1beta2 projection violates this for
//     the `context deadline exceeded` and `no route to host`
//     keys; the user-reported incident produces a counterexample.
type MHC struct{}

// Spec returns trace.SpecMachineHealthCheck.
func (MHC) Spec() trace.SpecModule { return trace.SpecMachineHealthCheck }

// diagnosticKeys is the contractual set from
// formal/contracts/kcp-machine-contract.md §3.
var diagnosticKeys = []string{
	"context deadline exceeded",
	"no route to host",
	"no corresponding etcd member",
	"failed to get etcdStatus",
	"failed to connect to etcd",
}

// Check enforces the InformativenessLocal invariant for each
// DeriveCondition record encountered.
func (MHC) Check(records []trace.TraceRecord) trace.Verdict {
	saw := false
	for _, r := range records {
		if r.Spec != trace.SpecMachineHealthCheck {
			continue
		}
		saw = true
		if r.Action != "DeriveCondition" {
			continue
		}
		v1Msg, _ := r.AsString("v1beta1MessageTag")
		v2Msg, _ := r.AsString("v1beta2MessageTag")
		for _, k := range diagnosticKeys {
			if strings.Contains(v1Msg, k) && !strings.Contains(v2Msg, k) {
				return failed(r, "InformativenessLocal",
					fmt.Sprintf("v1beta1 carries %q but v1beta2 message %q does not", k, v2Msg))
			}
		}
	}
	if !saw {
		return trace.Verdict{Kind: trace.VerdictInapplicable, Spec: trace.SpecMachineHealthCheck}
	}
	return trace.Verdict{Kind: trace.VerdictOK, Spec: trace.SpecMachineHealthCheck}
}
