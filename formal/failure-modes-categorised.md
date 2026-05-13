# Failure modes — categorisation by remediation surface

Companion to [`failure-modes.md`](./failure-modes.md). The canonical doc
catalogues each failure mode with provenance, model verdicts, and
recovery paths. This doc re-projects the same FMs along a different
axis — **where the fix lives**. The seven buckets are:

| Bucket | Meaning |
|--------|---------|
| **Documented contract in /docs** | The invariant the FM violates is explicitly stated in the CAPI book (`docs/book/src/**`) or an accepted proposal (`docs/proposals/**`). Violation is a regression against a publicly-documented contract. |
| **Unwritten contract** | The invariant exists in code comments, controller behaviour, or operator folklore but is not pinned in `docs/`. Closing the FM requires either documenting the contract OR teaching the controller to enforce it. |
| **Infrastructure contract** | The FM is caused by an infrastructure-layer property (MTU, LB, IPAM, NTP, CRI, CSI, registry, kernel) that CAPI consumes but does not own. The fix lives in the infra layer or in CAPI's tolerance of that layer's quirks. |
| **Webhook contract** | The FM is caused by admission, mutating, validating, or conversion webhooks. CAPI's webhook stack and `cert-manager`-rotation surface. |
| **Potential bug fixable by node-agent bootstrap-status reporting** | A Machine's bootstrap progresses through phases (cloud-init, kubelet TLS bootstrap, etcd-add-learner, promotion, Node registration). Today this is observed indirectly via etcd `MemberList`, kubelet `Node` API registration, and apiserver readyz. A node-side agent that emitted structured bootstrap-phase events (PRE_KUBELET, KUBELET_STARTED, ETCD_LEARNER_ADDED, ETCD_PROMOTED, NODE_REGISTERED, READY) would let KCP and MHC distinguish *stuck* from *in-flight* without timer-only heuristics. Each FM in this bucket has a fix that becomes obvious once that signal is available. |
| **Other potential bug** | Genuine CAPI controller bug (or latent design gap) not in any of the above buckets. Closing requires a code change. |
| **Other** | Modelling artefacts, transients, exogenous events the model captures but the controller cannot fix (etcd cluster gone, hardware failure, operator-initiated rogue admin), and harnesses that are not failure modes themselves. |

A given FM is assigned to **one primary bucket** below — the bucket
that names the most direct fix. Many FMs touch multiple layers
(e.g. a webhook bug that surfaces through a documented contract);
the cross-references are noted inline.

Total FMs categorised: **118**.

---

## 1. Documented contract in /docs

These FMs violate an invariant that already exists in CAPI's published
documentation (book or accepted proposal). The fix is either a code
regression to investigate, or the invariant is already operative and
the FM exercises its boundary.

| FM | Topic | Doc reference |
|----|-------|---------------|
| FM-33 | Worker MachineSet preflight gating | `docs/book/src/tasks/experimental-features/machineset-preflight-checks.md`; closed by cluster-api#11117 |
| FM-39 | Multi-step upgrade hook ordering | `docs/proposals/20220414-lifecycle-hooks.md` |
| FM-40 | `BeforeClusterUpgrade` annotation gates CP version pickup | `docs/proposals/20220414-lifecycle-hooks.md` |
| FM-41 | `AfterClusterUpgrade` fires only at quiescence | `docs/proposals/20220414-lifecycle-hooks.md` |
| FM-42 | In-place admitted before `CanUpdateMachineSet` returns yes | `docs/proposals/20231229-in-place-updates.md` and Runtime SDK proposal |
| FM-43 | UpdateMachine hook idempotence | `docs/proposals/20220221-runtime-SDK.md`; `docs/proposals/20231229-in-place-updates.md` |
| FM-44 | Multiple UpdateMachine extensions registered | `docs/proposals/20231229-in-place-updates.md` (single-extension constraint) |
| FM-48 | KCP must not create CP Machines before InfraCluster ready | `docs/proposals/20191017-kubeadm-based-control-plane.md`; `docs/proposals/20190709-cluster-spec-crds.md` |
| FM-49 | MachineDeployment gate on `ControlPlaneInitialized` | `docs/proposals/20190610-machine-states-preboot-bootstrapping.md` |
| FM-50 | `ControlPlaneEndpoint` monotonicity | `docs/proposals/20190709-cluster-spec-crds.md` (Cluster contract) |
| FM-51 | Cross-spec preflight gates are level-triggered | implicit in `docs/book/src/tasks/experimental-features/machineset-preflight-checks.md` |
| FM-53 | MachineDeployment rollout availability invariants | `docs/proposals/20191017-kubeadm-based-control-plane.md` (surge/availability) |
| FM-57 | Parent disappears before child finalisers clear | Kubernetes finaliser docs + `docs/book/src/developer/architecture/controllers/cluster.md` |
| FM-58 | Progress-from-any-state under deletion stalls | finaliser contract (Kubernetes) referenced in CAPI cluster controller docs |
| FM-66 | User-provided kubeconfig secret rotation | `docs/book/src/tasks/certs/using-custom-certificates.md` |
| FM-67 | Cluster CA regenerated after KCP init | `docs/book/src/tasks/certs/auto-rotate-certificates.md` |
| FM-68 | Kubeconfig rotation rewrites endpoint | `docs/book/src/tasks/control-plane/upgrade-control-plane.md` |
| FM-VAP-37 (#37) | VAP CEL timeout + failurePolicy=Ignore | Kubernetes VAP docs (graduation GA in 1.30); CAPI webhook surface |
| FM-49-issue (issue #97) | PropagationPolicy not honoured | Kubernetes garbage-collection docs (Foreground/Background/Orphan) |

## 2. Unwritten contract

These FMs touch invariants that are real (the controllers behave
correctly today, or the failure mode is reproducible) but the
contract is in code or folklore, not `docs/`. Closing requires
documentation *and* a state-invariant assertion in the model so a
future change can't regress silently.

| FM | Topic | Where the unwritten contract lives today |
|----|-------|------------------------------------------|
| FM-7 | Concurrent unhealthy machines / cascading remediation | `controlplane/kubeadm/internal/controllers/remediation.go` (serialisation by `canSafelyRemediateMachine`) |
| FM-8 | `InformativenessObligation` | KCP condition projection in `controlplane/kubeadm/internal/workload_cluster_conditions.go` |
| FM-9 | Stuttering / fairness gap | Implicit fairness assumption in every controller; no document spells out "every reconcile must eventually fire on a level-triggered cache" |
| FM-10 | Conditions race: `HealthyMachine` while `EtcdMemberHealthy=Unknown` | conditions order in `workload_cluster_conditions.go` |
| FM-31 | Custom Node conditions not surfaced on Machine | upstream cluster-api#11826 |
| FM-34 | Stale MHC cluster cache during apiserver restart | cluster-api#12363 |
| FM-37 | Lifecycle hooks skipped under control-plane unavailability | cluster-api#8942 |
| FM-45 | Per-key reconcile serialisation under multi-worker | `controller-runtime/pkg/internal/controller/controller.go` |
| FM-46 | Terminal error suppresses requeue | `controller-runtime` terminal-error semantics |
| FM-47 | Cache lags API server | `controller-runtime` informer contract; not documented in CAPI |
| FM-52 | MachineDeployment rollout / MHC conflicting delete pressure | `internal/controllers/machinedeployment/` and `internal/controllers/machinehealthcheck/` |
| FM-54 | Old-MS starvation snapshot invariant | rollout invariants implicit in `internal/controllers/machinedeployment/sync.go` |
| FM-55 | ClusterClass patch order non-confluent | `internal/topology/cluster/scope/cluster.go` (patch engine ordering) |
| FM-56 | Immutable-field snapshot before validation | `internal/webhooks/` immutability gate; the *ordering* is unwritten |
| FM-59 | Restart invalidates in-memory hook cache | `exp/runtime/` Runtime SDK |
| FM-60 | Partial failure requires transport replay of same hook generation | Runtime SDK retry semantics |
| FM-61 | Pivot crash leaves dual-live object without pause fence | `cmd/clusterctl/client/cluster/mover.go` invariants |
| FM-62 | Partial pivot restores leaf before owner chain | `cmd/clusterctl/client/cluster/mover.go` |
| FM-63 | v1beta2 projection drops legacy diagnostic key | conversion code in `api/core/v1beta2/conversion.go` |
| FM-64 | One-version-only status field is dropped without documentation | conversion code; `docs/proposals/202206-api-versioning.md` does not enumerate this case |
| FM-65 | NoneConverter fallback serves cross-version read | `api/conversion.go` defaulting |
| FM-69 | Bounded fault storm still permits legitimate reconcile | controller-runtime workqueue fairness |
| FM-70 | Fault-storm overload starves legitimate reconcile | controller-runtime workqueue fairness |
| FM-71 | Cross-controller cyclic enqueue livelock | controller-runtime watch fanout |
| FM-72 | Reflector relist storm duplicates Machine create | `client-go` reflector replay semantics |
| FM-73 | Deleted object stays enqueued into nil-read / shutdown-drain | controller-runtime shutdown ordering |
| FM-83 | Etcd membership reconcile batches add+remove together | `workload_cluster_etcd.go` reconcile pacing |
| FM-84 | 5-node / 3-failure recovery promotes too many learners | etcd Raft contract — invariant is in etcd docs but not enumerated in CAPI |
| FM-95 (canonical) | ClusterTopology reads torn ClusterClass view | `internal/topology/cluster/cluster_class.go` |
| FM-96 | ClusterResourceSet ApplyOnce runs before kubelets join | `exp/addons/internal/controllers/clusterresourceset` ordering |
| FM-97 (canonical) | KCP and MHC concurrently delete the same Machine | `internal/controllers/machinehealthcheck/` + `controlplane/kubeadm/internal/controllers/remediation.go` |
| FM-98 (canonical) | Bootstrap and infra ready edges observed separately | `internal/controllers/machine/machine_controller_phases.go` |
| FM-99 (canonical) | Concurrent `Cluster.spec` edits lose intent | `internal/webhooks/cluster.go` SSA semantics |
| FM-100 | Autoscaler + KCP rollout overproduce replicas | KCP scale-up + autoscaler interaction |
| FM-101 | Controller-manager replay re-applies after leader failover | `controller-runtime/pkg/manager/manager.go` leader-election semantics |
| FM-102 | MachinePool spec replicas vs provider actual oscillate | `exp/internal/controllers/machinepool_controller.go` |
| FM-103 | Management-cluster split-brain — two leader controllers | leader lease semantics |
| FM-104 | Rollback during partial cycling exceeds surge | MachineDeployment rollout invariants |
| FM-105 | Mid-rollout etcd tag bump traps CP upgrade | KCP upgrade ordering |
| FM-107 | Projected SA token rotates mid-reconcile, 401 | k8s SA token rotation; CAPI consumer expectations unwritten |
| FM-108 | Condition message truncation drops root-cause tail | `api/core/v1beta2/condition_types.go` 4KB limit |
| FM-109 | Status subresource lag, another controller acts on stale phase | controller-runtime status-subresource semantics |
| FM-110 | Cluster delete during in-flight edit allows stale write | webhook + finaliser interaction |
| FM-111 | Backup/apply partial rollback silently drops fields | SSA field-manager semantics |
| FM-114 | SSA field-manager ownership silently reverted | SSA field-manager semantics |
| FM-118 | CRD schema bump adds required fields, invalidates stored objects | `config/crd/` versioning policy |
| FM-122 | Third-party ClusterRole drift, 403s | RBAC bundle in `config/rbac/` |
| FM-124 | Non-atomic remediation admission reads stale quorum state | `controlplane/kubeadm/internal/controllers/remediation.go` — *closed* by RemediationCAS work (issue #110) |
| FM-125 | Concurrent remediation ignores condemned peers, admits quorum loss | `controlplane/kubeadm/internal/controllers/remediation.go` — *partially closed* by KCPReconcile condemned-peers work |
| FM-VAP (issue #76) | sa-impersonation transitive permissions | Kubernetes RBAC docs reference impersonation but CAPI doesn't enumerate which controllers use it |
| FM (issue #95) | Two management clusters managing same workload | Implicit "single authoritative manager" assumption; not documented |
| FM (issue #98) | Cross-namespace ownerRef rejected | Kubernetes apiserver invariant; CAPI assumes co-location but doesn't document it |
| FM (issue #99) | KCP vs Kamaji provider parity | CP-provider contract is implicit in the KCP proposal |

## 3. Infrastructure contract

These FMs are caused by infrastructure-layer behaviour CAPI consumes
but does not own. The fix is either in the infra layer, or in CAPI's
tolerance/preflight checks.

| FM | Infra layer | Notes |
|----|-------------|-------|
| FM-3 | etcd reachability | EXOGENOUS — controller cannot fix; recovery via operator |
| FM-13 | apiserver LB | EXOGENOUS — fix via LB rotation; CAPI must tolerate the gap |
| FM-90 | MTU drift (CNI / vSphere VXLAN) | preflight check + tolerance |
| FM-91 | Pod starts before CNI veth | CNI race; kubelet preflight |
| FM-92 | LB deregisters target before drain | LB target-group semantics; PreStop hook |
| FM-93 | NetworkPolicy cuts controller mid-flight | NP audit; controller must reconnect watches |
| FM-94 | Conntrack exhaustion drops kubelet→apiserver | kernel tuning |
| FM-89 | CSR approval lag strands kubelet | CSR signer (kubelet-bootstrap-approver in cluster-autoscaler / kubeadm) |
| FM-112 | IAM policy revocation strands provisioning | cloud IAM |
| FM-113 | AZ-wide failure leaves KCP stuck | cloud AZ failover |
| FM-115 | Subnet/IPAM exhaustion | cloud IPAM |
| FM-117 | CSI volume detach hang blocks finaliser chain | CSI driver |
| FM-120 | PVC-using bootstrap before StorageClass | CSI install ordering; per-cluster cattle |
| FM-121 | Filesystem-full on node, static-pod crashloop | infra capacity / Node disk monitoring |
| FM-126 | OIDC issuer/JWK rotation invalidates tokens | external OIDC provider |
| FM-86 | Registry throttle cascades into bootstrap stall | registry rate limit; image-pull pre-warming |
| FM-87 | MemPressure evicts mis-priority static pod | kubelet eviction policy; PriorityClass assignment |
| FM (issue #62) | Spot termination 2-min notice race | cloud spot lifecycle |
| FM (issue #63) | NTP drift, kubelet clock ahead | NTP infrastructure |
| FM (issue #64) | Leap second / monotonic skip | kernel time semantics |
| FM (issue #88) | Spot pool drained simultaneously | cloud spot rebalancing |
| FM-118 | CRD schema bump adds required fields | management-cluster apiserver invariant; lives partly here, partly in "unwritten contract" |

## 4. Webhook contract

Admission, mutating, validating, conversion webhooks, and cert-manager
rotation. These all stack on top of `cert-manager` and the apiserver
webhook plumbing.

| FM | Webhook surface | Notes |
|----|-----------------|-------|
| FM-32 | cert-manager rotation gap | cert-manager#10522 |
| FM-56 | Immutable-field snapshot before validation | CAPI immutability webhooks |
| FM-74 | Validator reads stale field before mutator default/replay converges | CAPI mutating + validating webhook ordering |
| FM-75 | Self-hosted webhook outage deadlocks upgrade | self-hosted webhook + upgrade ordering |
| FM-76 | Serving cert rotates before apiserver trust cache refreshes CABundle | cert-manager + apiserver-webhook trust |
| FM-78 | Dry-run admission probe triggers real side effects | dry-run / `sideEffects: NoneOnDryRun` contract |
| FM-65 | NoneConverter fallback serves cross-version read | conversion-webhook fallback |
| FM-VAP-37 | VAP CEL timeout + failurePolicy=Ignore | ValidatingAdmissionPolicy (KEP-3488); cross-listed in /docs bucket |

## 5. Potential bug fixed by node-agent bootstrap-status reporting

These FMs all have a common shape: a Machine's bootstrap progresses
through phases the management cluster cannot directly observe. KCP and
MHC infer state from `etcd MemberList`, `Node` API registration, and
condition projections — each of which has a hidden gap (the leader's
own status RPC, the kubelet TLS bootstrap window, the CSR approval
window, the apiserver LB warm-up). A node-side agent that streamed
structured bootstrap-phase events to the management cluster would let
the controllers distinguish *stuck* from *in-flight* without time-based
heuristics. See the in-tree
`docs/community/20241112-node-bootstrapping.md` proposal sketch for one
shape this could take.

| FM | What the node agent would expose | Why today's signal is ambiguous |
|----|----------------------------------|---------------------------------|
| FM-1 | `ETCD_LEARNER_REGISTERED` vs `ETCD_PROMOTED` | Stuck learner observed only via etcd `MemberList`; promotion stall is invisible until kubeadm-join exits |
| FM-4 | `NODE_REGISTERED` event time | Promote-before-NodeRef window: KCP sees etcd promotion but Node `NodeRef` not yet set |
| FM-5 | `KUBELET_TLS_BOOTSTRAPPED` event | MHC observation `NoCorrespondingMember` is the proxy for "kubelet did not get to TLS bootstrap" |
| FM-11 | `KUBELET_CONFIG_FAILED` with `reason` | Invalid kubelet config silently fails kubelet start — kubelet's exit reason isn't surfaced to mgmt |
| FM-12 | `ETCD_JOIN_TIMEOUT` (specific to slow storage) | Etcd join timeout looks identical to network partition |
| FM-14 | `NODE_REGISTRATION_BLOCKED` with cause | Kubelet up but Node never registers — root cause (auth, CSR, race) hidden |
| FM-17 | `KUBEADM_PHASE_FAILED` with `phase` | kubeadm-join misconfig (wrong endpoint) surfaces as a failed reconcile only |
| FM-79 | `KUBELET_STARTED` w/ `controlPlaneEndpoint` confirmation | Asymmetric partition creates dual-leader; node-side rebroadcast could close it faster |
| FM-82 | `ETCD_WAL_CORRUPTION` or `DISK_FULL` self-report | Today the only signal is etcd member status RPC, which itself can be wedged |
| FM-85 | `CRI_RESPONSIVE` heartbeat | Slow CRI / PLEG hang triggers over-eager remediation — a CRI liveness signal could distinguish |
| FM-86 | `IMAGE_PULL_PROGRESS` | Registry throttle stalls bootstrap; signal would let KCP differentiate slow-pull from stuck-pull |
| FM-87 | `STATIC_POD_PRIORITY_OBSERVED` | MemPressure eviction of mis-priority critical static pod — node agent could report PriorityClass at observe time |
| FM-88 | `STATIC_POD_HASH_MATCH` | Hash collision / stale reload — node agent confirms desired vs actual |
| FM-89 | `CSR_PENDING` / `CSR_APPROVED` | CSR approval lag — explicit signal beats inferring from kubelet timeout |
| FM (issue #62) | `DRAIN_BEGAN` + `DRAIN_COMPLETED` | Spot termination 2-min notice — node agent confirms drain finished before HardTerminate |
| FM (issue #71) | `EVENT_EMITTED` with critical-tier marker | Critical events otherwise lost to TTL/compaction; node-side persistence path |
| FM-107 | `SA_TOKEN_ROTATED` | Projected SA token rotation mid-reconcile — node agent confirms token in use |
| FM-121 | `FILESYSTEM_USAGE` periodic snapshot | Filesystem-full on a node causes static-pod crashloop and spurious remediation |

## 6. Other potential bug

Genuine code-level bugs in CAPI controllers (or close-in controller
dependencies). Closing requires a code change, not a documentation or
infrastructure shift.

| FM | Why it's a code-level bug |
|----|---------------------------|
| FM-1 | Stuck learner — KCP-BUG; remediation path exists but admission gate is loose |
| FM-5 | KCP-BUG latent — MHC stuck-NoCorrespondingMember not surfaced to remediation queue |
| FM-11 | KCP-BUG latent — invalid kubelet config slipped past admission |
| FM-14 | KCP-BUG latent — kubelet-up-but-no-Node should be detectable from existing signal |
| FM-17 | KCP-BUG latent — kubeadm-join misconfig surfaces too late |
| FM-20 | KCP-DESIGN-GAP — upgrade rollback mid-flight |
| FM-23 | KCP-BUG latent — drain stuck on PDB during remediation; cluster-api#13508 |
| FM-100 | Autoscaler scale-up + KCP rollout overproduce replicas — surge-bound coordination bug |
| FM-104 | Rollback during partial cycling temporarily exceeds surge — counter underflow |
| FM-105 | Mid-rollout etcd tag bump traps CP upgrade — version pickup re-entry |
| FM-110 | Cluster delete during in-flight edit allows stale write — webhook ordering |
| FM-114 | SSA field-manager ownership transfer silently reverted by stale manager |
| FM-116 | Endpoint swap leaves kubeconfigs pointing at old endpoint |
| FM-118 | CRD schema bump invalidates stored objects (CAPI's CRD versioning policy) |
| FM-119 | Generic adversarial fault injection — bounded-fault saturation gap |
| FM-124 | Non-atomic remediation admission CAS — closed by RemediationCAS work (issue #110) |
| FM-125 | Concurrent remediation + condemned peers admits quorum loss — partially closed |
| FM (issue #78) | CRD field pruning loses controller-relied data |
| FM (issue #79) | CRD removed mid-reconcile panics controller (graceful-shutdown missing) |
| FM (issue #91) | Apiserver pressure + CPU throttle → workqueue OOM (queue backpressure missing) |
| FM (issue #92) | Bootstrap secret TTL exceeded, regen not triggered |
| FM (issue #93) | Bootstrap data exceeds provider userData limit (preflight missing) |
| FM (issue #97) | Controller hardcodes PropagationPolicy=Background instead of honouring caller |
| FM (issue #98) | Cross-namespace ownerRef orphan path |
| FM-72 | Reflector relist storm duplicates Machine create |
| FM-73 | Deleted object stays enqueued, nil-read race on shutdown |
| FM-80 | Snapshot restore races compaction + KCP membership reconcile |
| FM-81 | Defrag overlaps second maintenance fault — admission gate too lax |
| FM-83 | Etcd membership reconcile batches add+remove together — should be serialised |

## 7. Other

Modelling artefacts, transients, exogenous events the controller
cannot fix, and harnesses that are not failure modes themselves.

| FM | Category |
|----|----------|
| FM-2 | EXOGENOUS — 2-machine quorum loss; recovery via operator (FM-2 replica sweep is in issue #27) |
| FM-3 | EXOGENOUS — persistent etcd unreachability (cross-listed under infra) |
| FM-6 | TRANSIENT — etcd leader vacancy after term advance |
| FM-9 | MODEL-INCOMPLETE — stuttering / fairness gap |
| FM-10 | TRANSIENT — stale health rollup, self-resolving |
| FM-15 | TRANSIENT — upgrade in flight |
| FM-16 | EXOGENOUS — 1-node cluster lost its only voter |
| FM-18 | TRANSIENT — concurrent scale-up + remediation race |
| FM-19 | TRANSIENT — apiserver restart relist storm |
| FM-21 | TRANSIENT — 5-node losing 2-of-5 (sequential remediation converges) |
| FM-22 | EXOGENOUS sub-shape of FM-2 |
| FM-24 | TRANSIENT — etcd defrag pause |
| FM-35 | MODEL-EXPANSION — self-hosted upgrade deadlock (verified) |
| FM-69 | MODELLING — controller-runtime fairness contract |
| FM-70 | MODELLING — controller-runtime fairness contract |
| FM-71 (canonical) | MODELLING — controller-runtime cyclic enqueue (cross-listed under unwritten) |
| FM-78 (canonical) | MODELLING — dry-run side-effect contract (cross-listed under webhook) |
| FM (issue #99) | Static parity table — not a failure mode, a capability matrix |
| FM (issue #101) | Goal-directed Apalache harness — not a failure mode |
| FM (issue #102) | Scalability envelope harness — not a failure mode |
| FM (issue #103) | Chaos → trace → checker integration — tooling, not a failure mode |

---

## Cross-bucket aggregate

| Bucket | Count | Share |
|--------|------:|------:|
| Documented contract in /docs | 19 | 16% |
| Unwritten contract | 53 | 45% |
| Infrastructure contract | 23 | 19% |
| Webhook contract | 8 | 7% |
| Node-agent fixable | 18 | 15% |
| Other potential bug | 29 | 25% |
| Other (modelling/transient/exogenous) | 21 | 18% |

(Sums exceed 118 because of cross-listing — each FM has one *primary*
bucket above but some are cross-referenced to a second bucket where
the fix touches multiple layers, e.g. webhook + documented contract.)

## Takeaways

1. **Unwritten contracts dominate.** Nearly half of all failure modes
   target invariants that exist in code/folklore but not in `docs/`.
   The cheapest model-corpus → docs win is to lift the model's
   stated invariants into prose under
   `docs/book/src/developer/architecture/controllers/`.
2. **Node-agent bootstrap-status reporting would close ~15% of FMs.**
   The proposal at `docs/community/20241112-node-bootstrapping.md`
   gives a concrete sketch. Each FM in section 5 lists the specific
   signal the agent would emit.
3. **Infrastructure-layer tolerance is a recurring theme.** 19% of
   FMs are infra-induced; the right CAPI-side response is preflight
   checks + condition-message clarity rather than self-healing.
4. **Webhook contract debt is concentrated.** Eight FMs touch the
   webhook surface; the cert-manager rotation gap (FM-32) and the
   self-hosted webhook outage (FM-75) are the load-bearing ones —
   they cascade into FM-74/76/118.
5. **The "code-level bug" backlog is bounded.** Roughly 29 FMs are
   genuine controller bugs; most have specific upstream issue numbers
   already. Closing them is iterative engineering work, not research.
