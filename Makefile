# Acme Co. OSRAMP demo: one-shot local environment.
#
# Prerequisites: docker, kind, kubectl, kustomize, flux, helm, cosign, jq,
# bats (tests), syft/grype/govulncheck/vexctl/witness (VEX demo). On Windows,
# run from WSL2 or Git Bash.
#
# `make up` builds the whole demo: kind cluster, in-cluster zot registry,
# signed OCI artifacts, Flux bootstrap, app images, then waits for the
# GitOps reconciliation to converge.

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

CLUSTER_NAME ?= osramp
KEYS_DIR := .keys
SIGNALLOOM_PLATFORM_ROOT ?= /home/andy/src/cp/platform
OSRAMP_PRODUCT_ROOT ?= /home/andy/src/cp/osramp
OSRAMP_DEMO_ROOT ?= /home/andy/src/cp/osramp-demo
D2_BAO_ROOT ?= /home/andy/src/cp/d2-bao-apps
SIGNALLOOM_INTEGRATION_BRANCH ?= plan/d2-bao-integration
ZOT_CACHE_DIR ?= .cache/zot

.PHONY: up
up: cluster registry signing-keys push-local bootstrap-local images workload-key wait olly-pdi-secret olly-llm-secret orbit-approval-configmap security-sandbox ## Build the full local demo environment.

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Signal Loom preflight

.PHONY: signalloom-check
signalloom-check: ## Validate Signal Loom, OSRAMP, demo, and D2-BAO source roots.
	./scripts/signalloom-preflight.sh check "$(SIGNALLOOM_PLATFORM_ROOT)" "$(OSRAMP_PRODUCT_ROOT)" "$(OSRAMP_DEMO_ROOT)" "$(D2_BAO_ROOT)"

.PHONY: signalloom-help
signalloom-help: ## Show Signal Loom roots and the safe pre-deployment command sequence.
	./scripts/signalloom-preflight.sh help "$(SIGNALLOOM_PLATFORM_ROOT)" "$(OSRAMP_PRODUCT_ROOT)" "$(OSRAMP_DEMO_ROOT)" "$(D2_BAO_ROOT)" "$(SIGNALLOOM_INTEGRATION_BRANCH)"

##@ Cluster lifecycle

.PHONY: cluster
cluster: ## Create the Kind cluster with a persistent host-backed Zot cache.
	CLUSTER_NAME="$(CLUSTER_NAME)" ZOT_CACHE_DIR="$(ZOT_CACHE_DIR)" ./scripts/create-kind-cluster.sh

.PHONY: down
down: ## Delete the kind cluster.
	-kind delete cluster --name $(CLUSTER_NAME)

.PHONY: teardown
teardown: ## Tear down the environment: delete the cluster + local build state.
	./scripts/teardown.sh

.PHONY: teardown-all
teardown-all: ## Tear down everything, including the tools setup.sh installed.
	./scripts/teardown.sh --all

.PHONY: zot-cache-reset
zot-cache-reset: ## Remove persisted local Zot OCI data; the next `make up` repopulates it.
	rm -rf "$(ZOT_CACHE_DIR)"

.PHONY: registry
registry: ## Deploy the in-cluster zot registry.
	$(MAKE) -C d2-osramp-fleet zot-up

##@ Supply chain

.PHONY: signing-keys
signing-keys: ## Generate the local cosign and witness keys.
	@mkdir -p $(KEYS_DIR)
	@if [ ! -f $(KEYS_DIR)/cosign.key ]; then \
		cd $(KEYS_DIR) && COSIGN_PASSWORD="" cosign generate-key-pair; \
	fi
	@if [ ! -f $(KEYS_DIR)/witness.pem ]; then \
		openssl genpkey -algorithm ed25519 -out $(KEYS_DIR)/witness.pem; \
		openssl pkey -in $(KEYS_DIR)/witness.pem -pubout -out $(KEYS_DIR)/witness-pub.pem; \
	fi
	@# Orbit approval keypair: the broker holds the PRIVATE half to mint
	@# approval JWTs; the sentinel gets only the PUBLIC half and can verify but
	@# never sign, so the agent process cannot forge its own approval.
	@if [ ! -f $(KEYS_DIR)/orbit-approval.pem ]; then \
		openssl genpkey -algorithm ed25519 -out $(KEYS_DIR)/orbit-approval.pem; \
		openssl pkey -in $(KEYS_DIR)/orbit-approval.pem -pubout -out $(KEYS_DIR)/orbit-approval-pub.pem; \
	fi

.PHONY: push-local
push-local: ## Push signed manifest artifacts to the in-cluster registry.
	./scripts/push-local.sh

.PHONY: bootstrap-local
bootstrap-local: ## Bootstrap Flux syncing from the in-cluster registry.
	$(MAKE) -C d2-osramp-fleet bootstrap-local COSIGN_PUB=../$(KEYS_DIR)/cosign.pub

.PHONY: images
images: ## Build the app and olly-replica images and load them into kind.
	$(MAKE) -C d2-osramp-apps build
	$(MAKE) -C olly-replica build

.PHONY: workload-key
workload-key: ## Generate the ed25519 key the processor signs attestations with.
	@for i in $$(seq 1 60); do \
		kubectl get ns frontend >/dev/null 2>&1 && break; \
		echo "waiting for the frontend namespace (created by the apps ResourceSet)..."; \
		sleep 5; \
	done
	kubectl get ns frontend >/dev/null
	$(MAKE) -C d2-osramp-apps signing-key

.PHONY: wait
wait: ## Wait for the GitOps reconciliation to converge.
	./scripts/wait-reconciled.sh

.PHONY: olly-pdi-secret
olly-pdi-secret: ## Create the ServiceNow PDI secret from .env (no-op without one).
	./scripts/olly-pdi-secret.sh

.PHONY: olly-llm-secret
olly-llm-secret: ## Create the Olly LLM secret from .env (no-op without one).
	./scripts/olly-llm-secret.sh

.PHONY: security-sandbox
security-sandbox: ## Apply the Security Sandbox toggle from .env (SECURITY_SANDBOX_ENABLED; off by default).
	./scripts/security-sandbox.sh

.PHONY: orbit-approval-configmap
orbit-approval-configmap: signing-keys ## Publish the PUBLIC orbit approval key into the cluster (private half stays local).
	@kubectl -n olly-replica create configmap orbit-approval-pub \
		--from-file=orbit-approval-pub.pem=$(KEYS_DIR)/orbit-approval-pub.pem \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "orbit approval PUBLIC key published; the private half never leaves $(KEYS_DIR)"

##@ Demos and tests

.PHONY: test
test: ## Run the end-to-end bats suite against the running cluster.
	$(MAKE) -C d2-osramp-apps test

.PHONY: test-zot-cache
test-zot-cache: ## Verify the Kind/Zot persistent-cache configuration without a cluster.
	bats test/zot-cache.bats

.PHONY: attested-test
attested-test: ## Run the test suite under witness, storing evidence in Archivista.
	./scripts/attested-test.sh

.PHONY: olly-test
olly-test: ## Run the olly-replica bats suite (enrichment loop end to end).
	$(MAKE) -C olly-replica test

.PHONY: a2a-demo
a2a-demo: ## Fire one Olly -> Orbit A2A hand-off for the dashboard demo (APP=payments-api).
	$(MAKE) -C olly-replica a2a-demo APP="$(APP)"

.PHONY: olly-eval
olly-eval: ## Run the sentinel ADK eval offline (signal-check gate + rca_readiness).
	./scripts/olly-eval.sh

.PHONY: olly-adk-web
olly-adk-web: ## Launch `adk web` for the sentinel (ADK Studio: Trace + Eval tabs).
	./scripts/olly-adk-web.sh

.PHONY: vex-demo
vex-demo: ## Run the Phase 1 VEX triage demo (scan, triage, rescan green).
	./scripts/vex-demo.sh

.PHONY: witness-policy
witness-policy: ## Generate and sign the witness promotion policy.
	./scripts/gen-witness-policy.sh

.PHONY: promotion-demo
promotion-demo: ## Gate promotion on the witness policy: one approved, one rejected.
	./scripts/promotion-demo.sh

.PHONY: admission-demo
admission-demo: ## Kyverno admission: signed image admitted, unsigned denied.
	./scripts/admission-demo.sh

.PHONY: revocation-demo
revocation-demo: ## Revoke trust in an artifact, watch Flux block it, restore.
	./scripts/revocation-demo.sh

.PHONY: agent-demo
agent-demo: ## Sandboxed agent analyzes a CVE and recommends (human gate stops it).
	./agent/harness.sh

.PHONY: console
console: ## Serve the Estate 95 win95 console (whole demo) at http://localhost:8675.
	@KCFG=$$(./scripts/olly-readonly-kubeconfig.sh 2>/dev/null || true); \
	 cd tools/demo-console && CONSOLE_READONLY_KUBECONFIG="$$KCFG" go run .

.PHONY: readonly-kubeconfig
readonly-kubeconfig: ## Create the scoped read-only kubeconfig the terminal uses.
	./scripts/olly-readonly-kubeconfig.sh
