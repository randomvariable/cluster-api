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

import (
	"encoding/json"
	"fmt"
	"time"
)

// SpecModule names a Quint module declared in formal/specs/.
type SpecModule string

const (
	SpecEtcdMembership     SpecModule = "EtcdMembership"
	SpecKubeadmJoin        SpecModule = "KubeadmJoin"
	SpecKCPReconcile       SpecModule = "KCPReconcile"
	SpecMachineHealthCheck SpecModule = "MachineHealthCheck"
	SpecComposition        SpecModule = "Composition"
)

// Action names a Quint action within a SpecModule. Action names
// match the Quint source exactly; abstraction-mapping.md is the
// authoritative cross-reference.
type Action string

// TraceRecord is one observed transition in the running system.
// The wire format is JSON Lines (one record per line). Records
// are append-only; the recorder MUST NOT amend a previously
// emitted record.
type TraceRecord struct {
	// Seq is a monotonically increasing sequence number assigned
	// by the recorder. Checkers use Seq to tie failure messages
	// back to the offending record.
	Seq uint64 `json:"seq"`

	// Time is the wall-clock time at which the recorder accepted
	// the record. Used for diagnostic output only — invariants
	// MUST NOT depend on it because the trace's logical order is
	// the only sound order.
	Time time.Time `json:"time"`

	// Spec is the Quint module the action belongs to.
	Spec SpecModule `json:"spec"`

	// Action is the Quint action name.
	Action Action `json:"action"`

	// Vars carries the action's named parameters and any other
	// values the checker needs to reconstruct the post-state.
	// Values use JSON's natural mapping: strings, numbers,
	// booleans, arrays, objects. Sets are encoded as sorted
	// arrays; maps are encoded as JSON objects.
	Vars map[string]any `json:"vars,omitempty"`

	// Subject is an optional opaque identifier for the affected
	// object (e.g. a Machine's namespaced name). Useful for
	// grep-friendly diagnostic output.
	Subject string `json:"subject,omitempty"`
}

// MarshalLine renders the record as a single JSON line suitable
// for appending to a JSON-Lines file.
func (r *TraceRecord) MarshalLine() ([]byte, error) {
	b, err := json.Marshal(r)
	if err != nil {
		return nil, fmt.Errorf("marshal trace record seq=%d: %w", r.Seq, err)
	}
	return append(b, '\n'), nil
}

// UnmarshalLine parses one JSON line into a TraceRecord.
func UnmarshalLine(line []byte) (*TraceRecord, error) {
	var r TraceRecord
	if err := json.Unmarshal(line, &r); err != nil {
		return nil, fmt.Errorf("unmarshal trace record: %w", err)
	}
	return &r, nil
}

// AsUint64 reads a uint64-valued field from the record's Vars
// map, returning ok=false if absent or wrongly typed. Convenience
// for checker authors.
func (r *TraceRecord) AsUint64(key string) (val uint64, ok bool) {
	v, present := r.Vars[key]
	if !present {
		return 0, false
	}
	switch x := v.(type) {
	case float64:
		return uint64(x), true
	case int:
		return uint64(x), true
	case int64:
		return uint64(x), true
	case uint64:
		return x, true
	}
	return 0, false
}

// AsString reads a string-valued field from Vars.
func (r *TraceRecord) AsString(key string) (string, bool) {
	v, ok := r.Vars[key]
	if !ok {
		return "", false
	}
	s, isStr := v.(string)
	return s, isStr
}

// AsBool reads a bool-valued field from Vars.
func (r *TraceRecord) AsBool(key string) (bool, bool) {
	v, ok := r.Vars[key]
	if !ok {
		return false, false
	}
	b, isBool := v.(bool)
	return b, isBool
}

// AsStringSet reads a set-encoded-as-array field from Vars.
func (r *TraceRecord) AsStringSet(key string) ([]string, bool) {
	v, ok := r.Vars[key]
	if !ok {
		return nil, false
	}
	if a, isArr := v.([]string); isArr {
		out := make([]string, 0, len(a))
		out = append(out, a...)
		return out, true
	}
	a, isArr := v.([]any)
	if !isArr {
		return nil, false
	}
	out := make([]string, 0, len(a))
	for _, e := range a {
		s, isStr := e.(string)
		if !isStr {
			return nil, false
		}
		out = append(out, s)
	}
	return out, true
}
