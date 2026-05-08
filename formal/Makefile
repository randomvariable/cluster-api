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
# matrix and install hints.

SHELL := /bin/bash

QUINT ?= quint
LEAN  ?= lake
TLC   ?= tlc

SPECS_DIR    := specs
PROOFS_DIR   := proofs
CONTRACTS_DIR := contracts

QUINT_FILES := $(wildcard $(SPECS_DIR)/*.qnt)
TLA_FILES   := $(wildcard $(SPECS_DIR)/*.tla)
TLA_CFGS    := $(patsubst %.tla,%.cfg,$(TLA_FILES))

.PHONY: help typecheck test proofs tlc verify drift clean

help:
	@echo "formal/ targets:"
	@echo "  typecheck   quint typecheck every Quint module"
	@echo "  test        quint run every Quint module that declares runs"
	@echo "  proofs      lake build the Lean 4 project"
	@echo "  tlc         run TLC on every TLA+ module that has a .cfg"
	@echo "  drift       check abstraction-mapping rows resolve"
	@echo "  verify      typecheck + test + proofs + tlc + drift"
	@echo "  clean       remove tool caches"

typecheck:
	@if ! command -v $(QUINT) >/dev/null 2>&1; then \
	  echo "SKIP: quint not in PATH (install: npm install -g @informalsystems/quint)"; \
	  exit 0; \
	fi
	@for f in $(QUINT_FILES); do \
	  echo "==> quint typecheck $$f"; \
	  $(QUINT) typecheck $$f || exit 1; \
	done

test:
	@if ! command -v $(QUINT) >/dev/null 2>&1; then \
	  echo "SKIP: quint not in PATH"; \
	  exit 0; \
	fi
	@for f in $(QUINT_FILES); do \
	  if grep -qE '^[[:space:]]*run[[:space:]]' $$f; then \
	    echo "==> quint run $$f"; \
	    $(QUINT) run --max-samples 200 $$f || exit 1; \
	  fi; \
	done

proofs:
	@if ! command -v $(LEAN) >/dev/null 2>&1; then \
	  echo "SKIP: lake not in PATH (install via elan)"; \
	  exit 0; \
	fi
	cd $(PROOFS_DIR) && $(LEAN) build

tlc:
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

drift:
	@../scripts/verify-formal.sh --drift-only

verify: typecheck test tlc proofs drift

clean:
	rm -rf $(PROOFS_DIR)/.lake $(PROOFS_DIR)/build
