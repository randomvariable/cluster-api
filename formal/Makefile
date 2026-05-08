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

# typescript backend is needed for Lifecycle.qnt — the rust
# evaluator hits a recursion limit on the per-action
# ConvergenceFair temporal expression (Phase 11b).
QUINT_BACKEND ?= typescript

#
# Verification depths.
#
MAX_STEPS_TLC      ?= 8
MAX_STEPS_APALACHE ?= 4

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
TOPO_REFINED  := $(SPECS_DIR)/TopologyRefined.qnt
INPLACE_REFINED := $(SPECS_DIR)/InPlaceUpdateRefined.qnt
MSPREFLIGHT_REFINED := $(SPECS_DIR)/MachineSetPreflightRefined.qnt
E2E           := $(SPECS_DIR)/ClusterE2E.qnt

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

.PHONY: verify-cr
verify-cr: verify-cr-happy verify-cr-multiworker verify-cr-dedup verify-cr-requeue verify-cr-terminal verify-cr-leader-loss verify-cr-random  ## Full controller-runtime substrate suite

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

.PHONY: lsp-list
lsp-list:  ## Print every Go entry-point cited in abstraction-mapping.md
	@grep -hoE '[A-Za-z0-9_/.-]+\.go(:[0-9]+)?' abstraction-mapping.md \
	  lsp-grounding.md | sort -u
