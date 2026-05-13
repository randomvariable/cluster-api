// Copyright 2026 The Kubernetes Authors.
//
// ScalabilityEnvelope.qnt — issue #102.
//
// This module is the lightweight harness for the verify-envelope
// Make target: it provides a deterministically-scalable spec with
// a tunable `N` (the cardinality of the state space) so the
// envelope-measurement script has a controlled subject. The real
// envelope measurement scripts (formal/scripts/verify-envelope.sh)
// iterate `quint verify --max-steps=4..N` and record
// (depth, time, memory) per spec under measurement.
//
// The model is a trivial counter with parameterised wrap-around;
// state size scales linearly with N. Empirical depth × time
// curves can be compared across N.

module ScalabilityEnvelope {

  pure val N: int = 20

  var counter: int

  action init = all {
    counter' = 0,
  }

  action Inc: bool = all {
    counter < N,
    counter' = counter + 1,
  }

  action Wrap: bool = all {
    counter == N,
    counter' = 0,
  }

  action step = any {
    Inc,
    Wrap,
  }

  val CounterBounded = counter >= 0 and counter <= N
}
