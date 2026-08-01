# Acme Co. OSRAMP demo: one-shot local environment.
#
# Prerequisites: docker, kind, kubectl, kustomize, flux, helm, cosign, jq,
# bats (tests), syft/grype/govulncheck/vexctl/witness (VEX demo). On Windows,
# run from WSL2 or Git Bash.
#
# `make up` creates only the shared cluster foundation. It does not start a
# demo; run one of the advertised `demo-*-up` targets after it is healthy.

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

CLUSTER_NAME ?= osramp
KEYS_DIR := .keys
SIGNALLOOM_PLATFORM_ROOT ?= /home/andy/src/cp/platform
OSRAMP_PRODUCT_ROOT ?= /home/andy/src/cp/osramp
OSRAMP_DEMO_ROOT ?= /home/andy/src/cp/osramp-demo
D2_BAO_ROOT ?= /home/andy/src/cp/d2-bao-apps
SIGNALLOOM_INTEGRATION_BRANCH ?= integration/signalloom-d2-v2.5.0
CPAI_CLI_ROOT ?= /home/andy/src/cp/cpai-cli
ZOT_CACHE_DIR ?= .cache/zot

.PHONY: up
up: ## Create the shared cluster foundation and advertise opt-in demos.
	$(MAKE) cluster
	$(MAKE) registry
	$(MAKE) signing-keys
	$(MAKE) push-local-foundation
	$(MAKE) bootstrap-local
	$(MAKE) wait
	$(MAKE) healthcheck
	$(MAKE) demo-help

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Signal Loom preflight

.PHONY: signalloom-check
signalloom-check: signalloom-contract-check ## Validate the delivery contract and Signal Loom source roots before deployment.
	./scripts/signalloom-preflight.sh check "$(SIGNALLOOM_PLATFORM_ROOT)" "$(OSRAMP_PRODUCT_ROOT)" "$(OSRAMP_DEMO_ROOT)" "$(D2_BAO_ROOT)"

.PHONY: signalloom-contract-check
signalloom-contract-check: signalloom-security-release-pack-check ## Statically validate delivery branch, repository, and delivery evidence guard.
	./scripts/signalloom-contract-check.sh "docs/signalloom/delivery-contract.json" "$(SIGNALLOOM_INTEGRATION_BRANCH)"

.PHONY: signalloom-security-release-pack-check
signalloom-security-release-pack-check: ## Statically validate the security release-pack template.
	./scripts/signalloom-security-release-pack-check.sh "docs/signalloom/security-release-pack.md"

.PHONY: signalloom-help
signalloom-help: ## Show Signal Loom roots and the safe pre-deployment command sequence.
	./scripts/signalloom-preflight.sh help "$(SIGNALLOOM_PLATFORM_ROOT)" "$(OSRAMP_PRODUCT_ROOT)" "$(OSRAMP_DEMO_ROOT)" "$(D2_BAO_ROOT)" "$(SIGNALLOOM_INTEGRATION_BRANCH)"

.PHONY: test-demo-signalloom-lifecycle test-signalloom-security-validation-evidence
test-demo-signalloom-lifecycle: ## Test the deterministic local Signal Loom lifecycle with fake kubectl/Flux clients.
	bats test/signalloom-local-lifecycle.bats

test-signalloom-security-validation-evidence: ## Verify Signal Loom fail-closed security validation evidence.
	bats test/signalloom-security-validation-evidence.bats

##@ Cluster lifecycle

.PHONY: cluster
cluster: ## Create the Kind cluster with a persistent host-backed Zot cache.
	CLUSTER_NAME="$(CLUSTER_NAME)" ZOT_CACHE_DIR="$(ZOT_CACHE_DIR)" ./scripts/create-kind-cluster.sh

.PHONY: cluster-up
cluster-up: cluster ## Phase 2 alias: create the shared Kind cluster.

.PHONY: down
down: ## Delete the kind cluster.
	-kind delete cluster --name $(CLUSTER_NAME)

.PHONY: cluster-down
cluster-down: down ## Phase 2 alias: delete the shared Kind cluster.

.PHONY: cluster-debug
cluster-debug: ## Dump all cluster errors, unhealthy pods, Flux failures, and resource state.
	./scripts/cluster-debug.sh

.PHONY: teardown
teardown: ## Tear down the environment: delete the cluster + local build state.
	./scripts/teardown.sh

.PHONY: teardown-all
teardown-all: ## Tear down everything, including the tools setup.sh installed.
	./scripts/teardown.sh --all

.PHONY: zot-cache-reset
zot-cache-reset: ## Remove persisted local Zot OCI data; the next `make up` repopulates it.
	CLUSTER_NAME="$(CLUSTER_NAME)" ZOT_CACHE_DIR="$(ZOT_CACHE_DIR)" ./scripts/zot-cache-reset.sh

.PHONY: registry
registry: ## Deploy the in-cluster zot registry.
	$(MAKE) -C d2-osramp-fleet zot-up

.PHONY: wait-lib-sync
WAIT_LIB_SOURCE ?= $(HOME)/.andy_sync/includes/wait.sh
wait-lib-sync: ## Re-vendor scripts/lib/wait.sh from the ~/.andy_sync source of truth.
	@test -f "$(WAIT_LIB_SOURCE)" || { echo "source of truth not found: $(WAIT_LIB_SOURCE)" >&2; exit 1; }
	@{ \
	  printf '%s\n' \
	    '# shellcheck shell=bash' \
	    '# wait.sh — VENDORED COPY, DO NOT EDIT HERE.' \
	    '# Source of truth: ~/.andy_sync/includes/wait.sh   Re-vendor: make wait-lib-sync' \
	    '#'; \
	  tail -n +2 "$(WAIT_LIB_SOURCE)"; \
	} > scripts/lib/wait.sh
	@echo "re-vendored scripts/lib/wait.sh from $(WAIT_LIB_SOURCE)"

##@ Supply chain

.PHONY: signing-keys
signing-keys: ## Generate the local cosign and witness keys.
	@mkdir -p $(KEYS_DIR)
	@if [ ! -f $(KEYS_DIR)/cosign.key ]; then \
		cd $(KEYS_DIR) && COSIGN_PASSWORD="" cosign generate-key-pair; \
	fi
	@# No-transparency-log signing config (cosign v3) — the non-deprecated
	@# replacement for --tlog-upload=false. Empty rekor/tsa services keep signing
	@# key-only with no tlog upload, so no Rekor contact and no deprecation warning.
	@if [ ! -f $(KEYS_DIR)/signing-config.json ]; then \
		cosign signing-config create \
			--no-default-rekor --no-default-fulcio --no-default-oidc --no-default-tsa \
			--out $(KEYS_DIR)/signing-config.json; \
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

.PHONY: push-local-foundation
push-local-foundation: ## Push only the fleet and shared infrastructure artifacts.
	./scripts/push-local.sh foundation

.PHONY: push-local-signalloom
push-local-signalloom: ## Push Signal Loom artifacts for the explicit demo lifecycle.
	./scripts/push-local.sh signalloom

.PHONY: bootstrap-local
bootstrap-local: ## Bootstrap Flux syncing from the in-cluster registry.
	$(MAKE) -C d2-osramp-fleet bootstrap-local COSIGN_PUB=../$(KEYS_DIR)/cosign.pub

.PHONY: flux-bootstrap
flux-bootstrap: bootstrap-local ## Phase 2 alias: bootstrap the sole Flux control plane.

.PHONY: flux-test
flux-test: ## Verify Flux readiness, including the Signalloom ResourceSets.
	./scripts/demo-lifecycle.sh flux-test

.PHONY: images
images: ## Build the app and olly-replica images and persist them in Zot.
	$(MAKE) -C d2-osramp-apps build
	$(MAKE) -C olly-replica build

.PHONY: signalloom-spire-helper
signalloom-spire-helper: ## Build and load the disposable SPIRE proof helper into Kind.
	docker build -f d2-signalloom/proof-helper.Dockerfile -t signalloom-spire-helper:local d2-signalloom
	kind load docker-image --name $(CLUSTER_NAME) signalloom-spire-helper:local

.PHONY: signalloom-dashboard-image
signalloom-dashboard-image: ## Build, sign, and load the dashboard workload image.
	./scripts/build-sign-dashboard.sh

.PHONY: preload-foundation-images preload-snapshot
preload-foundation-images: ## kind-load foundation base images already in host Docker (parallel); missing ones fall back to the pull-through mirror.
	@echo "==> Preloading foundation base images present in host Docker (parallel)"
	@images=$$(grep -vE '^[[:space:]]*#|^[[:space:]]*$$' scripts/foundation-images.txt); \
	for img in $$images; do \
		if docker image inspect "$$img" >/dev/null 2>&1; then \
			( kind load docker-image --name $(CLUSTER_NAME) "$$img" >/dev/null 2>&1 \
				&& echo "  loaded $$img" || echo "  FAILED $$img" ) & \
		else \
			echo "  skip (not in host docker, will use mirror) $$img"; \
		fi; \
	done; \
	wait
preload-snapshot: ## Print the cluster's current upstream base images (redirect into scripts/foundation-images.txt to refresh).
	@kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
		| grep -vE 'zot.registry.svc.cluster.local|acme/images' | sed 's/@sha256:.*//' | sort -u

.PHONY: signalloom-images
signalloom-images: ## Build and persist local Signal Loom workload images in Zot.
	kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 & \
	PORT_FORWARD_PID=$$!; \
	IMAGE_TAR=$$(mktemp); \
	trap 'kill $$PORT_FORWARD_PID 2>/dev/null || true; rm -f "$$IMAGE_TAR"' EXIT; \
	for _ in $$(seq 1 60); do \
		curl -fsS http://localhost:5001/v2/ >/dev/null 2>&1 && break; \
		sleep 0.5; \
	done; \
	curl -fsS http://localhost:5001/v2/ >/dev/null; \
	# Build the two plain workload images in parallel (the dominant cost). The \
	# dashboard build+sign and all registry pushes stay sequential to avoid \
	# racing on the single zot port-forward. \
	docker build -t zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest d2-signalloom/apps/fe-signalloom & FE_PID=$$!; \
	docker build -t fake-integration-proxy:dev d2-signalloom/apps/fake-integration-proxy & FP_PID=$$!; \
	BUILD_FAIL=0; wait $$FE_PID || BUILD_FAIL=1; wait $$FP_PID || BUILD_FAIL=1; \
	[ $$BUILD_FAIL -eq 0 ] || { echo "signalloom parallel image build failed" >&2; exit 1; }; \
	kind load docker-image --name $(CLUSTER_NAME) zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest; \
	docker save -o "$$IMAGE_TAR" zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest; \
	crane push --insecure "$$IMAGE_TAR" localhost:5001/acme/images/signalloom/apps/fe-signalloom:latest; \
	# dashboard image repository literal: signalloom/apps/dashboard-signalloom:latest \
	# dashboard build context literal: d2-signalloom/apps/dashboard-signalloom \
	# dashboard kind load literal: kind load docker-image --name $(CLUSTER_NAME) zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest \
	./scripts/build-sign-dashboard.sh; \
	kind load docker-image --name $(CLUSTER_NAME) fake-integration-proxy:dev

.PHONY: cpai-images
cpai-images: ## Build CPAI runtime image from cpai-cli, push to Zot, and cosign sign.
	kubectl -n registry port-forward svc/zot 5001:5000 >/dev/null 2>&1 & \
	PORT_FORWARD_PID=$$!; \
	IMAGE_TAR=$$(mktemp); \
	trap 'kill $$PORT_FORWARD_PID 2>/dev/null || true; rm -f "$$IMAGE_TAR"' EXIT; \
	for _ in $$(seq 1 60); do \
		curl -fsS http://localhost:5001/v2/ >/dev/null 2>&1 && break; \
		sleep 0.5; \
	done; \
	curl -fsS http://localhost:5001/v2/ >/dev/null; \
	docker build -f $(CPAI_CLI_ROOT)/Dockerfile.runtime \
		-t zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest \
		$(CPAI_CLI_ROOT); \
	kind load docker-image --name $(CLUSTER_NAME) \
		zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest; \
	docker save -o "$$IMAGE_TAR" \
		zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest; \
	crane push --insecure "$$IMAGE_TAR" \
		localhost:5001/acme/images/cpai/apps/cpai-runtime:latest; \
	DIGEST=$$(crane digest --insecure \
		localhost:5001/acme/images/cpai/apps/cpai-runtime:latest); \
	COSIGN_PASSWORD="" cosign sign --yes \
		--key $(KEYS_DIR)/cosign.key \
		--signing-config $(KEYS_DIR)/signing-config.json \
		--allow-insecure-registry \
		--registry-referrers-mode=legacy \
		"localhost:5001/acme/images/cpai/apps/cpai-runtime@$${DIGEST}"

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
wait: ## Wait for shared infrastructure reconciliation to converge.
	./scripts/wait-reconciled.sh

.PHONY: healthcheck
healthcheck: ## Verify the shared cluster foundation is ready for demos.
	./scripts/healthcheck.sh

.PHONY: demo-help
demo-help: ## Show demos available after the shared cluster becomes healthy.
	@printf '\nCluster foundation is ready. No demos are running.\n\nNext: choose one demo to start:\n  make demo-signalloom-up\n  make demo-osramp-up\n  make demo-olly-up\n  make demo-bao-up\n  make demo-cpai-up\n\n'

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

##@ Composable demo lifecycle

.PHONY: demo-bao-up demo-bao-test-config demo-bao-test demo-bao-down
demo-bao-up: ## Reconcile and wait for only the bounded OpenBao/SPIRE slice.
	./scripts/demo-lifecycle.sh bao-up
demo-bao-test-config: ## Render and statically validate the bounded Bao/SPIRE proof.
	$(MAKE) -C d2-signalloom bao-test-config
demo-bao-test: demo-bao-test-config ## Run bounded positive and negative Bao/SPIRE proof.
	./scripts/demo-lifecycle.sh bao-test
demo-bao-down: ## Prune only the Bao slice; keep the shared Kind cluster.
	./scripts/demo-lifecycle.sh bao-down

.PHONY: demo-signalloom-up demo-signalloom-test-config demo-signalloom-test demo-signalloom-runtime-test demo-signalloom-test-1 demo-signalloom-down
demo-signalloom-up: healthcheck ## Start the explicit Signal Loom demo lifecycle.
	$(MAKE) push-local-signalloom
	$(MAKE) signalloom-spire-helper
	$(MAKE) signalloom-images
	SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
demo-signalloom-test-config: ## Render and validate Signalloom configuration without a cluster.
	$(MAKE) -C d2-signalloom test
demo-signalloom-test: demo-signalloom-test-config ## Verify focused Signal Loom Flux readiness.
	./scripts/signalloom-local.sh verify
demo-signalloom-runtime-test: demo-signalloom-test ## Run focused BATS/DETIK assertions against the local Signal Loom slice.
	bats d2-signalloom/test/runtime.bats
	@if command -v netassert >/dev/null 2>&1; then $(MAKE) -C d2-signalloom test-netassert; else echo "netassert not installed — skipping NetworkPolicy tests"; fi
demo-signalloom-test-1: ## Run the complete TEST-1 Playwright, BATS, and pytest integration gate.
	DEX_DEMO_PASSWORD="$${DEX_DEMO_PASSWORD:-demo-user}" ./scripts/signalloom-test-1.sh
demo-signalloom-down: ## Remove Signal Loom frontend via shared ResourceSet cleanup.
	./scripts/signalloom-down.sh
	./scripts/signalloom-runtime-test.sh

.PHONY: demo-signalloom-agents-up demo-signalloom-agents-down demo-signalloom-agents-list
demo-signalloom-agents-up: ## Recreate the demo agent cohort (random Monty Python names; AGENTS=N, default 4).
	N="$(AGENTS)"; ./scripts/signalloom-agents.sh up "$${N:-4}"
demo-signalloom-agents-down: ## Delete the ephemeral demo agent cohort (keeps the Flux baseline agent).
	./scripts/signalloom-agents.sh down
demo-signalloom-agents-list: ## List agents currently in the fe-signalloom-agents namespace.
	./scripts/signalloom-agents.sh list

##@ Live demo population (all agents + mock data in one shot)

.PHONY: demo-signalloom-demo-up
demo-signalloom-demo-up: ## Populate ALL demo data: every Monty Python agent + mock Postgres data.
	./scripts/signalloom-agents.sh up all
	./scripts/signalloom-data.sh mock

##@ Signal Loom data lifecycle (three UI states: demo-toggle / live-empty / mock-populated)

.PHONY: demo-signalloom-data-reset demo-signalloom-data-mock demo-signalloom-api-test
demo-signalloom-data-reset: ## Reset data stores to empty defaults (live mode = empty UI). Optional: SERVICE=agents|audit|...
	./scripts/signalloom-data.sh reset $(SERVICE)
demo-signalloom-data-mock: ## Populate data stores with realistic demo data (mock mode = populated UI).
	./scripts/signalloom-data.sh mock
demo-signalloom-api-test: ## Run the consumer-driven contract + integration test suite.
	./scripts/signalloom-api-test.sh $${TIER:-contract}

##@ SuperCred demo — agent identity chain, compliance scan, stun
##  Each numbered step has a preflight check. Run in order: 1 → 2 → 3 → 4 → 5.

.PHONY: demo-signalloom-supercred-images
demo-signalloom-supercred-images: ## Build cardvault, policy-engine, cardvault-agent images + load into kind.
	docker build -t cardvault:local d2-signalloom/apps/cardvault
	docker build -t policy-engine:local d2-signalloom/apps/policy-engine
	docker build -t cardvault-agent:local d2-signalloom/apps/cardvault-agent
	kind load docker-image --name $(CLUSTER_NAME) cardvault:local policy-engine:local cardvault-agent:local

.PHONY: demo-signalloom-supercred-1
demo-signalloom-supercred-1: demo-signalloom-supercred-images ## Step 1: Deploy services, agent, OpenBao secrets, SPIRE entry.
	./scripts/supercred-demo.sh 1

.PHONY: demo-signalloom-supercred-2
demo-signalloom-supercred-2: demo-signalloom-supercred-images ## Step 2: Run SPIFFE → OpenBao → cardvault credential chain.
	./scripts/supercred-demo.sh 2

.PHONY: demo-signalloom-supercred-3
demo-signalloom-supercred-3: ## Step 3: Compliance scan — discovers missing securityContext.
	./scripts/supercred-demo.sh 3

.PHONY: demo-signalloom-supercred-4
demo-signalloom-supercred-4: demo-signalloom-supercred-images ## Step 4: Stun — revoke credentials, verify denial.
	./scripts/supercred-demo.sh 4

.PHONY: demo-signalloom-supercred-5
demo-signalloom-supercred-5: ## Step 5: Teardown + verify clean.
	./scripts/supercred-demo.sh 5

.PHONY: demo-signalloom-supercred-all
demo-signalloom-supercred-all: demo-signalloom-supercred-images ## Run full SuperCred demo (steps 1→5).
	./scripts/supercred-demo.sh all

.PHONY: demo-osramp-up demo-osramp-test-config demo-osramp-test demo-osramp-down
demo-osramp-up: ## Restore OSRAMP frontend+backend (durable: restores ResourceSet inputs).
	./scripts/osramp-up.sh
demo-osramp-test-config: ## Validate existing OSRAMP manifests without a running slice.
	kubectl kustomize d2-osramp-apps/components >/dev/null
demo-osramp-test: demo-osramp-test-config ## Run existing OSRAMP acceptance tests.
	$(MAKE) test
demo-osramp-down: ## Remove OSRAMP frontend+backend via shared ResourceSet cleanup.
	./scripts/osramp-down.sh

.PHONY: demo-olly-up demo-olly-test-config demo-olly-test demo-olly-down
demo-olly-up: ## Restore Olly Sentinel replica (durable: restores ResourceSet inputs).
	./scripts/olly-up.sh
demo-olly-test-config: ## Render the Olly component configuration without a running slice.
	kubectl kustomize olly-replica/components >/dev/null
demo-olly-test: demo-olly-test-config ## Run existing Olly acceptance tests.
	$(MAKE) olly-test
demo-olly-down: ## Remove Olly Sentinel replica via shared ResourceSet cleanup.
	./scripts/olly-down.sh

##@ KubeSec-AFM (D2 — standalone RBAC analysis platform)

.PHONY: demo-k8s-afm-up demo-k8s-afm-down demo-k8s-afm-test demo-k8s-afm-status
demo-k8s-afm-up: ## Build + deploy KubeSec-AFM platform (RBAC analysis + Z3 + Next.js dashboard).
	./scripts/k8s-afm.sh up
demo-k8s-afm-down: ## Remove the KubeSec-AFM D2 slice.
	./scripts/k8s-afm.sh down
demo-k8s-afm-test: ## Run the AFM backend pytest suite from source.
	./scripts/k8s-afm.sh test
demo-k8s-afm-status: ## Show AFM pods + /health.
	./scripts/k8s-afm.sh status

.PHONY: cpai-foundation cpai-only demo-cpai-up demo-cpai-test-config demo-cpai-test demo-cpai-down
cpai-foundation: ## Minimal foundation for CPAI only: kind cluster + Zot + cosign keys (no Flux/cert-manager/ingress/monitoring/trivy).
	$(MAKE) cluster
	$(MAKE) registry
	$(MAKE) signing-keys
cpai-only: cpai-foundation ## Fast path: stand up ONLY the CPAI demo on a minimal foundation, skipping the full shared foundation.
	$(MAKE) cpai-images
	./scripts/cpai-up.sh
	@printf '\nCPAI runtime is up (fast path). Test with:\n  make demo-cpai-test\n  make demo-cpai-conversation\n\n'
demo-cpai-up: healthcheck ## Build CPAI runtime image, push to Zot, and deploy to cpai namespace.
	$(MAKE) cpai-images
	./scripts/cpai-up.sh
demo-cpai-test-config: ## Render and validate CPAI Kustomize overlays without a cluster.
	$(MAKE) -C d2-cpai test
demo-cpai-test: demo-cpai-test-config ## Run CPAI runtime smoke tests against the running cluster.
	bats d2-cpai/test/cpai-runtime.bats
demo-cpai-conversation: ## Run 3-turn aichat conversation e2e test against the CPAI runtime.
	bats d2-cpai/test/conversation.bats
demo-cpai-down: ## Remove the CPAI runtime demo namespace.
	./scripts/cpai-down.sh

.PHONY: demo-signalloom-stack-up demo-signalloom-stack-down demo-signalloom-stack-purge demo-signalloom-stack-purge-force
demo-signalloom-stack-up: demo-signalloom-up demo-signalloom-test ## Compatibility composition; demo-signalloom-up owns the Phase 1 dependency order.
demo-signalloom-stack-down: demo-signalloom-down ## Remove Signalloom only; never remove shared Bao.
demo-signalloom-stack-purge: demo-signalloom-stack-down ## Remove Bao only after an authoritative empty consumer query.
	./scripts/demo-lifecycle.sh stack-purge
demo-signalloom-stack-purge-force: demo-signalloom-stack-down ## Explicitly override unknown or remaining consumer state.
	DEMO_BAO_FORCE=1 ./scripts/demo-lifecycle.sh stack-purge

.PHONY: test-zot-cache
test-zot-cache: ## Verify the Kind/Zot persistent-cache configuration without a cluster.
	bats test/zot-cache.bats

.PHONY: test-demo-lifecycle
test-demo-lifecycle: ## Validate composable lifecycle aliases and fail-closed purge semantics.
	bats test/demo-lifecycle.bats

.PHONY: test-bao-spire-proof-harness
test-bao-spire-proof-harness: ## Verify positive and negative Bao/SPIRE runtime-proof assertions with a local fake kubectl.
	bats test/bao-spire-proof.bats

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

.PHONY: doctor
doctor: cluster-debug ## Alias for the comprehensive cluster diagnostic report.

.PHONY: olly-down
olly-down: ## Remove Olly Sentinel replica via shared ResourceSet cleanup.
	./scripts/olly-down.sh

.PHONY: olly-up
olly-up: ## Restore Olly Sentinel replica to the cluster.
	./scripts/olly-up.sh

.PHONY: osramp-down
osramp-down: ## Remove OSRAMP apps via shared ResourceSet cleanup.
	./scripts/osramp-down.sh

.PHONY: osramp-up
osramp-up: ## Restore OSRAMP apps (frontend + backend) to the cluster.
	./scripts/osramp-up.sh

.PHONY: signalloom-down
signalloom-down: ## Remove Signal Loom frontend via shared ResourceSet cleanup.
	./scripts/signalloom-down.sh

.PHONY: signalloom-up
signalloom-up: ## Restore Signal Loom frontend to the cluster.
	./scripts/signalloom-up.sh

.PHONY: acceptance-test
acceptance-test: ## Run browser-driven acceptance tests (Playwright).
	./scripts/acceptance-test.sh

##@ CI

CI_2_ENV = GCP_CI_VM_NAME=signalloom-ci-2 GCP_CI_LABELS=purpose=signalloom-ci-2,worker=signalloom-ci-2,persistent=true GCP_CI_REMOTE_WORK_DIR=/home/ci/osramp-demo-ci-2 GCP_CI_REMOTE_REPORT_DIR=/home/ci/reports-signalloom-ci-2 GCP_CI_REPORT_DIR=ci-reports-2 GCP_CI_REPORT_FILENAME=signalloom-ci-2-report.yaml GCP_CI_PIPELINE_LOG=/home/ci/ci-pipeline-ci-2.log

.PHONY: ci-provision
ci-provision: ## One-time: create the persistent GCP CI VM + networking.
	./scripts/ci/gcp-ci.sh provision

.PHONY: ci-gcp
ci-gcp: ## Resume the CI VM, run Signalloom D2 e2e, suspend on pass.
	./scripts/ci/gcp-ci.sh run

.PHONY: ci-provision-2
ci-provision-2: ## One-time: create the isolated second GCP CI VM.
	$(CI_2_ENV) ./scripts/ci/gcp-ci.sh provision

.PHONY: ci-gcp-2
ci-gcp-2: ## Sync local tree to VM2, run Signalloom D2 e2e, suspend on pass.
	$(CI_2_ENV) ./scripts/ci/gcp-ci.sh provision
	$(CI_2_ENV) ./scripts/ci/gcp-ci.sh run

.PHONY: ci-ssh-2
ci-ssh-2: ## Resume and SSH into VM2 after a failed CI run.
	$(CI_2_ENV) ./scripts/ci/gcp-ci.sh ssh

.PHONY: ci-status-2
ci-status-2: ## Show the isolated second CI VM state.
	$(CI_2_ENV) ./scripts/ci/gcp-ci.sh status

.PHONY: ci-report-2
ci-report-2: ## View VM2's last collected stage summary and report path.
	@if [ -f ci-reports-2/summary.json ]; then \
		jq . ci-reports-2/summary.json; \
	else \
		echo "No report found. Run 'make ci-gcp-2' first."; \
	fi
	@if [ -f ci-reports-2/signalloom-ci-2-report.yaml ]; then \
		echo "OpenReports: ci-reports-2/signalloom-ci-2-report.yaml"; \
	fi

.PHONY: ci-ssh
ci-ssh: ## SSH into the CI VM for debugging (resumes if suspended).
	./scripts/ci/gcp-ci.sh ssh

.PHONY: ci-status
ci-status: ## Show CI VM status (RUNNING / SUSPENDED / etc).
	./scripts/ci/gcp-ci.sh status

.PHONY: ci-report
ci-report: ## View the last OpenReports report from a ci-gcp run.
	@if [ -f ci-reports/summary.json ]; then \
		jq . ci-reports/summary.json; \
	else \
		echo "No report found. Run 'make ci-gcp' first."; \
	fi
	@if [ -f ci-reports/signalloom-ci-report.yaml ]; then \
		echo "OpenReports: ci-reports/signalloom-ci-report.yaml"; \
	fi
