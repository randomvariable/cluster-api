# KCPReconcile condemned peer traces

## 3-node cluster: second remediation blocked

Trace:
`HealthChange(1, Unhealthy) -> RequestRemediation(1) -> EvaluateRemediationAdmission(1) -> MarkCondemnedPeer(1) -> HealthChange(2, Unhealthy) -> RequestRemediation(2) -> EvaluateRemediationAdmission(2)`

- Post-state blocks Machine 2 because survivors after removing target 2 and condemned peer 1 leave only voter 3, while the pre-state quorum bar is 2.

## 5-node cluster: second remediation admitted

Trace:
`InitFiveNode -> HealthChange(1, Unhealthy) -> RequestRemediation(1) -> EvaluateRemediationAdmission(1) -> MarkCondemnedPeer(1) -> HealthChange(2, Unhealthy) -> RequestRemediation(2) -> EvaluateRemediationAdmission(2)`

- Post-state keeps voters `{3,4,5}`; pre-state quorum bar is `3`, so admission is allowed.

## Wind-down carve-out

Trace:
`init -> MarkDeletingWithoutCleanup(3) -> HealthChange(1, Unhealthy) -> RequestRemediation(1) -> EvaluateRemediationAdmission(1)`

- No non-deleting peer survives besides the target, so the stricter pre-state quorum bar is not applied.
