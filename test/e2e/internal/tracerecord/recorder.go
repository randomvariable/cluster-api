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

// Package tracerecord wires the formal-model recorder
// (sigs.k8s.io/cluster-api/internal/trace) into the CAPD e2e
// harness. The recorder writes JSON-Lines trace files to the
// per-test artifact folder; after the suite finishes, the
// trace-validator binary at hack/tools/trace-validator/ ingests
// each file and runs every checker in
// internal/trace/checkers/ against the recorded events.
//
// Recording is deliberately observer-style: the e2e test reads
// Kubernetes object state via the management cluster proxy and
// emits a TraceRecord whenever it observes a spec-relevant
// transition. The CAPI controllers themselves are not modified.
// This costs some refinement fidelity (the test sees object
// state, not reconcile-internal events) but keeps the scope
// strictly inside the test harness — exactly what the issue
// scoping calls out as "no recorder-call in upstream code".
//
// Lifecycle:
//
//   r, closeFn := tracerecord.Start(artifactFolder, "fm2-quorum-loss")
//   defer closeFn()
//   r.Bootstrap(voters)
//   ... (more events as the test progresses)
//
// The closeFn flushes the buffered writer and closes the
// underlying file. Tests SHOULD defer it; if they don't, the
// finalizer-style fail-safe in the suite-level After hook will
// close any leaked recorders.
package tracerecord

import (
	"bufio"
	"fmt"
	"hash/fnv"
	"os"
	"path/filepath"
	"sync"

	"sigs.k8s.io/cluster-api/internal/trace"
)

// E2ERecorder wraps a trace.JSONLinesRecorder with helpers that
// emit the action shapes the existing checkers in
// internal/trace/checkers/ expect.
type E2ERecorder struct {
	mu       sync.Mutex
	inner    *trace.JSONLinesRecorder
	file     *os.File
	bufw     *bufio.Writer
	path     string
	scenario string
}

// Start creates a recorder writing to
// `<artifactFolder>/trace/<scenario>.trace.jsonl`. The artifact
// folder is created if absent. Returns the recorder and a
// close-and-flush function suitable for `defer`.
func Start(artifactFolder, scenario string) (*E2ERecorder, func() error, error) {
	dir := filepath.Join(artifactFolder, "trace")
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, nil, fmt.Errorf("mkdir %s: %w", dir, err)
	}
	path := filepath.Join(dir, scenario+".trace.jsonl")
	f, err := os.Create(path)
	if err != nil {
		return nil, nil, fmt.Errorf("create %s: %w", path, err)
	}
	bufw := bufio.NewWriterSize(f, 16*1024)
	r := &E2ERecorder{
		inner:    trace.NewJSONLinesRecorder(bufw, nil),
		file:     f,
		bufw:     bufw,
		path:     path,
		scenario: scenario,
	}
	return r, r.Close, nil
}

// Path returns the absolute path the recorder is writing to.
// Useful for the suite-level After hook that runs the validator.
func (r *E2ERecorder) Path() string { return r.path }

// Close flushes the buffer and closes the file. Safe to call
// multiple times; subsequent calls are no-ops.
func (r *E2ERecorder) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.file == nil {
		return nil
	}
	flushErr := r.bufw.Flush()
	closeErr := r.file.Close()
	r.file = nil
	if flushErr != nil {
		return flushErr
	}
	return closeErr
}

// VoterIDFromNodeRef hashes a Kubernetes Node name into a stable
// uint64 voter ID. The EtcdMembership checker treats voter IDs
// as opaque uint64s; what matters is that the same Node maps to
// the same ID across records in a single trace.
func VoterIDFromNodeRef(nodeName string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(nodeName))
	return h.Sum64()
}

// Bootstrap records the initial voter set. Every recorded trace
// for an FM-* scenario MUST start with one Bootstrap; the
// EtcdMembership checker treats the voters as the seed members.
func (r *E2ERecorder) Bootstrap(nodeNames []string) error {
	voters := make([]string, 0, len(nodeNames))
	for _, n := range nodeNames {
		voters = append(voters, fmt.Sprintf("%d", VoterIDFromNodeRef(n)))
	}
	return r.inner.Record(
		trace.SpecEtcdMembership,
		"Bootstrap",
		"",
		map[string]any{
			"voters": voters,
		},
	)
}

// RemoveMember records that an etcd member has been removed
// (e.g. during a Machine deletion). The EtcdMembership checker
// will refuse the record if the resulting state would violate
// VoterSetNonEmpty.
func (r *E2ERecorder) RemoveMember(nodeName string) error {
	return r.inner.Record(
		trace.SpecEtcdMembership,
		"RemoveMember",
		nodeName,
		map[string]any{
			"id": VoterIDFromNodeRef(nodeName),
		},
	)
}

// AddLearner records a learner addition (e.g. during scale-up).
func (r *E2ERecorder) AddLearner(nodeName string) error {
	return r.inner.Record(
		trace.SpecEtcdMembership,
		"AddLearner",
		nodeName,
		map[string]any{
			"id": VoterIDFromNodeRef(nodeName),
		},
	)
}

// PromoteLearner records a learner-to-voter promotion. The
// checker requires a prior `ObserveLearnerProgress(.., Eligible)`
// for the same id.
func (r *E2ERecorder) PromoteLearner(nodeName string) error {
	return r.inner.Record(
		trace.SpecEtcdMembership,
		"PromoteLearner",
		nodeName,
		map[string]any{
			"id": VoterIDFromNodeRef(nodeName),
		},
	)
}

// ObserveLearnerProgress records an observation of a learner's
// raft progress, e.g. "Eligible" once the learner is in sync.
func (r *E2ERecorder) ObserveLearnerProgress(nodeName, progress string) error {
	return r.inner.Record(
		trace.SpecEtcdMembership,
		"ObserveLearnerProgress",
		nodeName,
		map[string]any{
			"id":       VoterIDFromNodeRef(nodeName),
			"progress": progress,
		},
	)
}

// ReadGate records the remediation gate's admission-time snapshot.
func (r *E2ERecorder) ReadGate(machine string, voters []string, inFlightCount int, result bool, targetIsLearner bool, admissionVoterCount int) error {
	return r.inner.Record(
		trace.SpecRemediation,
		"ReadGate",
		machine,
		map[string]any{
			"member":               machine,
			"voterSet":             voters,
			"inFlightCount":        inFlightCount,
			"result":               result,
			"targetIsLearner":      targetIsLearner,
			"admissionVoterCount":  admissionVoterCount,
		},
	)
}

// CommitAdmission records the CAS-checked commit-time state before an RPC.
func (r *E2ERecorder) CommitAdmission(machine string, freshVoters []string, freshTargetIsLearner bool) error {
	return r.inner.Record(
		trace.SpecRemediation,
		"CommitAdmission",
		machine,
		map[string]any{
			"member":               machine,
			"freshVoterSet":        freshVoters,
			"freshTargetIsLearner": freshTargetIsLearner,
		},
	)
}

// CommitAdmissionAborted records an expected CAS abort.
func (r *E2ERecorder) CommitAdmissionAborted(machine, reason string) error {
	return r.inner.Record(
		trace.SpecRemediation,
		"CommitAdmissionAborted",
		machine,
		map[string]any{
			"member": machine,
			"reason": reason,
		},
	)
}

// RemoveMemberRPC records that the actual etcd removal RPC was issued.
func (r *E2ERecorder) RemoveMemberRPC(machine string) error {
	return r.inner.Record(
		trace.SpecRemediation,
		"RemoveMemberRPC",
		machine,
		map[string]any{
			"member": machine,
		},
	)
}
