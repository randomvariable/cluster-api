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

package trace_test

import (
	"bytes"
	"sync"
	"testing"
	"time"

	"sigs.k8s.io/cluster-api/internal/chaos"
	"sigs.k8s.io/cluster-api/internal/trace"
)

// TestRecorder_ConcurrentUseUnderChaos exercises
// JSONLinesRecorder under high concurrency with chaos sleeps
// inserted at strategic points. Run with `go test -race` to
// detect goroutine-level races: the recorder uses a sync.Mutex
// + atomic.Uint64 + bufio.Writer, all of which `-race` will
// flag if accessed without proper happens-before.
//
// This is the canonical chaos-under-race scenario for issue #12.
// The trace recorder is a load-bearing primitive (it sits on
// the hot path of every reconcile when formal tracing is on),
// so its race-cleanliness gates everything downstream.
func TestRecorder_ConcurrentUseUnderChaos(t *testing.T) {
	t.Parallel()

	eng := chaos.NewEngine(t, chaos.Profile{
		SleepProbability: 0.10,
		SleepMaxJitter:   500 * time.Microsecond,
	})
	defer eng.Stop()

	const (
		numWriters     = 16
		recordsPerGoroutine = 64
	)

	// A bytes.Buffer is NOT safe for concurrent writes — that's
	// the recorder's responsibility to serialise. If the
	// recorder's mutex is wrong, -race will report on the buffer
	// access. (The recorder writes to its own bufio.Writer; the
	// underlying io.Writer is the buffer.)
	var buf bytes.Buffer
	r := trace.NewJSONLinesRecorder(&buf, func() time.Time { return time.Unix(0, 0) })

	var wg sync.WaitGroup
	wg.Add(numWriters)
	for w := 0; w < numWriters; w++ {
		go func(id int) {
			defer wg.Done()
			for i := 0; i < recordsPerGoroutine; i++ {
				eng.MaybeSleep()
				if err := r.Record(
					trace.SpecEtcdMembership,
					"AddLearner",
					"chaos-test",
					map[string]any{"id": uint64(id*1000 + i)},
				); err != nil {
					t.Errorf("Record returned: %v", err)
					return
				}
			}
		}(w)
	}
	wg.Wait()

	// Validate the resulting JSONL — every line should parse,
	// and the record count must equal numWriters × recordsPerGoroutine.
	records, err := trace.LoadJSONLines(&buf)
	if err != nil {
		t.Fatalf("LoadJSONLines: %v", err)
	}
	expected := numWriters * recordsPerGoroutine
	if got := len(records); got != expected {
		t.Errorf("record count: got %d want %d", got, expected)
	}

	// Sequence numbers must be a permutation of [1..N].
	seen := make(map[uint64]bool, expected)
	for _, rec := range records {
		if rec.Seq == 0 || rec.Seq > uint64(expected) {
			t.Errorf("Seq out of range: %d (expected 1..%d)", rec.Seq, expected)
			continue
		}
		if seen[rec.Seq] {
			t.Errorf("duplicate Seq %d — atomic counter regressed", rec.Seq)
		}
		seen[rec.Seq] = true
	}
}

// TestRecorder_ChaosWithNilEngineIsNoop confirms that the
// chaos primitives are safe to invoke when the engine is nil
// (production code path). This guards against a future change
// that introduces a nil dereference in MaybeSleep / MaybePanic.
func TestRecorder_ChaosWithNilEngineIsNoop(t *testing.T) {
	t.Parallel()

	var eng *chaos.Engine // nil
	for i := 0; i < 100; i++ {
		eng.MaybeSleep()
		eng.MaybePanic("never")
	}
	eng.Stop()
}
