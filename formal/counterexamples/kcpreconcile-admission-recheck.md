# KCPReconcile admission vs pre-terminate hook recheck

Issue: `#108`

Counterexample trace:

1. `HealthChange(1, UnhealthyMachine)`
2. `RequestRemediation(1)`
3. `EvaluateRemediationAdmission(1)` records `admissionSafe[1] = true`
4. `ExternalMembershipChangeDrop(3)` shrinks the live voter set from `{1,2,3}` to `{1,2}`
5. `PreTerminateHookGateRecheck(1)` still advances `decision[1]` to `RemediationInFlight`

Why it violates the property:

- At admission time, removing `1` from `{1,2,3}` preserves quorum.
- After the external drop of `3`, removing `1` from `{1,2}` would leave only `{2}`.
- The hook-time recheck therefore observes `hookFreshSafe[1] = false`.
- The buggy variant still commits to `RemediationInFlight`, violating `GateRecheckAgreesWithAdmission`.

Fixed variant:

- `PreTerminateHookGateRecheckStrict(1)` uses the fresh predicate.
- It transitions the Machine to `RemediationBlocked` with `PreTerminateHookGateFailed` instead of proceeding.

Saved to support issue `#108` acceptance criteria and to distinguish this per-Machine two-call-site race from:

- issue `#106` non-atomic queue admission across two Machines, and
- issue `#109` condemned-peer / pre-state quorum accounting.
