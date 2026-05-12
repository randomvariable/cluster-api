# ConcurrentRemediationGate counterexample

Issue: `#106`

Failing variant: non-atomic `ReadGate` + `CommitAdmission`

Minimal trace:

1. `ReadGate(1)`
2. `ReadGate(2)`
3. `CommitAdmission(1)`
4. `CommitAdmission(2)`

Explanation:

- Both reads observe `inFlight = {}` and conclude quorum is preserved after deleting one member.
- `CommitAdmission(1)` moves Machine `1` into `inFlight`.
- `CommitAdmission(2)` still trusts the stale `gateResult[2] = pass` and also moves Machine `2` into `inFlight`.
- The post-state has `voterSet \ inFlight = {3}`, which is below quorum for a 3-voter cluster.

Fixed variant:

- `AdmitOrBlockAtomic(m)` fuses read + commit.
- The second admission evaluates safety against `inFlight ∪ {m}` and therefore blocks instead of violating quorum.
