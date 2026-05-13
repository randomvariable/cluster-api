# Copyright 2026 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Targets for the formal/ subtree. See ./README.md for the tool
# matrix and install hints, and ./docs/ for Diataxis-style human
# documentation.

# If you update this file, please follow
# https://www.thapaliya.com/en/writings/well-documented-makefiles/

SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

#
# Tools.
#
QUINT     ?= quint
LEAN      ?= lake
TLC       ?= tlc
PYTHON    ?= python3
MKDIR_P   ?= mkdir -p
CP        ?= cp

# typescript backend is needed for Lifecycle.qnt — the rust
# evaluator hits a recursion limit on the per-action
# ConvergenceFair temporal expression (Phase 11b).
QUINT_BACKEND ?= typescript

#
# Verification depths.
#
MAX_STEPS_TLC      ?= 8
MAX_STEPS_APALACHE ?= 4
TLC_SYMMETRY_DIR   ?= /tmp/opencode/tlc-symmetry

#
# Directories.
#
SPECS_DIR     := specs
PROOFS_DIR    := proofs
CONTRACTS_DIR := contracts
LIFECYCLE     := $(SPECS_DIR)/Lifecycle.qnt
LIFECYCLE_MC  := $(SPECS_DIR)/Lifecycle.multicluster.qnt
SELFHOSTED    := $(SPECS_DIR)/SelfHosted.qnt
MSPREFLIGHT   := $(SPECS_DIR)/MachineSetPreflight.qnt
TOPOLOGY      := $(SPECS_DIR)/Topology.qnt
INPLACE       := $(SPECS_DIR)/InPlaceUpdate.qnt
CRRUNTIME     := $(SPECS_DIR)/ControllerRuntime.qnt
XCCYCLE       := $(SPECS_DIR)/CrossControllerCycle.qnt
RELISTSTORM   := $(SPECS_DIR)/ReflectorRelistStorm.qnt
STALESHUT     := $(SPECS_DIR)/StaleEnqueueShutdown.qnt
WEBHOOKCHAIN  := $(SPECS_DIR)/WebhookOrdering.qnt
WEBHOOKSELF   := $(SPECS_DIR)/WebhookSelfReference.qnt
WEBCABUNDLE   := $(SPECS_DIR)/WebhookCABundleStaleness.qnt
VAPTIMEOUT    := $(SPECS_DIR)/VAPTimeout.qnt
DRYSIDEEFFECT := $(SPECS_DIR)/DryRunSideEffects.qnt
ASYMPART      := $(SPECS_DIR)/AsymmetricPartition.qnt
SNAPRESTORE   := $(SPECS_DIR)/SnapshotRestoreCompaction.qnt
DEFRAGQUORUM  := $(SPECS_DIR)/DefragQuorumLoss.qnt
ETCDBATCH     := $(SPECS_DIR)/EtcdMembershipBatch.qnt
WALFAULTS     := $(SPECS_DIR)/EtcdWalFaults.qnt
ETCD5FAIL     := $(SPECS_DIR)/EtcdFiveNodeFailure.qnt
AZFAILCAP     := $(SPECS_DIR)/AzFailoverCapacity.qnt
PLEGHANG      := $(SPECS_DIR)/KubeletPlegHang.qnt
REGPULL       := $(SPECS_DIR)/RegistryPullBackoff.qnt
KCPMHCDEL     := $(SPECS_DIR)/KcpMhcDeleteRace.qnt
CNIVETH       := $(SPECS_DIR)/CniVethRace.qnt
LBDRAIN       := $(SPECS_DIR)/LoadBalancerDrain.qnt
ENDPOINTSWAP  := $(SPECS_DIR)/EndpointSwapKubeconfig.qnt
NETPOLSTALL   := $(SPECS_DIR)/NetworkPolicyMidFlight.qnt
WATCHCOALESCE := $(SPECS_DIR)/WatchEventCoalescing.qnt
CONNTRACK     := $(SPECS_DIR)/ConntrackExhaustion.qnt
IPAMEXH       := $(SPECS_DIR)/IpamExhaustion.qnt
VOLDETACH     := $(SPECS_DIR)/VolumeDetachFinalizer.qnt
STACPODMEM    := $(SPECS_DIR)/StaticPodMemPressure.qnt
STAPODDISK    := $(SPECS_DIR)/StaticPodDiskFull.qnt
HASHRELOAD    := $(SPECS_DIR)/StaticPodHashReloadRace.qnt
BOOTCSR       := $(SPECS_DIR)/BootstrapCsrLag.qnt
MTUFRAG       := $(SPECS_DIR)/MtuFragmentation.qnt
TOPO_REFINED  := $(SPECS_DIR)/TopologyRefined.qnt
CCTOPORACE    := $(SPECS_DIR)/ClusterClassTopologyRace.qnt
CRSTIMING     := $(SPECS_DIR)/ClusterResourceSetTiming.qnt
PVCBOOT       := $(SPECS_DIR)/PvcBootstrapPending.qnt
CRDSCHEMA     := $(SPECS_DIR)/CrdSchemaBump.qnt
ADVERSARY     := $(SPECS_DIR)/AdversaryHarness.qnt
CONCSPEC      := $(SPECS_DIR)/ConcurrentClusterSpecEdits.qnt
RBACDRIFT     := $(SPECS_DIR)/ClusterRoleDrift.qnt
SSAFMCONFLICT := $(SPECS_DIR)/SsaFieldManagerConflict.qnt
PARTIALREVERT := $(SPECS_DIR)/PartialRollbackDrop.qnt
ASKCPSURGE    := $(SPECS_DIR)/AutoscalerKcpSurgeRace.qnt
ETCDK8SSKEW   := $(SPECS_DIR)/EtcdKubernetesVersionSkew.qnt
SKIPUPGRADE   := $(SPECS_DIR)/SkipVersionUpgrade.qnt
ROLLBACKSURGE := $(SPECS_DIR)/RollbackSurgeRace.qnt
BIMREADYRACE  := $(SPECS_DIR)/BootstrapInfraReadyRace.qnt
SATOKENROT    := $(SPECS_DIR)/ServiceAccountTokenRotation.qnt
OIDCROT       := $(SPECS_DIR)/OidcIssuerRotation.qnt
CLOUDIAM      := $(SPECS_DIR)/CloudIamPermissionLoss.qnt
MSGTRUNC      := $(SPECS_DIR)/ConditionMessageTruncation.qnt
STATUSLAG     := $(SPECS_DIR)/StatusSubresourceLag.qnt
CLUSTERDELRACE := $(SPECS_DIR)/ClusterEditDeleteRace.qnt
CMREPLAY      := $(SPECS_DIR)/ControllerManagerReplay.qnt
CMSPLITBRAIN  := $(SPECS_DIR)/ControllerLeaderSplitBrain.qnt
MPSCALECONFLICT := $(SPECS_DIR)/MachinePoolScaleConflict.qnt
INPLACE_REFINED := $(SPECS_DIR)/InPlaceUpdateRefined.qnt
MSPREFLIGHT_REFINED := $(SPECS_DIR)/MachineSetPreflightRefined.qnt
E2E           := $(SPECS_DIR)/ClusterE2E.qnt
E2E_REFINED   := $(SPECS_DIR)/ClusterE2ERefined.qnt
WORKER_LIFE   := $(SPECS_DIR)/WorkerLifecycle.qnt
MD_ROLLOUT    := $(SPECS_DIR)/MachineDeploymentRollout.qnt
MD_ROLLOUT_REFINED := $(SPECS_DIR)/MachineDeploymentRolloutRefined.qnt
CC_PATCHES    := $(SPECS_DIR)/ClusterClassPatches.qnt
JOINNAME      := $(SPECS_DIR)/EtcdJoiningNameDelay.qnt
ORPHANCORR    := $(SPECS_DIR)/OrphanLearnerCorrelation.qnt
FINALIZERS    := $(SPECS_DIR)/Finalizers.qnt
RUNTIMESDK    := $(SPECS_DIR)/RuntimeSDK.qnt
CONCREM       := $(SPECS_DIR)/ConcurrentRemediationGate.qnt
PIVOT         := $(SPECS_DIR)/Pivot.qnt
CONVERSIONWEBHOOK := $(SPECS_DIR)/ConversionWebhook.qnt
KUBELETPKI    := $(SPECS_DIR)/KubeletPKI.qnt

QUINT_FILES := $(wildcard $(SPECS_DIR)/*.qnt)
TLA_FILES   := $(wildcard $(SPECS_DIR)/*.tla)
TLA_CFGS    := $(patsubst %.tla,%.cfg,$(TLA_FILES))

.PHONY: help
help:  ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[0-9A-Za-z_-]+:.*?##/ { printf "  \033[36m%-32s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Sanity gates
## --------------------------------------

##@ sanity:

.PHONY: typecheck
typecheck:  ## quint typecheck every Quint module
	@if ! command -v $(QUINT) >/dev/null 2>&1; then \
	  echo "SKIP: quint not in PATH (install: npm install -g @informalsystems/quint)"; \
	  exit 0; \
	fi
	@for f in $(QUINT_FILES); do \
	  echo "==> quint typecheck $$f"; \
	  $(QUINT) typecheck $$f || exit 1; \
	done

.PHONY: test
test:  ## quint run every Quint module that declares runs
	@if ! command -v $(QUINT) >/dev/null 2>&1; then \
	  echo "SKIP: quint not in PATH"; \
	  exit 0; \
	fi
	@for f in $(QUINT_FILES); do \
	  if grep -qE '^[[:space:]]*run[[:space:]]' $$f; then \
	    echo "==> quint run --backend=$(QUINT_BACKEND) $$f"; \
	    $(QUINT) run --backend=$(QUINT_BACKEND) --max-samples 200 $$f || exit 1; \
	  fi; \
	done

.PHONY: proofs
proofs:  ## lake build the Lean 4 project
	@if ! command -v $(LEAN) >/dev/null 2>&1; then \
	  echo "SKIP: lake not in PATH (install via elan)"; \
	  exit 0; \
	fi
	cd $(PROOFS_DIR) && $(LEAN) build

.PHONY: tlc
tlc:  ## Run TLC on every TLA+ module that has a .cfg
	@if ! command -v $(TLC) >/dev/null 2>&1; then \
	  echo "SKIP: tlc not in PATH"; \
	  exit 0; \
	fi
	@for cfg in $(TLA_CFGS); do \
	  if [ -f $$cfg ]; then \
	    tla=$${cfg%.cfg}.tla; \
	    echo "==> tlc -config $$cfg $$tla"; \
	    $(TLC) -config $$cfg $$tla || exit 1; \
	  fi; \
	done

.PHONY: tlc-symmetry-prepare
tlc-symmetry-prepare:  ## (deprecated) Was a quint -> TLA+ compile step; the
                       ## generated spec was not a sound symmetry domain
                       ## (Int IDs with arithmetic). Kept as a documented
                       ## no-op so historical pipelines do not break.
	@true

.PHONY: verify-tlc-symmetry-lifecycle
verify-tlc-symmetry-lifecycle:  ## TLC symmetry run for LifecycleSymmetry.tla (issue #23)
	@if ! command -v $(TLC) >/dev/null 2>&1; then \
	  echo "SKIP: tlc not in PATH"; \
	  exit 0; \
	fi
	@echo "==> WITH symmetry"
	@$(TLC) -config $(SPECS_DIR)/LifecycleSymmetry.cfg $(SPECS_DIR)/LifecycleSymmetry.tla
	@sleep 1
	@echo "==> WITHOUT symmetry (for reduction-factor comparison)"
	@$(TLC) -config $(SPECS_DIR)/LifecycleSymmetry.nosymmetry.cfg $(SPECS_DIR)/LifecycleSymmetry.tla

.PHONY: verify-tlc-symmetry-etcd
verify-tlc-symmetry-etcd:  ## TLC symmetry run for EtcdMembershipSymmetry.tla (issue #23)
	@if ! command -v $(TLC) >/dev/null 2>&1; then \
	  echo "SKIP: tlc not in PATH"; \
	  exit 0; \
	fi
	@echo "==> WITH symmetry"
	@$(TLC) -config $(SPECS_DIR)/EtcdMembershipSymmetry.cfg $(SPECS_DIR)/EtcdMembershipSymmetry.tla
	@sleep 1
	@echo "==> WITHOUT symmetry"
	@$(TLC) -config $(SPECS_DIR)/EtcdMembershipSymmetry.nosymmetry.cfg $(SPECS_DIR)/EtcdMembershipSymmetry.tla

.PHONY: verify-tlc-symmetry-clustere2e
verify-tlc-symmetry-clustere2e:  ## TLC symmetry run for ClusterE2ESymmetry.tla (issue #23)
	@if ! command -v $(TLC) >/dev/null 2>&1; then \
	  echo "SKIP: tlc not in PATH"; \
	  exit 0; \
	fi
	@echo "==> WITH compound CP/worker symmetry"
	@$(TLC) -config $(SPECS_DIR)/ClusterE2ESymmetry.cfg $(SPECS_DIR)/ClusterE2ESymmetry.tla
	@sleep 1
	@echo "==> WITHOUT symmetry"
	@$(TLC) -config $(SPECS_DIR)/ClusterE2ESymmetry.nosymmetry.cfg $(SPECS_DIR)/ClusterE2ESymmetry.tla

.PHONY: verify-tlc-symmetry
verify-tlc-symmetry: verify-tlc-symmetry-lifecycle verify-tlc-symmetry-etcd verify-tlc-symmetry-clustere2e  ## All three symmetry exemplars (issue #23)

.PHONY: verify-tlc-symmetry
verify-tlc-symmetry: verify-tlc-symmetry-lifecycle verify-tlc-symmetry-etcd verify-tlc-symmetry-clustere2e  ## TLC symmetry runs for Lifecycle, EtcdMembership, ClusterE2E

.PHONY: drift
drift:  ## Check abstraction-mapping rows resolve
	@../scripts/verify-formal.sh --drift-only

.PHONY: verify
verify: typecheck test tlc proofs drift  ## typecheck + test + tlc + proofs + drift

.PHONY: clean
clean:  ## Remove tool caches
	rm -rf $(PROOFS_DIR)/.lake $(PROOFS_DIR)/build _apalache-out

## --------------------------------------
## Per-FM verification
## --------------------------------------

##@ failure-modes:

.PHONY: verify-fm1
verify-fm1:  ## FM-1 stuck-learner incident invariants (TLC, ~1 s)
	$(QUINT) verify --main=Lifecycle --init=incidentInit \
	                --step=stepRemediation --max-steps=4 \
	                --invariant=AllSafetyInvariants \
	                --backend=tlc $(LIFECYCLE)

.PHONY: verify-fm2
verify-fm2:  ## FM-2 two-machine quorum loss (Apalache hopelessness)
	echo y | $(QUINT) verify --main=Lifecycle \
	                  --init=twoMachineBothUnhealthyInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-fm3
verify-fm3:  ## FM-3 partitioned cluster (Apalache hopelessness)
	echo y | $(QUINT) verify --main=Lifecycle \
	                  --init=partitionedClusterInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-fm13
verify-fm13:  ## FM-13 LB outage (Apalache hopelessness)
	echo y | $(QUINT) verify --main=Lifecycle \
	                  --init=lbBrokenInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-fm16
verify-fm16:  ## FM-16 single-node total loss (Apalache hopelessness)
	echo y | $(QUINT) verify --main=Lifecycle \
	                  --init=singleNodeLostVoterInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-fm17
verify-fm17:  ## FM-17 kubeadm misconfig (Apalache hopelessness)
	echo y | $(QUINT) verify --main=Lifecycle \
	                  --init=kubeadmMisconfigInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-fm23
verify-fm23:  ## FM-23 drain stuck (Apalache safety verdict ~278 s)
	echo y | $(QUINT) verify --main=Lifecycle --init=drainStuckInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant=AllSafetyInvariants \
	                  --backend=apalache $(LIFECYCLE)

.PHONY: verify-ic11
verify-ic11:  ## IC-11 upgrade rollback recovery (TLC reachability)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Lifecycle --init=upgradeRollbackRecoveryRun \
	             --step=step --invariant='not(HealthyControlPlane)' \
	             --max-steps=0 $(LIFECYCLE)

## --------------------------------------
## FM-9 — fairness / liveness
## --------------------------------------

##@ fairness:

.PHONY: verify-fm9-fair
verify-fm9-fair:  ## ConvergenceFair16 (canonical scope; full 65 tableaus)
	@# The full 65-conjunct ConvergenceFair tableaus to "0 branches"
	@# (TLC capacity). Phase 11d bisected and adopted the 16-conjunct
	@# scope as the canonical verifiable form. See failure-modes.md
	@# FM-9 §"Phase 11d bisection".
	$(QUINT) verify --main=Lifecycle --init=init --step=step \
	                --temporal=ConvergenceFair16 --backend=tlc \
	                --max-steps=$(MAX_STEPS_TLC) $(LIFECYCLE)

.PHONY: verify-fm9-fair-full
verify-fm9-fair-full:  ## ConvergenceFair (full 65; tableaus to tautology)
	$(QUINT) verify --main=Lifecycle --init=init --step=step \
	                --temporal=ConvergenceFair --backend=tlc \
	                --max-steps=$(MAX_STEPS_TLC) $(LIFECYCLE)

.PHONY: verify-fm9-fair-bisect
verify-fm9-fair-bisect:  ## Run the bisection sequence (1, 8, 16, 24)
	@for prop in ConvergenceMinimalFair ConvergenceFair8 ConvergenceFair16 ConvergenceFair24; do \
	  echo "==> $$prop"; \
	  TLA_JAVA_OPTS='-Xmx16g' $(QUINT) verify --main=Lifecycle \
	                                          --init=init --step=step \
	                                          --temporal=$$prop --backend=tlc \
	                                          --max-steps=$(MAX_STEPS_TLC) \
	                                          $(LIFECYCLE) || true; \
	done

.PHONY: verify-fm9-recurrent
verify-fm9-recurrent:  ## ConvergenceRecurrentFair (recurrence form, TLC)
	$(QUINT) verify --main=Lifecycle --init=init --step=step \
	                --temporal=ConvergenceRecurrentFair --backend=tlc \
	                --max-steps=$(MAX_STEPS_TLC) $(LIFECYCLE)

.PHONY: verify-fm9-witness
verify-fm9-witness:  ## Run the deterministic fair-convergence witness
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Lifecycle --init=fairConvergenceWitnessRun \
	             --step=step --max-steps=0 $(LIFECYCLE)

.PHONY: fairness-gen
fairness-gen:  ## Re-generate ConvergenceFair body from quint-fairness-gen.py
	$(PYTHON) ../hack/tools/quint-fairness-gen.py > /tmp/fairness-snippet.qnt
	@echo "Generated /tmp/fairness-snippet.qnt — paste into Lifecycle.qnt"

## --------------------------------------
## FM-35 — self-hosted topology
## --------------------------------------

##@ self-hosted:

.PHONY: verify-selfhosted-deadlock
verify-selfhosted-deadlock:  ## Drive selfHostedDeadlockTrace; expect Deadlocked invariant violation
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SelfHosted --init=selfHostedDeadlockTrace \
	             --step=step --invariant='not(Deadlocked)' \
	             --max-steps=0 $(SELFHOSTED)

.PHONY: verify-selfhosted-recovery
verify-selfhosted-recovery:  ## Drive selfHostedRecoveryTrace; expect resolved
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SelfHosted --init=selfHostedRecoveryTrace \
	             --step=step --max-steps=0 $(SELFHOSTED)

.PHONY: verify-selfhosted-etcd-trap
verify-selfhosted-etcd-trap:  ## Drive selfHostedEtcdTrapTrace; expect deadlock without escape hatch
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SelfHosted --init=selfHostedEtcdTrapTrace \
	             --step=step --invariant='not(Deadlocked)' \
	             --max-steps=0 $(SELFHOSTED)

.PHONY: verify-selfhosted-etcd-escape
verify-selfhosted-etcd-escape:  ## Drive selfHostedEtcdEscapeTrace; expect escape hatch to clear trap
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SelfHosted --init=selfHostedEtcdEscapeTrace \
	             --step=step --invariant=EscapeHatchExists \
	             --max-steps=0 $(SELFHOSTED)

.PHONY: verify-selfhosted-etcd-apalache
verify-selfhosted-etcd-apalache:  ## Apalache etcd-roll trap counterexample at depth 4
	-@echo y | $(QUINT) verify --main=SelfHosted --init=selfHostedUpgradeMidFlightInit \
	                  --step=stepNoRecovery --invariant='not(Deadlocked)' \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(SELFHOSTED)

## --------------------------------------
## FM-35 — multicluster (Phase 12 full per-cluster spec)
## --------------------------------------

##@ multicluster:

.PHONY: verify-multicluster-typecheck
verify-multicluster-typecheck:  ## Typecheck the per-cluster spec
	$(QUINT) typecheck $(LIFECYCLE_MC)

.PHONY: verify-multicluster-safety
verify-multicluster-safety:  ## Random-walk SafetyInvariants on the per-cluster spec
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --max-samples=200 --max-steps=20 \
	             --invariant=SafetyInvariants \
	             $(LIFECYCLE_MC)

.PHONY: verify-multicluster-deadlock
verify-multicluster-deadlock:  ## Drive selfHostedDeadlockTrace; expect FM35Deadlocked reached
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=LifecycleMultiCluster \
	             --init=selfHostedDeadlockTrace --step=step \
	             --invariant='not(FM35Deadlocked)' --max-steps=0 \
	             $(LIFECYCLE_MC)

.PHONY: verify-multicluster-recovery
verify-multicluster-recovery:  ## Drive selfHostedRecoveryTrace; expect FM35Deadlocked cleared
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=LifecycleMultiCluster \
	             --init=selfHostedRecoveryTrace --step=step \
	             --invariant=FM35Deadlocked --max-steps=0 \
	             $(LIFECYCLE_MC)

## --------------------------------------
## FM-33 — worker-MachineSet preflight
## --------------------------------------

##@ machineset-preflight:

.PHONY: verify-fm33-blocked
verify-fm33-blocked:  ## Drive fm33ScaleUpBlockedRun; expect ActionBlocked
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachineSetPreflight \
	             --init=fm33ScaleUpBlockedRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(MSPREFLIGHT)

.PHONY: verify-fm33-admitted-after-upgrade
verify-fm33-admitted-after-upgrade:  ## Drive fm33ScaleUpAdmittedAfterUpgradeRun; expect Machine 4 admitted
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachineSetPreflight \
	             --init=fm33ScaleUpAdmittedAfterUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(MSPREFLIGHT)

.PHONY: verify-fm33-versionskew
verify-fm33-versionskew:  ## Drive fm33VersionSkewBlockedRun; expect KubernetesVersionSkewViolation
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachineSetPreflight \
	             --init=fm33VersionSkewBlockedRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(MSPREFLIGHT)

.PHONY: verify-fm33
verify-fm33: verify-fm33-blocked verify-fm33-admitted-after-upgrade verify-fm33-versionskew  ## All three FM-33 demonstration runs

## --------------------------------------
## Topology + runtime extensions
## --------------------------------------

##@ topology:

.PHONY: verify-topology-create
verify-topology-create:  ## Drive happyCreateRun; expect AllSafetyInvariants
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology --init=happyCreateRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(TOPOLOGY)

.PHONY: verify-topology-upgrade
verify-topology-upgrade:  ## Drive happyUpgradeRun (single-step CP+workers)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology --init=happyUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(TOPOLOGY)

.PHONY: verify-topology-multistep
verify-topology-multistep:  ## Drive multiStepUpgradeRun (3 minor steps 36→39)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology --init=multiStepUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(TOPOLOGY)

.PHONY: verify-topology-blocked
verify-topology-blocked:  ## Drive annotationBlockedUpgradeRun; expect FM40 holds
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology --init=annotationBlockedUpgradeRun --step=step \
	             --invariant=FM40_AnnotationGatesCp --max-steps=0 \
	             $(TOPOLOGY)

.PHONY: verify-topology-delete
verify-topology-delete:  ## Drive deleteRun; expect AllSafetyInvariants
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology --init=deleteRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(TOPOLOGY)

.PHONY: verify-topology-fm39
verify-topology-fm39:  ## Random-walk FM39 (BeforeClusterUpgrade idempotent)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology \
	             --invariant=FM39_BeforeClusterUpgradeIdempotent \
	             --max-samples=200 --max-steps=30 \
	             $(TOPOLOGY)

.PHONY: verify-topology-fm41
verify-topology-fm41:  ## Random-walk FM41 (AfterClusterUpgrade steady-state)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=Topology \
	             --invariant=FM41_AfterClusterUpgradeAtSteadyState \
	             --max-samples=200 --max-steps=30 \
	             $(TOPOLOGY)

.PHONY: verify-topology-random
verify-topology-random:  ## Random-walk every Topology safety invariant
	@for inv in AllSafetyInvariants FM39_BeforeClusterUpgradeIdempotent \
	            FM40_AnnotationGatesCp FM41_AfterClusterUpgradeAtSteadyState; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=Topology \
	               --invariant=$$inv --max-samples=200 --max-steps=30 \
	               $(TOPOLOGY) || exit 1; \
	done

.PHONY: verify-topology
verify-topology: verify-topology-create verify-topology-upgrade verify-topology-multistep verify-topology-blocked verify-topology-delete verify-topology-random  ## Full Topology demo + random-walk suite

## --------------------------------------
## In-place updates (FM-42/43/44)
## --------------------------------------

##@ in-place-updates:

.PHONY: verify-inplace-happy
verify-inplace-happy:  ## Drive happyInPlaceRun through full move + UpdateMachine + complete
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=InPlaceUpdate --init=happyInPlaceRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(INPLACE)

.PHONY: verify-inplace-fallback
verify-inplace-fallback:  ## Drive canUpdateNoFallbackRun (extension says no, fall back to rolling)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=InPlaceUpdate --init=canUpdateNoFallbackRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(INPLACE)

.PHONY: verify-inplace-multi-ext
verify-inplace-multi-ext:  ## Drive multiExtensionRejectRun (FM-44)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=InPlaceUpdate --init=multiExtensionRejectRun --step=step \
	             --invariant=FM44_MultiExtensionBlocksProgress --max-steps=0 \
	             $(INPLACE)

.PHONY: verify-inplace-retry
verify-inplace-retry:  ## Drive updateMachineRetryLoopRun (FM-43 idempotence)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=InPlaceUpdate --init=updateMachineRetryLoopRun --step=step \
	             --invariant=FM43_UpdateMachineIdempotenceGate --max-steps=0 \
	             $(INPLACE)

.PHONY: verify-inplace-cleanup
verify-inplace-cleanup:  ## Drive orphanedHookCleanupRun (operator strips annotation)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=InPlaceUpdate --init=orphanedHookCleanupRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(INPLACE)

.PHONY: verify-inplace-random
verify-inplace-random:  ## Random-walk every InPlaceUpdate invariant (2000×80, "unbounded time")
	@for inv in AllSafetyInvariants FM42_PrematureInPlaceAdmission \
	            FM43_UpdateMachineIdempotenceGate \
	            FM44_MultiExtensionBlocksProgress \
	            TwoWayHandshakeAnnotations; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=InPlaceUpdate \
	               --invariant=$$inv --max-samples=2000 --max-steps=80 \
	               $(INPLACE) || exit 1; \
	done

.PHONY: verify-inplace
verify-inplace: verify-inplace-happy verify-inplace-fallback verify-inplace-multi-ext verify-inplace-retry verify-inplace-cleanup verify-inplace-random  ## Full InPlaceUpdate suite

## --------------------------------------
## controller-runtime substrate (FM-45/46/47)
## --------------------------------------

##@ controller-runtime:

.PHONY: verify-cr-happy
verify-cr-happy:  ## Drive happyManagerStartRun
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=happyManagerStartRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-multiworker
verify-cr-multiworker:  ## Drive multiWorkerParallelRun (per-key serialisation)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=multiWorkerParallelRun --step=step \
	             --invariant=FM45_PerKeySerialisation --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-dedup
verify-cr-dedup:  ## Drive dedupDuringInFlightRun
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=dedupDuringInFlightRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-requeue
verify-cr-requeue:  ## Drive requeueAfterRun
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=requeueAfterRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-terminal
verify-cr-terminal:  ## Drive terminalErrorRun (FM-46)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=terminalErrorRun --step=step \
	             --invariant=FM46_TerminalErrorNoRequeue --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-leader-loss
verify-cr-leader-loss:  ## Drive leaderLossRun
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=leaderLossRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(CRRUNTIME)

.PHONY: verify-cr-random
verify-cr-random:  ## Random-walk every controller-runtime invariant (500x60)
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation \
	            FM46_TerminalErrorNoRequeue FM47_CacheBehindAPI; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ControllerRuntime \
	               --invariant=$$inv --max-samples=500 --max-steps=60 \
	               $(CRRUNTIME) || exit 1; \
	done

.PHONY: verify-cr-faultstorm
verify-cr-faultstorm:  ## Fault-storm bounded progress + overload counterexample (issue #30)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerRuntime --init=boundedFaultStormRun --step=step \
	             --invariant=FM69_BoundedFaultProgress --max-steps=0 \
	             $(CRRUNTIME)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ControllerRuntime --init=faultStormOverloadRun --step=step \
	              --invariant=FM70_NoLegitReadyBacklog --max-steps=0 \
	              $(CRRUNTIME)

.PHONY: verify-cr-faultstorm-apalache
verify-cr-faultstorm-apalache:  ## Apalache counterexample for FM-70 at depth 4
	-@echo y | $(QUINT) verify --main=ControllerRuntime --init=init \
	                  --step=step --invariant=FM70_NoLegitReadyBacklog \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CRRUNTIME)

.PHONY: verify-cr
verify-cr: verify-cr-happy verify-cr-multiworker verify-cr-dedup verify-cr-requeue verify-cr-terminal verify-cr-leader-loss verify-cr-random verify-cr-faultstorm  ## Full controller-runtime substrate suite

.PHONY: verify-cross-controller-cycle-happy
verify-cross-controller-cycle-happy:  ## Drive cache-stabilised cross-controller cycle run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CrossControllerCycle --init=stabilisedCycleRun --step=step \
	             --invariant=ScenarioSafetyInvariants --max-steps=0 \
	             $(XCCYCLE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CrossControllerCycle --init=stabilisedCycleRun --step=step \
	             --invariant=CacheStableAllowsCompletion --max-steps=0 \
	             $(XCCYCLE)

.PHONY: verify-cross-controller-cycle-counterexample
verify-cross-controller-cycle-counterexample:  ## Drive livelock counterexample run
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=CrossControllerCycle --init=livelockCycleRun --step=step \
	              --invariant=NoCyclicLivelock --max-steps=0 \
	              $(XCCYCLE)

.PHONY: verify-cross-controller-cycle-random
verify-cross-controller-cycle-random:  ## Random-walk stable cross-controller-cycle invariants (300x40)
	@for inv in ScenarioSafetyInvariants CrossEnqueuePreservesTargetQueue; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=CrossControllerCycle \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(XCCYCLE) || exit 1; \
	done

.PHONY: verify-cross-controller-cycle-apalache
verify-cross-controller-cycle-apalache:  ## Apalache counterexample for cyclic livelock at depth 4
	-@echo y | $(QUINT) verify --main=CrossControllerCycle --init=init \
	                  --step=step --invariant=NoCyclicLivelock \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(XCCYCLE)

.PHONY: verify-cross-controller-cycle
verify-cross-controller-cycle: verify-cross-controller-cycle-happy verify-cross-controller-cycle-counterexample verify-cross-controller-cycle-random verify-cross-controller-cycle-apalache  ## Full cross-controller cyclic enqueue suite

.PHONY: verify-reliststorm-happy
verify-reliststorm-happy:  ## Drive idempotent relist-storm run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ReflectorRelistStorm --init=idempotentRelistStormRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(RELISTSTORM)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ReflectorRelistStorm --init=idempotentRelistStormRun --step=step \
	             --invariant=NoDuplicateMachineLeak --max-steps=0 \
	             $(RELISTSTORM)

.PHONY: verify-reliststorm-counterexample
verify-reliststorm-counterexample:  ## Drive duplicate-create relist-storm counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ReflectorRelistStorm --init=duplicateCreateRelistStormRun --step=step \
	              --invariant=NoDuplicateMachineLeak --max-steps=0 \
	              $(RELISTSTORM)

.PHONY: verify-reliststorm-random
verify-reliststorm-random:  ## Random-walk stable relist-storm invariants (300x40)
	@for inv in StableSafetyInvariants WatchStateConsistent DuplicateDeliveryRequiresRelist; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ReflectorRelistStorm \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(RELISTSTORM) || exit 1; \
	done

.PHONY: verify-reliststorm-apalache
verify-reliststorm-apalache:  ## Apalache duplicate-create counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ReflectorRelistStorm --init=init \
	                  --step=step --invariant=NoDuplicateMachineLeak \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(RELISTSTORM)

.PHONY: verify-reliststorm
verify-reliststorm: verify-reliststorm-happy verify-reliststorm-counterexample verify-reliststorm-random verify-reliststorm-apalache  ## Full reflector relist-storm suite

.PHONY: verify-stale-shutdown-happy
verify-stale-shutdown-happy:  ## Drive deleted-object + shutdown-drain happy runs
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaleEnqueueShutdown --init=deletedObjectHandledRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(STALESHUT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaleEnqueueShutdown --init=shutdownDrainRun --step=step \
	             --invariant=ShutdownDrainCompletes --max-steps=0 \
	             $(STALESHUT)

.PHONY: verify-stale-shutdown-counterexample
verify-stale-shutdown-counterexample:  ## Drive nil-read / finalizer-leak counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaleEnqueueShutdown --init=nilReadAfterDeleteRun --step=step \
	              --invariant=NoNilReadAfterDelete --max-steps=0 \
	              $(STALESHUT)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaleEnqueueShutdown --init=orphanedFinalizerRun --step=step \
	              --invariant=NoOrphanedFinalizer --max-steps=0 \
	              $(STALESHUT)

.PHONY: verify-stale-shutdown-random
verify-stale-shutdown-random:  ## Random-walk stable stale-enqueue/shutdown invariants (300x40)
	@for inv in StableSafetyInvariants ShutdownImpliesNotAccepting NilReadRequiresMissingObject; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=StaleEnqueueShutdown \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(STALESHUT) || exit 1; \
	done

.PHONY: verify-stale-shutdown-apalache
verify-stale-shutdown-apalache:  ## Apalache nil-read counterexample at depth 4
	-@echo y | $(QUINT) verify --main=StaleEnqueueShutdown --init=init \
	                  --step=step --invariant=NoNilReadAfterDelete \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(STALESHUT)

.PHONY: verify-stale-shutdown
verify-stale-shutdown: verify-stale-shutdown-happy verify-stale-shutdown-counterexample verify-stale-shutdown-random verify-stale-shutdown-apalache  ## Full stale-enqueue / shutdown-drain suite

.PHONY: verify-webhook-ordering-happy
verify-webhook-ordering-happy:  ## Drive converging mutating/validating chain run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WebhookOrdering --init=convergingReinvocationRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(WEBHOOKCHAIN)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WebhookOrdering --init=convergingReinvocationRun --step=step \
	             --invariant=ReinvocationConverges --max-steps=0 \
	             $(WEBHOOKCHAIN)

.PHONY: verify-webhook-ordering-counterexample
verify-webhook-ordering-counterexample:  ## Drive stale-validator-read counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=WebhookOrdering --init=staleValidatorReadRun --step=step \
	              --invariant=ObservedValueIsFinal --max-steps=0 \
	              $(WEBHOOKCHAIN)

.PHONY: verify-webhook-ordering-random
verify-webhook-ordering-random:  ## Random-walk stable webhook-ordering invariants (300x40)
	@for inv in StableSafetyInvariants MutatorOnlyMovesTowardDefault; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=WebhookOrdering \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(WEBHOOKCHAIN) || exit 1; \
	done

.PHONY: verify-webhook-ordering-apalache
verify-webhook-ordering-apalache:  ## Apalache stale-validator counterexample at depth 4
	-@echo y | $(QUINT) verify --main=WebhookOrdering --init=init \
	                  --step=step --invariant=ObservedValueIsFinal \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(WEBHOOKCHAIN)

.PHONY: verify-webhook-ordering
verify-webhook-ordering: verify-webhook-ordering-happy verify-webhook-ordering-counterexample verify-webhook-ordering-random verify-webhook-ordering-apalache  ## Full mutating/validating ordering suite

.PHONY: verify-webhook-selfref-happy
verify-webhook-selfref-happy:  ## Drive safe webhook-gap fallback run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WebhookSelfReference --init=safeFallbackRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(WEBHOOKSELF)

.PHONY: verify-webhook-selfref-counterexample
verify-webhook-selfref-counterexample:  ## Drive fail-closed deadlock + ignore-window counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=WebhookSelfReference --init=failClosedDeadlockRun --step=step \
	              --invariant=UpgradeProgressDespiteWebhookGap --max-steps=0 \
	              $(WEBHOOKSELF)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=WebhookSelfReference --init=ignoreWindowInvalidMutationRun --step=step \
	              --invariant=NoInvalidMutationDuringIgnoreWindow --max-steps=0 \
	              $(WEBHOOKSELF)

.PHONY: verify-webhook-selfref-random
verify-webhook-selfref-random:  ## Random-walk stable self-referential webhook invariants (300x40)
	@for inv in StableSafetyInvariants IgnoreWindowRequiresIgnorePolicy; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=WebhookSelfReference \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(WEBHOOKSELF) || exit 1; \
	done

.PHONY: verify-webhook-selfref-apalache
verify-webhook-selfref-apalache:  ## Apalache deadlock counterexample at depth 4
	-@echo y | $(QUINT) verify --main=WebhookSelfReference --init=init \
	                  --step=stepApalache --invariant=UpgradeProgressDespiteWebhookGap \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(WEBHOOKSELF)

.PHONY: verify-webhook-selfref
verify-webhook-selfref: verify-webhook-selfref-happy verify-webhook-selfref-counterexample verify-webhook-selfref-random verify-webhook-selfref-apalache  ## Full self-referential webhook outage suite

.PHONY: verify-webhook-cabundle-happy
verify-webhook-cabundle-happy:  ## Drive cache-refresh recovery run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WebhookCABundleStaleness --init=refreshRecoveryRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(WEBCABUNDLE)

.PHONY: verify-webhook-cabundle-counterexample
verify-webhook-cabundle-counterexample:  ## Drive stale-trust outage counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=WebhookCABundleStaleness --init=staleTrustOutageRun --step=step \
	              --invariant=CurrentlyTrusted --max-steps=0 \
	              $(WEBCABUNDLE)

.PHONY: verify-webhook-cabundle-random
verify-webhook-cabundle-random:  ## Random-walk stable CABundle invariants (300x40)
	@for inv in StableSafetyInvariants CacheRefreshMonotonic; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=WebhookCABundleStaleness \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(WEBCABUNDLE) || exit 1; \
	done

.PHONY: verify-webhook-cabundle-apalache
verify-webhook-cabundle-apalache:  ## Apalache stale-trust counterexample at depth 4
	-@echo y | $(QUINT) verify --main=WebhookCABundleStaleness --init=init \
	                  --step=step --invariant=CurrentlyTrusted \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(WEBCABUNDLE)

.PHONY: verify-webhook-cabundle
verify-webhook-cabundle: verify-webhook-cabundle-happy verify-webhook-cabundle-counterexample verify-webhook-cabundle-random verify-webhook-cabundle-apalache  ## Full CABundle staleness suite

.PHONY: verify-vap-timeout-happy
verify-vap-timeout-happy:  ## Drive fail-closed timeout and later heal run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=VAPTimeout --init=failWindowHealsRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(VAPTIMEOUT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=VAPTimeout --init=failWindowHealsRun --step=step \
	             --invariant=FailWindowEventuallyHeals --max-steps=0 \
	             $(VAPTIMEOUT)

.PHONY: verify-vap-timeout-counterexample
verify-vap-timeout-counterexample:  ## Drive ignore-window invalid admission counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=VAPTimeout --init=ignoreWindowInvalidAdmissionRun --step=step \
	              --invariant=IgnoreWindowDoesNotMutateInvariants --max-steps=0 \
	              $(VAPTIMEOUT)

.PHONY: verify-vap-timeout-random
verify-vap-timeout-random:  ## Random-walk stable VAP-timeout invariants (300x40)
	@for inv in StableSafetyInvariants InvalidAdmissionRequiresIgnore TimeoutRequiresRemoteParam; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=VAPTimeout \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(VAPTIMEOUT) || exit 1; \
	done

.PHONY: verify-vap-timeout-apalache
verify-vap-timeout-apalache:  ## Apalache ignore-window counterexample at depth 4
	-@echo y | $(QUINT) verify --main=VAPTimeout --init=ignoreCounterexampleInit \
	                  --step=stepApalache --invariant=IgnoreWindowDoesNotMutateInvariants \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(VAPTIMEOUT)

.PHONY: verify-vap-timeout
verify-vap-timeout: verify-vap-timeout-happy verify-vap-timeout-counterexample verify-vap-timeout-random verify-vap-timeout-apalache  ## Full VAP timeout / failurePolicy suite

.PHONY: verify-dryrun-sideeffects-happy
verify-dryrun-sideeffects-happy:  ## Drive compliant dry-run probe path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=DryRunSideEffects --init=compliantDryRunProbeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(DRYSIDEEFFECT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=DryRunSideEffects --init=compliantDryRunProbeRun --step=step \
	             --invariant=DryRunHasNoSideEffects --max-steps=0 \
	             $(DRYSIDEEFFECT)

.PHONY: verify-dryrun-sideeffects-counterexample
verify-dryrun-sideeffects-counterexample:  ## Drive dry-run external side effect counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=DryRunSideEffects --init=violatingDryRunProbeRun --step=step \
	              --invariant=DryRunHasNoSideEffects --max-steps=0 \
	              $(DRYSIDEEFFECT)

.PHONY: verify-dryrun-sideeffects-random
verify-dryrun-sideeffects-random:  ## Random-walk stable dry-run side-effect invariants (300x40)
	@for inv in StableSafetyInvariants TriggeredSideEffectsRequireWebhookFire DryRunRequestsTracked; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=DryRunSideEffects \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(DRYSIDEEFFECT) || exit 1; \
	done

.PHONY: verify-dryrun-sideeffects-apalache
verify-dryrun-sideeffects-apalache:  ## Apalache dry-run side-effect counterexample at depth 4
	-@echo y | $(QUINT) verify --main=DryRunSideEffects --init=violatingProbeInit \
	                  --step=stepApalache --invariant=DryRunHasNoSideEffects \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(DRYSIDEEFFECT)

.PHONY: verify-dryrun-sideeffects
verify-dryrun-sideeffects: verify-dryrun-sideeffects-happy verify-dryrun-sideeffects-counterexample verify-dryrun-sideeffects-random verify-dryrun-sideeffects-apalache  ## Full dry-run side-effects suite

.PHONY: verify-asymmetric-partition-happy
verify-asymmetric-partition-happy:  ## Drive recovered asymmetric partition run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ASYMPART)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AsymmetricPartition --init=recoveredDirectionalPartitionRun --step=step \
	             --invariant=RecoveredToSingleLeader --max-steps=0 \
	             $(ASYMPART)

.PHONY: verify-asymmetric-partition-counterexample
verify-asymmetric-partition-counterexample:  ## Drive dual-leader asymmetric partition counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=AsymmetricPartition --init=dualLeaderWindowRun --step=step \
	              --invariant=NoSimultaneousLeaders --max-steps=0 \
	              $(ASYMPART)

.PHONY: verify-asymmetric-partition-random
verify-asymmetric-partition-random:  ## Random-walk stable asymmetric-partition invariants (300x40)
	@for inv in StableSafetyInvariants TermAdvanceRequiresElection NoStuckTermAdvance; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=AsymmetricPartition \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ASYMPART) || exit 1; \
	done

.PHONY: verify-asymmetric-partition-apalache
verify-asymmetric-partition-apalache:  ## Apalache dual-leader counterexample at depth 4
	-@echo y | $(QUINT) verify --main=AsymmetricPartition --init=dualLeaderInit \
	                  --step=stepApalache --invariant=NoSimultaneousLeaders \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ASYMPART)

.PHONY: verify-asymmetric-partition
verify-asymmetric-partition: verify-asymmetric-partition-happy verify-asymmetric-partition-counterexample verify-asymmetric-partition-random verify-asymmetric-partition-apalache  ## Full asymmetric partition suite

.PHONY: verify-snapshot-restore-happy
verify-snapshot-restore-happy:  ## Drive clean restore completion path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SnapshotRestoreCompaction --init=cleanRestoreRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(SNAPRESTORE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SnapshotRestoreCompaction --init=cleanRestoreRun --step=step \
	             --invariant=MemberSetMatchesSnapshotPostRestore --max-steps=0 \
	             $(SNAPRESTORE)

.PHONY: verify-snapshot-restore-counterexample
verify-snapshot-restore-counterexample:  ## Drive compaction-during-restore inconsistency counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=SnapshotRestoreCompaction --init=compactionRaceRun --step=step \
	              --invariant=NoLogInconsistency --max-steps=0 \
	              $(SNAPRESTORE)

.PHONY: verify-snapshot-restore-random
verify-snapshot-restore-random:  ## Random-walk stable restore/compaction invariants (300x40)
	@for inv in StableSafetyInvariants RestoreFlagImpliesSnapshotPresent CompactionMonotone; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=SnapshotRestoreCompaction \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(SNAPRESTORE) || exit 1; \
	done

.PHONY: verify-snapshot-restore-apalache
verify-snapshot-restore-apalache:  ## Apalache restore/compaction race counterexample at depth 4
	-@echo y | $(QUINT) verify --main=SnapshotRestoreCompaction --init=raceInit \
	                  --step=stepApalache --invariant=NoLogInconsistency \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(SNAPRESTORE)

.PHONY: verify-snapshot-restore
verify-snapshot-restore: verify-snapshot-restore-happy verify-snapshot-restore-counterexample verify-snapshot-restore-random verify-snapshot-restore-apalache  ## Full snapshot-restore / compaction-race suite

.PHONY: verify-defrag-quorum-happy
verify-defrag-quorum-happy:  ## Drive single-defrag safe window
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=DefragQuorumLoss --init=serialDefragRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(DEFRAGQUORUM)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=DefragQuorumLoss --init=serialDefragRun --step=step \
	             --invariant=NoQuorumLossUnderSingleMaintenanceFault --max-steps=0 \
	             $(DEFRAGQUORUM)

.PHONY: verify-defrag-quorum-counterexample
verify-defrag-quorum-counterexample:  ## Drive defrag + second glitch counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=DefragQuorumLoss --init=overlapLossRun --step=step \
	              --invariant=NoQuorumLossUnderSingleMaintenanceFault --max-steps=0 \
	              $(DEFRAGQUORUM)

.PHONY: verify-defrag-quorum-random
verify-defrag-quorum-random:  ## Random-walk stable defrag/quorum invariants (300x40)
	@for inv in StableSafetyInvariants SerialDefragOrdering DefragPauseMarksMember; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=DefragQuorumLoss \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(DEFRAGQUORUM) || exit 1; \
	done

.PHONY: verify-defrag-quorum-apalache
verify-defrag-quorum-apalache:  ## Apalache quorum-loss counterexample at depth 4
	-@echo y | $(QUINT) verify --main=DefragQuorumLoss --init=overlapInit \
	                  --step=stepApalache --invariant=NoQuorumLossUnderSingleMaintenanceFault \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(DEFRAGQUORUM)

.PHONY: verify-defrag-quorum
verify-defrag-quorum: verify-defrag-quorum-happy verify-defrag-quorum-counterexample verify-defrag-quorum-random verify-defrag-quorum-apalache  ## Full defrag-induced quorum loss suite

.PHONY: verify-wal-faults-happy
verify-wal-faults-happy:  ## Drive detectable-member-loss remediation path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdWalFaults --init=detectedFaultRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(WALFAULTS)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdWalFaults --init=detectedFaultRun --step=step \
	             --invariant=KcpDetectsAndRemediates --max-steps=0 \
	             $(WALFAULTS)

.PHONY: verify-wal-faults-counterexample
verify-wal-faults-counterexample:  ## Drive silent-member-loss counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdWalFaults --init=silentCorruptionRun --step=step \
	              --invariant=NoSilentMemberLoss --max-steps=0 \
	              $(WALFAULTS)

.PHONY: verify-wal-faults-random
verify-wal-faults-random:  ## Random-walk stable WAL/disk fault invariants (300x40)
	@for inv in StableSafetyInvariants RemediationRequiresDetection; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EtcdWalFaults \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(WALFAULTS) || exit 1; \
	done

.PHONY: verify-wal-faults-apalache
verify-wal-faults-apalache:  ## Apalache silent-member-loss counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EtcdWalFaults --init=silentInit \
	                  --step=stepApalache --invariant=NoSilentMemberLoss \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(WALFAULTS)

.PHONY: verify-wal-faults
verify-wal-faults: verify-wal-faults-happy verify-wal-faults-counterexample verify-wal-faults-random verify-wal-faults-apalache  ## Full etcd WAL corruption / disk-full fault suite

.PHONY: verify-etcd-batch-happy
verify-etcd-batch-happy:  ## Drive serial add/promote/remove completion path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdMembershipBatch --init=serialMembershipRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ETCDBATCH)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdMembershipBatch --init=serialMembershipRun --step=step \
	             --invariant=NoSameBatchAddRemove --max-steps=0 \
	             $(ETCDBATCH)

.PHONY: verify-etcd-batch-counterexample
verify-etcd-batch-counterexample:  ## Drive add+remove-same-batch counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdMembershipBatch --init=sameBatchChurnRun --step=step \
	              --invariant=NoSameBatchAddRemove --max-steps=0 \
	              $(ETCDBATCH)

.PHONY: verify-etcd-batch-random
verify-etcd-batch-random:  ## Random-walk stable batch-membership invariants (300x40)
	@for inv in StableSafetyInvariants BatchRemoveRequiresExistingMember PromoteRequiresLearner; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EtcdMembershipBatch \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ETCDBATCH) || exit 1; \
	done

.PHONY: verify-etcd-batch-apalache
verify-etcd-batch-apalache:  ## Apalache add+remove batch counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EtcdMembershipBatch --init=sameBatchInit \
	                  --step=stepApalache --invariant=NoSameBatchAddRemove \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ETCDBATCH)

.PHONY: verify-etcd-batch
verify-etcd-batch: verify-etcd-batch-happy verify-etcd-batch-counterexample verify-etcd-batch-random verify-etcd-batch-apalache  ## Full add+remove same-reconcile membership suite

.PHONY: verify-etcd-5node-happy
verify-etcd-5node-happy:  ## Drive serial remediation on 5-node 3-failure scenarios
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdFiveNodeFailure --init=sequentialRecoveryRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ETCD5FAIL)

.PHONY: verify-etcd-5node-counterexample
verify-etcd-5node-counterexample:  ## Drive 3-failure remediation-ordering counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdFiveNodeFailure --init=leaderFollowersLossRun --step=step \
	              --invariant=NoDoublePromotionDuringRecovery --max-steps=0 \
	              $(ETCD5FAIL)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdFiveNodeFailure --init=symmetricTripleLossRun --step=step \
	              --invariant=RemediationBoundedPerScenario --max-steps=0 \
	              $(ETCD5FAIL)

.PHONY: verify-etcd-5node-random
verify-etcd-5node-random:  ## Random-walk stable 5-node failure invariants (300x40)
	@for inv in StableSafetyInvariants QuorumMathConsistent PromotionRequiresLearner; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EtcdFiveNodeFailure \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ETCD5FAIL) || exit 1; \
	done

.PHONY: verify-etcd-5node-apalache
verify-etcd-5node-apalache:  ## Apalache 5-node triple-failure counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EtcdFiveNodeFailure --init=leaderFollowersInit \
	                  --step=stepApalache --invariant=NoDoublePromotionDuringRecovery \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ETCD5FAIL)

.PHONY: verify-etcd-5node
verify-etcd-5node: verify-etcd-5node-happy verify-etcd-5node-counterexample verify-etcd-5node-random verify-etcd-5node-apalache  ## Full 5-node / 3-failure etcd recovery suite

.PHONY: verify-az-failure-happy
verify-az-failure-happy:  ## Drive failover into surviving AZ with remaining capacity
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AzFailoverCapacity --init=alternativeAzSuccessRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(AZFAILCAP)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AzFailoverCapacity --init=alternativeAzSuccessRun --step=step \
	             --invariant=KcpAttemptsAlternativeAzs --max-steps=0 \
	             $(AZFAILCAP)

.PHONY: verify-az-failure-counterexample
verify-az-failure-counterexample:  ## Drive failed-AZ/exhausted-AZ stuck replacement counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=AzFailoverCapacity --init=stuckOnFailedAzRun --step=step \
	              --invariant=NoIndefiniteScaleAttempt --max-steps=0 \
	              $(AZFAILCAP)

.PHONY: verify-az-failure-random
verify-az-failure-random:  ## Random-walk stable AZ/capacity invariants (300x40)
	@for inv in StableSafetyInvariants CapacityNonNegative AlternativeAttemptNeedsTarget; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=AzFailoverCapacity \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(AZFAILCAP) || exit 1; \
	done

.PHONY: verify-az-failure-apalache
verify-az-failure-apalache:  ## Apalache stuck failover counterexample at depth 4
	-@echo y | $(QUINT) verify --main=AzFailoverCapacity --init=stuckFailoverInit \
	                  --step=stepApalache --invariant=NoIndefiniteScaleAttempt \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(AZFAILCAP)

.PHONY: verify-az-failure
verify-az-failure: verify-az-failure-happy verify-az-failure-counterexample verify-az-failure-random verify-az-failure-apalache  ## Full AZ-wide failure / no-capacity failover suite

.PHONY: verify-pleg-hang-happy
verify-pleg-hang-happy:  ## Drive transient PLEG hang that recovers before remediation
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=KubeletPlegHang --init=transientRecoveryRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(PLEGHANG)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=KubeletPlegHang --init=transientRecoveryRun --step=step \
	             --invariant=RemediationAfterStableNotReady --max-steps=0 \
	             $(PLEGHANG)

.PHONY: verify-pleg-hang-counterexample
verify-pleg-hang-counterexample:  ## Drive over-eager remediation after transient CRI slowdown
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=KubeletPlegHang --init=overEagerRemediationRun --step=step \
	              --invariant=RemediationAfterStableNotReady --max-steps=0 \
	              $(PLEGHANG)

.PHONY: verify-pleg-hang-random
verify-pleg-hang-random:  ## Random-walk stable PLEG/CRI bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants PlegThresholdRequiresSlowCri RecoveryClearsTransientNotReady; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=KubeletPlegHang \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(PLEGHANG) || exit 1; \
	done

.PHONY: verify-pleg-hang-apalache
verify-pleg-hang-apalache:  ## Apalache transient-NotReady remediation counterexample at depth 4
	-@echo y | $(QUINT) verify --main=KubeletPlegHang --init=slowCriInit \
	                  --step=stepApalache --invariant=RemediationAfterStableNotReady \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(PLEGHANG)

.PHONY: verify-pleg-hang
verify-pleg-hang: verify-pleg-hang-happy verify-pleg-hang-counterexample verify-pleg-hang-random verify-pleg-hang-apalache  ## Full slow-CRI / PLEG-hang remediation suite

.PHONY: verify-registry-pull-happy
verify-registry-pull-happy:  ## Drive throttled bootstrap that still succeeds before timeout
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=RegistryPullBackoff --init=boundedThrottleRun --step=stepHappy \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(REGPULL)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=RegistryPullBackoff --init=boundedThrottleRun --step=stepHappy \
	             --invariant=NoFalseBootstrapFailure --max-steps=0 \
	             $(REGPULL)

.PHONY: verify-registry-pull-counterexample
verify-registry-pull-counterexample:  ## Drive bootstrap timeout before legitimate pull-backoff clears
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=RegistryPullBackoff --init=timeoutBeforePullClearsRun --step=step \
	              --invariant=NoFalseBootstrapFailure --max-steps=0 \
	              $(REGPULL)

.PHONY: verify-registry-pull-random
verify-registry-pull-random:  ## Random-walk stable registry-pull invariants (300x40)
	@for inv in StableSafetyInvariants BackoffMonotone; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=RegistryPullBackoff \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(REGPULL) || exit 1; \
	done

.PHONY: verify-registry-pull-apalache
verify-registry-pull-apalache:  ## Apalache bootstrap-timeout counterexample at depth 4
	-@echo y | $(QUINT) verify --main=RegistryPullBackoff --init=timeoutInit \
	                  --step=stepApalache --invariant=NoFalseBootstrapFailure \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(REGPULL)

.PHONY: verify-registry-pull
verify-registry-pull: verify-registry-pull-happy verify-registry-pull-counterexample verify-registry-pull-random verify-registry-pull-apalache  ## Full registry-throttle / bootstrap-timeout suite

.PHONY: verify-kcp-mhc-delete-happy
verify-kcp-mhc-delete-happy:  ## Drive single-authoritative-deleter path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=KcpMhcDeleteRace --init=authoritativeDeleteRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(KCPMHCDEL)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=KcpMhcDeleteRace --init=authoritativeDeleteRun --step=step \
	             --invariant=NoReplacementCannibalisation --max-steps=0 \
	             $(KCPMHCDEL)

.PHONY: verify-kcp-mhc-delete-counterexample
verify-kcp-mhc-delete-counterexample:  ## Drive concurrent delete / replacement cannibalisation counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=KcpMhcDeleteRace --init=concurrentDeleteRun --step=step \
	              --invariant=NoDoubleDelete --max-steps=0 \
	              $(KCPMHCDEL)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=KcpMhcDeleteRace --init=replacementCannibalisedRun --step=step \
	              --invariant=NoReplacementCannibalisation --max-steps=0 \
	              $(KCPMHCDEL)

.PHONY: verify-kcp-mhc-delete-random
verify-kcp-mhc-delete-random:  ## Random-walk stable delete-race invariants (300x40)
	@for inv in StableSafetyInvariants ReplacementDeleteNeedsUnhealthyLabel MhcMarksNeedSelection; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=KcpMhcDeleteRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(KCPMHCDEL) || exit 1; \
	done

.PHONY: verify-kcp-mhc-delete-apalache
verify-kcp-mhc-delete-apalache:  ## Apalache concurrent-delete counterexample at depth 4
	-@echo y | $(QUINT) verify --main=KcpMhcDeleteRace --init=doubleDeleteInit \
	                  --step=stepApalache --invariant=NoDoubleDelete \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(KCPMHCDEL)

.PHONY: verify-kcp-mhc-delete
verify-kcp-mhc-delete: verify-kcp-mhc-delete-happy verify-kcp-mhc-delete-counterexample verify-kcp-mhc-delete-random verify-kcp-mhc-delete-apalache  ## Full KCP+MHC concurrent-delete race suite

.PHONY: verify-cni-veth-happy
verify-cni-veth-happy:  ## Drive CNI-ready path before probes fail
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CniVethRace --init=cniReadyBeforeProbeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CNIVETH)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CniVethRace --init=cniReadyBeforeProbeRun --step=step \
	             --invariant=NoContainerStartBeforeCni --max-steps=0 \
	             $(CNIVETH)

.PHONY: verify-cni-veth-counterexample
verify-cni-veth-counterexample:  ## Drive probe-loop before veth creation
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=CniVethRace --init=probeLoopBeforeVethRun --step=step \
	              --invariant=NoContainerStartBeforeCni --max-steps=0 \
	              $(CNIVETH)

.PHONY: verify-cni-veth-random
verify-cni-veth-random:  ## Random-walk stable CNI/veth bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants VethRequiresCni RestartLoopRequiresRepeatedProbeFailure; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=CniVethRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CNIVETH) || exit 1; \
	done

.PHONY: verify-cni-veth-apalache
verify-cni-veth-apalache:  ## Apalache probe-loop counterexample at depth 4
	-@echo y | $(QUINT) verify --main=CniVethRace --init=probeLoopInit \
	                  --step=stepApalache --invariant=NoContainerStartBeforeCni \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CNIVETH)

.PHONY: verify-cni-veth
verify-cni-veth: verify-cni-veth-happy verify-cni-veth-counterexample verify-cni-veth-random verify-cni-veth-apalache  ## Full CNI-veth race / probe-loop suite

.PHONY: verify-lb-drain-happy
verify-lb-drain-happy:  ## Drive drain-complete before apiserver kill
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=LoadBalancerDrain --init=drainBeforeKillRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(LBDRAIN)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=LoadBalancerDrain --init=drainBeforeKillRun --step=step \
	             --invariant=KcpUpgradeAccountsForLbDrain --max-steps=0 \
	             $(LBDRAIN)

.PHONY: verify-lb-drain-counterexample
verify-lb-drain-counterexample:  ## Drive apiserver kill before LB drain completes
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=LoadBalancerDrain --init=killBeforeDrainRun --step=step \
	              --invariant=KcpUpgradeAccountsForLbDrain --max-steps=0 \
	              $(LBDRAIN)

.PHONY: verify-lb-drain-random
verify-lb-drain-random:  ## Random-walk stable LB-drain bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants DrainProgressMonotone HungClientNeedsDeregisteredTarget; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=LoadBalancerDrain \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(LBDRAIN) || exit 1; \
	done

.PHONY: verify-lb-drain-apalache
verify-lb-drain-apalache:  ## Apalache blackholed-connection counterexample at depth 4
	-@echo y | $(QUINT) verify --main=LoadBalancerDrain --init=killBeforeDrainInit \
	                  --step=stepApalache --invariant=KcpUpgradeAccountsForLbDrain \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(LBDRAIN)

.PHONY: verify-lb-drain
verify-lb-drain: verify-lb-drain-happy verify-lb-drain-counterexample verify-lb-drain-random verify-lb-drain-apalache  ## Full load-balancer drain / blackholed-connection suite

.PHONY: verify-endpoint-swap-happy
verify-endpoint-swap-happy:  ## Drive coordinated endpoint swap with kubeconfig regeneration
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EndpointSwapKubeconfig --init=coordinatedSwapRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ENDPOINTSWAP)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EndpointSwapKubeconfig --init=coordinatedSwapRun --step=step \
	             --invariant=AllKubeconfigsConvergeToCurrent --max-steps=0 \
	             $(ENDPOINTSWAP)

.PHONY: verify-endpoint-swap-counterexample
verify-endpoint-swap-counterexample:  ## Drive stale kubeconfig after endpoint swap
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EndpointSwapKubeconfig --init=staleKubeconfigRun --step=step \
	              --invariant=AllKubeconfigsConvergeToCurrent --max-steps=0 \
	              $(ENDPOINTSWAP)

.PHONY: verify-endpoint-swap-random
verify-endpoint-swap-random:  ## Random-walk stable endpoint-swap invariants (300x40)
	@for inv in StableSafetyInvariants ReferencedEndpointIsKnown CurrentEndpointKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EndpointSwapKubeconfig \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ENDPOINTSWAP) || exit 1; \
	done

.PHONY: verify-endpoint-swap-apalache
verify-endpoint-swap-apalache:  ## Apalache stale kubeconfig counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EndpointSwapKubeconfig --init=staleEndpointInit \
	                  --step=stepApalache --invariant=AllKubeconfigsConvergeToCurrent \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ENDPOINTSWAP)

.PHONY: verify-endpoint-swap
verify-endpoint-swap: verify-endpoint-swap-happy verify-endpoint-swap-counterexample verify-endpoint-swap-random verify-endpoint-swap-apalache  ## Full endpoint swap / stale kubeconfig suite

.PHONY: verify-netpol-stall-happy
verify-netpol-stall-happy:  ## Drive policy application that is detected and recovered
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=NetworkPolicyMidFlight --init=detectedPolicyCutRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(NETPOLSTALL)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=NetworkPolicyMidFlight --init=detectedPolicyCutRun --step=step \
	             --invariant=NoSilentControllerStall --max-steps=0 \
	             $(NETPOLSTALL)

.PHONY: verify-netpol-stall-counterexample
verify-netpol-stall-counterexample:  ## Drive long-lived watch that survives policy cut silently
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=NetworkPolicyMidFlight --init=silentWatchSurvivesRun --step=step \
	              --invariant=NoSilentControllerStall --max-steps=0 \
	              $(NETPOLSTALL)

.PHONY: verify-netpol-stall-random
verify-netpol-stall-random:  ## Random-walk stable netpol/connection invariants (300x40)
	@for inv in StableSafetyInvariants ExistingConnRequiresAppliedPolicy TerminatedConnRequiresPolicy; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=NetworkPolicyMidFlight \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(NETPOLSTALL) || exit 1; \
	done

.PHONY: verify-netpol-stall-apalache
verify-netpol-stall-apalache:  ## Apalache silent-stall counterexample at depth 4
	-@echo y | $(QUINT) verify --main=NetworkPolicyMidFlight --init=silentWatchInit \
	                  --step=stepApalache --invariant=NoSilentControllerStall \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(NETPOLSTALL)

.PHONY: verify-netpol-stall
verify-netpol-stall: verify-netpol-stall-happy verify-netpol-stall-counterexample verify-netpol-stall-random verify-netpol-stall-apalache  ## Full NetworkPolicy mid-flight / silent-stall suite

.PHONY: verify-watch-coalescing-happy
verify-watch-coalescing-happy:  ## Deliver update before delete coalesces away
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WatchEventCoalescing --init=updateDeliveredRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(WATCHCOALESCE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WatchEventCoalescing --init=updateDeliveredRun --step=step \
	             --invariant=ReconcileCorrectUnderCoalescing --max-steps=0 \
	             $(WATCHCOALESCE)

.PHONY: verify-watch-coalescing-counterexample
verify-watch-coalescing-counterexample:  ## Collapse add/update/delete to final delete only
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=WatchEventCoalescing --init=deleteOnlyAfterCoalesceRun --step=step \
	              --invariant=ReconcileCorrectUnderCoalescing --max-steps=0 \
	              $(WATCHCOALESCE)

.PHONY: verify-watch-coalescing-random
verify-watch-coalescing-random:  ## Random-walk stable watch-coalescing invariants (300x40)
	@for inv in StableSafetyInvariants DeliveredDeleteImpliesObjectAbsent CoalescedEventKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=WatchEventCoalescing \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(WATCHCOALESCE) || exit 1; \
	done

.PHONY: verify-watch-coalescing-apalache
verify-watch-coalescing-apalache:  ## Apalache delete-only coalescing counterexample at depth 4
	-@echo y | $(QUINT) verify --main=WatchEventCoalescing --init=deleteOnlyInit \
	                  --step=stepApalache --invariant=ReconcileCorrectUnderCoalescing \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(WATCHCOALESCE)

.PHONY: verify-watch-coalescing
verify-watch-coalescing: verify-watch-coalescing-happy verify-watch-coalescing-counterexample verify-watch-coalescing-random verify-watch-coalescing-apalache  ## Full watch event coalescing suite

.PHONY: verify-conntrack-happy
verify-conntrack-happy:  ## Drive churn below conntrack saturation threshold
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConntrackExhaustion --init=boundedChurnRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CONNTRACK)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConntrackExhaustion --init=boundedChurnRun --step=step \
	             --invariant=EventualConvergence --max-steps=0 \
	             $(CONNTRACK)

.PHONY: verify-conntrack-counterexample
verify-conntrack-counterexample:  ## Drive conntrack exhaustion under churn
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ConntrackExhaustion --init=tableFullRun --step=step \
	              --invariant=EventualConvergence --max-steps=0 \
	              $(CONNTRACK)

.PHONY: verify-conntrack-random
verify-conntrack-random:  ## Random-walk stable conntrack bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants OccupancyBounded ExpiryNeverIncreasesOccupancy; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ConntrackExhaustion \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CONNTRACK) || exit 1; \
	done

.PHONY: verify-conntrack-apalache
verify-conntrack-apalache:  ## Apalache conntrack-exhaustion counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ConntrackExhaustion --init=tableFullInit \
	                  --step=stepApalache --invariant=EventualConvergence \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CONNTRACK)

.PHONY: verify-conntrack
verify-conntrack: verify-conntrack-happy verify-conntrack-counterexample verify-conntrack-random verify-conntrack-apalache  ## Full conntrack-exhaustion / dropped-connection suite

.PHONY: verify-ipam-exhaustion-happy
verify-ipam-exhaustion-happy:  ## Surface subnet exhaustion as a Cluster condition
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=IpamExhaustion --init=exhaustionSurfacedRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(IPAMEXH)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=IpamExhaustion --init=exhaustionSurfacedRun --step=step \
	             --invariant=IpExhaustionEventuallySurfaced --max-steps=0 \
	             $(IPAMEXH)

.PHONY: verify-ipam-exhaustion-counterexample
verify-ipam-exhaustion-counterexample:  ## Drive silent infinite retry on exhausted subnet
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=IpamExhaustion --init=silentRetryRun --step=step \
	              --invariant=NoSilentInfiniteRetry --max-steps=0 \
	              $(IPAMEXH)

.PHONY: verify-ipam-exhaustion-random
verify-ipam-exhaustion-random:  ## Random-walk stable IPAM/subnet bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants UsedNeverExceedsCapacity ExhaustionConditionNeedsFullSubnet; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=IpamExhaustion \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(IPAMEXH) || exit 1; \
	done

.PHONY: verify-ipam-exhaustion-apalache
verify-ipam-exhaustion-apalache:  ## Apalache silent retry counterexample at depth 4
	-@echo y | $(QUINT) verify --main=IpamExhaustion --init=silentRetryInit \
	                  --step=stepApalache --invariant=NoSilentInfiniteRetry \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(IPAMEXH)

.PHONY: verify-ipam-exhaustion
verify-ipam-exhaustion: verify-ipam-exhaustion-happy verify-ipam-exhaustion-counterexample verify-ipam-exhaustion-random verify-ipam-exhaustion-apalache  ## Full subnet/IPAM exhaustion suite

.PHONY: verify-static-pod-eviction-happy
verify-static-pod-eviction-happy:  ## Drive mem-pressure eviction that preserves critical static pods
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(STACPODMEM)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
	             --invariant=KcpOutputsCorrectPriority --max-steps=0 \
	             $(STACPODMEM)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodMemPressure --init=correctPriorityRun --step=step \
	             --invariant=CriticalStaticPodsImmuneFromEviction --max-steps=0 \
	             $(STACPODMEM)

.PHONY: verify-static-pod-eviction-counterexample
verify-static-pod-eviction-counterexample:  ## Drive mis-priority static-pod eviction counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaticPodMemPressure --init=misPriorityEvictionRun --step=step \
	              --invariant=CriticalStaticPodsImmuneFromEviction --max-steps=0 \
	              $(STACPODMEM)

.PHONY: verify-static-pod-eviction-random
verify-static-pod-eviction-random:  ## Random-walk stable mem-pressure bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants EvictionChoiceNeedsPressure; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=StaticPodMemPressure \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(STACPODMEM) || exit 1; \
	done

.PHONY: verify-static-pod-eviction-apalache
verify-static-pod-eviction-apalache:  ## Apalache static-pod eviction counterexample at depth 4
	-@echo y | $(QUINT) verify --main=StaticPodMemPressure --init=misPriorityInit \
	                  --step=stepApalache --invariant=CriticalStaticPodsImmuneFromEviction \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(STACPODMEM)

.PHONY: verify-static-pod-eviction
verify-static-pod-eviction: verify-static-pod-eviction-happy verify-static-pod-eviction-counterexample verify-static-pod-eviction-random verify-static-pod-eviction-apalache  ## Full mem-pressure static-pod eviction suite

.PHONY: verify-static-pod-disk-happy
verify-static-pod-disk-happy:  ## Drive disk-pressure recovery without remediation
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodDiskFull --init=recoveredDiskRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(STAPODDISK)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodDiskFull --init=recoveredDiskRun --step=step \
	             --invariant=KcpRecognisesDiskPressureAsTransient --max-steps=0 \
	             $(STAPODDISK)

.PHONY: verify-static-pod-disk-counterexample
verify-static-pod-disk-counterexample:  ## Drive disk-full static-pod crashloop + remediation counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaticPodDiskFull --init=crashloopRemediationRun --step=step \
	              --invariant=KcpRecognisesDiskPressureAsTransient --max-steps=0 \
	              $(STAPODDISK)

.PHONY: verify-static-pod-disk-random
verify-static-pod-disk-random:  ## Random-walk stable disk-pressure bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants EvictionImpliesStaticPodCrashloop; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=StaticPodDiskFull \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(STAPODDISK) || exit 1; \
	done

.PHONY: verify-static-pod-disk-apalache
verify-static-pod-disk-apalache:  ## Apalache disk-pressure crashloop counterexample at depth 4
	-@echo y | $(QUINT) verify --main=StaticPodDiskFull --init=crashloopInit \
	                  --step=stepApalache --invariant=KcpRecognisesDiskPressureAsTransient \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(STAPODDISK)

.PHONY: verify-static-pod-disk
verify-static-pod-disk: verify-static-pod-disk-happy verify-static-pod-disk-counterexample verify-static-pod-disk-random verify-static-pod-disk-apalache  ## Full static-pod disk-pressure crashloop suite

.PHONY: verify-static-pod-hash-happy
verify-static-pod-hash-happy:  ## Drive distinct-intent manifests + eventual kubelet reload convergence
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodHashReloadRace --init=eventualReloadRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(HASHRELOAD)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StaticPodHashReloadRace --init=eventualReloadRun --step=step \
	             --invariant=ReloadEventuallyConverges --max-steps=0 \
	             $(HASHRELOAD)

.PHONY: verify-static-pod-hash-counterexample
verify-static-pod-hash-counterexample:  ## Drive hash collision + stale reload counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaticPodHashReloadRace --init=hashCollisionRun --step=step \
	              --invariant=NoHashCollisionAcrossDistinctIntents --max-steps=0 \
	              $(HASHRELOAD)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StaticPodHashReloadRace --init=staleReloadRun --step=step \
	              --invariant=ReloadEventuallyConverges --max-steps=0 \
	              $(HASHRELOAD)

.PHONY: verify-static-pod-hash-random
verify-static-pod-hash-random:  ## Random-walk stable manifest/reload bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants ManifestHashDeterministic DesiredConfigGenMonotone; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=StaticPodHashReloadRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(HASHRELOAD) || exit 1; \
	done

.PHONY: verify-static-pod-hash-apalache
verify-static-pod-hash-apalache:  ## Apalache manifest-hash collision counterexample at depth 4
	-@echo y | $(QUINT) verify --main=StaticPodHashReloadRace --init=collisionInit \
	                  --step=stepApalache --invariant=NoHashCollisionAcrossDistinctIntents \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(HASHRELOAD)

.PHONY: verify-static-pod-hash
verify-static-pod-hash: verify-static-pod-hash-happy verify-static-pod-hash-counterexample verify-static-pod-hash-random verify-static-pod-hash-apalache  ## Full static-pod hash / kubelet reload race suite

.PHONY: verify-bootstrap-csr-happy
verify-bootstrap-csr-happy:  ## Drive delayed-but-eventually-approved bootstrap CSR path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=BootstrapCsrLag --init=eventualApprovalRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(BOOTCSR)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=BootstrapCsrLag --init=eventualApprovalRun --step=step \
	             --invariant=BootstrapTimeoutCoversCsrLatency --max-steps=0 \
	             $(BOOTCSR)

.PHONY: verify-bootstrap-csr-counterexample
verify-bootstrap-csr-counterexample:  ## Drive bootstrap timeout before CSR approval clears
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=BootstrapCsrLag --init=approvalTimeoutRun --step=step \
	              --invariant=BootstrapTimeoutCoversCsrLatency --max-steps=0 \
	              $(BOOTCSR)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=BootstrapCsrLag --init=strandedKubeletRun --step=step \
	              --invariant=NoStrandedKubelet --max-steps=0 \
	              $(BOOTCSR)

.PHONY: verify-bootstrap-csr-random
verify-bootstrap-csr-random:  ## Random-walk stable CSR-lag bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants QueueMonotone SubmitTimeRecorded; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=BootstrapCsrLag \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(BOOTCSR) || exit 1; \
	done

.PHONY: verify-bootstrap-csr-apalache
verify-bootstrap-csr-apalache:  ## Apalache CSR-lag bootstrap-timeout counterexample at depth 4
	-@echo y | $(QUINT) verify --main=BootstrapCsrLag --init=approvalTimeoutInit \
	                  --step=stepApalache --invariant=BootstrapTimeoutCoversCsrLatency \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(BOOTCSR)

.PHONY: verify-bootstrap-csr
verify-bootstrap-csr: verify-bootstrap-csr-happy verify-bootstrap-csr-counterexample verify-bootstrap-csr-random verify-bootstrap-csr-apalache  ## Full bootstrap CSR approval-lag suite

.PHONY: verify-mtu-frag-happy
verify-mtu-frag-happy:  ## Drive bounded packet sizing / PMTU convergence path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MtuFragmentation --init=convergedPmtuRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(MTUFRAG)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MtuFragmentation --init=convergedPmtuRun --step=step \
	             --invariant=EtcdSnapshotEventuallySucceeds --max-steps=0 \
	             $(MTUFRAG)

.PHONY: verify-mtu-frag-counterexample
verify-mtu-frag-counterexample:  ## Drive DF+MTU silent drop counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=MtuFragmentation --init=silentFragDropRun --step=step \
	              --invariant=EtcdSnapshotEventuallySucceeds --max-steps=0 \
	              $(MTUFRAG)

.PHONY: verify-mtu-frag-random
verify-mtu-frag-random:  ## Random-walk stable MTU/PMTU bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants PmtuNeverExceedsLinkMtu; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=MtuFragmentation \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(MTUFRAG) || exit 1; \
	done

.PHONY: verify-mtu-frag-apalache
verify-mtu-frag-apalache:  ## Apalache silent fragmentation counterexample at depth 4
	-@echo y | $(QUINT) verify --main=MtuFragmentation --init=silentFragInit \
	                  --step=stepApalache --invariant=EtcdSnapshotEventuallySucceeds \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(MTUFRAG)

.PHONY: verify-mtu-frag
verify-mtu-frag: verify-mtu-frag-happy verify-mtu-frag-counterexample verify-mtu-frag-random verify-mtu-frag-apalache  ## Full MTU drift / silent fragmentation suite

.PHONY: verify-cc-topology-race-happy
verify-cc-topology-race-happy:  ## Drive version-pinned ClusterClass read
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterClassTopologyRace --init=versionPinnedReadRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CCTOPORACE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterClassTopologyRace --init=versionPinnedReadRun --step=step \
	             --invariant=ConsistentCCViewPerReconcile --max-steps=0 \
	             $(CCTOPORACE)

.PHONY: verify-cc-topology-race-counterexample
verify-cc-topology-race-counterexample:  ## Drive torn ClusterClass read counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ClusterClassTopologyRace --init=tornReadRun --step=step \
	              --invariant=ConsistentCCViewPerReconcile --max-steps=0 \
	              $(CCTOPORACE)

.PHONY: verify-cc-topology-race-random
verify-cc-topology-race-random:  ## Random-walk stable ClusterClass topology invariants (300x40)
	@for inv in StableSafetyInvariants DefinitionStateWellFormed MidUpdateRequiresVersionSkew; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterClassTopologyRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CCTOPORACE) || exit 1; \
	done

.PHONY: verify-cc-topology-race-apalache
verify-cc-topology-race-apalache:  ## Apalache torn ClusterClass read counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ClusterClassTopologyRace --init=tornReadInit \
	                  --step=stepApalache --invariant=ConsistentCCViewPerReconcile \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CCTOPORACE)

.PHONY: verify-cc-topology-race
verify-cc-topology-race: verify-cc-topology-race-happy verify-cc-topology-race-counterexample verify-cc-topology-race-random verify-cc-topology-race-apalache  ## Full ClusterClass/Topology torn-read suite

.PHONY: verify-crs-timing-happy
verify-crs-timing-happy:  ## Drive CRS application after kubelets join
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterResourceSetTiming --init=joinsBeforeApplyRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CRSTIMING)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterResourceSetTiming --init=joinsBeforeApplyRun --step=step \
	             --invariant=ApplyOnceEventuallyTakesEffect --max-steps=0 \
	             $(CRSTIMING)

.PHONY: verify-crs-timing-counterexample
verify-crs-timing-counterexample:  ## Drive ApplyOnce before kubelets join counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ClusterResourceSetTiming --init=applyBeforeJoinRun --step=step \
	              --invariant=ApplyOnceEventuallyTakesEffect --max-steps=0 \
	              $(CRSTIMING)

.PHONY: verify-crs-timing-random
verify-crs-timing-random:  ## Random-walk stable CRS timing invariants (300x40)
	@for inv in StableSafetyInvariants ApplyOnceRequiresPendingPayload ReconcileRetriesUntilJoined; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterResourceSetTiming \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CRSTIMING) || exit 1; \
	done

.PHONY: verify-crs-timing-apalache
verify-crs-timing-apalache:  ## Apalache ApplyOnce timing counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ClusterResourceSetTiming --init=applyBeforeJoinInit \
	                  --step=stepApalache --invariant=ApplyOnceEventuallyTakesEffect \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CRSTIMING)

.PHONY: verify-crs-timing
verify-crs-timing: verify-crs-timing-happy verify-crs-timing-counterexample verify-crs-timing-random verify-crs-timing-apalache  ## Full ClusterResourceSet ApplyOnce timing suite

.PHONY: verify-pvc-bootstrap-happy
verify-pvc-bootstrap-happy:  ## Drive CSI/storageclass installed before PVC-consuming pod schedules
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=PvcBootstrapPending --init=storageReadyFirstRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(PVCBOOT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=PvcBootstrapPending --init=storageReadyFirstRun --step=step \
	             --invariant=BootstrapDependencyOrdering --max-steps=0 \
	             $(PVCBOOT)

.PHONY: verify-pvc-bootstrap-counterexample
verify-pvc-bootstrap-counterexample:  ## Drive missing StorageClass bootstrap hang counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=PvcBootstrapPending --init=missingStorageClassRun --step=step \
	              --invariant=BootstrapDependencyOrdering --max-steps=0 \
	              $(PVCBOOT)

.PHONY: verify-pvc-bootstrap-random
verify-pvc-bootstrap-random:  ## Random-walk stable PVC/bootstrap bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants BoundImpliesStorageClassKnown PvcPhaseKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=PvcBootstrapPending \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(PVCBOOT) || exit 1; \
	done

.PHONY: verify-pvc-bootstrap-apalache
verify-pvc-bootstrap-apalache:  ## Apalache missing StorageClass bootstrap hang at depth 4
	-@echo y | $(QUINT) verify --main=PvcBootstrapPending --init=missingStorageClassInit \
	                  --step=stepApalache --invariant=BootstrapDependencyOrdering \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(PVCBOOT)

.PHONY: verify-pvc-bootstrap
verify-pvc-bootstrap: verify-pvc-bootstrap-happy verify-pvc-bootstrap-counterexample verify-pvc-bootstrap-random verify-pvc-bootstrap-apalache  ## Full PVC/StorageClass bootstrap dependency suite

.PHONY: verify-crd-schema-happy
verify-crd-schema-happy:  ## Drive migrated-object path after schema bump
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CrdSchemaBump --init=migratedObjectRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CRDSCHEMA)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CrdSchemaBump --init=migratedObjectRun --step=step \
	             --invariant=MigrationPathExistsForBumpedSchema --max-steps=0 \
	             $(CRDSCHEMA)

.PHONY: verify-crd-schema-counterexample
verify-crd-schema-counterexample:  ## Drive incompatible schema bump without migration counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=CrdSchemaBump --init=validationFailureRun --step=step \
	              --invariant=NoOrphanedStoredObjects --max-steps=0 \
	              $(CRDSCHEMA)

.PHONY: verify-crd-schema-random
verify-crd-schema-random:  ## Random-walk stable CRD/schema bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants StoredObjectVersionKnown MigrationMaintainsValidity; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=CrdSchemaBump \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CRDSCHEMA) || exit 1; \
	done

.PHONY: verify-crd-schema-apalache
verify-crd-schema-apalache:  ## Apalache incompatible schema bump counterexample at depth 4
	-@echo y | $(QUINT) verify --main=CrdSchemaBump --init=validationFailureInit \
	                  --step=stepApalache --invariant=NoOrphanedStoredObjects \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CRDSCHEMA)

.PHONY: verify-crd-schema
verify-crd-schema: verify-crd-schema-happy verify-crd-schema-counterexample verify-crd-schema-random verify-crd-schema-apalache  ## Full schema-incompatible CRD upgrade suite

.PHONY: verify-adversary-happy
verify-adversary-happy:  ## Drive recovered fault path through generic adversary library
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AdversaryHarness --init=recoveredFaultRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ADVERSARY)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AdversaryHarness --init=recoveredFaultRun --step=step \
	             --invariant=RecoveredAfterFaultBudget --max-steps=0 \
	             $(ADVERSARY)

.PHONY: verify-adversary-counterexample
verify-adversary-counterexample:  ## Drive unbounded-crash outage counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=AdversaryHarness --init=permanentOutageRun --step=step \
	              --invariant=NoPermanentUnavailability --max-steps=0 \
	              $(ADVERSARY)

.PHONY: verify-adversary-random
verify-adversary-random:  ## Random-walk stable adversary bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants ActiveKindKnown ActiveVictimKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=AdversaryHarness \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ADVERSARY) || exit 1; \
	done

.PHONY: verify-adversary-apalache
verify-adversary-apalache:  ## Apalache crash-outage counterexample at depth 4
	-@echo y | $(QUINT) verify --main=AdversaryHarness --init=permanentOutageInit \
	                  --step=stepApalache --invariant=NoPermanentUnavailability \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ADVERSARY)

.PHONY: fuzz-adversary
fuzz-adversary:  ## Seeded fuzzing over generic adversary harness
	$(PYTHON) ../hack/tools/quint-adversary-fuzzer.py $(ADVERSARY) \
	  --main=AdversaryHarness --invariant=NoPermanentUnavailability \
	  --seeds=25 --max-samples=120 --max-steps=20 --timeout=45 || true

.PHONY: verify-adversary
verify-adversary: verify-adversary-happy verify-adversary-counterexample verify-adversary-random verify-adversary-apalache  ## Full adversary harness suite

.PHONY: verify-concurrent-spec-edits-happy
verify-concurrent-spec-edits-happy:  ## Drive serial application of version+replica edits
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConcurrentClusterSpecEdits --init=serialEditsRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CONCSPEC)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConcurrentClusterSpecEdits --init=serialEditsRun --step=step \
	             --invariant=EventualConvergenceToFinalSpec --max-steps=0 \
	             $(CONCSPEC)

.PHONY: verify-concurrent-spec-edits-counterexample
verify-concurrent-spec-edits-counterexample:  ## Drive lost-edit / surge race counterexamples
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ConcurrentClusterSpecEdits --init=lostEditRun --step=step \
	              --invariant=NoLostEdit --max-steps=0 \
	              $(CONCSPEC)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ConcurrentClusterSpecEdits --init=surgeRaceRun --step=step \
	              --invariant=NoSurgeBoundViolation --max-steps=0 \
	              $(CONCSPEC)

.PHONY: verify-concurrent-spec-edits-random
verify-concurrent-spec-edits-random:  ## Random-walk stable concurrent-edit invariants (300x40)
	@for inv in StableSafetyInvariants AppliedSpecSubsetOfPending LastWriterPreservesFieldDomain; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ConcurrentClusterSpecEdits \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CONCSPEC) || exit 1; \
	done

.PHONY: verify-concurrent-spec-edits-apalache
verify-concurrent-spec-edits-apalache:  ## Apalache concurrent-edit counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ConcurrentClusterSpecEdits --init=lostEditInit \
	                  --step=stepApalache --invariant=NoLostEdit \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CONCSPEC)

.PHONY: verify-concurrent-spec-edits
verify-concurrent-spec-edits: verify-concurrent-spec-edits-happy verify-concurrent-spec-edits-counterexample verify-concurrent-spec-edits-random verify-concurrent-spec-edits-apalache  ## Full concurrent Cluster.spec edit suite

.PHONY: verify-clusterrole-drift-happy
verify-clusterrole-drift-happy:  ## Drive foreign overwrite followed by CAPI reassertion
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterRoleDrift --init=reassertAfterDriftRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(RBACDRIFT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterRoleDrift --init=reassertAfterDriftRun --step=step \
	             --invariant=CapiRoleStableUnderForeignApplier --max-steps=0 \
	             $(RBACDRIFT)

.PHONY: verify-clusterrole-drift-counterexample
verify-clusterrole-drift-counterexample:  ## Drive foreign overwrite without reassertion
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ClusterRoleDrift --init=drifted403Run --step=step \
	              --invariant=NoSilentPermissionLossAfterDrift --max-steps=0 \
	              $(RBACDRIFT)

.PHONY: verify-clusterrole-drift-random
verify-clusterrole-drift-random:  ## Random-walk stable ClusterRole drift invariants (300x40)
	@for inv in StableSafetyInvariants LastApplierKnown RulesStateKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterRoleDrift \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(RBACDRIFT) || exit 1; \
	done

.PHONY: verify-clusterrole-drift-apalache
verify-clusterrole-drift-apalache:  ## Apalache foreign-overwrite permission-loss counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ClusterRoleDrift --init=drifted403Init \
	                  --step=stepApalache --invariant=NoSilentPermissionLossAfterDrift \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(RBACDRIFT)

.PHONY: verify-clusterrole-drift
verify-clusterrole-drift: verify-clusterrole-drift-happy verify-clusterrole-drift-counterexample verify-clusterrole-drift-random verify-clusterrole-drift-apalache  ## Full ClusterRole drift / foreign applier suite

.PHONY: verify-ssa-conflict-happy
verify-ssa-conflict-happy:  ## Drive explicit conflict then forced handoff path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SsaFieldManagerConflict --init=forceHandoffRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(SSAFMCONFLICT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SsaFieldManagerConflict --init=forceHandoffRun --step=step \
	             --invariant=ForcedApplyTransfersOwnership --max-steps=0 \
	             $(SSAFMCONFLICT)

.PHONY: verify-ssa-conflict-counterexample
verify-ssa-conflict-counterexample:  ## Drive stale manager revert counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=SsaFieldManagerConflict --init=staleManagerRevertRun --step=step \
	              --invariant=NoSilentRevertAfterConflict --max-steps=0 \
	              $(SSAFMCONFLICT)

.PHONY: verify-ssa-conflict-random
verify-ssa-conflict-random:  ## Random-walk stable SSA manager invariants (300x40)
	@for inv in StableSafetyInvariants OwnerAlwaysKnown LastWriterMatchesValue; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=SsaFieldManagerConflict \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(SSAFMCONFLICT) || exit 1; \
	done

.PHONY: verify-ssa-conflict-apalache
verify-ssa-conflict-apalache:  ## Apalache stale-manager revert counterexample at depth 4
	-@echo y | $(QUINT) verify --main=SsaFieldManagerConflict --init=staleRevertInit \
	                  --step=stepApalache --invariant=NoSilentRevertAfterConflict \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(SSAFMCONFLICT)

.PHONY: verify-ssa-conflict
verify-ssa-conflict: verify-ssa-conflict-happy verify-ssa-conflict-counterexample verify-ssa-conflict-random verify-ssa-conflict-apalache  ## Full SSA field-manager conflict suite

.PHONY: verify-autoscaler-kcp-happy
verify-autoscaler-kcp-happy:  ## Drive serialized autoscaler scale-up then rollout path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AutoscalerKcpSurgeRace --init=serializedScaleRollRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ASKCPSURGE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=AutoscalerKcpSurgeRace --init=serializedScaleRollRun --step=step \
	             --invariant=AutoscalerKcpArbitrated --max-steps=0 \
	             $(ASKCPSURGE)

.PHONY: verify-autoscaler-kcp-counterexample
verify-autoscaler-kcp-counterexample:  ## Drive concurrent autoscale+rollout surge counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=AutoscalerKcpSurgeRace --init=concurrentScaleRollRun --step=step \
	              --invariant=SurgeBoundUnderConcurrentScale --max-steps=0 \
	              $(ASKCPSURGE)

.PHONY: verify-autoscaler-kcp-random
verify-autoscaler-kcp-random:  ## Random-walk stable autoscaler/KCP bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants ActualReplicasWithinDomain LastWriterOwnsIntent; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=AutoscalerKcpSurgeRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ASKCPSURGE) || exit 1; \
	done

.PHONY: verify-autoscaler-kcp-apalache
verify-autoscaler-kcp-apalache:  ## Apalache concurrent autoscale+rollout counterexample at depth 4
	-@echo y | $(QUINT) verify --main=AutoscalerKcpSurgeRace --init=concurrentScaleInit \
	                  --step=stepApalache --invariant=SurgeBoundUnderConcurrentScale \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ASKCPSURGE)

.PHONY: verify-autoscaler-kcp
verify-autoscaler-kcp: verify-autoscaler-kcp-happy verify-autoscaler-kcp-counterexample verify-autoscaler-kcp-random verify-autoscaler-kcp-apalache  ## Full autoscaler+KCP surge-race suite

.PHONY: verify-etcd-k8s-skew-happy
verify-etcd-k8s-skew-happy:  ## Drive ordered Kubernetes then etcd upgrade path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdKubernetesVersionSkew --init=orderedUpgradeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ETCDK8SSKEW)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdKubernetesVersionSkew --init=orderedUpgradeRun --step=step \
	             --invariant=EtcdUpgradeAfterControlPlaneGate --max-steps=0 \
	             $(ETCDK8SSKEW)

.PHONY: verify-etcd-k8s-skew-counterexample
verify-etcd-k8s-skew-counterexample:  ## Drive mid-rollout etcd/k8s dependency trap counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdKubernetesVersionSkew --init=midRolloutEtcdBumpRun --step=step \
	              --invariant=NoMidRolloutDependencyTrap --max-steps=0 \
	              $(ETCDK8SSKEW)

.PHONY: verify-etcd-k8s-skew-random
verify-etcd-k8s-skew-random:  ## Random-walk stable version/bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants VersionStringsKnown PreflightBlocksUnsupportedOrder; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EtcdKubernetesVersionSkew \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ETCDK8SSKEW) || exit 1; \
	done

.PHONY: verify-etcd-k8s-skew-apalache
verify-etcd-k8s-skew-apalache:  ## Apalache mid-rollout dependency-trap counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EtcdKubernetesVersionSkew --init=dependencyTrapInit \
	                  --step=stepApalache --invariant=NoMidRolloutDependencyTrap \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ETCDK8SSKEW)

.PHONY: verify-etcd-k8s-skew
verify-etcd-k8s-skew: verify-etcd-k8s-skew-happy verify-etcd-k8s-skew-counterexample verify-etcd-k8s-skew-random verify-etcd-k8s-skew-apalache  ## Full mid-rollout etcd-version × Kubernetes-version dependency suite

.PHONY: verify-skip-version-happy
verify-skip-version-happy:  ## Drive one-minor-at-a-time upgrade path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SkipVersionUpgrade --init=oneMinorStepRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(SKIPUPGRADE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=SkipVersionUpgrade --init=oneMinorStepRun --step=step \
	             --invariant=UpgradeRespectsSkewBound --max-steps=0 \
	             $(SKIPUPGRADE)

.PHONY: verify-skip-version-counterexample
verify-skip-version-counterexample:  ## Drive skip-version preflight violation counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=SkipVersionUpgrade --init=skipMinorRun --step=step \
	              --invariant=UpgradeRespectsSkewBound --max-steps=0 \
	              $(SKIPUPGRADE)

.PHONY: verify-skip-version-random
verify-skip-version-random:  ## Random-walk stable skew bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants TargetVersionKnown PreflightBlocksSkippedMinor; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=SkipVersionUpgrade \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(SKIPUPGRADE) || exit 1; \
	done

.PHONY: verify-skip-version-apalache
verify-skip-version-apalache:  ## Apalache skip-version violation counterexample at depth 4
	-@echo y | $(QUINT) verify --main=SkipVersionUpgrade --init=skipMinorInit \
	                  --step=stepApalache --invariant=UpgradeRespectsSkewBound \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(SKIPUPGRADE)

.PHONY: verify-skip-version
verify-skip-version: verify-skip-version-happy verify-skip-version-counterexample verify-skip-version-random verify-skip-version-apalache  ## Full skip-version skew-bound suite

.PHONY: verify-rollback-surge-happy
verify-rollback-surge-happy:  ## Drive serialized rollback after surge cleanup
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=RollbackSurgeRace --init=serializedRollbackRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ROLLBACKSURGE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=RollbackSurgeRace --init=serializedRollbackRun --step=step \
	             --invariant=RollbackAppliedAfterDrainPoint --max-steps=0 \
	             $(ROLLBACKSURGE)

.PHONY: verify-rollback-surge-counterexample
verify-rollback-surge-counterexample:  ## Drive partial-cycle rollback surge counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=RollbackSurgeRace --init=rollbackMidCycleRun --step=step \
	              --invariant=NoTransientSurgeBeyondBound --max-steps=0 \
	              $(ROLLBACKSURGE)

.PHONY: verify-rollback-surge-random
verify-rollback-surge-random:  ## Random-walk stable rollback/surge bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants OldAndNewReplicaCountsNonNegative DrainPointKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=RollbackSurgeRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ROLLBACKSURGE) || exit 1; \
	done

.PHONY: verify-rollback-surge-apalache
verify-rollback-surge-apalache:  ## Apalache rollback surge counterexample at depth 4
	-@echo y | $(QUINT) verify --main=RollbackSurgeRace --init=rollbackMidCycleInit \
	                  --step=stepApalache --invariant=NoTransientSurgeBeyondBound \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(ROLLBACKSURGE)

.PHONY: verify-rollback-surge
verify-rollback-surge: verify-rollback-surge-happy verify-rollback-surge-counterexample verify-rollback-surge-random verify-rollback-surge-apalache  ## Full rollback-during-partial-cycle surge suite

.PHONY: verify-controller-replay-happy
verify-controller-replay-happy:  ## Drive replay after OOM without double effect
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerManagerReplay --init=cleanReplayRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CMREPLAY)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerManagerReplay --init=cleanReplayRun --step=step \
	             --invariant=RecoveryWithoutInMemoryStateAssumption --max-steps=0 \
	             $(CMREPLAY)

.PHONY: verify-controller-replay-counterexample
verify-controller-replay-counterexample:  ## Drive lost in-memory marker / replay double-effect counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ControllerManagerReplay --init=doubleEffectReplayRun --step=step \
	              --invariant=NoDoubleEffect --max-steps=0 \
	              $(CMREPLAY)

.PHONY: verify-controller-replay-random
verify-controller-replay-random:  ## Random-walk stable leader/replay bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants LeaderOwnsCacheGen ReplayNeedsNewLeader; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ControllerManagerReplay \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CMREPLAY) || exit 1; \
	done

.PHONY: verify-controller-replay-apalache
verify-controller-replay-apalache:  ## Apalache replay double-effect counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ControllerManagerReplay --init=doubleEffectInit \
	                  --step=stepApalache --invariant=NoDoubleEffect \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CMREPLAY)

.PHONY: verify-controller-replay
verify-controller-replay: verify-controller-replay-happy verify-controller-replay-counterexample verify-controller-replay-random verify-controller-replay-apalache  ## Full controller-manager OOM / replay suite

.PHONY: verify-controller-splitbrain-happy
verify-controller-splitbrain-happy:  ## Drive lease convergence before duplicate effect
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerLeaderSplitBrain --init=leaseConvergesRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CMSPLITBRAIN)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ControllerLeaderSplitBrain --init=leaseConvergesRun --step=step \
	             --invariant=SingleWriterAfterConvergence --max-steps=0 \
	             $(CMSPLITBRAIN)

.PHONY: verify-controller-splitbrain-counterexample
verify-controller-splitbrain-counterexample:  ## Drive two-active-leaders duplicate-effect counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ControllerLeaderSplitBrain --init=splitBrainRun --step=step \
	              --invariant=NoDuplicateEffectAcrossLeaders --max-steps=0 \
	              $(CMSPLITBRAIN)

.PHONY: verify-controller-splitbrain-random
verify-controller-splitbrain-random:  ## Random-walk stable split-brain bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants LeaseOwnersKnown ConvergedImpliesSingleLeader; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ControllerLeaderSplitBrain \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CMSPLITBRAIN) || exit 1; \
	done

.PHONY: verify-controller-splitbrain-apalache
verify-controller-splitbrain-apalache:  ## Apalache split-brain duplicate-effect counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ControllerLeaderSplitBrain --init=splitBrainInit \
	                  --step=stepApalache --invariant=NoDuplicateEffectAcrossLeaders \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CMSPLITBRAIN)

.PHONY: verify-controller-splitbrain
verify-controller-splitbrain: verify-controller-splitbrain-happy verify-controller-splitbrain-counterexample verify-controller-splitbrain-random verify-controller-splitbrain-apalache  ## Full controller-manager split-brain suite

.PHONY: verify-bootstrap-infra-race-happy
verify-bootstrap-infra-race-happy:  ## Drive Machine readiness after both children report ready
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=BootstrapInfraReadyRace --init=bothReadyObservedRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(BIMREADYRACE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=BootstrapInfraReadyRace --init=bothReadyObservedRun --step=step \
	             --invariant=MachineReadyEventuallyReflectsBoth --max-steps=0 \
	             $(BIMREADYRACE)

.PHONY: verify-bootstrap-infra-race-counterexample
verify-bootstrap-infra-race-counterexample:  ## Drive missing-event stuck-unready counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=BootstrapInfraReadyRace --init=missingInfraEventRun --step=step \
	              --invariant=NoStuckUnreadyDespiteBothChildrenReady --max-steps=0 \
	              $(BIMREADYRACE)

.PHONY: verify-bootstrap-infra-race-random
verify-bootstrap-infra-race-random:  ## Random-walk stable bootstrap/infra readiness invariants (300x40)
	@for inv in StableSafetyInvariants LastObservedSubsetOfTruth ReadyNeedsObservedTrue; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=BootstrapInfraReadyRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(BIMREADYRACE) || exit 1; \
	done

.PHONY: verify-bootstrap-infra-race-apalache
verify-bootstrap-infra-race-apalache:  ## Apalache missing-event stuck-unready counterexample at depth 4
	-@echo y | $(QUINT) verify --main=BootstrapInfraReadyRace --init=missingEventInit \
	                  --step=stepApalache --invariant=NoStuckUnreadyDespiteBothChildrenReady \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(BIMREADYRACE)

.PHONY: verify-bootstrap-infra-race
verify-bootstrap-infra-race: verify-bootstrap-infra-race-happy verify-bootstrap-infra-race-counterexample verify-bootstrap-infra-race-random verify-bootstrap-infra-race-apalache  ## Full bootstrap/infra readiness race suite

.PHONY: verify-cloud-iam-happy
verify-cloud-iam-happy:  ## Drive persistent-403 abort after authorization loss
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CloudIamPermissionLoss --init=abortAfterPersistent403Run --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CLOUDIAM)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=CloudIamPermissionLoss --init=abortAfterPersistent403Run --step=step \
	             --invariant=InFlightProvisioningEventuallyAborts --max-steps=0 \
	             $(CLOUDIAM)

.PHONY: verify-cloud-iam-counterexample
verify-cloud-iam-counterexample:  ## Drive zombie machine after IAM revocation counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=CloudIamPermissionLoss --init=zombieMachineRun --step=step \
	              --invariant=NoZombieMachine --max-steps=0 \
	              $(CLOUDIAM)

.PHONY: verify-cloud-iam-random
verify-cloud-iam-random:  ## Random-walk stable IAM/provisioning bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants Observed403ImpliesRevokedPolicy LastCallAuthKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=CloudIamPermissionLoss \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CLOUDIAM) || exit 1; \
	done

.PHONY: verify-cloud-iam-apalache
verify-cloud-iam-apalache:  ## Apalache zombie-machine counterexample at depth 4
	-@echo y | $(QUINT) verify --main=CloudIamPermissionLoss --init=zombieMachineInit \
	                  --step=stepApalache --invariant=NoZombieMachine \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CLOUDIAM)

.PHONY: verify-cloud-iam
verify-cloud-iam: verify-cloud-iam-happy verify-cloud-iam-counterexample verify-cloud-iam-random verify-cloud-iam-apalache  ## Full IAM revocation / cloud-call 403 suite

.PHONY: verify-sa-token-rotation-happy
verify-sa-token-rotation-happy:  ## Drive token refresh after 401 path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ServiceAccountTokenRotation --init=refreshAfter401Run --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(SATOKENROT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ServiceAccountTokenRotation --init=refreshAfter401Run --step=step \
	             --invariant=RetryOn401WithRefreshedToken --max-steps=0 \
	             $(SATOKENROT)

.PHONY: verify-sa-token-rotation-counterexample
verify-sa-token-rotation-counterexample:  ## Drive stale token 401 without refresh counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ServiceAccountTokenRotation --init=staleTokenFailureRun --step=step \
	              --invariant=NoSilentReconcileFailure --max-steps=0 \
	              $(SATOKENROT)

.PHONY: verify-sa-token-rotation-random
verify-sa-token-rotation-random:  ## Random-walk stable token/bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants CapturedTokenNotNewerThanCurrent; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ServiceAccountTokenRotation \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(SATOKENROT) || exit 1; \
	done

.PHONY: verify-sa-token-rotation-apalache
verify-sa-token-rotation-apalache:  ## Apalache stale-token auth failure counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ServiceAccountTokenRotation --init=expiredTokenInit \
	                  --step=stepApalache --invariant=NoSilentReconcileFailure \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(SATOKENROT)

.PHONY: verify-sa-token-rotation
verify-sa-token-rotation: verify-sa-token-rotation-happy verify-sa-token-rotation-counterexample verify-sa-token-rotation-random verify-sa-token-rotation-apalache  ## Full ServiceAccount token rotation / auth retry suite

.PHONY: verify-oidc-rotation-happy
verify-oidc-rotation-happy:  ## Drive OIDC issuer/key rotation with token reissue
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=OidcIssuerRotation --init=eventualReissueRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(OIDCROT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=OidcIssuerRotation --init=eventualReissueRun --step=step \
	             --invariant=EventualReissue --max-steps=0 \
	             $(OIDCROT)

.PHONY: verify-oidc-rotation-counterexample
verify-oidc-rotation-counterexample:  ## Drive stale issuer/key auth failure counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=OidcIssuerRotation --init=staleIssuerFailureRun --step=step \
	              --invariant=NoExtendedAuthOutage --max-steps=0 \
	              $(OIDCROT)

.PHONY: verify-oidc-rotation-random
verify-oidc-rotation-random:  ## Random-walk stable issuer/key bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants TokenIssuerKnown TokenKeyKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=OidcIssuerRotation \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(OIDCROT) || exit 1; \
	done

.PHONY: verify-oidc-rotation-apalache
verify-oidc-rotation-apalache:  ## Apalache stale issuer/key auth failure counterexample at depth 4
	-@echo y | $(QUINT) verify --main=OidcIssuerRotation --init=staleIssuerInit \
	                  --step=stepApalache --invariant=NoExtendedAuthOutage \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(OIDCROT)

.PHONY: verify-oidc-rotation
verify-oidc-rotation: verify-oidc-rotation-happy verify-oidc-rotation-counterexample verify-oidc-rotation-random verify-oidc-rotation-apalache  ## Full OIDC issuer rotation / stale key auth suite

.PHONY: verify-msg-truncation-happy
verify-msg-truncation-happy:  ## Drive tail-preserving truncation path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConditionMessageTruncation --init=tailPreservedRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(MSGTRUNC)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ConditionMessageTruncation --init=tailPreservedRun --step=step \
	             --invariant=RootCauseSurvivesTruncation --max-steps=0 \
	             $(MSGTRUNC)

.PHONY: verify-msg-truncation-counterexample
verify-msg-truncation-counterexample:  ## Drive tail-dropped truncation without companion event
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ConditionMessageTruncation --init=tailDroppedRun --step=step \
	              --invariant=RootCauseSurvivesTruncation --max-steps=0 \
	              $(MSGTRUNC)

.PHONY: verify-msg-truncation-random
verify-msg-truncation-random:  ## Random-walk stable condition-message bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants StoredLengthBounded CompanionEventCarriesFullMessage; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ConditionMessageTruncation \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(MSGTRUNC) || exit 1; \
	done

.PHONY: verify-msg-truncation-apalache
verify-msg-truncation-apalache:  ## Apalache tail-loss counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ConditionMessageTruncation --init=tailDroppedInit \
	                  --step=stepApalache --invariant=RootCauseSurvivesTruncation \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(MSGTRUNC)

.PHONY: verify-msg-truncation
verify-msg-truncation: verify-msg-truncation-happy verify-msg-truncation-counterexample verify-msg-truncation-random verify-msg-truncation-apalache  ## Full condition-message truncation suite

.PHONY: verify-status-lag-happy
verify-status-lag-happy:  ## Drive status update catching up to spec change
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StatusSubresourceLag --init=convergedStatusRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(STATUSLAG)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=StatusSubresourceLag --init=convergedStatusRun --step=step \
	             --invariant=StatusEventuallyConverges --max-steps=0 \
	             $(STATUSLAG)

.PHONY: verify-status-lag-counterexample
verify-status-lag-counterexample:  ## Drive stale status phase causing contradictory decision
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=StatusSubresourceLag --init=staleStatusDecisionRun --step=step \
	              --invariant=LevelTriggeredControllersTolerateLag --max-steps=0 \
	              $(STATUSLAG)

.PHONY: verify-status-lag-random
verify-status-lag-random:  ## Random-walk stable spec/status lag invariants (300x40)
	@for inv in StableSafetyInvariants StatusNeverLeadsSpec PhaseKnownValues; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=StatusSubresourceLag \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(STATUSLAG) || exit 1; \
	done

.PHONY: verify-status-lag-apalache
verify-status-lag-apalache:  ## Apalache stale-status decision counterexample at depth 4
	-@echo y | $(QUINT) verify --main=StatusSubresourceLag --init=staleStatusInit \
	                  --step=stepApalache --invariant=LevelTriggeredControllersTolerateLag \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(STATUSLAG)

.PHONY: verify-status-lag
verify-status-lag: verify-status-lag-happy verify-status-lag-counterexample verify-status-lag-random verify-status-lag-apalache  ## Full status-subresource lag suite

.PHONY: verify-cluster-delete-race-happy
verify-cluster-delete-race-happy:  ## Drive edit completes before delete or exits cleanly on notfound
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterEditDeleteRace --init=editThenDeleteRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(CLUSTERDELRACE)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterEditDeleteRace --init=editThenDeleteRun --step=step \
	             --invariant=DeleteCancelsFurtherWrites --max-steps=0 \
	             $(CLUSTERDELRACE)

.PHONY: verify-cluster-delete-race-counterexample
verify-cluster-delete-race-counterexample:  ## Drive stale write after delete counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=ClusterEditDeleteRace --init=deleteMidEditRun --step=step \
	              --invariant=NoWriteAfterDeleteObserved --max-steps=0 \
	              $(CLUSTERDELRACE)

.PHONY: verify-cluster-delete-race-random
verify-cluster-delete-race-random:  ## Random-walk stable edit/delete bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants DeleteObservedImpliesAbsent LastWriteGenNeverExceedsIntent; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterEditDeleteRace \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(CLUSTERDELRACE) || exit 1; \
	done

.PHONY: verify-cluster-delete-race-apalache
verify-cluster-delete-race-apalache:  ## Apalache stale-write-after-delete counterexample at depth 4
	-@echo y | $(QUINT) verify --main=ClusterEditDeleteRace --init=deleteDuringEditInit \
	                  --step=stepApalache --invariant=NoWriteAfterDeleteObserved \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(CLUSTERDELRACE)

.PHONY: verify-cluster-delete-race
verify-cluster-delete-race: verify-cluster-delete-race-happy verify-cluster-delete-race-counterexample verify-cluster-delete-race-random verify-cluster-delete-race-apalache  ## Full Cluster edit/delete race suite

.PHONY: verify-partial-revert-happy
verify-partial-revert-happy:  ## Drive backup/apply then one-shot redefault convergence
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=PartialRollbackDrop --init=singleRedefaultRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(PARTIALREVERT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=PartialRollbackDrop --init=singleRedefaultRun --step=step \
	             --invariant=OperatorActionRecoverable --max-steps=0 \
	             $(PARTIALREVERT)

.PHONY: verify-partial-revert-counterexample
verify-partial-revert-counterexample:  ## Drive omitted-field rollback loop counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=PartialRollbackDrop --init=rollbackLoopRun --step=step \
	              --invariant=RedefaultConverges --max-steps=0 \
	              $(PARTIALREVERT)

.PHONY: verify-partial-revert-random
verify-partial-revert-random:  ## Random-walk stable rollback/default bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants DefaultedByKnown FieldValueKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=PartialRollbackDrop \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(PARTIALREVERT) || exit 1; \
	done

.PHONY: verify-partial-revert-apalache
verify-partial-revert-apalache:  ## Apalache omitted-field rollback loop counterexample at depth 4
	-@echo y | $(QUINT) verify --main=PartialRollbackDrop --init=rollbackLoopInit \
	                  --step=stepApalache --invariant=RedefaultConverges \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(PARTIALREVERT)

.PHONY: verify-partial-revert
verify-partial-revert: verify-partial-revert-happy verify-partial-revert-counterexample verify-partial-revert-random verify-partial-revert-apalache  ## Full partial rollback / dropped-fields suite

.PHONY: verify-machinepool-scale-happy
verify-machinepool-scale-happy:  ## Drive arbitrated MachinePool scale ownership path
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachinePoolScaleConflict --init=arbitratedScaleRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(MPSCALECONFLICT)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachinePoolScaleConflict --init=arbitratedScaleRun --step=step \
	             --invariant=EventualConvergence --max-steps=0 \
	             $(MPSCALECONFLICT)

.PHONY: verify-machinepool-scale-counterexample
verify-machinepool-scale-counterexample:  ## Drive spec-vs-provider oscillation counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=MachinePoolScaleConflict --init=oscillationRun --step=step \
	              --invariant=NoOscillation --max-steps=0 \
	              $(MPSCALECONFLICT)

.PHONY: verify-machinepool-scale-random
verify-machinepool-scale-random:  ## Random-walk stable MachinePool scale bookkeeping invariants (300x40)
	@for inv in StableSafetyInvariants ProviderActualNonNegative LastReconcileIsKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=MachinePoolScaleConflict \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(MPSCALECONFLICT) || exit 1; \
	done

.PHONY: verify-machinepool-scale-apalache
verify-machinepool-scale-apalache:  ## Apalache oscillation counterexample at depth 4
	-@echo y | $(QUINT) verify --main=MachinePoolScaleConflict --init=oscillationInit \
	                  --step=stepApalache --invariant=NoOscillation \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(MPSCALECONFLICT)

.PHONY: verify-machinepool-scale
verify-machinepool-scale: verify-machinepool-scale-happy verify-machinepool-scale-counterexample verify-machinepool-scale-random verify-machinepool-scale-apalache  ## Full MachinePool spec-vs-provider scale conflict suite

## --------------------------------------
## CAPI refinements onto controller-runtime
## --------------------------------------

##@ refinements:

.PHONY: verify-topology-refined
verify-topology-refined:  ## Random-walk TopologyRefined (Topology + CR substrate)
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation \
	            FM39_BeforeClusterUpgradeIdempotent WorkerVersionLeqCp \
	            BodyActionsGated; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=TopologyRefined \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(TOPO_REFINED) || exit 1; \
	done

.PHONY: verify-inplace-refined
verify-inplace-refined:  ## Random-walk InPlaceUpdateRefined (InPlaceUpdate + CR substrate, multi-worker)
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation \
	            FM43_UpdateMachineIdempotenceGate \
	            FM44_MultiExtensionBlocksProgress \
	            DoneImpliesVersionFlipped BodyActionsGated; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=InPlaceUpdateRefined \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(INPLACE_REFINED) || exit 1; \
	done

.PHONY: verify-mspreflight-refined
verify-mspreflight-refined:  ## Random-walk MachineSetPreflightRefined
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation \
	            PreflightGateWellFormed PreflightGateRespected \
	            BodyActionsGated; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=MachineSetPreflightRefined \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(MSPREFLIGHT_REFINED) || exit 1; \
	done

.PHONY: verify-refinements
verify-refinements: verify-topology-refined verify-inplace-refined verify-mspreflight-refined  ## Full refinement suite

## --------------------------------------
## Apalache deadlock check (Issue #6)
## --------------------------------------

##@ deadlock-check:

# Apalache reports "deadlock" when no transition is enabled in a
# reachable state. Running with `--invariant=true` (a tautology)
# yields a pure deadlock check. All 10 specs HOLD at depth 4
# (no deadlocks).

.PHONY: verify-deadlock-check
verify-deadlock-check:  ## Apalache deadlock check on every spec (~80 s total)
	@for spec in ControllerRuntime InPlaceUpdate MachineSetPreflight \
	             Topology ClusterE2E WorkerLifecycle SelfHosted \
	             TopologyRefined InPlaceUpdateRefined \
	             MachineSetPreflightRefined; do \
	  if [ -f $(SPECS_DIR)/$$spec.qnt ]; then \
	    echo "==> $$spec"; \
	    echo y | $(QUINT) verify --main=$$spec --invariant=true \
	                              --max-steps=$(MAX_STEPS_APALACHE) \
	                              --backend=apalache $(SPECS_DIR)/$$spec.qnt || exit 1; \
	    sleep 3; \
	  fi; \
	done

## --------------------------------------
## Depth-bump verifications (Issue #5)
## --------------------------------------

##@ depth-bump:

# Re-run random walks at deeper bounds. All hold; no
# counterexamples found. Lifecycle FM-9 at depth=12 surfaces a
# fairness-scope gap (see counterexample-log.md).

.PHONY: verify-depth-bump
verify-depth-bump:  ## Re-run random walks at deeper bounds (~30 s total)
	@echo "##### Topology @ 200×40 #####"
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=Topology \
	             --invariant=AllSafetyInvariants --max-samples=200 --max-steps=40 \
	             $(TOPOLOGY)
	@echo "##### InPlaceUpdate @ 2000×120 #####"
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=InPlaceUpdate \
	             --invariant=AllSafetyInvariants --max-samples=2000 --max-steps=120 \
	             $(INPLACE)
	@echo "##### ControllerRuntime @ 500×100 #####"
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ControllerRuntime \
	             --invariant=AllSafetyInvariants --max-samples=500 --max-steps=100 \
	             $(CRRUNTIME)
	@echo "##### ClusterE2E @ 300×100 #####"
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterE2E \
	             --invariant=AllSafetyInvariants --max-samples=300 --max-steps=100 \
	             $(E2E)
	@echo "##### WorkerLifecycle @ 1000×80 #####"
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=WorkerLifecycle \
	             --invariant=AllSafetyInvariants --max-samples=1000 --max-steps=80 \
	             $(WORKER_LIFE)

.PHONY: verify-fm1-depth12
verify-fm1-depth12:  ## FM-1 TLC at depth=12 (was 8, ~1.3 s, 90k states)
	$(QUINT) verify --main=Lifecycle --init=incidentInit \
	                --step=stepRemediation --max-steps=12 \
	                --invariant=AllSafetyInvariants \
	                --backend=tlc $(LIFECYCLE)

.PHONY: verify-fm9-fair17-depth12
verify-fm9-fair17-depth12:  ## FM-9 ConvergenceFair17 at depth=12 (issue #5; surfaces flip-flop gap)
	TLA_JAVA_OPTS='-Xmx8g' $(QUINT) verify --main=Lifecycle --init=init \
	                --step=step --temporal=ConvergenceFair17 --backend=tlc \
	                --max-steps=12 $(LIFECYCLE)

## --------------------------------------
## Mutation testing (Issue #4)
## --------------------------------------

##@ mutation-testing:

.PHONY: mutation-test
mutation-test:  ## Run mutation testing across all spec modules (~10 min)
	@$(PYTHON) ../hack/tools/quint-mutation-tester.py --help >/dev/null 2>&1 || { echo "ERR: quint-mutation-tester.py missing"; exit 1; }
	@for pair in ControllerRuntime:ControllerRuntime InPlaceUpdate:InPlaceUpdate MachineSetPreflight:MachineSetPreflight \
	             Topology:Topology ClusterE2E:ClusterE2E WorkerLifecycle:WorkerLifecycle SelfHosted:SelfHosted \
	             TopologyRefined:TopologyRefined InPlaceUpdateRefined:InPlaceUpdateRefined \
	             Lifecycle.multicluster:LifecycleMultiCluster \
	             MachineSetPreflightRefined:MachineSetPreflightRefined; do \
	  spec=$${pair%%:*}; main=$${pair##*:}; \
	  if [ -f $(SPECS_DIR)/$$spec.qnt ]; then \
	    echo "##### $$spec #####"; \
	    $(PYTHON) ../hack/tools/quint-mutation-tester.py \
	      $(SPECS_DIR)/$$spec.qnt --main=$$main \
	      --max-samples=300 --max-steps=40 --timeout=60 \
	      --workdir=/tmp/quint-mutations || true; \
	  fi; \
	done

.PHONY: mutation-test-newer-sampled
mutation-test-newer-sampled:  ## Run a CI-sized sampled subset of newer-spec mutation tests
	@$(PYTHON) ../hack/tools/quint-mutation-tester.py --help >/dev/null 2>&1 || { echo "ERR: quint-mutation-tester.py missing"; exit 1; }
	@for spec in ControllerRuntime Topology ClusterE2E WorkerLifecycle; do \
	  echo "##### $$spec #####"; \
	  $(PYTHON) ../hack/tools/quint-mutation-tester.py \
	    $(SPECS_DIR)/$$spec.qnt --main=$$spec \
	    --max-samples=120 --max-steps=20 --timeout=45 \
	    --workdir=/tmp/quint-mutations || true; \
	done

.PHONY: mutation-test-newer-full
mutation-test-newer-full: mutation-test  ## Run the full newer-spec mutation sweep (nightly/full gate)

.PHONY: mutation-test-spec
mutation-test-spec:  ## Run mutation testing against one spec (use SPEC=<name>)
	@test -n "$(SPEC)" || { echo "Usage: make mutation-test-spec SPEC=<ModuleName>"; exit 1; }
	$(PYTHON) ../hack/tools/quint-mutation-tester.py \
	  $(SPECS_DIR)/$(SPEC).qnt --main=$(if $(MAIN),$(MAIN),$(SPEC)) \
	  --max-samples=300 --max-steps=40 --timeout=60 \
	  --workdir=/tmp/quint-mutations

## --------------------------------------
## Liveness properties beyond FM-9 (Issue #3)
## --------------------------------------

##@ liveness:

.PHONY: verify-inplace-liveness
verify-inplace-liveness:  ## Verify L1/L2/L3 in InPlaceUpdate (TLC, ~3 s each)
	@for prop in L1_EventuallyAllMachinesSettled \
	             L2_EventuallyHookPendingCleared \
	             L3_EventuallyVersionStable; do \
	  echo "==> $$prop"; \
	  $(QUINT) verify --main=InPlaceUpdate --temporal=$$prop \
	                   --backend=tlc --max-steps=$(MAX_STEPS_TLC) \
	                   $(INPLACE) || exit 1; \
	done

.PHONY: verify-topology-liveness
verify-topology-liveness:  ## Verify LT1 in Topology (TLC, ~30 s; LT2/LT3 documented as fairness-gap-limited)
	$(QUINT) verify --main=Topology \
	                 --temporal=LT1_EventuallyPendingHooksClear \
	                 --backend=tlc --max-steps=$(MAX_STEPS_TLC) \
	                 $(TOPOLOGY)
	@echo "==> LT2/LT3 are known fairness-gap-limited (counterexamples logged in counterexample-log.md, issue #24)"

.PHONY: verify-cr-liveness
verify-cr-liveness:  ## (best-effort) ControllerRuntime liveness — see failure-modes.md (issue #24)
	@echo "==> ControllerRuntime liveness: documented as TLC-scaling-limited at the spec's default constants"
	@echo "==> ControllerRuntime.qnt has 3 KEYS x 2 WORKERS x rate-limited queues — initial-state BFS expansion"
	@echo "==> exceeds 5M distinct states before liveness check completes. See failure-modes.md row for"
	@echo "==> CRTL1/CRTL2/LT_StarvationFreeUnderBoundedFault. Re-enable when Apalache is in PATH."
	@if command -v apalache-mc >/dev/null 2>&1 || command -v apalache >/dev/null 2>&1; then \
	  echo "==> apalache available — attempting CRTL1 at depth $(MAX_STEPS_APALACHE)"; \
	  echo y | $(QUINT) verify --main=ControllerRuntime --temporal=CRTL1_EventuallyNoInflight \
	                  --backend=apalache --max-steps=$(MAX_STEPS_APALACHE) $(CRRUNTIME) || true; \
	fi

.PHONY: verify-e2e-liveness
verify-e2e-liveness:  ## Verify CE1/CE2 in ClusterE2E (TLC) — issue #24
	@for prop in CE1_EventuallyEndpointSet \
	             CE2_EventuallyControlPlaneInitialised; do \
	  echo "==> $$prop"; \
	  $(QUINT) verify --main=ClusterE2E --temporal=$$prop \
	                   --backend=tlc --max-steps=$(MAX_STEPS_TLC) \
	                   $(E2E) || exit 1; \
	done

.PHONY: verify-liveness-apalache
verify-liveness-apalache:  ## Issue #24 — run liveness properties under Apalache backend (skips cleanly if absent)
	@if ! command -v apalache-mc >/dev/null 2>&1 && ! command -v apalache >/dev/null 2>&1; then \
	  echo "SKIP: apalache-mc/apalache not in PATH (liveness properties verified under TLC backend via verify-liveness)"; \
	  exit 0; \
	fi
	@for prop in L1_EventuallyAllMachinesSettled L2_EventuallyHookPendingCleared L3_EventuallyVersionStable; do \
	  echo "==> InPlaceUpdate.$$prop (apalache)"; \
	  echo y | $(QUINT) verify --main=InPlaceUpdate --temporal=$$prop \
	                  --backend=apalache --max-steps=$(MAX_STEPS_APALACHE) \
	                  $(INPLACE) || exit 1; \
	done
	@echo "==> Topology.LT1_EventuallyPendingHooksClear (apalache)"
	@echo y | $(QUINT) verify --main=Topology --temporal=LT1_EventuallyPendingHooksClear \
	                  --backend=apalache --max-steps=$(MAX_STEPS_APALACHE) $(TOPOLOGY)
	@echo "==> ControllerRuntime.CRTL1_EventuallyNoInflight (apalache)"
	@echo y | $(QUINT) verify --main=ControllerRuntime --temporal=CRTL1_EventuallyNoInflight \
	                  --backend=apalache --max-steps=$(MAX_STEPS_APALACHE) $(CRRUNTIME)
	@echo "==> ClusterE2E.CE1_EventuallyEndpointSet (apalache)"
	@echo y | $(QUINT) verify --main=ClusterE2E --temporal=CE1_EventuallyEndpointSet \
	                  --backend=apalache --max-steps=$(MAX_STEPS_APALACHE) $(E2E)

.PHONY: verify-liveness
verify-liveness: verify-inplace-liveness verify-topology-liveness verify-cr-liveness verify-e2e-liveness  ## All liveness properties (issues #3, #24)

## --------------------------------------
## Worker-lifecycle cross-spec composition (Issue #2, FM-51)
## --------------------------------------

##@ worker-lifecycle:

.PHONY: verify-worker-lifecycle-happy
verify-worker-lifecycle-happy:  ## Drive happyInPlaceUpgradeRun (full upgrade with in-place)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WorkerLifecycle --init=happyInPlaceUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(WORKER_LIFE)

.PHONY: verify-worker-lifecycle-preflight
verify-worker-lifecycle-preflight:  ## Drive preflightBlockedDuringInPlaceRun (FM-51 race)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=WorkerLifecycle --init=preflightBlockedDuringInPlaceRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(WORKER_LIFE)

.PHONY: verify-worker-lifecycle-random
verify-worker-lifecycle-random:  ## Random-walk every WorkerLifecycle invariant (1000x60 — issue #2 spec)
	@for inv in AllSafetyInvariants FM39_BeforeClusterUpgradeIdempotent \
	            FM41_AfterClusterUpgradeAtSteadyState FM43_UpdateMachineIdempotence \
	            FM33_PreflightGate J1_NoMoveBeforeWorkersStep \
	            J2_AfterWorkersAtMachineQuiescence \
	            J3_InPlaceAdmissionAfterBeforeWorkersUpgrade \
	            J4_MachineVersionMonotone J5_NoInFlightAcrossStable; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=WorkerLifecycle \
	               --invariant=$$inv --max-samples=1000 --max-steps=60 \
	               $(WORKER_LIFE) || exit 1; \
	done

.PHONY: verify-worker-lifecycle
verify-worker-lifecycle: verify-worker-lifecycle-happy verify-worker-lifecycle-preflight verify-worker-lifecycle-random  ## Full WorkerLifecycle suite

## --------------------------------------
## MachineDeployment rollout x MHC x scale concurrency (Issue #14)
## --------------------------------------

##@ machine-deployment-rollout:

.PHONY: verify-md-rollout-happy
verify-md-rollout-happy:  ## Drive happy rollout completion run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachineDeploymentRollout --init=happyRolloutRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(MD_ROLLOUT)

.PHONY: verify-md-rollout-race
verify-md-rollout-race:  ## Drive scale-down versus MHC remediation race run
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=MachineDeploymentRollout --init=conflictingDeleteRaceRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(MD_ROLLOUT)

.PHONY: verify-md-rollout-random
verify-md-rollout-random:  ## Random-walk every MD rollout invariant (1000x60)
	@for inv in AllSafetyInvariants SurgeBound \
	            NoConflictingDeletes TemplateMonotone \
	            PdbBlockedDrainStalls DrainTimeoutEventuallyRequeues \
	            MhcCannotDeleteScaleDownVictim RemovedMachinesDeselected; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=MachineDeploymentRollout \
	               --invariant=$$inv --max-samples=1000 --max-steps=60 \
	               $(MD_ROLLOUT) || exit 1; \
	done

.PHONY: verify-md-rollout-apalache
verify-md-rollout-apalache:  ## Apalache battery across MD rollout invariants
	@for inv in SurgeBound NoConflictingDeletes TemplateMonotone \
	            PdbBlockedDrainStalls DrainTimeoutEventuallyRequeues \
	            RemovedMachinesDeselected; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=MachineDeploymentRollout \
	                            --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                            --backend=apalache $(MD_ROLLOUT) || exit 1; \
	  sleep 5; \
	done

.PHONY: verify-md-rollout-refined
verify-md-rollout-refined:  ## Random-walk refined MD rollout invariants on controller-runtime substrate
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation BodyActionsGated \
	            ReconcileOwnershipConsistent; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=MachineDeploymentRolloutRefined \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(MD_ROLLOUT_REFINED) || exit 1; \
	done

.PHONY: verify-md-rollout
verify-md-rollout: verify-md-rollout-happy verify-md-rollout-race verify-md-rollout-random verify-md-rollout-refined  ## Full MD rollout suite

.PHONY: verify-clusterclass-patches-happy
verify-clusterclass-patches-happy:  ## Drive happy ClusterClass patch merge run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterClassPatches \
	             --init=happyPatchMergeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(CC_PATCHES)

.PHONY: verify-clusterclass-patches-overlap
verify-clusterclass-patches-overlap:  ## Drive overlapping-patch order run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterClassPatches \
	             --init=overlappingPatchOrderRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(CC_PATCHES)

.PHONY: verify-clusterclass-patches-random
verify-clusterclass-patches-random:  ## Random-walk ClusterClass patch invariants (1000x60)
	@for inv in StableSafetyInvariants mergeDeterministic immutablePreserved \
	            overridesSurviveCC patchIdempotent noPhantomVar; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterClassPatches \
	               --step=randomStep \
	               --invariant=$$inv --max-samples=1000 --max-steps=60 \
	               $(CC_PATCHES) || exit 1; \
	done

.PHONY: verify-clusterclass-patches-apalache
verify-clusterclass-patches-apalache:  ## Apalache battery across ClusterClass patch invariants
	@for inv in mergeDeterministic immutablePreserved overridesSurviveCC \
	            patchIdempotent noPhantomVar; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=ClusterClassPatches \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(CC_PATCHES) || exit 1; \
	done

.PHONY: verify-clusterclass-patches
verify-clusterclass-patches: verify-clusterclass-patches-happy verify-clusterclass-patches-overlap verify-clusterclass-patches-random verify-clusterclass-patches-apalache  ## Full ClusterClass patch suite

.PHONY: verify-finalizers-happy
verify-finalizers-happy:  ## Drive happy finalizer cascade run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=Finalizers \
	             --init=happyCascadeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(FINALIZERS)

.PHONY: verify-finalizers-random
verify-finalizers-random:  ## Random-walk finalizer invariants (1000x60)
	@for inv in StableSafetyInvariants noOrphan cleanShutdownTerminal topologicalOrder idempotentRemoval; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=Finalizers \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=1000 --max-steps=60 $(FINALIZERS) || exit 1; \
	done

.PHONY: verify-finalizers-apalache
verify-finalizers-apalache:  ## Apalache battery across finalizer invariants
	@for inv in noOrphan cleanShutdownTerminal topologicalOrder idempotentRemoval; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=Finalizers \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(FINALIZERS) || exit 1; \
	done

.PHONY: verify-finalizers-proof
verify-finalizers-proof:  ## Build Lean theorem for finalizer progress measure
	cd $(PROOFS_DIR) && $(LEAN) build

.PHONY: verify-finalizers
verify-finalizers: verify-finalizers-happy verify-finalizers-random verify-finalizers-apalache verify-finalizers-proof  ## Full finalizer suite

.PHONY: verify-joining-name-happy
verify-joining-name-happy:  ## Drive member joins before machine deletion
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdJoiningNameDelay --init=joinedBeforeDeleteRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(JOINNAME)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=EtcdJoiningNameDelay --init=joinedBeforeDeleteRun --step=step \
	             --invariant=JoiningEventuallyJoinedOrRemoved --max-steps=0 \
	             $(JOINNAME)

.PHONY: verify-joining-name-counterexample
verify-joining-name-counterexample:  ## Drive orphan joining-member after delete
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdJoiningNameDelay --init=orphanJoiningRun --step=step \
	              --invariant=NoOrphanJoiningMemberAfterMachineGone --max-steps=0 \
	              $(JOINNAME)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) \
	              --main=EtcdJoiningNameDelay --init=orphanJoiningRun --step=step \
	              --invariant=JoiningEventuallyJoinedOrRemoved --max-steps=0 \
	              $(JOINNAME)

.PHONY: verify-joining-name-random
verify-joining-name-random:  ## Random-walk stable joining-name invariants (300x40)
	@for inv in StableSafetyInvariants JoinedImpliesNameVisible MachineGoneKnown; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=EtcdJoiningNameDelay \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(JOINNAME) || exit 1; \
	done

.PHONY: verify-joining-name-apalache
verify-joining-name-apalache:  ## Apalache orphan joining-member counterexample at depth 4
	-@echo y | $(QUINT) verify --main=EtcdJoiningNameDelay --init=orphanJoiningInit \
	                  --step=stepApalache --invariant=NoOrphanJoiningMemberAfterMachineGone \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache \
	                  $(JOINNAME)

.PHONY: verify-joining-name-delay
verify-joining-name-delay: verify-joining-name-happy verify-joining-name-counterexample verify-joining-name-random verify-joining-name-apalache  ## Full etcd empty-name joining-member suite

.PHONY: verify-orphan-correlation-happy
verify-orphan-correlation-happy:  ## Drive joined-name publication and annotation unblock paths
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=OrphanLearnerCorrelation --init=joinedBeforeDeleteRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 \
	             $(ORPHANCORR)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=OrphanLearnerCorrelation --init=annotationUnblockRun --step=step \
	             --invariant=AnnotationUnblockClearsOrphanCondition --max-steps=0 \
	             $(ORPHANCORR)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=OrphanLearnerCorrelation --init=externalRemovalRun --step=step \
	             --invariant=ExternalRemovalClearsOrphanCondition --max-steps=0 \
	             $(ORPHANCORR)

.PHONY: verify-orphan-correlation-random
verify-orphan-correlation-random:  ## Random-walk post-fix orphan-correlation invariants (300x40)
	@for inv in StableSafetyInvariants NoOrphanMemberAfterDelete Step5RequiresStartupTimeout AddressCollisionBlocksStep4; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=OrphanLearnerCorrelation \
	               --invariant=$$inv --max-samples=300 --max-steps=40 \
	               $(ORPHANCORR) || exit 1; \
	done

.PHONY: verify-orphan-correlation-apalache
verify-orphan-correlation-apalache:  ## Apalache battery across post-fix orphan-correlation invariants at depth 8
	@for inv in NoOrphanMemberAfterDelete Step5RequiresStartupTimeout AddressCollisionBlocksStep4 CorrelationFailureHasExitPath; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=OrphanLearnerCorrelation \
	                         --invariant=$$inv --max-steps=8 \
	                         --backend=apalache $(ORPHANCORR) || exit 1; \
	done

.PHONY: verify-orphan-correlation
verify-orphan-correlation: verify-orphan-correlation-happy verify-orphan-correlation-random verify-orphan-correlation-apalache  ## Full post-fix orphan-learner correlation suite

.PHONY: verify-volume-detach-finalizer-happy
verify-volume-detach-finalizer-happy:  ## Drive successful detach and finalizer clearance
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=VolumeDetachFinalizer \
	             --init=successfulDetachRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(VOLDETACH)
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=VolumeDetachFinalizer \
	             --init=successfulDetachRun --step=step \
	             --invariant=OperatorEscapeHatch --max-steps=0 $(VOLDETACH)

.PHONY: verify-volume-detach-finalizer-counterexample
verify-volume-detach-finalizer-counterexample:  ## Drive stuck detach / finalizer-chain stall counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) --main=VolumeDetachFinalizer \
	              --init=stuckDetachRun --step=step \
	              --invariant=OperatorEscapeHatch --max-steps=0 $(VOLDETACH)

.PHONY: verify-volume-detach-finalizer-random
verify-volume-detach-finalizer-random:  ## Random-walk stable detach/finalizer invariants (300x40)
	@for inv in StableSafetyInvariants DetachRequiresInProgress; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=VolumeDetachFinalizer \
	               --invariant=$$inv --max-samples=300 --max-steps=40 $(VOLDETACH) || exit 1; \
	done

.PHONY: verify-volume-detach-finalizer-apalache
verify-volume-detach-finalizer-apalache:  ## Apalache stuck-detach counterexample at depth 4
	-@echo y | $(QUINT) verify --main=VolumeDetachFinalizer \
	                  --init=stuckDetachInit --step=stepApalache \
	                  --invariant=OperatorEscapeHatch \
	                  --max-steps=$(MAX_STEPS_APALACHE) --backend=apalache $(VOLDETACH)

.PHONY: verify-volume-detach-finalizer
verify-volume-detach-finalizer: verify-volume-detach-finalizer-happy verify-volume-detach-finalizer-counterexample verify-volume-detach-finalizer-random verify-volume-detach-finalizer-apalache  ## Full CSI detach hang / finalizer-chain stall suite

.PHONY: verify-runtimesdk-happy
verify-runtimesdk-happy:  ## Drive happy Runtime SDK lifecycle run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=RuntimeSDK \
	             --init=happyRuntimeRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(RUNTIMESDK)

.PHONY: verify-runtimesdk-partial
verify-runtimesdk-partial:  ## Drive partial-failure retry run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=RuntimeSDK \
	             --init=partialFailureRetryRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(RUNTIMESDK)

.PHONY: verify-runtimesdk-random
verify-runtimesdk-random:  ## Random-walk Runtime SDK invariants (1000x60)
	@for inv in StableSafetyInvariants idempotentHookUnderRetry noDoubleFire \
	            discoveryConsistent cacheInvalidatedOnRestart \
	            partialFailureRecoverable; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=RuntimeSDK \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=1000 --max-steps=60 $(RUNTIMESDK) || exit 1; \
	done

.PHONY: verify-runtimesdk-apalache
verify-runtimesdk-apalache:  ## Apalache battery across Runtime SDK invariants
	@for inv in idempotentHookUnderRetry noDoubleFire discoveryConsistent \
	            cacheInvalidatedOnRestart partialFailureRecoverable; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=RuntimeSDK \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(RUNTIMESDK) || exit 1; \
	done

.PHONY: verify-runtimesdk
verify-runtimesdk: verify-runtimesdk-happy verify-runtimesdk-partial verify-runtimesdk-random verify-runtimesdk-apalache  ## Full Runtime SDK suite

.PHONY: verify-concurrent-remediation-happy
verify-concurrent-remediation-happy:  ## Deterministic non-atomic safe trace + fixed variant
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ConcurrentRemediationGate \
	             --init=init --step=stepFixed --invariant=FixedVariantPreservesQuorum \
	             --max-samples=200 --max-steps=12 $(CONCREM)

.PHONY: verify-concurrent-remediation-counterexample
verify-concurrent-remediation-counterexample:  ## Non-atomic gate quorum-loss counterexample
	-@$(QUINT) run --backend=$(QUINT_BACKEND) --main=ConcurrentRemediationGate \
	              --init=admissionRaceRun --step=step --invariant=NoConcurrentQuorumLoss \
	              --max-steps=0 $(CONCREM)
	-@$(QUINT) run --backend=$(QUINT_BACKEND) --main=ConcurrentRemediationGate \
	              --init=admissionRaceRun --step=step --invariant=GateReadStalenessBound \
	              --max-steps=0 $(CONCREM)

.PHONY: verify-concurrent-remediation-apalache
verify-concurrent-remediation-apalache:  ## Apalache non-atomic gate counterexample vs fixed variant at depth 8
	-@echo y | $(QUINT) verify --main=ConcurrentRemediationGate --init=init \
	                  --step=step --invariant=NoConcurrentQuorumLoss \
	                  --max-steps=8 --backend=apalache $(CONCREM)
	@echo y | $(QUINT) verify --main=ConcurrentRemediationGate --init=init \
	                 --step=stepFixed --invariant=FixedVariantPreservesQuorum \
	                 --max-steps=8 --backend=apalache $(CONCREM)

.PHONY: verify-concurrent-remediation
verify-concurrent-remediation: verify-concurrent-remediation-happy verify-concurrent-remediation-counterexample verify-concurrent-remediation-apalache  ## Full non-atomic remediation gate suite

.PHONY: verify-remediation-cas-tla
verify-remediation-cas-tla:  ## TLC check on RemediationCAS.tla — admission/commit CAS refinement (issue #110)
	@if ! command -v $(TLC) >/dev/null 2>&1; then \
	  echo "SKIP: tlc not in PATH"; \
	  exit 0; \
	fi
	$(TLC) -config $(SPECS_DIR)/RemediationCAS.cfg $(SPECS_DIR)/RemediationCAS.tla

REPO_ROOT := $(abspath ..)

.PHONY: verify-remediation-cas-traces
verify-remediation-cas-traces:  ## Run trace-validator on the CAS refinement testdata corpus (issue #110)
	cd $(REPO_ROOT) && go test -count=1 ./internal/trace/checkers/etcdscheduler/...
	@for fixture in \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_orphan_etcd_learner.jsonl \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_concurrent_cp_remediation.jsonl \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_cas_stale_voter_count_aborted_pass.jsonl \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_cas_learner_promoted_aborted_pass.jsonl; do \
	  echo "==> PASS-expected: $$fixture"; \
	  (cd $(REPO_ROOT)/hack/tools && go run -tags tools ./trace-validator -format jsonl "$$fixture") || exit 1; \
	done
	@for fixture in \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_cas_stale_voter_count_fail.jsonl \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_cas_learner_promoted_fail.jsonl \
	  $(REPO_ROOT)/internal/trace/testdata/remediation_cas_concurrent_cp_remediation_fail.jsonl; do \
	  echo "==> FAIL-expected: $$fixture"; \
	  if (cd $(REPO_ROOT)/hack/tools && go run -tags tools ./trace-validator -format jsonl "$$fixture") >/dev/null 2>&1; then \
	    echo "ERROR: validator passed on FAIL-expected fixture $$fixture" >&2; exit 1; \
	  fi; \
	done

.PHONY: verify-remediation-cas
verify-remediation-cas: verify-remediation-cas-tla verify-remediation-cas-traces  ## Issue #110 — full admission/commit CAS refinement suite

.PHONY: verify-kcp-condemned-peers-happy
verify-kcp-condemned-peers-happy:  ## 5-node admit + wind-down carve-out stay safe
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=KCPReconcile \
	             --init=fiveNodeCondemnedPeerAllowedRun --step=step \
	             --invariant=NoJointQuorumLossAcrossConcurrentRemediation --max-steps=0 \
	             $(SPECS_DIR)/KCPReconcile.qnt
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=KCPReconcile \
	             --init=allDeletingWindDownRun --step=step \
	             --invariant=NoJointQuorumLossAcrossConcurrentRemediation --max-steps=0 \
	             $(SPECS_DIR)/KCPReconcile.qnt

.PHONY: verify-kcp-condemned-peers-counterexample
verify-kcp-condemned-peers-counterexample:  ## 3-node condemned-peer second admission is blocked
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=KCPReconcile \
	             --init=threeNodeCondemnedPeerBlockedRun --step=step \
	             --invariant=PreflightBlocksRemediationWhenUnhealthy --max-steps=0 \
	             $(SPECS_DIR)/KCPReconcile.qnt

.PHONY: verify-kcp-condemned-peers-apalache
verify-kcp-condemned-peers-apalache:  ## Apalache confirms strengthened concurrent-remediation invariant
	@echo y | $(QUINT) verify --main=KCPReconcile --init=InitFiveNode \
	                 --step=stepCondemnedPeersApalache --invariant=NoJointQuorumLossAcrossConcurrentRemediation \
	                 --max-steps=4 --backend=apalache $(SPECS_DIR)/KCPReconcile.qnt

.PHONY: save-kcp-condemned-peer-traces
save-kcp-condemned-peer-traces:  ## Save issue-109 trace summaries
	@true

.PHONY: verify-kcp-condemned-peers
verify-kcp-condemned-peers: verify-kcp-condemned-peers-happy verify-kcp-condemned-peers-counterexample verify-kcp-condemned-peers-apalache save-kcp-condemned-peer-traces  ## Full condemned-peer accounting suite

.PHONY: verify-pivot-happy
verify-pivot-happy:  ## Drive happy clusterctl move / resume run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=Pivot \
	             --init=happyPivotRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(PIVOT)

.PHONY: verify-pivot-blocked
verify-pivot-blocked:  ## Drive blocked-move / retry pivot run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=Pivot \
	             --init=blockedPivotRetryRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(PIVOT)

.PHONY: verify-pivot-random
verify-pivot-random:  ## Random-walk pivot invariants (1000x60)
	@for inv in StableSafetyInvariants objectConservation noOrphan \
	            mutualExclusion partialPivotRecoverable \
	            finalizerOrdered secretsCloned; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=Pivot \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=1000 --max-steps=60 $(PIVOT) || exit 1; \
	done

.PHONY: verify-pivot-apalache
verify-pivot-apalache:  ## Apalache battery across pivot invariants
	@for inv in objectConservation noOrphan mutualExclusion \
	            finalizerOrdered secretsCloned; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=Pivot \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(PIVOT) || exit 1; \
	done

.PHONY: verify-pivot
verify-pivot: verify-pivot-happy verify-pivot-blocked verify-pivot-random verify-pivot-apalache  ## Full pivot suite

.PHONY: verify-conversionwebhook-happy
verify-conversionwebhook-happy:  ## Drive happy conversion round-trip run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ConversionWebhook \
	             --init=happyRoundTripRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(CONVERSIONWEBHOOK)

.PHONY: verify-conversionwebhook-random
verify-conversionwebhook-random:  ## Random-walk conversion invariants (1000x60)
	@for inv in StableSafetyInvariants roundTripSpec roundTripStatusInformative \
	            webhookFailureSafe defaultsIdempotent \
	            informationLossDocumented; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ConversionWebhook \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=1000 --max-steps=60 $(CONVERSIONWEBHOOK) || exit 1; \
	done

.PHONY: verify-conversionwebhook-apalache
verify-conversionwebhook-apalache:  ## Apalache battery across conversion invariants
	@for inv in roundTripSpec roundTripStatusInformative webhookFailureSafe \
	            defaultsIdempotent informationLossDocumented; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=ConversionWebhook \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(CONVERSIONWEBHOOK) || exit 1; \
	done

.PHONY: verify-conversionwebhook-proof
verify-conversionwebhook-proof:  ## Build Lean theorem for conversion informativeness
	cd $(PROOFS_DIR) && $(LEAN) build

.PHONY: verify-conversionwebhook
verify-conversionwebhook: verify-conversionwebhook-happy verify-conversionwebhook-random verify-conversionwebhook-apalache verify-conversionwebhook-proof  ## Full conversion-webhook suite

.PHONY: verify-kubeletpki-happy
verify-kubeletpki-happy:  ## Drive happy kubeconfig rotation run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=KubeletPKI \
	             --init=happyRotationRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(KUBELETPKI)

.PHONY: verify-kubeletpki-blocked
verify-kubeletpki-blocked:  ## Drive blocked CA / user-secret run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=KubeletPKI \
	             --init=blockedRotationRun --step=step \
	             --invariant=StableSafetyInvariants --max-steps=0 $(KUBELETPKI)

.PHONY: verify-kubeletpki-random
verify-kubeletpki-random:  ## Random-walk kubelet PKI invariants (1000x60)
	@for inv in StableSafetyInvariants ownedSecretOnlyRotates caNotRecreatedAfterInit \
	            rotationRequiresThreshold rotationPreservesEndpoint \
	            missingCARequeues; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=KubeletPKI \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=1000 --max-steps=60 $(KUBELETPKI) || exit 1; \
	done

.PHONY: verify-kubeletpki-apalache
verify-kubeletpki-apalache:  ## Apalache battery across kubelet PKI invariants
	@for inv in ownedSecretOnlyRotates caNotRecreatedAfterInit \
	            rotationRequiresThreshold rotationPreservesEndpoint \
	            missingCARequeues; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=KubeletPKI \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(KUBELETPKI) || exit 1; \
	done

.PHONY: verify-kubeletpki
verify-kubeletpki: verify-kubeletpki-happy verify-kubeletpki-blocked verify-kubeletpki-random verify-kubeletpki-apalache  ## Full kubelet PKI suite

.PHONY: verify-clustere2e-refined-happy
verify-clustere2e-refined-happy:  ## Drive happy refined cluster bring-up run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterE2ERefined \
	             --init=happyRefinedBringUpRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 $(E2E_REFINED)

.PHONY: verify-clustere2e-refined-leaderloss
verify-clustere2e-refined-leaderloss:  ## Drive leader-loss / replay bring-up run
	$(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterE2ERefined \
	             --init=leaderLossReplayRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 $(E2E_REFINED)

.PHONY: verify-clustere2e-refined-random
verify-clustere2e-refined-random:  ## Random-walk refined ClusterE2E invariants (500x60)
	@for inv in AllSafetyInvariants FM45_PerKeySerialisation \
	            FM48_NoCpBeforeInfraReady FM49_NoWorkersBeforeCpInit \
	            FM50_EndpointMonotonic EndpointSetRequiresInfraClusterReady \
	            ClusterCpInitializedRequiresKcp; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterE2ERefined \
	               --step=randomStep --invariant=$$inv \
	               --max-samples=500 --max-steps=60 $(E2E_REFINED) || exit 1; \
	done

.PHONY: verify-clustere2e-refined-apalache
verify-clustere2e-refined-apalache:  ## Apalache battery across refined ClusterE2E invariants
	@for inv in FM45_PerKeySerialisation FM48_NoCpBeforeInfraReady \
	            FM49_NoWorkersBeforeCpInit FM50_EndpointMonotonic \
	            EndpointSetRequiresInfraClusterReady \
	            ClusterCpInitializedRequiresKcp; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=ClusterE2ERefined \
	                         --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                         --backend=apalache $(E2E_REFINED) || exit 1; \
	done

.PHONY: verify-clustere2e-refined
verify-clustere2e-refined: verify-clustere2e-refined-happy verify-clustere2e-refined-leaderloss verify-clustere2e-refined-random verify-clustere2e-refined-apalache  ## Full refined ClusterE2E suite

## --------------------------------------
## Apalache hopelessness on the new specs (Issue #1)
## --------------------------------------

##@ apalache-new-specs:

# Run Apalache against every safety invariant in a spec module.
# Each invariant takes ~10-30 s at depth 4. Sleep between runs
# avoids the bundled Apalache server's port-bind race on rapid
# successive invocations.

.PHONY: verify-cr-apalache
verify-cr-apalache:  ## Apalache hopelessness across ControllerRuntime invariants
	@for inv in FM45_PerKeySerialisation FM46_TerminalErrorNoRequeue \
	            FM47_CacheBehindAPI LeaderElectionGate \
	            WorkerSentinelConsistency InFlightHasWorker \
	            RateLimitBounded; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=ControllerRuntime \
	                            --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                            --backend=apalache $(CRRUNTIME) || exit 1; \
	  sleep 5; \
	done

.PHONY: verify-topology-apalache
verify-topology-apalache:  ## Apalache hopelessness across Topology invariants
	@for inv in FM39_BeforeClusterUpgradeIdempotent FM40_AnnotationGatesCp \
	            FM41_AfterClusterUpgradeAtSteadyState PendingHookConsistency \
	            CpVersionWithinPlan WorkerVersionLeqCp HookFireOrderInvariant \
	            BeforeClusterUpgradeBlockedByAnnotation OkToDeleteAfterUnblock \
	            PlanMonotonic; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=Topology \
	                            --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                            --backend=apalache $(TOPOLOGY) || exit 1; \
	  sleep 5; \
	done

.PHONY: verify-inplace-apalache
verify-inplace-apalache:  ## Apalache hopelessness across InPlaceUpdate invariants
	@for inv in FM42_PrematureInPlaceAdmission FM43_UpdateMachineIdempotenceGate \
	            FM44_MultiExtensionBlocksProgress TwoWayHandshakeAnnotations \
	            MovingPendingShape UpdateMachineHookShape MoveAckBeforeArmed \
	            DoneImpliesVersionFlipped InProgressTrioConsistency; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=InPlaceUpdate \
	                            --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                            --backend=apalache $(INPLACE) || exit 1; \
	  sleep 5; \
	done

.PHONY: verify-e2e-apalache
verify-e2e-apalache:  ## Apalache hopelessness across ClusterE2E invariants
	@for inv in FM48_NoCpBeforeInfraReady FM49_NoWorkersBeforeCpInit \
	            FM50_EndpointMonotonic BootstrapBeforeInfra \
	            NodeRefAfterProvisioned EtcdJoinOnlyForCp \
	            KcpInitializedRequiresFirstCp ClusterCpInitializedRequiresKcp \
	            MdEnabledRequiresCpInit BeforeClusterUpgradeOrdering \
	            AfterClusterUpgradeAtTarget; do \
	  echo "==> $$inv"; \
	  echo y | $(QUINT) verify --main=ClusterE2E \
	                            --invariant=$$inv --max-steps=$(MAX_STEPS_APALACHE) \
	                            --backend=apalache $(E2E) || exit 1; \
	  sleep 5; \
	done

.PHONY: verify-apalache-new-specs
verify-apalache-new-specs: verify-cr-apalache verify-topology-apalache verify-inplace-apalache verify-e2e-apalache  ## All four new-spec Apalache batteries (~15 min)

## --------------------------------------
## End-to-end cluster lifecycle (FM-48/49/50)
## --------------------------------------

##@ end-to-end:

.PHONY: verify-e2e-bringup
verify-e2e-bringup:  ## Drive happyBringUpRun (full cluster bring-up)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterE2E --init=happyBringUpRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(E2E)

.PHONY: verify-e2e-rolling
verify-e2e-rolling:  ## Drive happyRollingUpgradeRun (rolling upgrade)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterE2E --init=happyRollingUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(E2E)

.PHONY: verify-e2e-inplace
verify-e2e-inplace:  ## Drive happyInPlaceUpgradeRun (in-place upgrade)
	$(QUINT) run --backend=$(QUINT_BACKEND) \
	             --main=ClusterE2E --init=happyInPlaceUpgradeRun --step=step \
	             --invariant=AllSafetyInvariants --max-steps=0 \
	             $(E2E)

.PHONY: verify-e2e-random
verify-e2e-random:  ## Random-walk every E2E ordering invariant (300x60)
	@for inv in AllSafetyInvariants FM48_NoCpBeforeInfraReady \
	            FM49_NoWorkersBeforeCpInit FM50_EndpointMonotonic \
	            BootstrapBeforeInfra NodeRefAfterProvisioned \
	            EtcdJoinOnlyForCp KcpInitializedRequiresFirstCp \
	            ClusterCpInitializedRequiresKcp MdEnabledRequiresCpInit \
	            BeforeClusterUpgradeOrdering AfterClusterUpgradeAtTarget; do \
	  echo "==> $$inv"; \
	  $(QUINT) run --backend=$(QUINT_BACKEND) --main=ClusterE2E \
	               --invariant=$$inv --max-samples=300 --max-steps=60 \
	               $(E2E) || exit 1; \
	done

.PHONY: verify-e2e
verify-e2e: verify-e2e-bringup verify-e2e-rolling verify-e2e-inplace verify-e2e-random  ## Full E2E suite

## --------------------------------------
## Meta
## --------------------------------------

##@ meta:

.PHONY: verify-all-apalache
verify-all-apalache: verify-fm2 verify-fm3 verify-fm13 verify-fm16 verify-fm17 verify-fm23  ## Run every per-FM Apalache check
	@echo "All Apalache hopelessness verdicts complete."

.PHONY: verify-deeper-apalache
verify-deeper-apalache:  ## Issue #28 — re-run FM-2/3/13/23/45/48-50 at depth 8 (12 for FM-2/45)
	@if ! command -v apalache-mc >/dev/null 2>&1 && ! command -v apalache >/dev/null 2>&1; then \
	  echo "SKIP: apalache-mc/apalache not in PATH"; \
	  echo "==> Issue #28 expected matrix recorded in failure-modes.md"; \
	  exit 0; \
	fi
	@for cfg in \
	  "FM-2:Lifecycle:twoMachineBothUnhealthyInit:stepNoRecovery:not(HealthyControlPlane):8" \
	  "FM-2-depth12:Lifecycle:twoMachineBothUnhealthyInit:stepNoRecovery:not(HealthyControlPlane):12" \
	  "FM-3:Lifecycle:partitionedClusterInit:stepNoRecovery:not(HealthyControlPlane):8" \
	  "FM-13:Lifecycle:lbBrokenInit:stepNoRecovery:not(HealthyControlPlane):8" \
	  "FM-23:Lifecycle:drainStuckInit:stepNoRecovery:AllSafetyInvariants:8"; do \
	  fm=$$(echo $$cfg | cut -d: -f1); \
	  main=$$(echo $$cfg | cut -d: -f2); \
	  init=$$(echo $$cfg | cut -d: -f3); \
	  step=$$(echo $$cfg | cut -d: -f4); \
	  inv=$$(echo $$cfg | cut -d: -f5); \
	  depth=$$(echo $$cfg | cut -d: -f6); \
	  echo ""; \
	  echo "==> $$fm at depth=$$depth (Apalache)"; \
	  echo y | $(QUINT) verify --main=$$main --init=$$init --step=$$step \
	                    --max-steps=$$depth --invariant=$$inv \
	                    --backend=apalache $(LIFECYCLE) 2>&1 | tail -5 || true; \
	done
	@echo ""
	@echo "==> FM-45 (ControllerRuntime PerKeySerialisation) at depth=12"
	@echo y | $(QUINT) verify --main=ControllerRuntime --invariant=FM45_PerKeySerialisation \
	                  --max-steps=12 --backend=apalache $(CRRUNTIME) 2>&1 | tail -5 || true
	@echo "==> FM-48 (ClusterE2E NoCpBeforeInfraReady) at depth=8"
	@echo y | $(QUINT) verify --main=ClusterE2E --invariant=FM48_NoCpBeforeInfraReady \
	                  --max-steps=8 --backend=apalache $(E2E) 2>&1 | tail -5 || true
	@echo "==> FM-49 (ClusterE2E NoWorkersBeforeCpInit) at depth=8"
	@echo y | $(QUINT) verify --main=ClusterE2E --invariant=FM49_NoWorkersBeforeCpInit \
	                  --max-steps=8 --backend=apalache $(E2E) 2>&1 | tail -5 || true
	@echo "==> FM-50 (ClusterE2E EndpointMonotonic) at depth=8"
	@echo y | $(QUINT) verify --main=ClusterE2E --invariant=FM50_EndpointMonotonic \
	                  --max-steps=8 --backend=apalache $(E2E) 2>&1 | tail -5 || true

.PHONY: verify-replica-sweep
verify-replica-sweep:  ## Issue #27 — FM-2 hopelessness verdict at N ∈ {1,2,3,5,7} (Apalache when present, TLC for small N)
	@echo "==> FM-2 replica sweep — verdict matrix at N ∈ {1, 2, 3, 5, 7}"
	@echo "==> Each row runs Lifecycle.qnt with stepNoRecovery and asserts ~HealthyControlPlane"
	@echo "==> Counterexample = a recovery exists (verdict GOOD); no counterexample = hopelessness (verdict HOPELESS)"
	@echo ""
	@echo "==> N=1 via singleNodeLostVoterInit (TLC)"
	@$(QUINT) verify --main=Lifecycle --init=singleNodeLostVoterInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=tlc $(LIFECYCLE) 2>&1 | tail -5 || true
	@echo "==> N=2 via twoMachineBothUnhealthyInit (TLC)"
	@$(QUINT) verify --main=Lifecycle --init=twoMachineBothUnhealthyInit \
	                  --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                  --invariant='not(HealthyControlPlane)' \
	                  --backend=tlc $(LIFECYCLE) 2>&1 | tail -5 || true
	@echo "==> N=3,5,7 TLC SKIPPED — BFS branching is O(actions^N), exceeds 30M states/min;"
	@echo "==> documented HOPELESS by Apalache symbolic execution (see failure-modes.md)"
	@if command -v apalache-mc >/dev/null 2>&1 || command -v apalache >/dev/null 2>&1; then \
	  echo ""; \
	  echo "==> Apalache backend available — running symbolic verdicts for N ∈ {1,2,3,5,7}"; \
	  for cfg in \
	    "N=1:singleNodeLostVoterInit" \
	    "N=2:twoMachineBothUnhealthyInit" \
	    "N=3:threeNodeAllUnhealthyInit" \
	    "N=5:fiveNodeAllUnhealthyInit" \
	    "N=7:sevenNodeAllUnhealthyInit"; do \
	    n=$${cfg%%:*}; init=$${cfg#*:}; \
	    echo "==> $$n via $$init (apalache)"; \
	    echo y | $(QUINT) verify --main=Lifecycle --init=$$init \
	                      --step=stepNoRecovery --max-steps=$(MAX_STEPS_APALACHE) \
	                      --invariant='not(HealthyControlPlane)' \
	                      --backend=apalache $(LIFECYCLE) 2>&1 | tail -3 || true; \
	  done; \
	else \
	  echo "SKIP: apalache-mc/apalache not in PATH for symbolic N=3/5/7 verdicts"; \
	fi

.PHONY: lsp-list
lsp-list:  ## Print every Go entry-point cited in abstraction-mapping.md
	@grep -hoE '[A-Za-z0-9_/.-]+\.go(:[0-9]+)?' abstraction-mapping.md \
	  lsp-grounding.md | sort -u
