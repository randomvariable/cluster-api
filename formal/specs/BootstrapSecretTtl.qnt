// Copyright 2026 The Kubernetes Authors.
//
// BootstrapSecretTtl.qnt — issue #92 (FM-92).
//
// Bootstrap secret has 48h TTL. Machine pending provisioning
// longer than TTL (quota wait, infra outage). Secret expires.
// Machine retries with stale data; provider rejects.

module BootstrapSecretTtl {

  type SecretState = Fresh | Stale
  type MachineState = Pending | Provisioning | Provisioned | Failed

  pure val MACHINES: Set[int] = 1.to(2)
  pure val TTL: int = 48

  var secretState: int -> SecretState
  var secretAgeHours: int -> int
  var machineState: int -> MachineState
  var providerAccepted: int -> bool

  action init = all {
    secretState' = MACHINES.mapBy(_ => Fresh),
    secretAgeHours' = MACHINES.mapBy(_ => 0),
    machineState' = MACHINES.mapBy(_ => Pending),
    providerAccepted' = MACHINES.mapBy(_ => false),
  }

  action Tick: bool = all {
    secretAgeHours' = MACHINES.mapBy(m => secretAgeHours.get(m) + 1),
    secretState' = MACHINES.mapBy(m =>
      if (secretAgeHours.get(m) + 1 >= TTL) Stale else Fresh),
    machineState' = machineState,
    providerAccepted' = providerAccepted,
  }

  action RegenerateSecret(m: int): bool = all {
    MACHINES.contains(m),
    secretAgeHours' = secretAgeHours.put(m, 0),
    secretState' = secretState.put(m, Fresh),
    machineState' = machineState,
    providerAccepted' = providerAccepted,
  }

  action AttemptProvision(m: int): bool = all {
    MACHINES.contains(m),
    machineState.get(m) == Pending,
    val accepted = secretState.get(m) == Fresh
    all {
      providerAccepted' = providerAccepted.put(m, accepted),
      machineState' = if (accepted) machineState.put(m, Provisioned)
                      else machineState.put(m, Failed),
      secretState' = secretState,
      secretAgeHours' = secretAgeHours,
    }
  }

  action step = any {
    Tick,
    nondet m = MACHINES.oneOf(); RegenerateSecret(m),
    nondet m = MACHINES.oneOf(); AttemptProvision(m),
  }

  val NoExpiredSecretInUse =
    MACHINES.forall(m =>
      machineState.get(m) != Failed or secretState.get(m) == Fresh)

  // Counterexample: Tick TTL times so secret goes stale, then provision.
  run staleSecretRejectsRun = init
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick)
    .then(AttemptProvision(1))
    // machineState[1] = Failed, secretState[1] = Stale; NoExpiredSecretInUse holds vacuously?
    // Actually the invariant says Failed => Fresh, but Failed => Stale here. Violated.

  // Recovery: regenerate before provisioning.
  run regenerateBeforeProvisionRun = init
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick).then(Tick).then(Tick)
    .then(Tick).then(Tick).then(Tick)
    .then(RegenerateSecret(1))
    .then(AttemptProvision(1))
}
