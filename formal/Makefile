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
SELFHOSTED    := $(SPECS_DIR)/SelfHosted.qnt

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
