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
	"context"
	"sync"
)

// StreamingRecorder is a Recorder that fan-outs every record to a
// set of subscribers in real time. Each subscriber gets the
// complete prefix-history as records arrive — i.e. it can run
// per-record incremental checking without re-loading the trace
// from disk.
//
// Use case (issue #103): a chaos-driven test injects faults via
// docker pause / tc qdisc; the trace recorder observes; a
// streaming checker consumes the trace in real time and produces
// verdicts before the test finishes. Operators / CI get
// immediate feedback on invariant violations.
type StreamingRecorder struct {
	mu          sync.Mutex
	inner       Recorder
	subscribers []chan<- TraceRecord
	closed      bool
}

// NewStreamingRecorder wraps an existing Recorder with fan-out.
// Records pass through to the wrapped recorder; a copy is sent
// to every subscriber channel.
func NewStreamingRecorder(inner Recorder) *StreamingRecorder {
	if inner == nil {
		inner = Discard
	}
	return &StreamingRecorder{inner: inner}
}

// Subscribe returns a receive channel that yields every record
// from now on. The channel must be drained — slow subscribers
// block the recorder. Use a buffered channel and a worker
// goroutine for soft real-time.
//
// The returned context-cancellation function unsubscribes the
// caller and closes the channel.
func (r *StreamingRecorder) Subscribe(buffer int) (<-chan TraceRecord, func()) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		ch := make(chan TraceRecord)
		close(ch)
		return ch, func() {}
	}
	ch := make(chan TraceRecord, buffer)
	r.subscribers = append(r.subscribers, ch)
	cancel := func() {
		r.mu.Lock()
		defer r.mu.Unlock()
		for i, sub := range r.subscribers {
			if sub == ch {
				r.subscribers = append(r.subscribers[:i], r.subscribers[i+1:]...)
				close(ch)
				return
			}
		}
	}
	return ch, cancel
}

// Record forwards to the inner Recorder, then fans out the
// resulting record to every subscriber.
func (r *StreamingRecorder) Record(spec SpecModule, action Action, subject string, vars map[string]any) error {
	rec := TraceRecord{Spec: spec, Action: action, Subject: subject, Vars: vars}
	if err := r.inner.Record(spec, action, subject, vars); err != nil {
		return err
	}
	r.mu.Lock()
	subs := append([]chan<- TraceRecord{}, r.subscribers...)
	r.mu.Unlock()
	for _, sub := range subs {
		// Non-blocking send: drop on slow subscriber.
		select {
		case sub <- rec:
		default:
		}
	}
	return nil
}

// Close closes the inner recorder and every subscriber channel.
// Subsequent Record calls return immediately.
func (r *StreamingRecorder) Close() error {
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return nil
	}
	r.closed = true
	subs := r.subscribers
	r.subscribers = nil
	r.mu.Unlock()
	for _, sub := range subs {
		close(sub)
	}
	return r.inner.Close()
}

// StreamingCheck runs a Checker incrementally against records
// arriving on `ch`. Each record appends to the running prefix
// and the checker re-checks. The returned channel yields one
// Verdict per checker re-run; close `ctx` to stop.
//
// The function does not own `ch` — callers MUST close (e.g. via
// StreamingRecorder.Close()) for the loop to exit.
func StreamingCheck(ctx context.Context, ch <-chan TraceRecord, c Checker) <-chan Verdict {
	out := make(chan Verdict, 16)
	go func() {
		defer close(out)
		var history []TraceRecord
		for {
			select {
			case <-ctx.Done():
				return
			case rec, ok := <-ch:
				if !ok {
					// Final verdict on the full history.
					if len(history) > 0 {
						out <- c.Check(history)
					}
					return
				}
				history = append(history, rec)
				v := c.Check(history)
				if v.IsFailure() {
					// Stream failures out for immediate operator
					// feedback; keep going so we also produce a
					// final verdict on close.
					out <- v
				}
			}
		}
	}()
	return out
}
