# KCP-Machine condition contract — what callers rely on from the
# KubeadmControlPlane and Machine surfaces

> Status: Authoritative for the working tree at the SHA recorded
> in [`commits.yaml`](./commits.yaml) under `repos.cluster-api.sha`
> (`HEAD`).
>
> Conformance keywords (MUST / MUST NOT / SHOULD / SHOULD NOT / MAY)
> follow [RFC 2119](https://datatracker.ietf.org/doc/html/rfc2119).

## Purpose

This is the inward-facing contract: the formal model in
[`../specs/MachineHealthCheck.qnt`](../specs/MachineHealthCheck.qnt)
and [`../specs/KCPReconcile.qnt`](../specs/KCPReconcile.qnt)
projects KCP's condition surface twice — once for v1beta1, once
for v1beta2 — and states an `InformativenessObligation` that the
v1beta2 projection MUST be at least as informative as the v1beta1
projection.

The user-reported incident at
`KubeadmControlPlane=ns-vault-prod-ky8ns/kvp22096-98cda1-fpx9t`
(2026-04-28) is a counterexample to that obligation. This
contract pins the projection's normative shape so that future
work can either:

- Restore the v1beta1 information content in the v1beta2 surface
  (and close the counterexample-log row); or
- Document an explicit, narrowly-scoped exception (and amend
  this contract to record what was deliberately dropped).

## Scope

This contract covers KCP's `EtcdMemberHealthy` and
`MachineOwnerRemediated` conditions only. Other CAPI conditions
are out of scope here; the formal model can be extended to cover
them in subsequent increments without amending this document.

## 1. Condition surfaces

### 1.1 EtcdMemberHealthy — v1beta2

Defined at
`api/controlplane/kubeadm/v1beta2/kubeadm_control_plane_types.go:397`:

```go
KubeadmControlPlaneMachineEtcdMemberHealthyCondition = "EtcdMemberHealthy"
```

The v1beta2 surface uses these reason constants:

- `Healthy` (`KubeadmControlPlaneMachineEtcdMemberHealthyReason`,
  line 403) — member responds and reports healthy.
- `InspectionFailed`
  (`KubeadmControlPlaneMachineEtcdMemberInspectionFailedReason`,
  line 407, aliased to `clusterv1.InspectionFailedReason` in
  `api/core/v1beta2/condition_consts.go:196`) — KCP could not
  determine the member's state. Used when `Status` returns
  timeout or is otherwise unreachable.
- `InternalError` (`clusterv1.InternalErrorReason`, defined at
  `api/core/v1beta2/condition_consts.go:162`) — surfaces
  unexpected controller-side errors.

### 1.2 EtcdMemberHealthy — v1beta1

Defined at
`api/controlplane/kubeadm/v1beta1/condition_consts.go:129`:

```go
MachineEtcdMemberHealthyCondition clusterv1beta1.ConditionType = "EtcdMemberHealthy"
```

The v1beta1 surface carries `(status, reason, severity, message)`.
The `severity` field is unique to v1beta1; v1beta2 dropped it.

### 1.3 MachineOwnerRemediated

The v1beta1 form of this condition carries
`severity=Error, reason=RemediationFailed, status=False` along
with the underlying error chain in `message`.

The v1beta2 form carries `reason=InternalError,
status=False` along with the generic message
`"Please check controller logs for errors"`.

## 2. Projection invariants

Let `O` denote the underlying observation made by KCP's etcd
client probe (e.g. `Status` returned a timeout, `MemberList`
showed no member matching this Machine's node name, etc.).

The formal model's projection functions are:

```
π_v1beta1 : Observation → V1Beta1Condition
π_v1beta2 : Observation → V1Beta2Condition
```

The InformativenessObligation states:

> For every `O` and every diagnostic key `k` in the contract's
> diagnostic-key set (§3), if `π_v1beta1(O)` carries `k`, then
> `π_v1beta2(O)` carries `k`.

This is a *MUST*. The current v1beta2 projection violates it for
two diagnostic keys (`context deadline exceeded`, `no route to
host`) under the `UnreachableTimeout` and `UnreachableNoRoute`
observations respectively.

## 3. Diagnostic-key set

The set of diagnostic keys whose presence is contractually
preserved across the projection is:

| Key | Source observation | Why it matters |
|---|---|---|
| `context deadline exceeded` | etcd `Status` gRPC call timed out | Operator can distinguish a timeout from a connection failure or an apparent unresponsiveness due to load. |
| `no route to host` | TCP connect to advertise address failed | Distinguishes infrastructure-network breakage from etcd-internal failures. |
| `no corresponding etcd member` | `MemberList` returned no entry matching this Machine's node name | Distinguishes "member never registered" from "member is unhealthy". |
| `failed to get etcdStatus` | upstream wrapper error | Identifies the call site for triage. |
| `failed to connect to etcd` | upstream wrapper error | Identifies the call site for triage. |

The set is open: new diagnostic keys MAY be added when a new
observation type lands in the model. Removals require a CAEP-grade
amendment.

## 4. Conformance summary

| ID | Statement |
|---|---|
| KMC1 | `EtcdMemberHealthy` v1beta2 reason is one of `Healthy`, `InspectionFailed`, `InternalError`. |
| KMC2 | The v1beta2 message MUST carry every diagnostic key (per §3) that the v1beta1 message carries for the same observation. |
| KMC3 | When `Status` returns timeout, the v1beta2 message MUST carry the `context deadline exceeded` diagnostic key. |
| KMC4 | When `MemberList` returns no entry for the Machine's node name, the v1beta2 message MUST carry the `no corresponding etcd member` diagnostic key. |
| KMC5 | The v1beta2 reason MUST NOT collapse multiple observation classes onto `InternalError` when a more specific reason is documented in §1.1. |

## 5. Open counterexamples

KMC2, KMC3 are violated by the current implementation in
`controlplane/kubeadm/internal/workload_cluster_conditions.go`.
The counterexample-log row inaugurated alongside this contract
records the violation; closure requires either restoring the
diagnostic content in the v1beta2 message or documenting a
narrowly-scoped exception here with rationale.
