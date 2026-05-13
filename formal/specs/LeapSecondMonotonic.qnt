// Copyright 2026 The Kubernetes Authors.
//
// LeapSecondMonotonic.qnt — issue #64 (FM-64).
//
// A leap-second event causes a backward step in `wallClock` on
// some nodes. Timeouts computed as wall-clock differences may
// compute as negative or huge positives; heartbeat windows
// misfire.
//
// The model asserts that timeouts MUST be computed using
// `monotonicTime`, not `wallClock`. If a controller uses
// `wallClock` for a timeout, a leap second can make
// `now - lastObserved` negative — invariant violated.

module LeapSecondMonotonic {

  pure val NODES: Set[int] = 1.to(2)

  var monotonicTime: int
  var wallClock: int
  var heartbeatMonotonicAt: int -> int
  var heartbeatWallAt: int -> int

  action init = all {
    monotonicTime' = 0,
    wallClock' = 0,
    heartbeatMonotonicAt' = NODES.mapBy(_ => 0),
    heartbeatWallAt' = NODES.mapBy(_ => 0),
  }

  action Tick: bool = all {
    monotonicTime' = monotonicTime + 1,
    wallClock' = wallClock + 1,
    heartbeatMonotonicAt' = heartbeatMonotonicAt,
    heartbeatWallAt' = heartbeatWallAt,
  }

  // Leap-second event: wallClock goes backward, monotonicTime
  // does not.
  action LeapSecond: bool = all {
    wallClock' = wallClock - 1,
    monotonicTime' = monotonicTime,
    heartbeatMonotonicAt' = heartbeatMonotonicAt,
    heartbeatWallAt' = heartbeatWallAt,
  }

  action Heartbeat(n: int): bool = all {
    NODES.contains(n),
    heartbeatMonotonicAt' = heartbeatMonotonicAt.put(n, monotonicTime),
    heartbeatWallAt' = heartbeatWallAt.put(n, wallClock),
    monotonicTime' = monotonicTime,
    wallClock' = wallClock,
  }

  action step = any {
    Tick,
    LeapSecond,
    nondet n = NODES.oneOf(); Heartbeat(n),
  }

  // Positive invariant: `now - lastObserved` (computed using
  // monotonicTime) is never negative.
  val MonotonicTimeoutNonNegative =
    NODES.forall(n => monotonicTime - heartbeatMonotonicAt.get(n) >= 0)

  // Negative witness: `now - lastObserved` (computed using
  // wallClock) CAN be negative after a leap second.
  val WallclockTimeoutNonNegative =
    NODES.forall(n => wallClock - heartbeatWallAt.get(n) >= 0)

  run leapSecondMakesWallclockNegativeRun = init
    .then(Tick).then(Tick).then(Tick)
    .then(Heartbeat(1))
    .then(LeapSecond).then(LeapSecond)
    // wallClock now < heartbeatWallAt[1]; WallclockTimeoutNonNegative violated.

  run monotonicSurvivesLeapSecondRun = init
    .then(Tick).then(Tick).then(Tick)
    .then(Heartbeat(1))
    .then(LeapSecond).then(LeapSecond)
    .then(Tick)
    // MonotonicTimeoutNonNegative still holds.
}
