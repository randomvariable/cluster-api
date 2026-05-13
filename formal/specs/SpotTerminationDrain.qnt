// Copyright 2026 The Kubernetes Authors.
//
// SpotTerminationDrain.qnt — issue #62 (FM-62).
//
// Cloud sends a 2-minute spot termination notice on a CP Machine.
// CAPI doesn't begin (or finish) drain within the notice window;
// the cloud hard-terminates the instance with workloads still
// running. Etcd member dies abruptly; quorum risk.
//
// Time is discretised as ticks. A "two-minute notice" is modelled
// as a deadline `notice_deadline = 12 ticks` (default; one tick
// ≈ 10 s of wall clock).

module SpotTerminationDrain {

  type DrainState = NotStarted | InProgress | Drained | HardTerminated

  pure val MACHINES: Set[int] = 1.to(3)
  pure val NOTICE_DEADLINE: int = 12

  var drain: int -> DrainState
  var noticeTick: int -> int      // tick the spot notice was received; 0 = no notice
  var clock: int

  action init = all {
    drain' = MACHINES.mapBy(_ => NotStarted),
    noticeTick' = MACHINES.mapBy(_ => 0),
    clock' = 1,           // clock starts at 1 so 0 means "no notice yet"
  }

  action Tick: bool = all {
    clock' = clock + 1,
    drain' = drain,
    noticeTick' = noticeTick,
  }

  action SpotNoticeReceived(m: int): bool = all {
    MACHINES.contains(m),
    noticeTick.get(m) == 0,
    drain.get(m) == NotStarted,
    noticeTick' = noticeTick.put(m, clock),
    drain' = drain,
    clock' = clock,
  }

  action DrainBegins(m: int): bool = all {
    MACHINES.contains(m),
    drain.get(m) == NotStarted,
    drain' = drain.put(m, InProgress),
    noticeTick' = noticeTick,
    clock' = clock,
  }

  action DrainCompletes(m: int): bool = all {
    MACHINES.contains(m),
    drain.get(m) == InProgress,
    drain' = drain.put(m, Drained),
    noticeTick' = noticeTick,
    clock' = clock,
  }

  // Cloud hard-terminates the node when the deadline elapses,
  // regardless of drain progress. The bad case: drain != Drained.
  action HardTerminate(m: int): bool = all {
    MACHINES.contains(m),
    noticeTick.get(m) > 0,
    clock - noticeTick.get(m) >= NOTICE_DEADLINE,
    drain.get(m) != HardTerminated,
    drain' = drain.put(m, HardTerminated),
    noticeTick' = noticeTick,
    clock' = clock,
  }

  action step = any {
    Tick,
    nondet m = MACHINES.oneOf(); SpotNoticeReceived(m),
    nondet m = MACHINES.oneOf(); DrainBegins(m),
    nondet m = MACHINES.oneOf(); DrainCompletes(m),
    nondet m = MACHINES.oneOf(); HardTerminate(m),
  }

  // The bad outcome: a Machine is HardTerminated without ever
  // reaching Drained. Violated by the buggy regime where drain
  // begins too late.
  val DrainCompletesBeforeTerminate =
    MACHINES.forall(m =>
      drain.get(m) != HardTerminated or
      (m.in(MACHINES) and drain.get(m) == HardTerminated and false))

  // Phrased as a positive: every HardTerminated Machine was Drained
  // first. We do not track that history directly; we approximate
  // by asserting drain.get(m) != HardTerminated (Drained is a
  // pre-state; HardTerminated overwrites). The negative phrasing
  // is the witness.
  val NoHardTerminate = MACHINES.forall(m => drain.get(m) != HardTerminated)

  // Counterexample run: spot notice arrives at t=0, drain never
  // begins, deadline elapses, HardTerminate fires.
  run hardTerminateUngracefulRun = init
    .then(SpotNoticeReceived(1))
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(HardTerminate(1))
    // NoHardTerminate is now false.

  // Recovery run: drain begins and completes before the deadline.
  run gracefulDrainRun = init
    .then(SpotNoticeReceived(1))
    .then(DrainBegins(1))
    .then(Tick).then(Tick).then(Tick).then(Tick)
    .then(DrainCompletes(1))
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    // m=1 reaches Drained before t=NOTICE_DEADLINE.

}
