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
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// Recorder accepts TraceRecord events and persists them. Two
// implementations live in this file: a discarding recorder
// (zero-cost when the formal-trace feature is off) and a
// JSON-Lines recorder that streams to an io.Writer.
//
// Recorders MUST be safe for concurrent use; controllers run
// many reconcile loops in parallel.
type Recorder interface {
	Record(spec SpecModule, action Action, subject string, vars map[string]any) error
	Close() error
}

// Discard is a Recorder that drops every record. Use this in
// production code paths where the formal-trace feature is off,
// so the call sites are uniform regardless of mode.
var Discard Recorder = discardRecorder{}

type discardRecorder struct{}

func (discardRecorder) Record(SpecModule, Action, string, map[string]any) error { return nil }
func (discardRecorder) Close() error                                            { return nil }

// JSONLinesRecorder writes one TraceRecord per line to the
// configured io.Writer. The writer is held under a mutex; each
// Record call is one MarshalLine + Write under the lock.
type JSONLinesRecorder struct {
	mu  sync.Mutex
	out io.Writer
	seq uint64
	now func() time.Time
}

// NewJSONLinesRecorder returns a Recorder that streams records
// as JSON Lines to `w`. The `now` parameter is exposed so tests
// can inject deterministic timestamps; pass time.Now in
// production.
func NewJSONLinesRecorder(w io.Writer, now func() time.Time) *JSONLinesRecorder {
	if now == nil {
		now = time.Now
	}
	return &JSONLinesRecorder{out: w, now: now}
}

// Record assigns a sequence number, marshals the record to a
// JSON line, and writes it. Returns the underlying writer's
// error verbatim — controllers SHOULD log and continue rather
// than fail their reconcile.
func (r *JSONLinesRecorder) Record(spec SpecModule, action Action, subject string, vars map[string]any) error {
	rec := TraceRecord{
		Seq:     atomic.AddUint64(&r.seq, 1),
		Time:    r.now(),
		Spec:    spec,
		Action:  action,
		Subject: subject,
		Vars:    vars,
	}
	line, err := rec.MarshalLine()
	if err != nil {
		return err
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	_, err = r.out.Write(line)
	return err
}

// Close is a no-op on the underlying writer; callers own the
// writer's lifecycle.
func (r *JSONLinesRecorder) Close() error { return nil }
