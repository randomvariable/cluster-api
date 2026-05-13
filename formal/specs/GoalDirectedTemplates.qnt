// Copyright 2026 The Kubernetes Authors.
//
// GoalDirectedTemplates.qnt — issue #101.
//
// Goal-directed Apalache uses a "find me a state where INV
// violates" mode. This module is an exemplar for the technique:
// it ships a documented INV (BadStateReachable) that *must* be
// reachable, plus a deterministic counterexample run that
// witnesses it. CI gates on:
//
//   1. quint run --init=expectedCounterexampleRun --invariant=BadStateReachable
//      MUST fail (BadStateReachable holds at the witness state).
//   2. apalache verify --invariant='not(BadStateReachable)'
//      MUST find a counterexample at depth <= 4.
//
// A regression in either direction (counterexample no longer
// reachable, or expected counterexample is broken) fails the
// gate.

module GoalDirectedTemplates {

  pure val FLAGS: Set[str] = Set("clean", "transient", "bad")

  var flag: str

  action init = all {
    flag' = "clean",
  }

  action GoTransient: bool = all {
    flag == "clean",
    flag' = "transient",
  }

  action GoBad: bool = all {
    flag == "transient",
    flag' = "bad",
  }

  action Recover: bool = all {
    flag == "transient" or flag == "bad",
    flag' = "clean",
  }

  action step = any {
    GoTransient,
    GoBad,
    Recover,
  }

  val BadStateReachable = flag == "bad"

  // Expected counterexample for the inverse property
  // ~BadStateReachable: the bad state IS reachable at depth 2.
  run expectedCounterexampleRun = init
    .then(GoTransient)
    .then(GoBad)
    // BadStateReachable now true; ~BadStateReachable violated.

  // Healthy run: the bad state is not reached.
  run cleanRun = init
    .then(GoTransient)
    .then(Recover)
    // BadStateReachable false.
}
