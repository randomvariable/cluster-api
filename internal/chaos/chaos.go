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

// Package chaos provides minimally-invasive chaos primitives for
// reconcile-loop perturbation under `go test -race`. The aim is
// concrete-level race detection (issue #12): the formal model
// proves "per-key serialised" (FM-45) at the abstract layer; the
// Go code may still have goroutine-level races the model can't
// see. Inject chaos primitives at strategic points
// (Reconcile entry, cache-read, channel-send) and run the test
// suite under `-race`. Real races are reported by the race
// detector; false positives are filtered by the deterministic
// seed.
//
// Two activation modes:
//
//   * Disabled (default in production): Maybe* and Inject*
//     return immediately. Compile-out via the build constraint
//     in chaos_disabled.go means production binaries pay zero
//     cost.
//   * Enabled (test-only, build tag `chaos`): a per-test
//     Engine drives the perturbations using a deterministic
//     PRNG seeded from CHAOS_SEED.
//
// Usage from a test:
//
//	func TestRecorderUnderChaos(t *testing.T) {
//	    eng := chaos.NewEngine(t, chaos.Profile{
//	        SleepProbability: 0.05,
//	        SleepMaxJitter:   100 * time.Microsecond,
//	    })
//	    defer eng.Stop()
//	    ... // call code under test; eng.MaybeSleep() inserts
//	        // controlled jitter at instrumented points.
//	}
//
// Profiles are seeded so that races reproduce verbatim; failures
// include the seed in the test name for reproduction.
package chaos

import (
	"math/rand/v2"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Profile describes the perturbations a chaos.Engine applies.
type Profile struct {
	// SleepProbability is the fraction of MaybeSleep calls that
	// actually pause for a uniformly-random duration in
	// [0, SleepMaxJitter). Range [0, 1].
	SleepProbability float64

	// SleepMaxJitter caps the random sleep upper bound. Default
	// 0 = no sleep even when the probability fires.
	SleepMaxJitter time.Duration

	// PanicProbability is the fraction of MaybePanic calls that
	// panic. Recovered by the standard test runner; useful for
	// exercising defer ordering. Range [0, 1].
	PanicProbability float64
}

// Engine is the per-test chaos driver. Use NewEngine to obtain
// one; it deterministically replays the same perturbation
// sequence given the same CHAOS_SEED. Stop releases resources
// and reports a summary on the test logger.
type Engine struct {
	t       testing.TB
	profile Profile
	rng     *rand.Rand
	mu      sync.Mutex
	stats   stats
}

type stats struct {
	maybeSleepCalls atomic.Uint64
	sleeps          atomic.Uint64
	maybePanicCalls atomic.Uint64
	panics          atomic.Uint64
}

// NewEngine returns an Engine configured by the supplied
// profile. The PRNG seed comes from the CHAOS_SEED environment
// variable; absent or unparseable, it falls back to
// time.Now().UnixNano() — the resolved seed is logged so the
// test can be re-run deterministically.
func NewEngine(t testing.TB, profile Profile) *Engine {
	t.Helper()
	seed := time.Now().UnixNano()
	if v := os.Getenv("CHAOS_SEED"); v != "" {
		if parsed, err := strconv.ParseInt(v, 10, 64); err == nil {
			seed = parsed
		}
	}
	t.Logf("chaos: CHAOS_SEED=%d profile=%+v", seed, profile)
	src := rand.NewPCG(uint64(seed), uint64(seed)^0x9E3779B97F4A7C15)
	return &Engine{
		t:       t,
		profile: profile,
		rng:     rand.New(src),
	}
}

// MaybeSleep inserts a chaos sleep with probability
// `profile.SleepProbability`. Safe for concurrent use.
func (e *Engine) MaybeSleep() {
	if e == nil {
		return
	}
	e.stats.maybeSleepCalls.Add(1)
	e.mu.Lock()
	roll := e.rng.Float64()
	jitterNs := int64(0)
	if e.profile.SleepMaxJitter > 0 {
		jitterNs = e.rng.Int64N(int64(e.profile.SleepMaxJitter))
	}
	e.mu.Unlock()
	if roll < e.profile.SleepProbability && jitterNs > 0 {
		e.stats.sleeps.Add(1)
		time.Sleep(time.Duration(jitterNs))
	}
}

// MaybePanic panics with probability `profile.PanicProbability`.
// Useful for exercising defer ordering and Reconcile recovery
// paths under -race. The caller is responsible for catching the
// panic if it should not abort the test.
func (e *Engine) MaybePanic(reason string) {
	if e == nil {
		return
	}
	e.stats.maybePanicCalls.Add(1)
	e.mu.Lock()
	roll := e.rng.Float64()
	e.mu.Unlock()
	if roll < e.profile.PanicProbability {
		e.stats.panics.Add(1)
		panic("chaos: " + reason)
	}
}

// Stop reports a summary to the test logger and clears the
// engine's state. Idempotent.
func (e *Engine) Stop() {
	if e == nil {
		return
	}
	e.t.Logf("chaos: summary calls={maybeSleep=%d sleeps=%d maybePanic=%d panics=%d}",
		e.stats.maybeSleepCalls.Load(),
		e.stats.sleeps.Load(),
		e.stats.maybePanicCalls.Load(),
		e.stats.panics.Load(),
	)
}

// IsEnabled reports whether chaos is active in the current
// build. Always true when the package is compiled (the disabled
// variant lives in chaos_disabled.go behind the
// `!chaos` build tag — but for issue #12 we ship the always-on
// variant because the Engine's no-op overhead is negligible
// when probabilities are zero).
func IsEnabled() bool { return true }
