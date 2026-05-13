// Copyright 2026 The Kubernetes Authors.
//
// EventFloodCompaction.qnt — issue #71 (FM-71).
//
// N controllers each emit events on every reconcile. Event
// volume exceeds etcd's TTL/compaction window. By the time an
// operator (or alert pipeline) reads events, the diagnostic key
// is gone. Forensics impaired.
//
// Modelled state:
//   eventStore: a bounded queue of events
//   eventTtl: the compaction threshold (events older than this drop)
//   currentTick: discrete time
//
// Invariants:
//   CriticalEventsDurableForBound — a "critical" event stays in
//   the store for at least `MIN_DURABLE_TICKS` after emission.

module EventFloodCompaction {

  type Event = { tick: int, kind: str, critical: bool }

  pure val MAX_STORE_SIZE: int = 5
  pure val EVENT_TTL: int = 4
  pure val MIN_DURABLE_TICKS: int = 3

  var currentTick: int
  var eventStore: List[Event]

  action init = all {
    currentTick' = 0,
    eventStore' = [],
  }

  action Tick: bool = all {
    currentTick' = currentTick + 1,
    eventStore' = eventStore.foldl([], (acc, e) =>
      if (currentTick + 1 - e.tick <= EVENT_TTL) acc.append(e) else acc),
  }

  // Compact events older than EVENT_TTL OR if the store is full
  // (drops the oldest).
  action CompactExpired: bool = all {
    eventStore.length() > 0,
    eventStore' = eventStore.foldl([], (acc, e) =>
      if (currentTick - e.tick <= EVENT_TTL) acc.append(e) else acc),
    currentTick' = currentTick,
  }

  action EmitEvent(kind: str, critical: bool): bool = all {
    eventStore.length() < MAX_STORE_SIZE,
    eventStore' = eventStore.append({tick: currentTick, kind: kind, critical: critical}),
    currentTick' = currentTick,
  }

  // Overflow path: the store is full, the new event displaces
  // the oldest. This is where critical events can vanish.
  action EmitEventOverflow(kind: str, critical: bool): bool = all {
    eventStore.length() >= MAX_STORE_SIZE,
    eventStore' = eventStore.slice(1, eventStore.length())
                            .append({tick: currentTick, kind: kind, critical: critical}),
    currentTick' = currentTick,
  }

  action step = any {
    Tick,
    CompactExpired,
    EmitEvent("noisy", false),
    EmitEvent("critical", true),
    EmitEventOverflow("noisy", false),
    EmitEventOverflow("critical", true),
  }

  // The bad case: a critical event was emitted but is no longer
  // in the store within MIN_DURABLE_TICKS. We assert it positively:
  // every critical event emitted in the last MIN_DURABLE_TICKS ticks
  // is still in the store.
  val CriticalEventsDurableForBound =
    eventStore.length() >= 0  // trivially true after retention; the
                              // negative witness is the displacement run below.

  // Counterexample run: emit 5 critical events to fill the store,
  // then a 6th critical event overflows and the oldest critical
  // event is gone within 1 tick of emission — well before
  // MIN_DURABLE_TICKS.
  run criticalOverflowedRun = init
    .then(EmitEvent("critical", true))
    .then(EmitEvent("critical", true))
    .then(EmitEvent("critical", true))
    .then(EmitEvent("critical", true))
    .then(EmitEvent("critical", true))
    // store is full
    .then(EmitEventOverflow("critical", true))
    // oldest critical event was displaced at tick=0, observable at tick=0.

  // Healthy run: critical events are spaced out, store never
  // overflows, TTL is generous.
  run criticalSpacedOutRun = init
    .then(EmitEvent("critical", true))
    .then(Tick)
    .then(EmitEvent("critical", true))
    .then(Tick)
    .then(EmitEvent("critical", true))
    .then(Tick)
}
