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
	"bufio"
	"encoding/json"
	"fmt"
	"io"
)

// LoadJSONLines reads a JSON-Lines trace from `r` and returns the
// parsed records. Lines that fail to parse are returned as an
// error pointing at the offending line number; the caller MAY
// inspect partial output via the returned slice.
func LoadJSONLines(r io.Reader) ([]TraceRecord, error) {
	out := make([]TraceRecord, 0, 256)
	sc := bufio.NewScanner(r)
	// Allow long lines — production traces can carry verbose Vars.
	sc.Buffer(make([]byte, 64*1024), 4*1024*1024)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		rec, err := UnmarshalLine(line)
		if err != nil {
			return out, fmt.Errorf("line %d: %w", lineNo, err)
		}
		out = append(out, *rec)
	}
	if err := sc.Err(); err != nil {
		return out, fmt.Errorf("scan: %w", err)
	}
	return out, nil
}

// LoadITF parses a Quint-emitted Informal Trace Format (ITF) JSON
// document and converts it to a slice of TraceRecord. The ITF
// document's `states` array encodes one state per element; we
// emit one TraceRecord per state-transition with action and vars
// recovered from the state's `#meta.action` field where
// available.
//
// This adapter is intentionally permissive: a Quint trace
// emitted with `quint run --out-itf=trace.itf.json` is the
// canonical input for the off-line trace-validator CLI.
func LoadITF(r io.Reader) ([]TraceRecord, error) {
	type itfMeta struct {
		Action string         `json:"action"`
		Args   map[string]any `json:"args,omitempty"`
	}
	type itfState struct {
		Meta *itfMeta       `json:"#meta,omitempty"`
		Vars map[string]any `json:"vars,omitempty"`
	}
	type itfDoc struct {
		Vars   []string   `json:"vars"`
		States []itfState `json:"states"`
	}
	var doc itfDoc
	if err := json.NewDecoder(r).Decode(&doc); err != nil {
		return nil, fmt.Errorf("decode itf: %w", err)
	}
	out := make([]TraceRecord, 0, len(doc.States))
	for i, s := range doc.States {
		rec := TraceRecord{
			Seq: uint64(i + 1),
		}
		if s.Meta != nil {
			rec.Action = Action(s.Meta.Action)
			if s.Meta.Args != nil {
				rec.Vars = s.Meta.Args
			}
		}
		// Quint ITF doesn't tag the spec module on a state, so
		// the consumer must cross-reference action names against
		// formal/abstraction-mapping.md to disambiguate. The
		// off-line validator does this.
		out = append(out, rec)
	}
	return out, nil
}
