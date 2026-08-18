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

# Signing keys live in the MAIN worktree and are shared by every linked one.
#
# .keys/ is gitignored, so it was per-checkout while the Kind cluster and the
# zot registry it signs for are shared. `signing-keys` only creates what is
# absent, so each new worktree minted its own keypair: on 2026-08-13 there were
# four on disk, the cluster trusted one of them, and pushes from the others were
# refused. cosign words that refusal "no matching signatures were found" —
# identical to the wording for an artifact that was never signed — so it reads
# as unsigned and sends the reader hunting for a signature that is present and
# valid. That cost hours and pinned the fleet OCIRepository to a stale revision.
#
# git knows where the main worktree is, so nothing needs configuring per
# worktree: --git-common-dir resolves to the main checkout's .git from inside
# any linked worktree, and to its own from the main checkout. On the main
# checkout this is exactly the old value, so that path is unchanged.
#
# The relative fallback almost never fires, and it is important not to believe
# otherwise. gcp-ci.sh:322 does tar the tree with --exclude='.git' — but
# vm-pipeline.sh:91-95 runs `git init` on the VM immediately after extracting it,
# because Kustomize treats .git/ as the security boundary for relative path
# traversal and rejects ../base/ refs without one. So the git branch below fires
# on CI too, and KEYS_DIR is absolute there as well.
#
# An earlier version of this comment claimed the opposite. That false premise is
# what made ../$(KEYS_DIR) at the bootstrap-local line look safe, and it aborted
# both CI lanes. The fallback is for a genuinely git-less tree only.
GIT_COMMON_DIR := $(shell git rev-parse --git-common-dir 2>/dev/null)
KEYS_DIR ?= $(if $(GIT_COMMON_DIR),$(abspath $(GIT_COMMON_DIR)/..)/.keys,.keys)
export KEYS_DIR
SIGNALLOOM_PLATFORM_ROOT ?= /home/andy/src/cp/platform
OSRAMP_PRODUCT_ROOT ?= /home/andy/src/cp/osramp
OSRAMP_DEMO_ROOT ?= /home/andy/src/cp/osramp-demo
D2_BAO_ROOT ?= /home/andy/src/cp/d2-bao-apps
SIGNALLOOM_INTEGRATION_BRANCH ?= integration/signalloom-d2-v2.5.0
CPAI_CLI_ROOT ?= /home/andy/src/cp/cpai-cli
ZOT_CACHE_DIR ?= .cache/zot
# Observability (kube-prometheus-stack + trivy-system) is OFF by default.
# These tenants are not dependencies of any demo slice and dominate cluster
# build time (~3 minutes of reconciliation waits). Opt in explicitly:
#   ENABLE_OBSERVABILITY=true make up
ENABLE_OBSERVABILITY ?= false
export ENABLE_OBSERVABILITY

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
	@printf '\n\033[1mWhere to read more\033[0m\n'
	@printf '  \033[36m%-34s\033[0m %s\n' 'AGENTS.md'                  'Start here — slices, shared foundation, conventions'
	@printf '  \033[36m%-34s\033[0m %s\n' 'scripts/ci/README.md'       'GCP CI VMs: warm/cold, locks, and the traps that cost hours'
	@printf '  \033[36m%-34s\033[0m %s\n' 'docs/cluster-debugging.md'  'Cluster/registry faults + probes that lie'
	@printf '  \033[36m%-34s\033[0m %s\n' 'TESTING.md'                 'Which suites exist and what actually runs'
	@printf '  \033[36m%-34s\033[0m %s\n' 'd2-agent-trust/AGENTS.md'   'SPIFFE trust slice + its Pitfalls section'
	@printf '  \033[36m%-34s\033[0m %s\n' 'docs/FAQ.md'               'Answers to what people actually ask'
	@printf '  \033[36m%-34s\033[0m %s\n' 'docs/signalloom/audit-trail.md' 'Who writes an audit row, and the rule that decides'
	@printf '\n\033[1mDebugging first moves\033[0m\n'
	@printf '  %s\n' 'make doctor                                  full read-only cluster diagnostic'
	@printf '  %s\n' 'make demo-signalloom-supercred-evidence      what is TRUE of the credential chain, with proof commands'
	@printf '  %s\n' 'make ci-state / ci-state-2                   what the last run DID, and which file says so (local, no gcloud)'
	@printf '  %s\n' 'make ci-status / ci-status-2                 CI VM state (SUSPENDED means the last run PASSED)'
	@printf '  %s\n' 'unset SSH_AUTH_SOCK                          before any ad-hoc gcloud compute ssh, or it "times out"'
	@printf '  %s\n' 'make check-deployed-staleness                is the cluster running THIS tree? (exit 2 = unproven, not a pass)'
	@printf '\n'

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
	ENABLE_OBSERVABILITY="$(ENABLE_OBSERVABILITY)" ./scripts/push-local.sh foundation

.PHONY: push-local-signalloom
push-local-signalloom: ## Push Signal Loom artifacts for the explicit demo lifecycle.
	./scripts/push-local.sh signalloom

.PHONY: push-local-fleet push-local-agent-trust
push-local-fleet: ## Push only the signed fleet artifact to the local registry.
	./scripts/push-local.sh fleet
push-local-agent-trust: ## Push only signed Agent Trust manifests to the local registry.
	./scripts/push-local.sh agent-trust

.PHONY: bootstrap-local
bootstrap-local: ## Bootstrap Flux syncing from the in-cluster registry.
	# $(abspath …), not ../$(KEYS_DIR): the sub-make runs -C d2-osramp-fleet, and
	# the `../` that used to walk back to the repo root silently produced
	# ..//home/ci/osramp-demo/.keys/cosign.pub once KEYS_DIR became absolute in
	# 72d0166. That aborted BOTH CI lanes before stage 1, and the assertion it
	# tripped tells you to run `make signing-keys` — which had already succeeded
	# two minutes earlier. Same treatment as AUDIT_ANCHOR_KEYS at the bottom of
	# this file; guarded by test/keys-dir-path-safety.bats.
	$(MAKE) -C d2-osramp-fleet bootstrap-local COSIGN_PUB=$(abspath $(KEYS_DIR))/cosign.pub

.PHONY: flux-bootstrap
flux-bootstrap: bootstrap-local ## Phase 2 alias: bootstrap the sole Flux control plane.

.PHONY: flux-test
flux-test: ## Verify Flux readiness, including the Signalloom ResourceSets.
	./scripts/demo-lifecycle.sh flux-test

# ─── Image builds ────────────────────────────────────────────────────────────
#
# `make images` builds EVERYTHING. Each slice also has its own `images-<slice>`
# target so a single area can be rebuilt without paying for the rest — which is
# the common case when iterating on one component.
#
# Keep this list complete: an image target that exists but is not reachable from
# `images` is how a cluster ends up running stale code while every test passes.

.PHONY: images
images: images-osramp images-olly images-signalloom images-afm images-supercred ## Build ALL images across every slice.
	@echo "images: all slices built (osramp, olly, signalloom, afm, supercred)"

.PHONY: images-osramp
images-osramp: ## Build the d2-osramp-apps workload images and persist them in Zot.
	$(MAKE) -C d2-osramp-apps build

.PHONY: images-olly
images-olly: ## Build the olly-replica images and persist them in Zot.
	$(MAKE) -C olly-replica build

.PHONY: images-signalloom
images-signalloom: signalloom-images ## Build the Signal Loom workload images (portal, dashboard, proxy, netassert-controller).

.PHONY: images-afm
images-afm: ## Build the KubeSec-AFM platform image (RBAC analysis + Z3 + dashboard).
	./scripts/k8s-afm.sh build

.PHONY: images-supercred
images-supercred: demo-signalloom-supercred-images ## Build the SuperCred demo images (cardvault, policy-engine, cardvault-agent, runner).
.PHONY: images-signalfusion
images-signalfusion: demo-signalloom-signalfusion-images ## Build the Signal Fusion images (signal-ingest).

.PHONY: images-helpers
images-helpers: signalloom-spire-helper netassert-runner-image ## Build the disposable helper images (SPIRE proof, netassert runner).

.PHONY: signalloom-spire-helper
signalloom-spire-helper: ## Build and load the disposable SPIRE proof helper into Kind.
	docker build -f d2-signalloom/proof-helper.Dockerfile -t signalloom-spire-helper:local d2-signalloom
	kind load docker-image --name $(CLUSTER_NAME) signalloom-spire-helper:local

.PHONY: netassert-runner-image
netassert-runner-image: ## Build and load the pinned netassert v2.1.5 runner used by the Scan Now button.
	docker build -f d2-signalloom/netassert-runner.Dockerfile -t netassert-runner:local d2-signalloom
	kind load docker-image --name $(CLUSTER_NAME) netassert-runner:local

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
	PF_STATE=$$(mktemp -d); \
	IMAGE_TAR=$$(mktemp); \
	trap './scripts/supervise-port-forward.sh down "$$PF_STATE"; rm -rf "$$PF_STATE"; rm -f "$$IMAGE_TAR"' EXIT; \
	# The three builds below take minutes; a one-shot kubectl port-forward does \
	# not survive that window reliably, and CI on 2026-08-13 burned a retry \
	# cycle on curl exit 7 when the registry leg died before the push. \
	./scripts/supervise-port-forward.sh up "$$PF_STATE" registry zot 5001 5000 /v2/ $$$$; \
	# Build the two plain workload images in parallel (the dominant cost). The \
	# dashboard build+sign and all registry pushes stay sequential to avoid \
	# racing on the single zot port-forward. \
	# The portal's build identity, so check-deployed-staleness.sh can tell \
	# whether the running pod is this tree. Assembled by the shared library and \
	# never by hand: an image built with a fingerprint computed a different way \
	# compares unequal to a correct deployment and reports drift that is not \
	# there. If the args come back empty the Dockerfile's `test -n "$$SOURCE_ID"` \
	# fails the build, rather than silently producing an uncheckable image. \
	source ./scripts/lib/source-id.sh; \
	mapfile -t FE_BUILD_ARGS < <(source_id_build_args fe-signalloom); \
	docker build "$${FE_BUILD_ARGS[@]}" -t zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest d2-signalloom/apps/fe-signalloom & FE_PID=$$!; \
	docker build -t fake-integration-proxy:dev d2-signalloom/apps/fake-integration-proxy & FP_PID=$$!; \
	docker build -t netassert-controller:dev d2-signalloom/apps/netassert-controller & NC_PID=$$!; \
	BUILD_FAIL=0; wait $$FE_PID || BUILD_FAIL=1; wait $$FP_PID || BUILD_FAIL=1; wait $$NC_PID || BUILD_FAIL=1; \
	[ $$BUILD_FAIL -eq 0 ] || { echo "signalloom parallel image build failed" >&2; exit 1; }; \
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest; \
	docker save -o "$$IMAGE_TAR" zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest; \
	./scripts/supervise-port-forward.sh ensure "$$PF_STATE"; \
	crane push --insecure "$$IMAGE_TAR" localhost:5001/acme/images/signalloom/apps/fe-signalloom:latest; \
	# dashboard image repository literal: signalloom/apps/dashboard-signalloom:latest \
	# dashboard build context literal: d2-signalloom/apps/dashboard-signalloom \
	# dashboard kind load literal: kind load docker-image --name $(CLUSTER_NAME) zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest \
	./scripts/supervise-port-forward.sh ensure "$$PF_STATE"; \
	./scripts/build-sign-dashboard.sh; \
	# kind-load-verified.sh, not `kind load`: on a Docker daemon using the \
	# containerd image store the loader exits 0 having transferred nothing, and \
	# these two images are the ones it drops. The pods then sit in \
	# ImagePullBackOff, inf-signalloom/infra-configs fails its health check, \
	# signalloom-apps never reconciles, fe-signalloom stays EMPTY, and CI \
	# stages 6-8 fail together naming no image at all. Masked on a warm VM \
	# because the node's image cache survives; fatal on every cold run. \
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh fake-integration-proxy:dev netassert-controller:dev

.PHONY: cpai-images
cpai-images: ## Build CPAI runtime image from cpai-cli, push to Zot, and cosign sign.
	PF_STATE=$$(mktemp -d); \
	IMAGE_TAR=$$(mktemp); \
	trap './scripts/supervise-port-forward.sh down "$$PF_STATE"; rm -rf "$$PF_STATE"; rm -f "$$IMAGE_TAR"' EXIT; \
	./scripts/supervise-port-forward.sh up "$$PF_STATE" registry zot 5001 5000 /v2/ $$$$; \
	docker build -f $(CPAI_CLI_ROOT)/Dockerfile.runtime \
		-t zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest \
		$(CPAI_CLI_ROOT); \
	kind load docker-image --name $(CLUSTER_NAME) \
		zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest; \
	docker save -o "$$IMAGE_TAR" \
		zot.registry.svc.cluster.local:5000/acme/images/cpai/apps/cpai-runtime:latest; \
	./scripts/supervise-port-forward.sh ensure "$$PF_STATE"; \
	crane push --insecure "$$IMAGE_TAR" \
		localhost:5001/acme/images/cpai/apps/cpai-runtime:latest; \
	./scripts/supervise-port-forward.sh ensure "$$PF_STATE"; \
	DIGEST=$$(crane digest --insecure \
		localhost:5001/acme/images/cpai/apps/cpai-runtime:latest); \
	./scripts/supervise-port-forward.sh ensure "$$PF_STATE"; \
	COSIGN_PASSWORD="" cosign sign --yes \
		--key $(KEYS_DIR)/cosign.key \
		--signing-config $(KEYS_DIR)/signing-config.json \
		--allow-insecure-registry \
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
	ENABLE_OBSERVABILITY="$(ENABLE_OBSERVABILITY)" ./scripts/wait-reconciled.sh

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
	# Wrapped, because on 2026-08-18 this target exited 0 with 8 tests and 8
	# skips ("namespace/frontend not deployed") while six live-data failures
	# were in front of a user. Every line was `ok`, so it read as a pass. The
	# wrapper fails a run in which nothing actually executed.
	./scripts/assert-bats-ran-something.sh $(MAKE) -C d2-osramp-apps test

# ─── Signal Fusion / Weave unit tests ───────────────────────────────────────
# All targets below run offline — no cluster, no network, no API key.
# The Go tests include FrostDB (build-tag gated) and the full store contract
# suite. The dashboard tests run vitest with jsdom against the Weave, Signal
# Fusion, and weaveApi test files.

.PHONY: test-signal-ingest test-signal-ingest-frostdb test-dashboard-weave test-signalfusion-bats test-signal-fusion

test-signal-ingest: ## Run Go signal-ingest unit tests (memory store, model, api, correlation).
	cd d2-signalloom/apps/signal-ingest && go test ./... -v -count=1

test-signal-ingest-frostdb: ## Run Go signal-ingest tests INCLUDING FrostDB store (requires cgo).
	cd d2-signalloom/apps/signal-ingest && go test -tags frostdb ./... -v -count=1

test-dashboard-weave: ## Run Weave, Signal Fusion, and weaveApi vitest suites.
	cd d2-signalloom/apps/dashboard-signalloom && bun install --frozen-lockfile
	node d2-signalloom/apps/dashboard-signalloom/node_modules/vitest/vitest.mjs run \
		--root d2-signalloom/apps/dashboard-signalloom \
		src/pages/WeavePage.test.tsx \
		src/pages/SignalFusionPage.test.tsx \
		src/api/weaveApi.test.ts \
		--reporter=verbose

test-signalfusion-bats: ## Run Signal Fusion structural BATS tests (no cluster required).
	bats test/signalfusion-demo.bats

test-signal-fusion: test-signal-ingest test-dashboard-weave test-signalfusion-bats ## Run all Signal Fusion / Weave test suites.

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

.PHONY: demo-agent-trust-up demo-agent-trust-test-config demo-agent-trust-test demo-agent-trust-network-test demo-agent-trust-down demo-agent-trust-render
demo-agent-trust-up: healthcheck ## Publish fleet and Agent Trust artifacts then reconcile after inf-bao readiness.
	$(MAKE) signalloom-spire-helper
	$(MAKE) push-local-fleet
	$(MAKE) push-local-agent-trust
	./scripts/agent-trust-local.sh up
demo-agent-trust-test-config: ## Render and statically validate Agent Trust lifecycle wiring.
	$(MAKE) -C d2-agent-trust test
	bats test/agent-trust-lifecycle.bats
demo-agent-trust-test: demo-agent-trust-test-config ## Verify Agent Trust readiness then prove enforced network boundaries.
	./scripts/agent-trust-local.sh test
demo-agent-trust-network-test: ## Prove Agent Trust NetworkPolicy boundaries; requires enforcing CNI.
	./scripts/agent-trust-local.sh network-test
demo-agent-trust-down: ## Prune only Agent Trust; inf-bao is never deleted.
	./scripts/agent-trust-local.sh down
demo-agent-trust-render: ## Render Agent Trust Kubernetes manifests.
	$(MAKE) -C d2-agent-trust render

.PHONY: demo-signalloom-up demo-signalloom-test-config demo-signalloom-test demo-signalloom-runtime-test demo-signalloom-test-1 demo-signalloom-down
demo-signalloom-up: healthcheck ## Start the explicit Signal Loom demo lifecycle.
	$(MAKE) push-local-signalloom
	$(MAKE) signalloom-spire-helper
	$(MAKE) netassert-runner-image
	$(MAKE) signalloom-images
	# supercred-demo-runner/base has been an unconditional member of
	# apps/fe-signalloom/base/kustomization.yaml since 0233217 (2026-08-03), so
	# every bring-up DEPLOYS it — but nothing here ever BUILT it. The workload
	# uses imagePullPolicy: IfNotPresent and a bare `supercred-demo-runner:local`
	# tag, so on a node that happens to have the image from an earlier
	# `make images` it starts silently, and on a fresh node the bare tag resolves
	# to docker.io/library and the kubelet reports
	#   failed to pull and unpack image "docker.io/library/supercred-demo-runner:local"
	# which reads as a registry problem rather than a missing build step.
	# Always-deployed has to mean always-built; the /demo-api proxy in
	# dashboard-signalloom/nginx.conf depends on it either way.
	$(MAKE) demo-signalloom-supercred-images
	$(MAKE) demo-signalloom-signalfusion-images
	# The dashboard renders the Agent Trust Topology panel unconditionally, but
	# the ResourceSet backing it ships with `inputs: []` and only materialises
	# when scripts/agent-trust-local.sh patches concrete values in. Nothing here
	# ever did, so every standard bring-up left all six agent-trust-* namespaces
	# absent, the topology collector refused by RBAC that the missing slice was
	# itself supposed to deliver, and the panel permanently on its derived
	# fallback. Always-rendered has to mean always-deployed -- the same rule
	# demo-signalloom-supercred-images above exists to enforce for images.
	#
	# The artifacts are pushed HERE rather than via demo-agent-trust-up so that
	# nothing runs between signalloom-local.sh activating its ResourceSets and
	# agent-trust-local.sh snapshotting them. That script restores the sibling
	# inputs after its own fleet refresh, because refreshing reapplies the
	# declarative `inputs: []` -- so it has to observe them ACTIVE. Any step in
	# between is a window in which the ten-minute flux-system reconcile can
	# blank them first, and the snapshot then restores nothing, leaving
	# preflight_bao waiting 600s on a signalloom-infra that will never go Ready.
	$(MAKE) push-local-fleet
	$(MAKE) push-local-agent-trust
	SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
	./scripts/agent-trust-local.sh up
	$(MAKE) demo-signalloom-afm-up

.PHONY: demo-signalloom-afm-up
demo-signalloom-afm-up: ## Deploy the KubeSec-AFM slice that the RBAC Explorer reads; warn, do not fail, if its source repo is absent.
	@if ./scripts/k8s-afm.sh preflight >/dev/null 2>&1; then \
	  $(MAKE) demo-k8s-afm-up; \
	else \
	  ./scripts/k8s-afm.sh preflight || true; \
	  echo "WARNING: continuing WITHOUT the AFM slice. Signal Loom's RBAC Explorer will"; \
	  echo "         report \"KubeSec-AFM is not deployed\" until the above is resolved."; \
	fi
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
demo-signalloom-supercred-images: ## Build cardvault, policy-engine, cardvault-agent, runner images + load into kind (verified).
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/supercred-images.sh load

.PHONY: demo-signalloom-signalfusion-images
demo-signalloom-signalfusion-images: ## Build Signal Fusion images (signal-ingest) + load into kind (verified).
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/signalfusion-images.sh load

.PHONY: demo-signalloom-supercred-runner-image
demo-signalloom-supercred-runner-image: demo-signalloom-supercred-images ## Build/load the standalone SuperCred demo-runner image via the verified SuperCred image set.

.PHONY: check-flux-dynamic-labels
check-flux-dynamic-labels: ## Fail if a runtime-owned field is declared in Flux desired state.
	./scripts/check-flux-dynamic-labels.sh

.PHONY: check-flux-dynamic-labels-test
check-flux-dynamic-labels-test: ## Unit-test the dynamic-label guard (no cluster required).
	bats test/flux-dynamic-labels.bats

.PHONY: demo-signalloom-supercred-images-test
demo-signalloom-supercred-images-test: ## Unit-test the supercred image build/load guard and node-image shim (no cluster required).
	bats test/supercred-images.bats test/supercred-crictl-shim.bats test/kind-load-verified.bats test/signalfusion-images.bats test/supervise-port-forward.bats test/deployed-staleness.bats

.PHONY: test-signalfusion-images
test-signalfusion-images: ## Verify the Signal Fusion image identity guard against fake docker/kind clients (no cluster required).
	bats test/signalfusion-images.bats

.PHONY: check-ci-build-parity
check-ci-build-parity: ## Fail if CI omits a build step demo-signalloom-up runs (no cluster required).
	./scripts/check-ci-build-parity.sh

.PHONY: test-ci-build-parity
test-ci-build-parity: ## Verify the CI build-parity guard against fixture recipes, including that it cannot pass vacuously (no cluster required).
	bats test/ci-build-parity.bats

.PHONY: test-kind-load-verified
test-kind-load-verified: ## Verify the kind image-load guard against fake docker/kind clients (no cluster required).
	bats test/kind-load-verified.bats

.PHONY: test-deployed-staleness
test-deployed-staleness: ## Verify the deployed-vs-source guard against a fake kubectl, including that it cannot pass vacuously (no cluster required).
	bats test/deployed-staleness.bats

.PHONY: test-supervise-port-forward
test-supervise-port-forward: ## Verify port-forward supervision against fake kubectl/curl clients (no cluster required).
	bats test/supervise-port-forward.bats

.PHONY: demo-signalloom-supercred-api-test
demo-signalloom-supercred-api-test: ## Probe the live /demo-api/ authorization boundary with real Dex tokens (cluster required).
	bats d2-signalloom/test/supercred-demo-api.bats

.PHONY: demo-signalloom-api-route-liveness
demo-signalloom-api-route-liveness: ## Assert the RUNNING backends serve every API route the UI calls (cluster required).
	bats d2-signalloom/test/api-route-liveness.bats

.PHONY: demo-signalloom-supercred-two-window
demo-signalloom-supercred-two-window: ## Two-browser-context proof that phase 4 stuns the audience window with no reload (cluster required).
	./scripts/acceptance-test.sh supercred-two-window.spec.ts

.PHONY: demo-signalloom-supercred-stream
demo-signalloom-supercred-stream: ## Prove the instructor run log arrives progressively while a phase runs, not in one frame at the end (cluster required).
	./scripts/acceptance-test.sh supercred-log-streaming.spec.ts

# The same streaming assertions with NO cluster: a scripted runner
# (test/acceptance/harness/server.ts) driving the real
# SuperCredInstructorPanel and StreamingLogBlock, plus a negative control that
# reproduces the original batching defect and requires the assertions to fail
# against it. ~25s. Deliberately not routed through scripts/acceptance-test.sh:
# that script establishes cluster port-forwards and runs a Gateway preflight,
# every one of which this target exists to do without.
#
# The install is UNCONDITIONAL, and that is the fix for a real failure rather
# than tidiness. This used to read `[ -d node_modules/@playwright ] || bun
# install`, which guards on one package to decide whether the whole dependency
# SET is present. A checkout whose node_modules predated react being added to
# package.json therefore short-circuited: @playwright was there, bun install
# never ran, and the harness died with `Cannot find package 'react'` — reported
# by the spec as "harness exited before it was ready", which reads as a harness
# bug rather than a missing install. Any guard of that shape is wrong for the
# same reason; the lockfile is the only thing that describes the dependency set,
# so let bun compare against it.
#
# --frozen-lockfile is deliberate twice over: it is a no-op in ~100ms when the
# tree already satisfies bun.lock, and it makes a package.json that disagrees
# with the lockfile a hard failure here rather than something bun silently
# reconciles — the same reason CI stage 1b passes it.
.PHONY: demo-signalloom-supercred-stream-harness
demo-signalloom-supercred-stream-harness: ## Prove the instructor run log streams, against a scripted runner (no cluster required).
	cd test/acceptance && bun install --frozen-lockfile && \
		bunx playwright test supercred-log-streaming-harness.spec.ts \
			--project=supercred-log-streaming-harness

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

.PHONY: demo-signalloom-supercred-evidence demo-signalloom-supercred-evidence-json
demo-signalloom-supercred-evidence: ## Observe the SuperCred credential chain and show the command that proved each step.
	./scripts/supercred-evidence.sh text

demo-signalloom-supercred-evidence-json: ## Same evidence as JSON — what the dashboard's Credential Lifecycle card renders.
	@./scripts/supercred-evidence.sh json

.PHONY: demo-signalloom-supercred-evidence-test
demo-signalloom-supercred-evidence-test: ## Unit-test what the evidence probes CONCLUDE, against a stub kubectl (no cluster required).
	bats d2-signalloom/test/supercred-evidence-probe.bats

.PHONY: demo-osramp-up demo-osramp-test-config demo-osramp-test demo-osramp-down
demo-osramp-up: ## Restore OSRAMP frontend+backend (durable: restores ResourceSet inputs).
	./scripts/osramp-up.sh
demo-osramp-test-config: ## Validate existing OSRAMP manifests without a running slice.
	@# components/ holds no kustomization.yaml of its own -- the overlays live one
	@# level down under backend/ and frontend/. Rendering the parent silently
	@# validated nothing; it just errored. Render every overlay instead.
	@# The empty-list guard is load-bearing: a for-loop over nothing exits 0, which
	@# is how the previous broken path could have gone unnoticed indefinitely.
	@set -e; dirs=$$(find d2-osramp-apps/components -name kustomization.yaml -printf '%h\n' | sort); \
	[ -n "$$dirs" ] || { echo "no kustomization.yaml under d2-osramp-apps/components" >&2; exit 1; }; \
	for d in $$dirs; do printf '  rendering %s\n' "$$d"; kubectl kustomize "$$d" >/dev/null; done
	@# backend-config.bats adds real yq assertions (postgres grant, redis pin,
	@# minio ports) that a bare render cannot make. It already existed and was
	@# simply never called from here.
	$(MAKE) -C d2-osramp-apps test-config
demo-osramp-test: demo-osramp-test-config ## Run existing OSRAMP acceptance tests.
	$(MAKE) test
demo-osramp-down: ## Remove OSRAMP frontend+backend via shared ResourceSet cleanup.
	./scripts/osramp-down.sh

.PHONY: demo-olly-up demo-olly-test-config demo-olly-test demo-olly-down
demo-olly-up: ## Restore Olly Sentinel replica (durable: restores ResourceSet inputs).
	./scripts/olly-up.sh
demo-olly-test-config: ## Render the Olly component configuration without a running slice.
	@# Same shape as demo-osramp-test-config: the overlays live under configs/
	@# and controllers/, not at components/ itself.
	@set -e; dirs=$$(find olly-replica/components -name kustomization.yaml -printf '%h\n' | sort); \
	[ -n "$$dirs" ] || { echo "no kustomization.yaml under olly-replica/components" >&2; exit 1; }; \
	for d in $$dirs; do printf '  rendering %s\n' "$$d"; kubectl kustomize "$$d" >/dev/null; done
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
	@# d2-cpai's `test` target runs kustomize-check AND bats test/cpai-runtime.bats,
	@# so this "without a cluster" target was dragging in cluster runtime tests --
	@# and demo-cpai-test then ran the same bats a second time. Point at the
	@# genuinely config-only target; demo-cpai-test still owns the runtime pass.
	$(MAKE) -C d2-cpai kustomize-check
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

.PHONY: test-revocation-demo-safety
test-revocation-demo-safety: ## Verify revocation-demo never strands an unsigned artifact (local fake flux/cosign/kubectl).
	bats test/revocation-demo.bats

.PHONY: test-cosign-signing-consistency
test-cosign-signing-consistency: ## Assert every cosign sign call site agrees and push-local verifies against the cluster's key (no cluster required).
	bats test/cosign-signing-consistency.bats

.PHONY: attested-test
attested-test: ## Run the test suite under witness, storing evidence in Archivista.
	./scripts/attested-test.sh

# ── Audit-trail transparency anchoring ────────────────────────────────────────
# Checkpoints over public.audit_events, signed with the same .keys/witness.pem
# attested-test.sh uses, published to Archivista when ARCHIVISTA_URL is set and
# answering, otherwise to AUDIT_ANCHOR_DIR. Read-only against the audit table.
# See d2-signalloom/apps/fe-signalloom/src/audit_anchor/README.md for what this
# proves and, more to the point, what it does not.
AUDIT_ANCHOR_SRC := d2-signalloom/apps/fe-signalloom/src
AUDIT_ANCHOR_PY  ?= python3

# Every recipe below cd's into the package directory, so the key paths MUST be
# absolute before the cd happens. KEYS_DIR is absolute in a worktree (the
# git-common-dir branch) but plain '.keys' in a single checkout and on a CI VM
# that has no git at all -- and there the relative form would resolve against
# $(AUDIT_ANCHOR_SRC) rather than the repo root. $(abspath) anchors a relative
# value to make's working directory and leaves an already-absolute one alone,
# which is the whole of the fix on this side.
AUDIT_ANCHOR_KEYS = $(abspath $(KEYS_DIR))

.PHONY: audit-anchor-checkpoint
audit-anchor-checkpoint: signing-keys ## Publish a signed checkpoint over the audit trail.
	cd $(AUDIT_ANCHOR_SRC) && $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--private-key $(AUDIT_ANCHOR_KEYS)/witness.pem \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem checkpoint

.PHONY: audit-anchor-verify
audit-anchor-verify: ## Verify the audit trail against its anchors (exit 2 = DIVERGED).
	cd $(AUDIT_ANCHOR_SRC) && $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem verify

.PHONY: audit-anchor-show
audit-anchor-show: ## List the published audit-trail anchors.
	cd $(AUDIT_ANCHOR_SRC) && $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem show

.PHONY: audit-anchor-tamper-demo
audit-anchor-tamper-demo: ## Prove the audit verifier detects a real tamper (writes and cleans up its own rows).
	KEYS_DIR=$(KEYS_DIR) PYTHON=$(AUDIT_ANCHOR_PY) ./scripts/audit-anchor-tamper-demo.sh

.PHONY: audit-anchor-test
audit-anchor-test: ## Run the audit-anchor unit tests (no cluster required).
	cd $(AUDIT_ANCHOR_SRC) && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 \
		$(AUDIT_ANCHOR_PY) -m pytest -q tests/test_audit_anchor_*.py

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

##@ Public tunnel (ngrok)

.PHONY: public
public: ## Expose SignalLoom publicly via ngrok tunnel (cookie-gated).
	./scripts/public-tunnel.sh up

.PHONY: public-down
public-down: ## Tear down the public tunnel and restore Dex config.
	./scripts/public-tunnel.sh down

.PHONY: public-status
public-status: ## Show public tunnel status and URL.
	./scripts/public-tunnel.sh status

.PHONY: public-test
public-test: ## Run acceptance tests against the public ngrok URL.
	@url=$$(./scripts/public-tunnel.sh url) || { echo "No tunnel running; run 'make public' first"; exit 1; }; \
	DASHBOARD_URL="$$url" \
	SIGNALLOOM_API_URL="$$url" \
	SIGNALLOOM_DEX_URL="$$url" \
	./scripts/acceptance-test.sh signalloom-test-1.spec.ts

##@ CI

# $(abspath …), not a bare `ci-reports-2`. gcp-ci.sh's DEFAULT report dir is
# ${REPO_ROOT}/ci-reports — absolute, and anchored to the script, which is what
# the warm lane gets. Passing a RELATIVE override made the cold lane the only
# asymmetric one: `ci-reports-2` resolves against the running process's cwd, so
# the two lanes anchored their reports to different things and `make -C … ci-gcp-2`
# wrote its reports outside the tree it was testing. That is how
# /home/andy/src/cp/osramp-demo/ci-reports-2/ came to hold a d574d7d report from
# a run nobody made there.
#
# Third instance of this class in this repo: ../$(KEYS_DIR) at bootstrap-local,
# AUDIT_ANCHOR_KEYS, and now this. Same treatment, same reason. gcp-ci.sh also
# anchors a relative value at REPO_ROOT now, so this is belt and braces — the
# two together mean neither the caller's cwd nor the env var can move the
# reports. test/ci-path-anchoring.bats derives the guard from this line.
CI_2_ENV = GCP_CI_VM_NAME=signalloom-ci-2 GCP_CI_LABELS=purpose=signalloom-ci-2,worker=signalloom-ci-2,persistent=true GCP_CI_REMOTE_WORK_DIR=/home/ci/osramp-demo-ci-2 GCP_CI_REMOTE_REPORT_DIR=/home/ci/reports-signalloom-ci-2 GCP_CI_REPORT_DIR=$(abspath ci-reports-2) GCP_CI_REPORT_FILENAME=signalloom-ci-2-report.yaml GCP_CI_PIPELINE_LOG=/home/ci/ci-pipeline-ci-2.log

.PHONY: ci-tools
ci-tools: ## Install the CI toolchain: pinned pre-built binaries, then setup.sh.
	@# Same two installers, same order, as scripts/ci/vm-pipeline.sh. The pinned
	@# pre-built binaries go first so setup.sh's `have` guards skip them and its
	@# `go install` compile path is never reached for anything already present;
	@# setup.sh still runs because it alone installs skopeo, witness, yq and jq.
	./scripts/ci/install-ci-tools.sh
	./scripts/setup.sh --tools-only

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

# ci-state answers "what happened to the last run?" without gcloud, without the
# network, and without touching the lock — so it is safe to run while a lane is
# in flight. It names the report file it read by absolute path, because with a
# dozen checkouts of this repo each holding their own <checkout>/ci-reports, the
# data was never the problem: knowing which file was authoritative was.
#
# It exits 0 only on PASS. ABORTED, STALE and a run still in flight all exit
# non-zero, so `make ci-state && deploy` cannot proceed on a non-verdict — make
# will print "Error 2" for those, which is the point, not a bug.
.PHONY: ci-state
ci-state: ## What did the last ci-gcp run do? Names the report file it read. Exit 0 only on PASS.
	@./scripts/ci/gcp-ci.sh state

.PHONY: ci-state-2
ci-state-2: ## What did the last ci-gcp-2 run do? Names the report file it read. Exit 0 only on PASS.
	@$(CI_2_ENV) ./scripts/ci/gcp-ci.sh state

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

# ---------------------------------------------------------------------------
# Risk — policy as versioned code, priced in pounds.
# See risk/README.md and docs/policy-as-versioned-code/INTEGRATION.md.
# All targets run fully offline: no cluster, no network, no API key.
# ---------------------------------------------------------------------------

RISKCTL      := tools/riskctl/riskctl
RISK_AGENT   ?= agent-remediation
RISK_PACK    ?= 2.0.0
RISK_ORG     ?= acme
RISK_WITH    ?= ludlow-health
# -buildvcs=false is deliberate, not a workaround for a broken checkout.
#
# Go's VCS stamping shells out to git and fails with "error obtaining VCS status: exit status 128"
# whenever the build runs inside a git WORKTREE — reproducible on a pristine repo, nothing to do
# with this code, and the message points at VCS rather than at the build. Worktrees are a
# first-class workflow here, so a build that only works in the primary checkout is a build that
# breaks for half the people running it.
#
# Turning it off is also the correct setting on its own merits. Nothing in this repository reads
# the build stamp (no debug.ReadBuildInfo anywhere), and the stamp embeds the commit hash and a
# dirty flag — so with it ON the binary bytes change when unrelated files are touched. These
# targets already declare themselves hermetic and offline (GOPROXY=off, -mod=mod); a fingerprint
# that moves with irrelevant git state works directly against that.
RISK_GOFLAGS := GOFLAGS='-mod=mod -buildvcs=false' GOPROXY=off

.PHONY: riskctl
riskctl: ## Build the riskctl binary (offline, vendored).
	@$(RISK_GOFLAGS) go build -C tools/riskctl -o "$(CURDIR)/$(RISKCTL)" .
	@echo "built $(RISKCTL)"

.PHONY: risk-baseline
risk-baseline: riskctl ## Baseline an agent's compliance posture against the versioned policy pack.
	@./$(RISKCTL) baseline --agent $(RISK_AGENT) --pack $(RISK_PACK) --org $(RISK_ORG)

.PHONY: risk
risk: riskctl ## Cash value of an agent's risk exposure: ALE / VaR95 / TVaR / TCoR.
	@./$(RISKCTL) risk --agent $(RISK_AGENT) --pack $(RISK_PACK) --org $(RISK_ORG)

.PHONY: risk-compare
risk-compare: riskctl ## Same agent, same pack, two institutions — the proportionality demo.
	@./$(RISKCTL) compare --agent $(RISK_AGENT) --pack $(RISK_PACK) --org $(RISK_ORG) --with $(RISK_WITH)

.PHONY: risk-report
risk-report: riskctl ## Regenerate the committed report under risk/out/.
	@./scripts/risk-report.sh

DASHBOARD_RATES_GEN := d2-signalloom/apps/dashboard-signalloom/scripts/generate-rates.ts
DASHBOARD_VECTORS   := d2-signalloom/apps/dashboard-signalloom/src/money/__fixtures__/fxTestVectors.json

.PHONY: fx
fx: riskctl ## Regenerate risk/fx/*.json from rates.yaml, and any downstream generated copies.
	@./$(RISKCTL) fx
	@# The dashboard cannot parse the authored YAML, so it generates a TypeScript copy from
	@# risk/fx/rates.json. Regenerating it HERE keeps "update the rates" a single command --
	@# otherwise the two artefacts drift between the edit and whenever someone remembers the
	@# second step, which is exactly the second-source-of-truth problem this file exists to avoid.
	@#
	@# Guarded on existence so this target works on a branch where the dashboard side has not
	@# landed yet: absent generator means nothing to regenerate, not a broken build. Once merged
	@# it always runs. The dashboard's own staleness test is the backstop if it is ever skipped.
	@if [ -f "$(DASHBOARD_RATES_GEN)" ]; then \
		echo "regenerating dashboard rates from risk/fx/rates.json"; \
		( cd d2-signalloom/apps/dashboard-signalloom && bun run scripts/generate-rates.ts ); \
	else \
		echo "fx: no dashboard generator at $(DASHBOARD_RATES_GEN) — skipping (nothing downstream to regenerate)"; \
	fi
	@# Self-check on the generation pipeline: after every generator has run, is every generated
	@# artefact actually current?
	@#
	@# This VERIFIES and FAILS. It deliberately does not repair, and that distinction is the whole
	@# point. An earlier version of this block copied the file and printed a warning — which meant
	@# that after it ran, the artefact was correct, the dashboard's staleness test passed, and a
	@# broken generator survived with nothing but a line of make output against it. A warning in a
	@# build log is missable; a failing test is not. Repairing the symptom suppressed the louder
	@# alarm downstream.
	@#
	@# It also is not a second writer. The dashboard generator owns the copy; this only asserts the
	@# generator did what it said. That matters because a generator CAN lie: removing a write while
	@# leaving its `console.log` in place produces "wrote X" over a write that never happened, which
	@# is exactly the class of failure this whole branch has been chasing. Verified against a
	@# deliberately neutered generator.
	@if [ -f "$(DASHBOARD_RATES_GEN)" ] && [ -f "$(DASHBOARD_VECTORS)" ]; then \
		if cmp -s risk/fx/testvectors.json "$(DASHBOARD_VECTORS)"; then \
			echo "fx: generated artefacts verified current"; \
		else \
			echo "fx: FAILED — $(DASHBOARD_VECTORS) is stale after generation." >&2; \
			echo "fx:   $(DASHBOARD_RATES_GEN) reported success but did not vendor" >&2; \
			echo "fx:   risk/fx/testvectors.json. Do not hand-fix the artefact — fix the generator," >&2; \
			echo "fx:   or the next edit silently drifts again." >&2; \
			exit 1; \
		fi; \
	fi

.PHONY: risk-check
risk-check: ## CI gate: artefacts validate, engine self-checks, results are reproducible.
	@$(RISK_GOFLAGS) go vet -C tools/riskctl ./...
	@$(RISK_GOFLAGS) go test -C tools/riskctl ./...
	@$(MAKE) --no-print-directory risk-report
	@git diff --quiet -- risk/out/ \
		|| { echo "risk/out/ is stale — commit the regenerated report"; git diff --stat -- risk/out/; exit 1; }
	@echo "risk-check: artefacts valid, engine self-checked, report reproducible"

.PHONY: test-ci-lock
test-ci-lock: ## Verify the exclusive CI-VM lock against a fake remote (no VM required).
	bats test/ci-lock.bats

.PHONY: test-ci-state
test-ci-state: ## Verify ci-state names its source, dates its claim, and cannot call a non-verdict a pass (no VM required).
	bats test/ci-state-locality.bats

.PHONY: test-ci-path-anchoring
test-ci-path-anchoring: ## Verify no CI path variable is relative, in the Makefile source AND in what make expands.
	bats test/ci-path-anchoring.bats

.PHONY: demo-signalloom-fleet-image demo-signalloom-fleet-up demo-signalloom-fleet-down
demo-signalloom-fleet-image: ## Build and kind-load the Fleet Manager image.
	docker build -t fleet-manager:local d2-signalloom/apps/fleet-manager
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh fleet-manager:local

demo-signalloom-fleet-up: demo-signalloom-fleet-image ## Deploy Fleet Manager (separate service; applied directly, not via Flux).
	kubectl apply -k d2-signalloom/apps/fleet-manager/base
	kubectl -n fe-signalloom rollout status deploy/fleet-manager --timeout=180s

demo-signalloom-fleet-down: ## Remove Fleet Manager only.
	kubectl delete -k d2-signalloom/apps/fleet-manager/base --ignore-not-found

.PHONY: check-backends
check-backends: ## Assert every backend the dashboard proxies to is declared and deployed.
	./scripts/check-backends.sh live

.PHONY: check-deployed-staleness
check-deployed-staleness: ## Assert the running pods are running THIS working tree, not an older build.
	./scripts/check-deployed-staleness.sh

# ===========================================================================
# GCP Terraform platform — appended by chunk F6. See terraform/CONTRACT.md §1.
#
# This block is APPEND-ONLY. Nothing above this line is edited, renamed or
# reordered by it, and no target here shadows an existing `ci-*` target: the
# existing GCP CI VM lane (`ci-gcp`, `ci-gcp-2`, `ci-provision`, `ci-status`)
# runs the kind-based demo pipeline and is untouched. Everything here is
# prefixed `gcp-tf-`.
# ===========================================================================

TF ?= terraform
TFLINT ?= tflint

# Roots. Overridable so the contract tests can point a target at a fixture tree
# rather than mutating the real one — and so `gcp-tf-destroy`'s refusal to run
# against `platform` or `bootstrap` is a testable behaviour rather than an
# accident of a hardcoded path.
TF_ROOT_BOOTSTRAP ?= terraform/bootstrap
TF_ROOT_PLATFORM ?= terraform/platform
TF_ROOT_ENV ?= terraform/environments

# No project id, billing account, domain or bucket name is hardcoded anywhere in
# this block. TF_STATE_BUCKET has no default on purpose: a default would be a
# real bucket name in a public repo, or a placeholder that produces a confusing
# 404 instead of a clear "you have not told me which bucket" message.
TF_STATE_BUCKET ?=
TF_STATE_PREFIX_BASE ?= osramp

# Per-environment data dir (CONTRACT §5a mechanism 2). Two environments cannot
# share a cached backend pointer, so cross-contamination is physically
# impossible rather than merely detected. TF_DATA_DIR resolves relative to the
# -chdir target, so this lands inside the root it belongs to.
TF_DATA_DIR_BASE ?= .terraform
GCP_TF_DATA_DIR = $(TF_DATA_DIR_BASE)-$(ENV)
GCP_TF_PREFIX = $(TF_STATE_PREFIX_BASE)/environments/$(ENV)
GCP_TF_PLAN_FILE = $(GCP_TF_DATA_DIR)/$(ENV).tfplan
GCP_TF_VAR_FILE ?= environments.tfvars

# Every offline terraform invocation runs with cloud credentials stripped from
# the environment. Working gcloud credentials exist on developer machines, so
# "the unit sweep passes here" would otherwise be no evidence at all that it
# passes on a runner with none (ISC-357).
GCP_TF_NOCREDS = env -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_CREDENTIALS \
	-u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_AUTH_ACCESS_TOKEN -u GOOGLE_OAUTH_ACCESS_TOKEN

# --- Discovery, not hand-maintained lists ----------------------------------
#
# This repo has already shipped 33 bats suites that no runner executed: all
# passing, all measuring nothing, because the runner named files by hand and
# nobody re-edited the list. d2-signalloom/Makefile fixed the same hole by
# globbing. Both lists below are DISCOVERED, so a new suite runs the day it
# lands and registration is default-on. test/terraform-suite-registration.bats
# fails if either is replaced by a hand-written list.

# Every directory under terraform/ holding .tf files — fmt, validate, tflint.
# Deliberately on ONE line each. A backslash-continued assignment is a landmine
# for anything that reads the Makefile a line at a time — including this repo's
# own `make help` awk and the registration guard in
# test/terraform-suite-registration.bats — and a line-oriented edit to the first
# half leaves the second half dangling as a syntax error.
GCP_TF_DIRS = $(sort $(shell find terraform -type f -name '*.tf' -not -path '*/.terraform*' -printf '%h\n' 2>/dev/null))

# Every directory holding a tests/*.tftest.hcl suite — `terraform test`.
GCP_TF_TEST_DIRS = $(sort $(patsubst %/tests,%,$(shell find terraform -type f -name '*.tftest.hcl' -not -path '*/.terraform*' -printf '%h\n' 2>/dev/null)))

# Every terraform bats suite.
GCP_TF_BATS = $(sort $(wildcard test/terraform-*.bats))

# Exclusions. Each entry needs a written reason immediately above it; an entry
# with no reason, or naming a file that does not exist, fails
# test/terraform-suite-registration.bats. Both are empty today, and an empty
# exclusion list is the correct steady state — reaching for one should feel
# like a decision, not a convenience.
GCP_TF_EXCLUDED_BATS =
GCP_TF_EXCLUDED_TEST_DIRS =

GCP_TF_BATS_RUN = $(filter-out $(GCP_TF_EXCLUDED_BATS),$(GCP_TF_BATS))
GCP_TF_TEST_DIRS_RUN = $(filter-out $(GCP_TF_EXCLUDED_TEST_DIRS),$(GCP_TF_TEST_DIRS))

# --- Guard rails ------------------------------------------------------------
#
# These are `define`d rather than factored into a shell script because
# scripts/gcp-tf/ belongs to another chunk, and because a guard that lives in
# the Makefile cannot be bypassed by invoking the Makefile.

define gcp_tf_require_env
	@if [ -z "$(ENV)" ]; then \
		echo "ERROR: ENV is required for '$@'."; \
		echo "       Usage: make $@ ENV=demo-1"; \
		echo "       Keys match ^(demo|ci)-[1-9][0-9]*\$$ — demo-1, demo-2, ci-1."; \
		exit 2; \
	fi
	@printf '%s' '$(ENV)' | grep -Eq '^(demo|ci)-[1-9][0-9]*$$' || { \
		echo "ERROR: ENV='$(ENV)' is not a valid environment key."; \
		echo "       Keys match ^(demo|ci)-[1-9][0-9]*\$$."; \
		echo "       'prod-1' is rejected on purpose: this platform builds demo and"; \
		echo "       CI estates only, and a prod-shaped key here would put production"; \
		echo "       naming on infrastructure with a demo's guard rails."; \
		exit 2; \
	}
endef

define gcp_tf_require_state_bucket
	@if [ -z "$(TF_STATE_BUCKET)" ]; then \
		echo "ERROR: TF_STATE_BUCKET is required for '$@'."; \
		echo "       Usage: make $@ ENV=$(ENV) TF_STATE_BUCKET=<bucket>"; \
		echo "       It is created by 'make gcp-tf-bootstrap' and has no default:"; \
		echo "       a default here would be either a real bucket name in a public"; \
		echo "       repo, or a placeholder that 404s instead of explaining itself."; \
		exit 2; \
	fi
endef

# CONTRACT §5a mechanism 3. Reads the resolved backend prefix back out of the
# data dir terraform just wrote and refuses to proceed unless it names ENV.
# This is the mechanism that catches a human editing state by hand, and the one
# that fires if `init` silently reused a cached backend pointer.
define gcp_tf_assert_prefix
	@backend_state="$(1)/$(GCP_TF_DATA_DIR)/terraform.tfstate"; \
	if [ ! -f "$$backend_state" ]; then \
		echo "ERROR: cannot read back the resolved backend configuration."; \
		echo "       Expected: $$backend_state"; \
		echo "       Refusing to plan or apply against an unverified state prefix."; \
		exit 3; \
	fi; \
	resolved="$$(sed -n 's/.*"prefix"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$$backend_state" | head -1)"; \
	if [ -z "$$resolved" ]; then \
		echo "ERROR: the resolved backend configuration names no prefix."; \
		echo "       Read from: $$backend_state"; \
		exit 3; \
	fi; \
	case "$$resolved" in \
		*"$(ENV)"*) ;; \
		*) echo "ERROR: backend prefix mismatch — this is CONTRACT §5a firing."; \
		   echo "       resolved prefix: $$resolved"; \
		   echo "       ENV:             $(ENV)"; \
		   echo "       Terraform would have written $(ENV)'s resources into another"; \
		   echo "       environment's state. Re-run 'terraform init -reconfigure'."; \
		   exit 3;; \
	esac; \
	echo "gcp-tf: backend prefix '$$resolved' matches ENV='$(ENV)'"
endef

# Offline init for the validate/test sweep.
#
# `terraform validate` and `terraform test` are genuinely offline — verified in
# a network namespace with no interfaces. `terraform init` is not: it resolves
# provider packages from registry.terraform.io, and that is a real network
# dependency no amount of local guarding removes. So init runs only when the
# providers are not yet installed, and says so when it does.
#
# This is not a guard that repairs what it detects. Nothing is being corrected:
# an uninstalled provider is installed, and if the installed set has drifted
# from required_providers, terraform's own "provider requirements have changed"
# error fires on the very next validate. There is no state in which a stale
# .terraform/ makes this sweep report a pass it has not earned.
define gcp_tf_init_offline
	if [ ! -d "$(1)/.terraform/providers" ]; then \
		echo "    (installing providers — this step, and only this step, needs the registry)"; \
		$(GCP_TF_NOCREDS) $(TF) -chdir=$(1) init -backend=false -input=false >/dev/null; \
	fi
endef

# init -reconfigure with the prefix derived from ENV, followed immediately by
# the readback assertion. Nothing plans or applies without passing through here.
define gcp_tf_init_env
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) init -reconfigure \
		-backend-config=bucket=$(TF_STATE_BUCKET) \
		-backend-config=prefix=$(GCP_TF_PREFIX)
	$(call gcp_tf_assert_prefix,$(TF_ROOT_ENV))
endef

.PHONY: gcp-tf-bootstrap
gcp-tf-bootstrap: ## Plan the one-time state-bucket bootstrap root (review, then apply by hand).
	@# Deliberately plan-only. Applying this root creates the bucket every other
	@# root's state lives in — the one action in the estate with no state to roll
	@# back from — so it is not reachable by a one-word make target typed
	@# absentmindedly. The plan is produced here; the apply is a human step, and
	@# terraform/RUNBOOK.md gives the exact command.
	$(TF) -chdir=$(TF_ROOT_BOOTSTRAP) init
	$(TF) -chdir=$(TF_ROOT_BOOTSTRAP) plan -out=bootstrap.tfplan
	@echo
	@echo "Plan written to $(TF_ROOT_BOOTSTRAP)/bootstrap.tfplan."
	@echo "Review it, then apply by hand:"
	@echo "    $(TF) -chdir=$(TF_ROOT_BOOTSTRAP) apply bootstrap.tfplan"

.PHONY: gcp-tf-plan
gcp-tf-plan: ## Plan one environment to a reviewable saved plan file (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) plan \
		-var-file=$(GCP_TF_VAR_FILE) \
		-var target_env=$(ENV) \
		-out=$(GCP_TF_PLAN_FILE)
	@echo
	@echo "Plan saved to $(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)."
	@echo "Review it, then: make gcp-tf-apply ENV=$(ENV) TF_STATE_BUCKET=$(TF_STATE_BUCKET)"

.PHONY: gcp-tf-apply
gcp-tf-apply: ## Apply a previously reviewed saved plan file (ENV=<key>). Never a bare apply.
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	@if [ ! -f "$(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)" ]; then \
		echo "ERROR: no saved plan at $(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)."; \
		echo "       Run: make gcp-tf-plan ENV=$(ENV) TF_STATE_BUCKET=$(TF_STATE_BUCKET)"; \
		echo "       This target applies a reviewed plan file and nothing else. A bare"; \
		echo "       'terraform apply' re-plans at apply time, so what a human read and"; \
		echo "       what Terraform executes are two different plans."; \
		exit 2; \
	fi
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) apply $(GCP_TF_PLAN_FILE)

.PHONY: gcp-tf-status
gcp-tf-status: ## Show one environment's state inventory and outputs, read-only (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) state list
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) output

.PHONY: gcp-tf-test
gcp-tf-test: ## Run the offline unit sweep plus the live edge probes against one environment (ENV=<key>).
	$(gcp_tf_require_env)
	$(MAKE) --no-print-directory gcp-tf-test-unit
	@probes="$$(ls scripts/gcp-tf/edge-probe-*.sh 2>/dev/null || true)"; \
	if [ -z "$$probes" ]; then \
		echo "ERROR: no live edge probes found at scripts/gcp-tf/edge-probe-*.sh."; \
		echo "       They are supplied by chunk F4 (feat/gcp-tf-edge). Until that"; \
		echo "       merges there is no live acceptance surface, and reporting a pass"; \
		echo "       from the offline sweep alone would be a green test measuring"; \
		echo "       nothing about the deployed environment."; \
		exit 2; \
	fi; \
	for p in $$probes; do echo "--- $$p"; ENV=$(ENV) "$$p"; done

.PHONY: gcp-tf-test-unit
gcp-tf-test-unit: ## Run every native `terraform test` suite offline, with cloud credentials stripped.
	@# DISCOVERED, not listed. Every directory holding tests/*.tftest.hcl runs.
	@if [ -z "$(GCP_TF_TEST_DIRS_RUN)" ]; then \
		echo "ERROR: no terraform test suites discovered under terraform/."; \
		echo "       Every root and module ships at least one (CONTRACT §7a), so an"; \
		echo "       empty sweep means discovery is broken, not that there is"; \
		echo "       nothing to run. Refusing to report a vacuous pass."; \
		exit 2; \
	fi
	@for d in $(GCP_TF_TEST_DIRS_RUN); do \
		echo "--- terraform test: $$d"; \
		$(call gcp_tf_init_offline,$$d); \
		$(GCP_TF_NOCREDS) $(TF) -chdir=$$d test; \
	done

.PHONY: gcp-tf-destroy
gcp-tf-destroy: ## Destroy one environment. Requires CONFIRM=<the same key> (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	@case "$(TF_ROOT_ENV)" in \
		*platform*|*bootstrap*) \
			echo "ERROR: refusing to destroy '$(TF_ROOT_ENV)'."; \
			echo "       This target destroys ONE demo environment. The platform root"; \
			echo "       owns the audit sink, the WIF pool and the DNS zone; the"; \
			echo "       bootstrap root owns the bucket holding every other root's"; \
			echo "       state. Neither is disposable and neither is reachable here."; \
			exit 2;; \
	esac
	@if [ "$(CONFIRM)" != "$(ENV)" ]; then \
		echo "ERROR: destroy requires a typed confirmation matching the environment key."; \
		echo "       Expected: CONFIRM=$(ENV)"; \
		echo "       Got:      CONFIRM=$(CONFIRM)"; \
		echo "       Typing the key is the point: it is the step that fails when you"; \
		echo "       meant demo-2 and your shell history said demo-1."; \
		exit 2; \
	fi
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(TF) -chdir=$(TF_ROOT_ENV) destroy \
		-var-file=$(GCP_TF_VAR_FILE) \
		-var target_env=$(ENV)
	@echo "Destroyed $(ENV). The state bucket, the audit log bucket and the platform"
	@echo "singletons are in other roots' state and were not touched."

.PHONY: gcp-tf-validate
gcp-tf-validate: ## Offline gate: fmt, validate, tflint, terraform test, terraform bats. No network, no credentials.
	@if [ -z "$(GCP_TF_DIRS)" ]; then \
		echo "ERROR: no terraform directories discovered under terraform/."; \
		exit 2; \
	fi
	$(GCP_TF_NOCREDS) $(TF) fmt -recursive -check terraform
	@for d in $(GCP_TF_DIRS); do \
		echo "--- validate: $$d"; \
		$(call gcp_tf_init_offline,$$d); \
		$(GCP_TF_NOCREDS) $(TF) -chdir=$$d validate; \
	done
	@for d in $(GCP_TF_DIRS); do \
		echo "--- tflint: $$d"; \
		$(GCP_TF_NOCREDS) $(TFLINT) --chdir=$$d; \
	done
	$(MAKE) --no-print-directory gcp-tf-test-unit
	@# GLOB, not a hand-maintained list — see the discovery comment above.
	@if [ -z "$(GCP_TF_BATS_RUN)" ]; then \
		echo "ERROR: no test/terraform-*.bats suites discovered."; \
		echo "       Refusing to report a vacuous pass."; \
		exit 2; \
	fi
	$(GCP_TF_NOCREDS) bats $(GCP_TF_BATS_RUN)

.PHONY: gcp-tf-ci
gcp-tf-ci: ## Plan the CI environment lane (CI=<ci-N>). Delegates to gcp-tf-plan.
	@if [ -z "$(CI)" ]; then \
		echo "ERROR: CI is required for '$@'. Usage: make $@ CI=ci-1"; \
		exit 2; \
	fi
	@printf '%s' '$(CI)' | grep -Eq '^ci-[1-9][0-9]*$$' || { \
		echo "ERROR: CI='$(CI)' is not a valid CI environment key (^ci-[1-9][0-9]*\$$)."; \
		echo "       This lane runs CI environments only; use ENV= for a demo."; \
		exit 2; \
	}
	$(MAKE) --no-print-directory gcp-tf-plan ENV=$(CI)

# ===========================================================================
# END GCP Terraform platform block
# ===========================================================================
