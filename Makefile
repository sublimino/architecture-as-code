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

KUBECONFIG ?= /tmp/osramp-kubeconfig.yaml
override GOPATH := /tmp/gopath
override GOMODCACHE := /tmp/gomodcache
override GOCACHE := /tmp/gocache
override CGO_ENABLED := 0
HELM_CACHE_HOME ?= /tmp/helm/cache
HELM_CONFIG_HOME ?= /tmp/helm/config
HELM_DATA_HOME ?= /tmp/helm/data
UV_CONFIG_FILE ?= /dev/null
UV_CACHE_DIR ?= /tmp/uv-cache
PW_CHANNEL ?= chromium
PLAYWRIGHT_BROWSERS_PATH ?= /tmp/ms-playwright
DOCKER_CONFIG ?= /tmp/docker
export KUBECONFIG GOPATH GONOSUMDB GOCACHE GOMODCACHE CGO_ENABLED HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME UV_CONFIG_FILE UV_CACHE_DIR PW_CHANNEL PLAYWRIGHT_BROWSERS_PATH DOCKER_CONFIG

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
DEFAULT_KEYS_DIR := $(if $(wildcard .keys/witness.pem),.keys,$(if $(GIT_COMMON_DIR),$(abspath $(GIT_COMMON_DIR)/..)/.keys,.keys))
KEYS_DIR ?= $(DEFAULT_KEYS_DIR)
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
	@printf '  %s\n' 'make doctor-node ENV=demo-1                  NODE level: VM, tailnet, docker, zot PUSH, AFM cluster count'
	@printf '  %s\n' 'make doctor-node-all                         every lane; exit 3 = could not measure, which is NOT a pass'
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

# CRKC Rule SP-1 — worktree Landlock confinement.
#
# A Makefile target rather than a CI stage, and deliberately so. The harness
# proves a KERNEL control: it needs `nono` on PATH and `landlock` in
# /sys/kernel/security/lsm, and the CI VM has neither. Inventing a stage that
# appears to satisfy those preconditions would produce a green report about a
# control that was never exercised, which is worse than not running it.
#
# The static half IS in CI: test/worktree-landlock-confinement.bats is registered
# in stage 1g and asserts the profile's content, the wrapper's argv handling and
# the committed evidence artifact on every run, skipping only the live-kernel
# tests and saying how many it skipped.
#
# Regenerate the evidence artifact after any change to the profile or wrapper —
# docs/signalloom/evidence/worktree-confinement-proof.json is what the bats suite
# reads, so a stale artifact is a stale claim.
.PHONY: test-worktree-confinement
test-worktree-confinement: ## Prove Rule SP-1 against the live kernel and regenerate the evidence artifact (nono + Landlock required).
	./scripts/test-worktree-confinement.sh

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
WAIT_LIB_DEST ?= scripts/lib/wait.sh
wait-lib-sync: ## Re-vendor scripts/lib/wait.sh from the ~/.andy_sync source of truth.
	@test -f "$(WAIT_LIB_SOURCE)" || { echo "source of truth not found: $(WAIT_LIB_SOURCE)" >&2; exit 1; }
	@tmp="$(WAIT_LIB_DEST).tmp"; trap 'rm -f "$$tmp"' EXIT; { \
	  printf '%s\n' \
	    '# shellcheck shell=bash' \
	    '# wait.sh — VENDORED COPY, DO NOT EDIT HERE.' \
	    '# Source of truth: ~/.andy_sync/includes/wait.sh   Re-vendor: make wait-lib-sync' \
	    '#'; \
	  tail -n +2 "$(WAIT_LIB_SOURCE)"; \
	} > "$$tmp"; mv "$$tmp" "$(WAIT_LIB_DEST)"; trap - EXIT
	@echo "re-vendored $(WAIT_LIB_DEST) from $(WAIT_LIB_SOURCE)"

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
	@test -f $(KEYS_DIR)/witness-pub.pem || { echo "$(KEYS_DIR)/witness-pub.pem missing for existing witness key" >&2; exit 1; }
	@actual_id=$$(openssl pkey -pubin -in $(KEYS_DIR)/witness-pub.pem -outform DER 2>/dev/null | openssl dgst -sha256 -r | cut -d' ' -f1); \
		policy=$(KEYS_DIR)/segment-signing-policy.json; \
		if [ ! -f "$$policy" ]; then \
			tmp="$$policy.tmp.$$$$"; \
			umask 077; \
			jq -n --arg id "$$actual_id" \
				'{schema_version:"signalloom.segment.signing-policy/v1",expected_key_ids:[$$id]}' > "$$tmp"; \
			mv "$$tmp" "$$policy"; \
		fi; \
		expected_id=$$(jq -er '.expected_key_ids | if length == 1 then .[0] else error("expected exactly one signer") end' "$$policy"); \
		[ "$$expected_id" = "$$actual_id" ] || { \
			echo "protected segment signing policy rejects $(KEYS_DIR)/witness-pub.pem" >&2; \
			exit 1; \
		}
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

.PHONY: signalloom-docs-image
signalloom-docs-image: ## Build, sign, and load the user documentation image.
	./scripts/build-sign-docs.sh

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
	./scripts/build-sign-docs.sh; \
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
	@bash -c 'source ./scripts/lib/wait.sh && wait_k8s_exists namespace frontend 300'
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

.PHONY: test-all test-all-estate test-all-offline test-all-cluster test-all-browser test-eap-offline

test-all-estate: test-all-offline test-all-cluster test-all-browser ## Run every single test across the entire estate (offline, cluster, and browser).
	@echo "=== COMPLETE: All estate test suites (offline, cluster, browser) passed successfully! ==="

test-all: test-all-estate ## Alias for test-all-estate.

test-all-offline: ## Run all offline test suites (Go unit, Vitest, Python, KPAI, static BATS/config/registry).
	@echo "=== [Offline 1/5] All Go Unit Tests (29 modules via dynamic discovery loop) ==="
	@modules=$$(find . -type d \( -name ".cache" -o -name "node_modules" \) -prune -o -type f -name "go.mod" -exec dirname {} \; | sort -u); \
	printf '%s\n' $$modules | xargs -I {} -P $${GO_TEST_JOBS:-8} sh -c 'echo "--- Running go test in $$1 ---" && (cd "$$1" && env GOPATH=$${GOPATH:-/tmp/gopath} GONOSUMDB=* GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./...)' _ {} || exit 1
	$(MAKE) test-signal-ingest-frostdb
	@echo "=== [Offline 2/5] Frontend Vitest Suites (162 files across dashboard, design-system, harness-dash) ==="
	$(MAKE) test-dashboard-weave
	cd d2-signalloom/apps/dashboard-signalloom && bun run test -- --run
	cd d2-signalloom/design-system-demo && bun run test
	cd tools/harness-dash && bun test
	@echo "=== [Offline 3/5] Python Unit & Invariant Suites ==="
	cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=$${UV_CACHE_DIR:-/tmp/uv-cache} uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests -q --disable-warnings
	UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=$${UV_CACHE_DIR:-/tmp/uv-cache} bash d2-signalloom/test/audit-guard-reintroduction-proof.sh
	$(MAKE) -C d2-agent-trust test
	$(MAKE) -C olly-replica authz-test
	cd olly-replica/apps/sentinel && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=$${UV_CACHE_DIR:-/tmp/uv-cache} uv run --python 3.12 --with-requirements requirements.txt python -m pytest tests -q
	$(MAKE) -C d2-signalloom/apps/netassert-controller test
	cd d2-signalloom/apps/fake-integration-proxy && python3 -m unittest discover -s test
	@echo "=== [Offline 4/5] KPAI Probe & Contract Tests (76 tests) ==="
	$(MAKE) test-kpai
	@echo "=== [Offline 5/5] Static Config, Manifests, Registries & Guards ==="
	bats test/acceptance-spec-coverage.bats
	bats d2-signalloom/test/bats-registry-coverage.bats
	$(MAKE) test-sler-multiplane-acceptance
	bats test/sler-p6-3-multiplane-acceptance.bats
	$(MAKE) demo-signalloom-test-config
	$(MAKE) demo-kagent-test-config
	$(MAKE) demo-cpai-test-config
	$(MAKE) demo-bao-test-config
	$(MAKE) demo-agent-trust-test-config
	$(MAKE) demo-osramp-test-config
	$(MAKE) demo-olly-test-config
	$(MAKE) test-zot-cache
	$(MAKE) test-demo-lifecycle
	$(MAKE) test-node-doctor
	$(MAKE) test-cosign-signing-consistency
	$(MAKE) test-ci-build-parity
	$(MAKE) test-kind-load-verified
	$(MAKE) test-deployed-staleness
	$(MAKE) test-supervise-port-forward
	$(MAKE) test-sfdp-p3-3-root-wiring
	$(MAKE) check-flux-dynamic-labels-test
	$(MAKE) demo-signalloom-supercred-images-test
	$(MAKE) test-signalfusion-images
	$(MAKE) demo-signalloom-supercred-evidence-test
	$(MAKE) test-bao-spire-proof-harness
	$(MAKE) test-revocation-demo-safety
	$(MAKE) test-ci-lock
	$(MAKE) test-ci-state
	$(MAKE) test-ci-path-anchoring
	$(MAKE) test-ui-typography
	$(MAKE) audit-anchor-test
	$(MAKE) test-signalfusion-bats
	$(MAKE) test-tetragon-bats
	$(MAKE) test-tetragon-stream
	bats d2-signalloom/test/olly-secret-argv.bats
	./scripts/signalloom-api-test.sh contract
	./scripts/signalloom-api-test.sh integration
	bats test/test-count-floor.bats
	@echo "=== [Offline] All offline test suites passed successfully! ==="


test-eap-offline: ## Run the EAP gate: four EAP pytest files + test_audit_provenance.py (SP-1 runner), then authz-suite-liveness and api-route-liveness bats. Green as of the SLSEC integration of P2-1/P2-2 (EAP routers behind authenticated_principal).
	@# EAPR-P1-3. One command every EAP card and governor cites (SP-2). Kept FLAT:
	@# no recursive make line, so `make -n test-eap-offline` prints rather than
	@# executes, and no trailing tail/echo, so the first non-zero status propagates.
	@# The five pytest files and both bats suites are unconditional — a red
	@# test_audit_provenance.py is the first card on every board, never an exemption.
	@# Both stages always run so one invocation reports the WHOLE red set (P2
	@# measures its delta against it); the exit status is the first stage that failed.
	@status=0; \
	(cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=$${UV_CACHE_DIR:-/tmp/uv-cache} uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with-requirements requirements.txt python -m pytest tests/test_tenant_isolation.py tests/test_scenario_seeding.py tests/test_environment_routing.py tests/test_environment_lifecycle.py tests/test_audit_provenance.py tests/test_eap_adversarial.py -q) || status=$$?; \
	bats d2-signalloom/test/authz-suite-liveness.bats d2-signalloom/test/api-route-liveness.bats d2-signalloom/test/eap-ingress-reconcile.bats || { s=$$?; [ $$status -ne 0 ] || status=$$s; }; \
	bash scripts/eap/test_tailscale_eap_env.sh || { s=$$?; [ $$status -ne 0 ] || status=$$s; }; \
	exit $$status
	@# EAPR-P3-1 uncomments the next line once d2-signalloom/test/eap-netpol.bats exists,
	@# appending it to the bats line above so its status joins the same chain.
	@# bats d2-signalloom/test/eap-netpol.bats

test-all-cluster: ## Run all live Kind cluster tests across all slices.
	@echo "=== [Cluster] Live Kind Cluster Slices & Runtime Tests ==="
	$(MAKE) test
	$(MAKE) demo-signalloom-runtime-test
	bats d2-k8s-afm/test/afm-smoke.bats
	$(MAKE) demo-cpai-test
	$(MAKE) demo-cpai-conversation
	$(MAKE) demo-agent-trust-test
	$(MAKE) demo-agent-trust-network-test
	$(MAKE) demo-bao-test
	$(MAKE) demo-kagent-test
	$(MAKE) demo-olly-test
	$(MAKE) test-tetragon-stream
	@echo "=== [Cluster] All cluster test suites passed successfully! ==="

test-all-browser: ## Run all Playwright browser acceptance tests across all slices.
	@echo "=== [Browser 1/3] Standalone Harness Browser Specs ==="
	$(MAKE) demo-signalloom-supercred-stream-harness
	$(MAKE) demo-signalloom-coding-agent-topology
	@echo "=== [Browser 2/3] Core & Feature Browser Specs ==="
	ADOPT_GATEWAY_FORWARD=1 PW_CHANNEL=chromium PLAYWRIGHT_BROWSERS_PATH=/tmp/ms-playwright ./scripts/acceptance-test.sh smoke.spec.ts docs.spec.ts live-data.spec.ts kagent-agents.spec.ts signalloom-login.spec.ts cloudaudit-dashboard.spec.ts distance-latency.spec.ts agent-drilldown-and-selectors.spec.ts signal-loom-baoaudit.spec.ts signal-loom-netebpf.spec.ts who-authorized.spec.ts agent-activity-timeline.spec.ts signalloom-test-1.spec.ts
	@echo "=== [Browser 3/3] AFM Browser Specs ==="
	ADOPT_GATEWAY_FORWARD=1 PW_CHANNEL=chromium PLAYWRIGHT_BROWSERS_PATH=/tmp/ms-playwright ./scripts/acceptance-test.sh afm-frontend.spec.ts afm-integration.spec.ts rbac-analysis.spec.ts rbac-explorer.spec.ts
	@echo "=== [Browser] All browser acceptance tests passed successfully! ==="

# ─── Signal Fusion / Weave unit tests ───────────────────────────────────────
# All targets below run offline — no cluster, no network, no API key.
# The Go tests include FrostDB (build-tag gated) and the full store contract
# suite. The dashboard tests run vitest with jsdom against the Weave, Signal
# Fusion, and weaveApi test files.

.PHONY: test-signal-ingest test-signal-ingest-frostdb test-dashboard-weave test-signalfusion-bats test-signal-fusion
.PHONY: test-tetragon test-tetragon-bats test-tetragon-stream
.PHONY: test-signal-segment-verifier verify-signal-segments
.PHONY: test-identity-rls-live

test-signal-ingest: test-signal-segment-verifier ## Run Go signal-ingest unit tests (memory store, model, api, correlation).
	cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./... -v -count=1

test-signal-ingest-frostdb: test-signal-segment-verifier ## Run Go signal-ingest tests INCLUDING FrostDB store.
	cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test -tags frostdb ./... -v -count=1

# SLDP-P2-2: tenant isolation is a SERVER behaviour, so the only evidence that counts comes from a
# server. This target stands one up, runs the hostile-context suite against it, and tears it down.
# Without it the identity suite asserts on migration text, which passes identically whether the
# policies deny anything or not.
IDENTITY_RLS_PG_CONTAINER ?= sldp-identity-rls-pg
IDENTITY_RLS_PG_PORT ?= 55432
IDENTITY_RLS_PG_IMAGE ?= postgres:16-alpine

test-identity-rls-live: ## Run the SLDP-P2-2 hostile-context row-level-security suite against a real PostgreSQL.
	@docker rm -f $(IDENTITY_RLS_PG_CONTAINER) >/dev/null 2>&1 || true
	@docker run -d --name $(IDENTITY_RLS_PG_CONTAINER) \
		-e POSTGRES_PASSWORD=devpass -e POSTGRES_DB=signalloom \
		-p $(IDENTITY_RLS_PG_PORT):5432 $(IDENTITY_RLS_PG_IMAGE) >/dev/null
	@# pg_isready goes green against the entrypoint's TEMPORARY server during initdb, so polling it
	@# reports ready seconds before the real listener exists. Poll a real TCP query instead.
	@for i in $$(seq 1 60); do \
		if docker exec $(IDENTITY_RLS_PG_CONTAINER) psql -U postgres -h 127.0.0.1 -d signalloom -Atc 'select 1' >/dev/null 2>&1; then break; fi; \
		sleep 1; \
	done
	@cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 \
		IDENTITY_TEST_DATABASE_URL='postgres://postgres:devpass@127.0.0.1:$(IDENTITY_RLS_PG_PORT)/signalloom?sslmode=disable' \
		INSECURE_DEV_ALLOW_NOOP_ENCRYPTOR=true \
		go test ./identity/... -run 'TestTenant' -count=1 -v; \
		rc=$$?; docker rm -f $(IDENTITY_RLS_PG_CONTAINER) >/dev/null 2>&1 || true; exit $$rc

# SLDP-P1-3: negative controls and the compiled auditor run in every ingest gate.
test-signal-segment-verifier: ## Verify real writer fixtures, tamper refusal, historical keys, schemas, and auditor CLI.
	cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test -count=1 -run '^TestVerify' ./store/... ./cmd/segment-verify

# For a later phase's actual offline snapshot, not just the verifier self-tests.
# Use the standalone command with repeated -public-key for rotated keyrings.
verify-signal-segments: ## Verify a supplied corpus; requires SIGNAL_VERIFY_{EVIDENCE,ROOT,HIGHWATER,PUBLIC_KEY} absolute paths.
	@test -n "$${SIGNAL_VERIFY_EVIDENCE}" && test -n "$${SIGNAL_VERIFY_ROOT}" && test -n "$${SIGNAL_VERIFY_HIGHWATER}" && test -n "$${SIGNAL_VERIFY_PUBLIC_KEY}" || { echo 'Set all four SIGNAL_VERIFY_* paths; no empty-corpus or audit-only bypass.' >&2; exit 1; }
	cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go run ./cmd/segment-verify -evidence-dir "$${SIGNAL_VERIFY_EVIDENCE}" -segment-root "$${SIGNAL_VERIFY_ROOT}" -highwater "$${SIGNAL_VERIFY_HIGHWATER}" -public-key "$${SIGNAL_VERIFY_PUBLIC_KEY}"

test-dashboard-weave: ## Run Weave, Signal Fusion, and weaveApi vitest suites.
	cd d2-signalloom/apps/dashboard-signalloom && bun install --frozen-lockfile
	node d2-signalloom/apps/dashboard-signalloom/node_modules/vitest/vitest.mjs run \
		--root d2-signalloom/apps/dashboard-signalloom \
		src/pages/WeavePage.test.tsx \
		src/pages/WeavePage.adversarial.test.tsx \
		src/pages/SignalFusionPage.test.tsx \
		src/components/WhoAuthorizedPanel.test.tsx \
		src/api/weaveApi.test.ts \
		--reporter=verbose

test-tetragon: ## Run the Tetragon telemetry collector Go unit suites (offline, no cluster).
	cd d2-signalloom/apps/signal-ingest && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./collectors/ebpf/... -v -count=1
	# test/mocks is a STANDALONE module (see its go.mod). `go test ./...` from the
	# repo root cannot reach it, so it is named explicitly. Dropping this line
	# would silently stop testing the mock server while this target stayed green.
	cd test/mocks && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./... -v -count=1

test-tetragon-stream: ## Run the offline Tetragon end-to-end stream harness and write the evidence artifact.
	./scripts/test-tetragon-stream.sh 1000
	@git checkout -- docs/signalloom/evidence/tetragon-stream-proof.json 2>/dev/null || true

test-tetragon-bats: ## Run the Tetragon enforcement-decoupling + telemetry BATS suite (no cluster required).
	bats test/tetragon-telemetry-stream.bats

test-signalfusion-bats: ## Run Signal Fusion structural BATS tests (no cluster required).
	bats test/signalfusion-demo.bats

test-signal-fusion: test-signal-ingest test-dashboard-weave test-signalfusion-bats ## Run all Signal Fusion / Weave test suites.

.PHONY: test-kpai
test-kpai: ## Run KPAI runtime harness probe tests and contract validation.
	bun test test/unit/kpai-harness-contract.test.ts test/unit/kpai-harness-execution.test.ts

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

.PHONY: deploy demo-signalloom-up demo-signalloom-test-config demo-signalloom-test demo-signalloom-runtime-test demo-signalloom-test-1 demo-signalloom-down
deploy: demo-signalloom-up ## Deploy Signal Loom and configure Dex OIDC to work over Tailscale.
	@set -e; \
	origin="$${ORIGIN:-$${TAILSCALE_ORIGIN:-}}"; \
	if [ -z "$$origin" ] && [ -f .tunnel/url ]; then \
	  origin="$$(cat .tunnel/url)"; \
	fi; \
	if [ -z "$$origin" ] && [ -f .tunnel/ts-fqdn ]; then \
	  origin="https://$$(cat .tunnel/ts-fqdn)"; \
	fi; \
	if [ -z "$$origin" ]; then \
	  origin="https://ftna-signalloom.taild4da3.ts.net"; \
	fi; \
	echo "==> Configuring Dex OIDC origin for Tailscale: $$origin"; \
	./scripts/lib/dex-origin.sh apply tailscale "$$origin"; \
	echo "==> Ensuring dashboard port-forward on port 19080..."; \
	if ! curl -sI --connect-timeout 2 http://127.0.0.1:19080/ >/dev/null 2>&1; then \
	  kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 19080:8080 >/dev/null 2>&1 & \
	  sleep 2; \
	fi; \
	echo "==> Verifying Dex issuer over port-forward..."; \
	issuer=$$(curl -s http://127.0.0.1:19080/dex/.well-known/openid-configuration | jq -r .issuer 2>/dev/null || true); \
	echo "==> Dex issuer is: $$issuer"; \
	echo "==> Signal Loom deployed successfully and Dex configured for Tailscale at $$origin"

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
	# fleet-manager/base became an unconditional member of
	# apps/fe-signalloom/base/kustomization.yaml, so every bring-up now DEPLOYS
	# it — and the same rule applies as for supercred-demo-runner above:
	# always-deployed has to mean always-built. The Deployment uses
	# imagePullPolicy: IfNotPresent against a bare `fleet-manager:local` tag, so
	# without this line a fresh node resolves that tag to docker.io/library and
	# the kubelet reports a pull failure that reads as a registry problem rather
	# than a missing build step. The dashboard's /fleet-api/ proxy has no
	# fallback: a missing fleet-manager is a raw nginx 502 on the Fleet page.
	$(MAKE) demo-signalloom-fleet-image
	SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up
	./scripts/agent-trust-local.sh up
	$(MAKE) demo-signalloom-afm-up
	# ─── The whole-estate assertion, last because it needs everything up ──────
	#
	# check-backends reads nginx.conf's proxy_pass set — which IS the set of
	# backends that must exist — and asserts each one resolves to a Service with
	# ready endpoints. It was written FOR this incident (its header names
	# afm-platform as one of the two motivating cases) and then nothing ever
	# called it outside `make check-backends` and doctor.sh, so it caught the bug
	# it was designed for exactly zero times.
	#
	# Here rather than in a test suite because the tests cannot see this class:
	# unit tests mock fetch, contract tests mock the upstream, and the BATS
	# suites assert manifest CONTENT rather than manifest PRESENCE in a cluster.
	# A backend that was never deployed passes all of them and fails only in a
	# browser.
	$(MAKE) check-backends

# ─── Why this target became fail-closed ──────────────────────────────────────
#
# It used to warn and continue whenever the AFM source checkout was absent, and
# the reasoning was sound at the time: the source was the ONLY way to obtain the
# image, a remote lane could never have it, and taking down an otherwise-healthy
# bring-up over it would have been a worse trade.
#
# That premise is gone. scripts/k8s-afm.sh now accepts a delivered image archive
# as well as a source checkout, and scripts/gcp-tf/demo-up.sh:deliver_afm_image
# ships one to every lane, so "AFM is unavailable here" stopped being a fact
# about the environment and became a fact about this run.
#
# What the warning actually bought was silence. The bring-up went green, the
# lane came up with d2-k8s-afm/ applied and no image behind it, and the ONLY
# place the missing slice ever surfaced was seven nginx locations answering 502
# — usually in a browser, usually in front of an audience. A warning in the
# middle of a twenty-minute log is not a report.
#
# AFM_REQUIRED=0 keeps the old behaviour for the case that is still legitimate:
# a contributor with only this repo cloned, no AFM source and no archive, who
# genuinely wants the rest of the estate. It is opt-IN because that makes it a
# decision somebody made rather than an outcome nobody noticed.
AFM_REQUIRED ?= 1

.PHONY: demo-signalloom-afm-up
demo-signalloom-afm-up: ## Deploy the KubeSec-AFM slice the RBAC pages read. FAILS if no image is obtainable; AFM_REQUIRED=0 downgrades to a warning.
	@if ./scripts/k8s-afm.sh preflight >/dev/null 2>&1; then \
	  $(MAKE) demo-k8s-afm-up; \
	elif [ "$(AFM_REQUIRED)" = "0" ]; then \
	  ./scripts/k8s-afm.sh preflight || true; \
	  echo "WARNING: AFM_REQUIRED=0 — continuing WITHOUT the AFM slice. Signal Loom's"; \
	  echo "         RBAC Explorer will report \"KubeSec-AFM is not deployed\", the RBAC"; \
	  echo "         Analysis page shows its unreachable banner, and /afm/ answers 502."; \
	else \
	  ./scripts/k8s-afm.sh preflight || true; \
	  echo ""; \
	  echo "ERROR: refusing to bring up Signal Loom without the AFM slice."; \
	  echo "       The RBAC Analysis and RBAC Explorer pages read from it, and SEVEN"; \
	  echo "       nginx locations proxy to afm-platform.fe-k8s-afm — /afm/, /dashboard/,"; \
	  echo "       /clusters, /metrics/, /health, /jobs and /webhooks/ would all 502."; \
	  echo "       This used to be a warning, which is why four lanes shipped that way."; \
	  echo ""; \
	  echo "       Provide the image (see the two routes above), or accept the gap"; \
	  echo "       explicitly:  make demo-signalloom-up AFM_REQUIRED=0"; \
	  exit 1; \
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

.PHONY: demo-signalloom-agents-up demo-signalloom-agents-down demo-signalloom-agents-list demo-signalloom-autoclaim demo-signalloom-autoclaim-test
demo-signalloom-agents-up: ## Recreate the demo agent cohort (random Monty Python names; AGENTS=N, default 4).
	N="$(AGENTS)"; ./scripts/signalloom-agents.sh up "$${N:-4}"
demo-signalloom-agents-down: ## Delete the ephemeral demo agent cohort (keeps the Flux baseline agent).
	./scripts/signalloom-agents.sh down
demo-signalloom-agents-list: ## List agents currently in the fe-signalloom-agents namespace.
	./scripts/signalloom-agents.sh list
demo-signalloom-autoclaim: ## Demonstrate agent discovery, auto-claim, compliance posture, and audit evidence.
	./scripts/demo-agent-autoclaim.sh
demo-signalloom-autoclaim-test: ## Run the BATS integration suite guarding in-cluster discovery and auto-claim.
	bats test/signalloom-autoclaim.bats

.PHONY: demo-signalloom-smoke
demo-signalloom-smoke: ## Rapid demo smoke test suite (<90s): cluster health, onboarding wizard, dual-agent claim & telemetry verification.
	./scripts/demo-signalloom-smoke.sh smoke-onboarding-agents.spec.ts

.PHONY: docs-render-check
docs-render-check: ## Build the docs portal, serve it locally, and render-check it in Chromium (docs.spec.ts). No cluster.
	# Deliberately offline. docs/signalloom/slon-p3-docs-portal-provenance.md
	# records that the running docs-signalloom image was published from a
	# different branch and that every Flux source in the demo cluster is an
	# OCIRepository with no git revision, so a probe of the gateway is evidence
	# about a deployed artifact and never about the checked-out tree. This
	# target therefore serves the tree's own build.
	./scripts/docs-render-check.sh docs.spec.ts

.PHONY: docs-lint docs-lint-test docs-rewrite-guard
docs-lint: ## Check every tracked doc by tier: links, anchors, paths, make targets, diagrams, index, and STE rules. No cluster.
	./scripts/docs-lint.sh

docs-lint-test: ## Run the BATS suites for docs-lint, the index sync, and the rewrite guard. No cluster.
	bats test/docs-lint.bats test/docs-index-sync.bats test/docs-rewrite-guard.bats

docs-rewrite-guard: ## Check that a doc rewrite kept every fact-bearing token: make docs-rewrite-guard FILES='a.md b.md'. No cluster.
	./scripts/docs-rewrite-guard.sh $(FILES)

.PHONY: bench-cgroup-freezer bench-tc-drop bench-redteam-stress
bench-cgroup-freezer: ## Run cgroup freezer latency benchmark.
	test/bench-cgroup-freezer.sh

bench-tc-drop: ## Run traffic control packet drop latency benchmark.
	test/bench-tc-drop.sh

bench-redteam-stress: ## Run redteam stress benchmark.
	test/bench-redteam-stress.sh


##@ Live demo population (all agents + mock data in one shot)

.PHONY: demo-signalloom-demo-up
demo-signalloom-demo-up: ## Populate ALL demo data: every Monty Python agent + mock Postgres data.
	./scripts/signalloom-agents.sh up all
	./scripts/signalloom-data.sh mock

##@ Signal Loom data lifecycle (three UI states: demo-toggle / live-empty / mock-populated)

.PHONY: demo-signalloom-data-reset demo-signalloom-data-mock demo-signalloom-api-test demo-agentmaxxing-contract-test demo-agentmaxxing-host-test demo-agentmaxxing-ingest-test demo-agentmaxxing-ui-test demo-agentmaxxing-docs-test demo-agentmaxxing-acceptance-test
demo-signalloom-data-reset: ## Reset data stores to empty defaults (live mode = empty UI). Optional: SERVICE=agents|audit|...
	./scripts/signalloom-data.sh reset $(SERVICE)
demo-signalloom-data-mock: ## Populate data stores with realistic demo data (mock mode = populated UI).
	./scripts/signalloom-data.sh mock
demo-signalloom-api-test: ## Run the consumer-driven contract + integration test suite.
	./scripts/signalloom-api-test.sh $${TIER:-contract}
demo-agentmaxxing-contract-test: ## Run attributable AgentMaxxing operator lifecycle contracts.
	bats test/signalloom/operator-identity.bats
demo-agentmaxxing-host-test: ## Run AgentMaxxing Linux host sensor, confinement, anti-escape, and TOCTOU hasher tests.
	python3 -m unittest discover -s d2-signalloom/apps/agentmaxxing-host-sensor/ -p 'test_*.py'
	PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -p no:libtmux -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k "nono or process or anti_escape or toctou"
	bats test/signalloom/agentmaxxing-host-confinement.bats
	bats test/signalloom/file-validator-anti-escape.bats
	bats test/signalloom/hasher-toctou.bats
	bats test/signalloom/slcd-ci-parity.bats
demo-agentmaxxing-ingest-test: ## Run AgentMaxxing audit session ingest, deduplication, and verification tests.
	cd d2-signalloom/apps/signal-ingest && GOPATH=/tmp/gopath GOMODCACHE=/tmp/gomodcache go test -v ./collectors/agentnono/...
	PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -p no:libtmux -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k "test_idempotency or test_concurrent_upload or test_interrupted_retry or test_ingest_finalized"
	PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -p no:libtmux -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_evidence.py
demo-agentmaxxing-ui-test: ## Run AgentMaxxing timeline vitest tests and interactive demo console Playwright acceptance suite.
	cd d2-signalloom/apps/dashboard-signalloom && bun x vitest run src/components/AgentActivityTab.test.tsx
	cd test/acceptance && bun install --frozen-lockfile && \
		AMXD_DEMO_CONSOLE=1 bunx playwright test agentmaxxing-demo-console.spec.ts \
			--project=agentmaxxing-demo-console
demo-agentmaxxing-docs-test: ## Build docs portal, run Astro diagnostics, audit links, and assert external-agent SVG diagram rendering in Chromium.
	./scripts/docs-render-check.sh docs.spec.ts
demo-agentmaxxing-acceptance-test: ## Run AgentMaxxing end-to-end local onboarding-to-removal acceptance journey.
	bats test/signalloom/agentmaxxing-acceptance-journey.bats
	PYTHONPATH=d2-signalloom/apps/fe-signalloom/src python3 -m pytest -p no:libtmux -o cache_dir=/tmp/pytest_cache_fe -v d2-signalloom/apps/fe-signalloom/src/tests/test_agentmaxxing_acceptance_journey.py

.PHONY: local-sensor-status local-sensor-scan local-sensor-watch
local-sensor-status: ## Probe local workstation sensor prerequisites and Tailscale reachability.
	./scripts/sensor/run-workstation-sensor.sh status

local-sensor-scan: ## Scan host process table for active coding agent harnesses (Claude, Agy, Cline).
	./scripts/sensor/run-workstation-sensor.sh scan

local-sensor-watch: ## Continuously observe and sample local coding agent processes.
	./scripts/sensor/run-workstation-sensor.sh watch

.PHONY: signalloom-wire-contract-emit signalloom-wire-contract-check signalloom-wire-contract-test
signalloom-wire-contract-emit: ## SLCD-P1-3: regenerate the codingagent.v1 Go, Python and OpenAPI artefacts from the frozen schema.
	python3 d2-signalloom/apps/agentmaxxing-host-sensor/scripts/gen_wire_contract.py --emit
	python3 d2-signalloom/apps/agentmaxxing-host-sensor/scripts/build_differential_corpus.py --emit
signalloom-wire-contract-check: ## SLCD-P1-3: fail if any generated codingagent.v1 artefact drifted from the schema.
	python3 d2-signalloom/apps/agentmaxxing-host-sensor/scripts/gen_wire_contract.py --check
	python3 d2-signalloom/apps/agentmaxxing-host-sensor/scripts/build_differential_corpus.py --check
signalloom-wire-contract-test: signalloom-wire-contract-check ## SLCD-P1-3: run both halves of the codingagent.v1 contract suite.
	cd d2-signalloom/apps/signal-ingest && go test ./... -run CodingAgentWireContract
	cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py'
	rg -n 'location /api/' d2-signalloom/apps/dashboard-signalloom/nginx.conf

.PHONY: demo-signalloom-dex-origin-set demo-signalloom-dex-origin-status demo-signalloom-dex-origin-restore
demo-signalloom-dex-origin-set: ## Set and apply Dex public origin and callback URIs (ORIGIN=<url> [METHOD=tailscale|ngrok|iap]).
	@if [ -z "$(ORIGIN)" ]; then \
		echo "ERROR: ORIGIN is required. Example: make demo-signalloom-dex-origin-set ORIGIN=https://ftna-signalloom.taild4da3.ts.net"; \
		exit 1; \
	fi
	./scripts/lib/dex-origin.sh apply "$${METHOD:-tailscale}" "$(ORIGIN)"

demo-signalloom-dex-origin-status: ## Show current Dex public origin, lease holder, and OIDC state.
	./scripts/lib/dex-origin.sh status

demo-signalloom-dex-origin-restore: ## Restore Dex public origin and callbacks to default baseline.
	./scripts/lib/dex-origin.sh restore

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

.PHONY: demo-signalloom-workspace-up test-workspace-acceptance
demo-signalloom-workspace-up: ## Deploy the Google Workspace agentic identity connector (mock/live Reports API polling).
	@echo "Starting workspace-connector for Signal Loom Demo 4..."
	@(cd d2-signalloom/apps/workspace-connector && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./...)

test-workspace-acceptance: ## Run the complete Workspace Agentic Identity Streaming acceptance test suite.
	bats test/workspace-identity-streaming.bats
	(cd d2-signalloom/apps/workspace-connector && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test ./...)

.PHONY: test-sler-multiplane-acceptance
test-sler-multiplane-acceptance: ## SLER-P6-3: end-to-end multi-plane containment acceptance suite (offline, no cluster).
	@# The Go half drives one containment decision across all five enforcement
	@# planes and asserts each PlaneResult individually; the bats half proves the
	@# Go half's plane coverage is derived from AllEnforcementPlanes() and that
	@# this very target is reachable from CI. Both halves are required: a derived
	@# guard nobody runs is the defect it was written to prevent, one level up.
	cd d2-signalloom/apps/fleet-manager && env GOCACHE=$${GOCACHE:-/tmp/gocache} GOMODCACHE=$${GOMODCACHE:-/tmp/gomodcache} CGO_ENABLED=0 go test -run 'TestAcceptance' -count=1 -v .
	bats test/sler-p6-3-multiplane-acceptance.bats

.PHONY: factory-schemas-validate factory-appraisal-test
factory-schemas-validate: ## Validate AI-Governed Software Factory JSON schemas.
	@for f in d2-signalloom/governance/schemas/*.v1.json; do python3 -m json.tool "$$f" >/dev/null && echo "✓ $$f is valid"; done

factory-appraisal-test: ## Run the complete AI-Governed Software Factory governance and appraisal test suite.
	bats test/software-factory-governance.bats
	(cd d2-signalloom/apps/factory-appraiser && go test ./...)

.PHONY: check-ci-build-parity
check-ci-build-parity: ## Fail if CI omits a build or activation step demo-signalloom-up runs (no cluster required).
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

.PHONY: test-supervise-port-forward test-signalloom-portforward
test-supervise-port-forward: ## Verify port-forward supervision against fake kubectl/curl clients (no cluster required).
	bats test/supervise-port-forward.bats

test-signalloom-portforward: ## Verify systemd user service portforward and automatic pod recovery (cluster required).
	./scripts/verify-portforward-service.sh
	bats test/signalloom-portforward.bats


.PHONY: demo-signalloom-supercred-runtime-test demo-signalloom-supercred-api-test
demo-signalloom-supercred-runtime-test: ## Probe Cardvault and agent-cardvault after explicit SuperCred step 1 (cluster required; does not deploy).
	bats d2-signalloom/test/supercred-step1-runtime.bats

demo-signalloom-supercred-api-test: ## Probe the live /demo-api/ authorization boundary with real Dex tokens (cluster required).
	bats d2-signalloom/test/supercred-demo-api.bats

# The other two d2-signalloom opt-outs, which until now had no owner at all.
#
# EXCLUDED_BATS took dashboard-image.bats and supercred-demo.bats out of the
# `make -C d2-signalloom test` glob and each carries a careful reason paragraph
# saying where it belongs instead — "with the image stages", "with the runtime
# stages, which already port-forward for it". Neither relocation was ever
# performed. Measured across the whole tree, the only non-comment occurrence of
# either basename was the EXCLUDED_BATS line removing them: two suites written,
# reviewed, documented, opted out with a stated destination, and then invoked by
# nothing whatsoever.
#
# That is precisely the defect d2-signalloom/test/bats-registry-coverage.bats
# exists to end, sitting inside the mechanism meant to end it — an exclusion
# comment that describes a move nobody made reads as a decision and functions as
# a deletion. The new test in that suite ("every excluded d2-signalloom bats
# suite is invoked by another runner") is what makes the omission impossible to
# repeat; these two targets are what make it true today.
#
# A Makefile target, not a CI stage, and deliberately so. Both suites need
# preconditions CI does not establish — docker plus a populated .keys/ for one,
# a live policy-engine on localhost:18081 for the other — and inventing a stage
# that appears to satisfy them would repeat the original error one level up.
# The repo's standard is already this: bats-registry-coverage.bats accepts that
# "a script legitimately invoked from a Makefile target is covered too — it need
# not be a CI stage."
.PHONY: test-dashboard-image test-supercred-demo
test-dashboard-image: ## Build the dashboard image and probe it on a host port (docker + populated .keys/ required).
	bats d2-signalloom/test/dashboard-image.bats

test-supercred-demo: ## Drive the SuperCred demo against a live policy-engine on localhost:18081 (cluster + port-forward required).
	bats d2-signalloom/test/supercred-demo.bats

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

.PHONY: demo-signalloom-coding-agent-topology
demo-signalloom-coding-agent-topology: ## Run browser acceptance tests for coding agent topology rendering (no cluster required).
	cd test/acceptance && bun install --frozen-lockfile && \
		bunx playwright test coding-agent-topology.spec.ts \
			--project=coding-agent-topology

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

##@ Kagent Cloud-Native AI Agents (D5 — CNCF Agent Framework)

.PHONY: swarm-kagent-up swarm-kagent-down demo-kagent-up demo-kagent-down demo-kagent-test demo-kagent-demo demo-kagent-test-config
swarm-kagent-up: ## Install the upstream Kagent 0.9.9 charts (controller, tools, UI, PostgreSQL, kmcp). ENABLE_OBSERVABILITY=true adds grafana-mcp, querydoc and observability-agent.
	ENABLE_OBSERVABILITY="$(ENABLE_OBSERVABILITY)" ./scripts/kagent-infra.sh up
swarm-kagent-down: ## Uninstall the Kagent release and namespace. CRDs are left in place (removing them cascades to every Agent CR).
	ENABLE_OBSERVABILITY="$(ENABLE_OBSERVABILITY)" ./scripts/kagent-infra.sh down
demo-kagent-test-config: ## Statically validate the Kagent namespace overlay, the upstream chart render, and the agent overlays without a cluster.
	@kubectl kustomize d2-signalloom/infra/kagent/local >/dev/null
	# The chart render is the half `kubectl kustomize` no longer covers. Once the
	# control plane came from Helm rather than from base/*.yaml, a values file
	# that fails to render — or renders something other than what it claims —
	# was invisible to every static check in this target.
	@helm template kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
		--version 0.9.9 --namespace kagent \
		-f d2-signalloom/infra/kagent/values.yaml >/dev/null
	@helm template kagent oci://ghcr.io/kagent-dev/kagent/helm/kagent \
		--version 0.9.9 --namespace kagent \
		-f d2-signalloom/infra/kagent/values.yaml \
		-f d2-signalloom/infra/kagent/values-observability.yaml >/dev/null
	@for d in d2-signalloom/infra/agent-swarm/kagent-*; do [ -d "$$d" ] && kubectl kustomize "$$d" >/dev/null; done
	bats d2-signalloom/test/kagent-contract.bats
	bats d2-signalloom/test/kagent-chart.bats
demo-kagent-up: ## Deploy all 8 Kagent agents (K8s Reader, Commit Summariser, Security Analyst, Network Auditor, Incident Responder, Compliance Checker, FinOps Optimizer, Chaos Prober).
	./scripts/kagent-agents.sh deploy
demo-kagent-down: ## Remove all Kagent agents.
	./scripts/kagent-agents.sh destroy
demo-kagent-test: ## Run Kagent agent and infrastructure test suite.
	./scripts/kagent-test.sh
demo-kagent-demo: ## Run the interactive Kagent D5 walkthrough demo.
	./scripts/kagent-demo.sh

.PHONY: demo-kagent-credentials demo-kagent-credentials-verify demo-kagent-invoke

# Reads ANTHROPIC_API_KEY from .env at the MAIN checkout root (gitignored), or
# from the environment, which takes precedence. Resolved via git rather than
# $$PWD so it works from a linked worktree, where .env does not exist.
#
# No-ops with guidance when no key is configured, matching olly-llm-secret.sh:
# a missing optional credential must not break `make up`. The loud failure is in
# demo-kagent-invoke, where the key is genuinely required.
demo-kagent-credentials: ## Store ANTHROPIC_API_KEY (.env or environment) in OpenBao and project it into the kagent Secret.
	./scripts/kagent-credentials.sh seed
	./scripts/kagent-credentials.sh sync
	./scripts/kagent-credentials.sh verify

demo-kagent-credentials-verify: ## Show credential path, presence and length in OpenBao and Kubernetes. Never prints the key.
	./scripts/kagent-credentials.sh verify

AGENT ?= kagent-k8s-reader
PROMPT ?= List every namespace in this cluster, then tell me how many there are.
demo-kagent-invoke: ## Invoke one agent through kagent's A2A endpoint. AGENT=<name> PROMPT="<task>"
	@if [ -z "$(strip $(AGENT))" ]; then \
	  echo "ERROR: AGENT is empty. Usage: make demo-kagent-invoke AGENT=kagent-k8s-reader PROMPT=\"...\"" >&2; exit 1; fi
	@if [ -z "$(strip $(PROMPT))" ]; then \
	  echo "ERROR: PROMPT is empty. Usage: make demo-kagent-invoke AGENT=kagent-k8s-reader PROMPT=\"...\"" >&2; exit 1; fi
	./scripts/kagent-invoke.sh --agent '$(AGENT)' --prompt '$(PROMPT)'

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
attested-test: signing-keys ## Run audit tests or the real FrostDB segment proof (ATTESTED_TEST_SOURCE=audit|segments).
	ATTESTED_TEST_SOURCE=$(ATTESTED_TEST_SOURCE) ./scripts/attested-test.sh

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
	strict="$${AUDIT_ANCHOR_REQUIRE_LOG:-}"; \
		[ -z "$${ARCHIVISTA_URL:-}" ] || strict=1; \
		cd $(AUDIT_ANCHOR_SRC) && AUDIT_ANCHOR_REQUIRE_LOG="$$strict" $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--private-key $(AUDIT_ANCHOR_KEYS)/witness.pem \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem $(ARGS) checkpoint $(COMMAND_ARGS)

.PHONY: audit-anchor-verify
audit-anchor-verify: signing-keys ## Verify the audit trail against its anchors (exit 2 = DIVERGED).
	expected=$$(jq -er '.expected_key_ids | if length == 1 then .[0] else error("expected exactly one signer") end' $(AUDIT_ANCHOR_KEYS)/segment-signing-policy.json); \
		strict="$${AUDIT_ANCHOR_REQUIRE_LOG:-}"; \
		[ -z "$${ARCHIVISTA_URL:-}" ] || strict=1; \
		cd $(AUDIT_ANCHOR_SRC) && AUDIT_ANCHOR_REQUIRE_LOG="$$strict" $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem \
		--expected-key-id "$$expected" $(ARGS) verify $(COMMAND_ARGS)

.PHONY: audit-anchor-show
audit-anchor-show: ## List the published audit-trail anchors.
	strict="$${AUDIT_ANCHOR_REQUIRE_LOG:-}"; \
		[ -z "$${ARCHIVISTA_URL:-}" ] || strict=1; \
		cd $(AUDIT_ANCHOR_SRC) && AUDIT_ANCHOR_REQUIRE_LOG="$$strict" $(AUDIT_ANCHOR_PY) -m audit_anchor \
		--public-key $(AUDIT_ANCHOR_KEYS)/witness-pub.pem $(ARGS) show $(COMMAND_ARGS)

.PHONY: audit-anchor-tamper-demo
audit-anchor-tamper-demo: signing-keys ## Prove real audit or FrostDB tamper detection (AUDIT_ANCHOR_TAMPER_SOURCE=audit|segments|all).
	KEYS_DIR=$(KEYS_DIR) PYTHON=$(AUDIT_ANCHOR_PY) ./scripts/audit-anchor-tamper-demo.sh

.PHONY: test-sfdp-p3-3-root-wiring
test-sfdp-p3-3-root-wiring: ## Verify local SFDP-P3-3 root script gates without cluster access.
	bats test/sfdp-p3-3-root-wiring.bats

.PHONY: test-sfdp-p4-4-tamper-regression
test-sfdp-p4-4-tamper-regression: signing-keys ## Verify SFDP-P4-4 witness verify and tamper regression suite.
	bats test/sfdp-p4-4-tamper-regression.bats

.PHONY: test-ui-typography
test-ui-typography: ## Run the UI typography and em-dash eradication lint gate.
	bats d2-signalloom/test/lint-ui-typography.bats

.PHONY: audit-anchor-test
audit-anchor-test: ## Run the audit-anchor unit tests (no cluster required).
	cd $(AUDIT_ANCHOR_SRC) && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 \
		$(AUDIT_ANCHOR_PY) -m pytest -o addopts="" -q tests/test_audit_anchor_*.py

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

# ── The NODE doctors ────────────────────────────────────────────────────────
#
# `doctor` above inspects the machine it is RUN ON — the current kubectl context
# plus the local docker. It has no lane concept, so from here it cannot reach
# any of the four lanes; it is run on the VM by the pipeline. These are
# addressed by ENV and reach the lane over IAP, and they cover what cluster-debug
# does not: gcloud (instance status, the lane-kind contract), tailscale, systemd,
# disk headroom, a REAL zot blob push, and the AFM cluster count. The gap list
# with its measurements is at the head of scripts/node-doctor.sh.
#
# ─── Why these are named `doctor-node*` and not `gcp-tf-doctor-node` ────────
#
# They take ENV and they reach the cloud, so on that axis they belong to the
# gcp-tf-* family and they reuse its guards verbatim. But the question an
# operator has is "what is wrong with this thing", and the answer to that
# question in this repo starts with `doctor`. Sitting next to `doctor` is worth
# more than sitting next to `gcp-tf-status`, because the discoverability that
# matters is at the moment something is broken.
#
# The guards ARE the family's: gcp_tf_require_env rejects a malformed key with
# the same message as its eleven siblings, and gcp_tf_require_impersonation
# refuses to run as a user identity. Two spellings of "is ENV valid" drift the
# moment one of them is corrected.
# Offline, ~2s, no cloud and no cluster. The node doctor's adjudicators are pure
# functions of the probe's text output, which is what makes states like an
# unlinked zot blob store or a drifted MagicDNS name testable at all.
.PHONY: test-node-doctor
test-node-doctor: ## Verify the node doctor's adjudicators against recorded probe output (no cloud, no cluster).
	bats test/node-doctor.bats

# Proves that suite can fail. It mutates the real node-doctor scripts in place
# and requires the suite to go RED at a NAMED test for each of 15 breakages.
# Run it alone — a concurrent edit in the same checkout lands inside a mutation
# window and reads exactly like a real finding.
.PHONY: test-node-doctor-proof
test-node-doctor-proof: ## Prove test/node-doctor.bats can go RED (mutates the tree in place; run it alone).
	./test/node-doctor-mutation-proof.sh

.PHONY: doctor-node
doctor-node: ## Node-level health check for one lane: VM, tailnet, docker, kind, zot push, AFM clusters (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x './scripts/node-doctor.sh' ]; then \
		echo "ERROR: ./scripts/node-doctor.sh is missing or not executable."; \
		exit 2; \
	fi
	@./scripts/node-doctor.sh '$(ENV)'

# Sweeps every lane that has a handoff file, and does NOT stop at the first
# fault. On a four-lane estate the second broken lane is most of the value, and
# a sweep that exits early makes it invisible.
#
# The per-lane verdict is read off the `NODE-DOCTOR <env> <kind> <verdict>` line
# each run emits as its last line — a machine-readable contract, so the human
# prose above it stays free to be reworded without breaking the sweep.
.PHONY: doctor-node-all
doctor-node-all: ## Run the node doctor against EVERY lane with a handoff file; reports all, fails if any failed.
	$(gcp_tf_require_impersonation)
	@if [ ! -x './scripts/node-doctor.sh' ]; then \
		echo "ERROR: ./scripts/node-doctor.sh is missing or not executable."; \
		exit 2; \
	fi
	@set -o pipefail; ./scripts/node-doctor.sh --all 2>&1 | tee /tmp/doctor-node-all.$$$$.log; rc=$$?; \
	 echo; \
	 echo "──────── lane verdicts ────────"; \
	 grep '^NODE-DOCTOR ' /tmp/doctor-node-all.$$$$.log || echo "  (no lane emitted a verdict line — the sweep did not complete)"; \
	 rm -f /tmp/doctor-node-all.$$$$.log; \
	 exit $$rc

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
acceptance-test: ## Run browser-driven acceptance tests (Playwright). Pass DASHBOARD_URL=<url> to target a remote endpoint.
	@DASHBOARD_URL="$${DASHBOARD_URL:-$(DASHBOARD_URL)}" \
	./scripts/acceptance-test.sh $(ARGS)

##@ Remote & Public access (Tailscale)
# SignalLoom uses a contract-first Dex single-issuer lease mechanism.
# Only one origin (Funnel, Serve, or IAP) can publish at a time.
# If a lease collision occurs:
#   1. Check status:   make public-status  (or make serve-status)
#   2. Release lease:  make public-down    (or make serve-down)
#   3. Bring up:       make public         (or make serve)

.PHONY: serve
serve: ## Expose SignalLoom on the Tailnet via Tailscale serve (ORIGIN=<url>, default https://ftna-signalloom.taild4da3.ts.net).
	@set -e; \
	origin="$(ORIGIN)"; \
	if [ -z "$$origin" ] && [ -f .tunnel/url ]; then origin="$$(cat .tunnel/url)"; fi; \
	if [ -z "$$origin" ] && [ -f .tunnel/ts-fqdn ]; then origin="https://$$(cat .tunnel/ts-fqdn)"; fi; \
	if [ -z "$$origin" ]; then origin="https://ftna-signalloom.taild4da3.ts.net"; fi; \
	echo "==> Configuring Dex origin and Tailscale serve for: $$origin"; \
	./scripts/lib/dex-origin.sh apply tailscale "$$origin"; \
	ORIGIN="$$origin" ./scripts/public-tunnel.sh serve || { \
	  echo "==> Note: Tailscale CLI serve returned non-zero (may be managed externally)."; \
	  echo "==> Verifying Dex issuer over local port-forward..."; \
	  curl -s http://127.0.0.1:19080/dex/.well-known/openid-configuration | jq .issuer || true; \
	}; \
	echo "==> Signal Loom serve active with Dex origin: $$origin"

.PHONY: serve-down
serve-down: ## Stop serving on the Tailnet and release Dex origin lease.
	./scripts/public-tunnel.sh serve-down

.PHONY: serve-status
serve-status: ## Show Tailscale serve status, MagicDNS URL, and Dex lease.
	@./scripts/public-tunnel.sh status || true

.PHONY: funnel
funnel: ## Expose SignalLoom to the public internet via Tailscale Funnel.
	./scripts/public-tunnel.sh funnel

.PHONY: funnel-down
funnel-down: ## Remove public Funnel listener (leaves Tailnet serve active).
	./scripts/public-tunnel.sh funnel-down

.PHONY: funnel-status
funnel-status: ## Show Tailscale Funnel status and public URL.
	@./scripts/public-tunnel.sh status || true

.PHONY: public
public: ## Expose SignalLoom publicly via Tailscale Funnel (alias for 'funnel').
	./scripts/public-tunnel.sh funnel

.PHONY: public-down
public-down: ## Tear down Tailscale Funnel and Serve, restore Dex config.
	./scripts/public-tunnel.sh down

.PHONY: public-status
public-status: ## Show public tunnel / Tailscale status and URL.
	@./scripts/public-tunnel.sh status || true

.PHONY: public-test
public-test: ## Run acceptance tests against the active public/serve URL.
	@url=$$(./scripts/public-tunnel.sh url) || { echo "No tunnel running; run 'make serve' or 'make funnel' first"; exit 1; }; \
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
	docker build -f d2-signalloom/apps/fleet-manager/Dockerfile -t fleet-manager:local d2-signalloom/apps
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh fleet-manager:local


demo-signalloom-fleet-up: demo-signalloom-fleet-image ## TEST ESCAPE HATCH ONLY — Flux owns Fleet Manager; use demo-signalloom-up.
	# Flux is the deploy path. fleet-manager/base is reconciled by the
	# signalloom-apps Kustomization via apps/fe-signalloom/base/kustomization.yaml,
	# and demo-signalloom-up builds the image and brings it up with everything
	# else. This target remains only to iterate on the manifests against a
	# running cluster without waiting for a reconcile.
	#
	# It is NOT equivalent to the Flux path and must not be mistaken for it:
	# the fe-signalloom-agents Role and RoleBinding are no longer in this
	# directory (they are in the signalloom-infra ResourceSet), so an apply from
	# here produces a fleet-manager with no grant on the agent namespace.
	# Whatever it writes, Flux reverts on the next reconcile.
	@echo "WARNING: hand-applying a Flux-managed slice. Flux reverts this on the"
	@echo "         next reconcile, and the cross-namespace RBAC is NOT applied."
	kubectl apply -k d2-signalloom/apps/fleet-manager/base
	kubectl -n fe-signalloom rollout status deploy/fleet-manager --timeout=180s

demo-signalloom-fleet-down: ## Remove the hand-applied Fleet Manager (Flux restores it on the next reconcile).
	kubectl delete -k d2-signalloom/apps/fleet-manager/base --ignore-not-found

.PHONY: swarm-cpai-engineer-image swarm-daytona-coder-image swarm-coding-images
swarm-cpai-engineer-image: ## Build and kind-load the cpai-engineer image (Tier 4A in-cluster sandboxed coding).
	docker build -t cpai-engineer:local d2-signalloom/apps/cpai-engineer
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh cpai-engineer:local

swarm-daytona-coder-image: ## Build and kind-load the hosted-daytona-coder workspace manager image (Tier 4B).
	docker build -t hosted-daytona-coder:local d2-signalloom/apps/hosted-daytona-coder
	CLUSTER_NAME=$(CLUSTER_NAME) ./scripts/kind-load-verified.sh hosted-daytona-coder:local

swarm-coding-images: swarm-cpai-engineer-image swarm-daytona-coder-image ## Build both coding harness images.

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

# Real inputs live in deploy/gcp/, OUTSIDE terraform/, and both paths below are
# relative to the -chdir root. This is not a filing preference. Terraform
# auto-loads `terraform.tfvars` and `*.auto.tfvars` from the root directory
# during `terraform test` as well as during plan, so a real tfvars file sitting
# in terraform/environments/ silently overrides the fixture values every native
# test suite asserts against — the suites stay green and stop measuring what
# they claim to. Keeping the real inputs one directory outside any Terraform
# root makes that physically impossible rather than merely discouraged.
GCP_TF_VAR_FILE ?= ../../deploy/gcp/environments.tfvars
GCP_TF_BOOTSTRAP_VAR_FILE ?= ../../deploy/gcp/bootstrap.tfvars

# Every offline terraform invocation runs with cloud credentials stripped from
# the environment. Working gcloud credentials exist on developer machines, so
# "the unit sweep passes here" would otherwise be no evidence at all that it
# passes on a runner with none (ISC-357).
GCP_TF_NOCREDS = env -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_CREDENTIALS \
	-u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_AUTH_ACCESS_TOKEN -u GOOGLE_OAUTH_ACCESS_TOKEN \
	-u GOOGLE_IMPERSONATE_SERVICE_ACCOUNT

# --- Deploy identity: impersonation is how this estate is applied ------------
#
# Terraform runs as a service account, never as the human at the keyboard. The
# human's own principal on this project is roles/editor, which is enough to
# create a VPC and a VM and NOT enough to create the IAM-shaped resources the
# estate needs. The observed failure is the ugly one: the apply gets a long way
# in, dies part-way through with a permission error that names an IAM API, and
# leaves a half-built estate. The error names IAM, so the obvious next move is
# to widen IAM — which is the wrong fix, applied under time pressure, to a
# project that is now in an inconsistent state.
#
# TF_DEPLOY_SA is read from an untracked one-line file so nobody retypes a
# service account email, and so the email — which contains the real project id —
# never lands in a tracked file. GCP_TF_IMPERSONATE defaults to it and is what
# actually gets exported; keeping them separate is what makes "a deploy identity
# is configured for this checkout, and you have blanked it" a detectable state
# rather than an indistinguishable one.
GCP_TF_DEPLOY_SA_FILE ?= deploy/gcp/deploy-sa
TF_DEPLOY_SA ?= $(strip $(shell sed -e 's/#.*//' -e '/^[[:space:]]*$$/d' '$(GCP_TF_DEPLOY_SA_FILE)' 2>/dev/null | head -1))
GCP_TF_IMPERSONATE ?= $(TF_DEPLOY_SA)

# Prefixed onto every terraform invocation in this block. Empty when no
# impersonation target is configured, so the recipe line is unchanged for the
# offline sweeps — and GCP_TF_NOCREDS strips the variable outright, so a
# developer's exported impersonation cannot make the offline suite pass
# differently from a runner that has none.
GCP_TF_IMPERSONATE_ENV = $(if $(strip $(GCP_TF_IMPERSONATE)),GOOGLE_IMPERSONATE_SERVICE_ACCOUNT='$(strip $(GCP_TF_IMPERSONATE))',)

# --- Untracked state in a linked worktree ------------------------------------
#
# Everything above this line that makes a run reach a real estate lives in
# gitignored files. `git worktree add` carries TRACKED content only, so a fresh
# worktree has none of it — and the resulting failures name the wrong subsystem.
#
# The deploy-sa case is the expensive one and it is worth spelling out, because
# the guard immediately above does NOT catch it. gcp_tf_require_impersonation
# refuses only when TF_DEPLOY_SA is non-empty and GCP_TF_IMPERSONATE has been
# blanked — "configured, and you have overridden it". An absent deploy-sa file
# makes TF_DEPLOY_SA empty, which takes the second arm: a WARNING. So the run
# proceeds, terraform applies COMPLETELY and successfully as the human's own
# principal, and the failure lands afterwards in gcp-tf-handoff as
# "the terraform outputs do not carry every value the hand-off contract
# requires ... deploy_sa" — a message whose two suggested causes are both wrong
# here. A full apply cycle is spent before the diagnosis points at outputs.tf.
#
# This guard fires before any of that, and only in a linked worktree: a main
# checkout with no deploy-sa is a legitimate state that the warning above
# correctly covers.
GCP_TF_WORKTREE_SCRIPT ?= scripts/gcp-tf/worktree-bootstrap.sh

#
# FAIL CLOSED on a missing script. An earlier draft made the whole guard
# conditional on `[ -x $(GCP_TF_WORKTREE_SCRIPT) ]`, which reads as defensive
# and is the opposite: with the script absent the guard silently evaluates to
# nothing and gcp-tf-up proceeds into exactly the apply this exists to stop —
# observed, in a worktree where the script had not yet been committed. A guard
# whose absence is indistinguishable from its success is not a guard. This
# matches the neighbouring gcp-tf-ts-* targets, which refuse rather than skip
# when their driver script is missing.
define gcp_tf_require_worktree_state
	@if [ -z '$(strip $(GCP_TF_IMPERSONATE))' ]; then \
		if [ ! -x '$(GCP_TF_WORKTREE_SCRIPT)' ]; then \
			echo "ERROR: $(GCP_TF_WORKTREE_SCRIPT) is missing or not executable, so the"; \
			echo "       worktree-state guard cannot run. Refusing rather than skipping:"; \
			echo "       an unprovisioned worktree applies cleanly and then fails in"; \
			echo "       gcp-tf-handoff blaming $(TF_ROOT_ENV)/outputs.tf."; \
			exit 2; \
		fi; \
		'$(GCP_TF_WORKTREE_SCRIPT)' gate || { \
			echo "       (refused by '$@' before terraform ran, which is the point:"; \
			echo "        without this the apply SUCCEEDS and gcp-tf-handoff then blames"; \
			echo "        $(TF_ROOT_ENV)/outputs.tf for an untracked file's absence.)"; \
			exit 2; \
		}; \
	fi
endef

# The handoff the test code reads. One file, no flags. Untracked: every value in
# it names a real project.
GCP_TF_HANDOFF_DIR ?= deploy/gcp
GCP_TF_HANDOFF_FILE = $(GCP_TF_HANDOFF_DIR)/$(ENV).handoff.json

# The identifier a consumer matches on before trusting the shape. `schema` is
# the string form the acceptance harness reads; `schema_version` is the integer
# to compare when the string matches. Both are emitted because two readers were
# already written against two spellings, and adding a field is cheaper than
# either of them renaming.
GCP_TF_HANDOFF_SCHEMA ?= signalloom.gcp.handoff/v1

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
# Shell mutation proofs owned by the Terraform validation domain. Kept
# overridable so registration tests can record the target without recursively
# running a mutation harness under their fake `bats` binary.
#
# GLOB, not a hand-written list, for the same reason GCP_TF_BATS is one: a proof
# that lands tomorrow must be executed the day it lands, not the day somebody
# remembers to add it here. A mutation proof nobody runs is worse than absent —
# it reads as evidence the guards it covers have been falsified.
#
# The `&&` chain rather than a `for` loop is deliberate. Under `make -n` a loop
# prints as unexpanded loop TEXT, so the recipe becomes unreviewable by a dry
# run and the registration suite can no longer see which proofs are wired in.
# This form expands to the literal command line that will run.
GCP_TF_PROOFS = $(wildcard test/*-mutation-proof.sh)
GCP_TF_PROOFS_RUN ?= $(foreach p,$(GCP_TF_PROOFS),bash $(p) &&) true

# ── Naming is the registration. There is no list to add yourself to. ────────
#
# A new mutation proof is picked up by the wildcard above the moment it is named
# `test/<something>-mutation-proof.sh`. Nothing else is required, and adding a
# hand-registered variable for one is actively harmful: it runs that proof
# TWICE, once via the glob and once via the extra invocation, on a gate that
# already takes ~13 minutes. That is exactly what happened here and it was
# caught in review, not by the gate — a duplicate run is green, just slower.
#
# ─── What is deliberately NOT in this glob, and why ─────────────────────────
#
# test/guard-falsification-proof.sh is a proof and is NOT matched, because it is
# not named `*-mutation-proof.sh`. That exclusion is CORRECT and must survive
# future tidying. It is a ~119KB VM-side harness that proves this repo's guards
# are capable of failing, and it is already run in the two places that can
# actually run it:
#
#   scripts/gcp-tf/demo-pipeline.sh:634   cd ${WORK_DIR} && ./test/guard-falsification-proof.sh
#   scripts/ci/vm-pipeline.sh:807         cd ${WORK_DIR} && ./test/guard-falsification-proof.sh
#
# No make target runs it and none should. `gcp-tf-validate` is the OFFLINE gate
# — no network, no cloud, no cluster — and that harness needs a VM. Widening
# this wildcard to `test/*-proof.sh` would drag it into the offline gate and
# break it. "No make target runs it" is a deliberate design decision here, not
# the unregistered-suite defect it superficially resembles.

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
	@grep -Eq '^(demo|ci)-[1-9][0-9]*$$' <<<'$(ENV)' || { \
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

define gcp_tf_require_bootstrap_var_file
	@if [ ! -f "$(TF_ROOT_BOOTSTRAP)/$(GCP_TF_BOOTSTRAP_VAR_FILE)" ]; then \
		echo "ERROR: bootstrap input file is required for '$@'."; \
		echo "       Expected: $(TF_ROOT_BOOTSTRAP)/$(GCP_TF_BOOTSTRAP_VAR_FILE)"; \
		echo "       Set GCP_TF_BOOTSTRAP_VAR_FILE=<path-relative-to-bootstrap-root>."; \
		exit 2; \
	fi
endef

# Refuse to mutate the estate as a user identity.
#
# The condition is narrow on purpose: it fires when a deploy identity IS
# configured for this checkout (deploy/gcp/deploy-sa names one) and the value
# that actually gets exported is empty. That is the reachable accident — an
# operator overriding GCP_TF_IMPERSONATE= on the command line, a CI job that
# clears the environment, a sub-make that forgot to forward it — and it is
# indistinguishable from "correctly configured" at the point of failure, because
# gcloud will happily authenticate as the human and Terraform will happily
# start.
#
# What it prevents is the half-applied estate. The user principal here holds
# roles/editor, which creates a VPC and a VM and then fails on the first
# IAM-shaped resource. The error names an IAM permission, so the diagnosis it
# invites is "widen IAM" — on a project that is now half-built. The message
# below therefore names impersonation first and IAM second, because the IAM
# error is the symptom and the missing impersonation is the cause.
define gcp_tf_require_impersonation
	@if [ -n '$(strip $(TF_DEPLOY_SA))' ] && [ -z '$(strip $(GCP_TF_IMPERSONATE))' ]; then \
		echo "ERROR: refusing to run '$@' without impersonation."; \
		echo "       A deploy service account is configured for this checkout"; \
		echo "       ($(GCP_TF_DEPLOY_SA_FILE) names one) but GCP_TF_IMPERSONATE is empty,"; \
		echo "       so Terraform would run as your own user identity."; \
		echo; \
		echo "       That does not fail cleanly. Your user principal can create a VPC"; \
		echo "       and a VM and cannot create the IAM-shaped resources, so the apply"; \
		echo "       gets a long way in and then dies with a permission error naming an"; \
		echo "       IAM API — leaving a half-applied estate and inviting the wrong fix"; \
		echo "       (widening IAM) instead of the right one (impersonate the SA)."; \
		echo; \
		echo "       Fix: make $@ ENV=$(ENV) GCP_TF_IMPERSONATE=\$$(cat $(GCP_TF_DEPLOY_SA_FILE))"; \
		echo "       or simply drop the override — it defaults to that file's contents."; \
		exit 2; \
	fi
	@if [ -z '$(strip $(GCP_TF_IMPERSONATE))' ]; then \
		echo "WARNING: no deploy service account is configured — '$@' will run as"; \
		echo "         whatever identity gcloud is currently authenticated as. Write the"; \
		echo "         deploy SA email into $(GCP_TF_DEPLOY_SA_FILE) (untracked) to fix"; \
		echo "         this permanently. See deploy/gcp/README.md."; \
	fi
endef

# CONTRACT §5a mechanism 3. Reads the resolved backend prefix back out of the
# data dir terraform just wrote and refuses to proceed unless it IS the prefix
# ENV derives. This is the mechanism that catches a human editing state by hand,
# and the one that fires if `init` silently reused a cached backend pointer.
#
# The comparison is exact equality, not a substring match. It was written as
# `case "$$resolved" in *"$(ENV)"*)`, which passed for any prefix merely
# CONTAINING the key: `osramp/environments/demo-10` satisfied `ENV=demo-1`.
# Since TF_STATE_PREFIX_BASE is ?=-overridable, so did anything else with the
# key somewhere in it. A hand-edit from demo-1 to demo-10 is precisely the
# mistake this guard exists to catch, and it was the one case it let through —
# while the typed CONFIRM on destroy still matched, because that checks ENV
# against the operator's typing, not against the state the backend resolved to.
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
	if [ "$$resolved" != "$(GCP_TF_PREFIX)" ]; then \
		echo "ERROR: backend prefix mismatch — this is CONTRACT §5a firing."; \
		echo "       resolved prefix: $$resolved"; \
		echo "       expected prefix: $(GCP_TF_PREFIX)"; \
		echo "       ENV:             $(ENV)"; \
		echo "       Terraform would have written $(ENV)'s resources into another"; \
		echo "       environment's state. Re-run 'terraform init -reconfigure'."; \
		exit 3; \
	fi; \
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
# Re-init when EITHER the provider cache or the lock file is missing.
#
# The condition used to test only .terraform/providers, which left a state that
# looks initialised and is not: a populated provider cache with no lock file.
# Terraform needs the lock to choose a version out of that cache, so `validate`
# fails with "Missing required provider" while the guard cheerfully skips init.
# That state is reachable any time lock files are cleaned — which they are,
# because child modules deliberately do not commit one.
define gcp_tf_init_offline
	if [ ! -d "$(1)/.terraform/providers" ] || [ ! -f "$(1)/.terraform.lock.hcl" ]; then \
		echo "    (installing providers — this step, and only this step, needs the registry)"; \
		$(GCP_TF_NOCREDS) $(TF) -chdir=$(1) init -backend=false -input=false >/dev/null; \
	fi
endef

# init -reconfigure with the prefix derived from ENV, followed immediately by
# the readback assertion. Nothing plans or applies without passing through here.
define gcp_tf_init_env
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) init -reconfigure \
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
	$(gcp_tf_require_bootstrap_var_file)
	$(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_BOOTSTRAP) init
	$(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_BOOTSTRAP) plan \
		-var-file=$(GCP_TF_BOOTSTRAP_VAR_FILE) \
		-out=bootstrap.tfplan
	@echo
	@echo "Plan written to $(TF_ROOT_BOOTSTRAP)/bootstrap.tfplan."
	@echo "Review it, then apply by hand:"
	@echo "    $(TF) -chdir=$(TF_ROOT_BOOTSTRAP) apply bootstrap.tfplan"

.PHONY: gcp-tf-plan
gcp-tf-plan: ## Plan one environment to a reviewable saved plan file (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_require_impersonation)
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) plan \
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
	$(gcp_tf_require_impersonation)
	@if [ ! -f "$(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)" ]; then \
		echo "ERROR: no saved plan at $(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)."; \
		echo "       Run: make gcp-tf-plan ENV=$(ENV) TF_STATE_BUCKET=$(TF_STATE_BUCKET)"; \
		echo "       This target applies a reviewed plan file and nothing else. A bare"; \
		echo "       'terraform apply' re-plans at apply time, so what a human read and"; \
		echo "       what Terraform executes are two different plans."; \
		exit 2; \
	fi
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) apply $(GCP_TF_PLAN_FILE)

.PHONY: gcp-tf-status
gcp-tf-status: ## Show one environment's state inventory and outputs, read-only (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_init_env)
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) state list
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) output

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
	$(gcp_tf_require_impersonation)
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
	@# Release the tailnet name BEFORE the VM goes away, because after it is gone
	@# there is nothing left to log out from.
	@#
	@# `terraform destroy` removes the GCP instance and NOTHING removes the
	@# tailnet device record. The corpse keeps owning sl-$(ENV), so the next build
	@# of this environment is handed sl-$(ENV)-1, then -2 — the demo URL drifts
	@# further on every rebuild, and that URL is the deliverable. Measured
	@# 2026-08-18: sl-demo-1 rebuilt as sl-demo-1-1.
	@#
	@# The leading `-` and the driver's own unconditional exit 0 are BOTH
	@# deliberate, and they are not redundant: the `-` covers the driver being
	@# unreachable at all (missing file, non-executable, 127), the driver covers
	@# everything that happens once it starts. A destroy that can be blocked by a
	@# best-effort cleanup is a worse failure than the stale device this prevents.
	@#
	@# The driver is invoked DIRECTLY rather than through `$(MAKE) gcp-tf-ts-logout`.
	@# Recursive make appears nowhere else in this file, and it is the one
	@# construct `make -n` executes anyway instead of printing — so the recursive
	@# form would both break the local convention and make the destroy recipe
	@# unreviewable by a dry run.
	@#
	@# --force is REQUIRED here and its absence would be a silent regression.
	@# The driver refuses to log out a node that is currently serving, because
	@# logout wipes the serve config and leaves a live demo online, correctly
	@# named and serving nothing. Destroying is the sanctioned case for that, so
	@# this caller forces. Without the flag the refusal would fire, the leading
	@# `-` would swallow it, and the logout would be skipped on exactly the
	@# demos most likely to be standing — reintroducing the drift this whole
	@# change exists to fix. Asserted by test/terraform-ts-stable-node-name.bats.
	-@$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ts-logout --force
	TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) destroy \
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
	@# Mutation proof for the Terraform-owned Dex origin contract. This is a shell
	@# script rather than a terraform-*.bats suite, so the dynamic BATS glob cannot
	@# discover it; keep it beside that suite's owning validation target.
	$(GCP_TF_NOCREDS) $(GCP_TF_PROOFS_RUN)

.PHONY: gcp-tf-ci
gcp-tf-ci: ## Plan the CI environment lane (CI=<ci-N>). Delegates to gcp-tf-plan.
	@if [ -z "$(CI)" ]; then \
		echo "ERROR: CI is required for '$@'. Usage: make $@ CI=ci-1"; \
		exit 2; \
	fi
	@grep -Eq '^ci-[1-9][0-9]*$$' <<<'$(CI)' || { \
		echo "ERROR: CI='$(CI)' is not a valid CI environment key (^ci-[1-9][0-9]*\$$)."; \
		echo "       This lane runs CI environments only; use ENV= for a demo."; \
		exit 2; \
	}
	$(MAKE) --no-print-directory gcp-tf-plan ENV=$(CI)

# --- The one target an operator types ---------------------------------------
#
# Everything above stays: the granular targets are how you review a plan, how
# you re-run a single step after fixing one thing, and how the contract tests
# reach individual guards. `gcp-tf-up` is the ordered sequence, so that "how do
# I deploy this" has exactly one answer and that answer cannot skip a step.
#
# Every variable is forwarded explicitly to the sub-makes. Command-line
# variables propagate through MAKEFLAGS on their own, but the ones with a
# computed default (GCP_TF_IMPERSONATE, resolved from an untracked file) do not
# arrive that way — and an impersonation target that silently fails to reach the
# apply is precisely the failure this whole block exists to prevent.
GCP_TF_FORWARD = ENV=$(ENV) TF_STATE_BUCKET=$(TF_STATE_BUCKET) TF_ROOT_ENV=$(TF_ROOT_ENV) GCP_TF_VAR_FILE=$(GCP_TF_VAR_FILE) GCP_TF_HANDOFF_DIR=$(GCP_TF_HANDOFF_DIR) GCP_TF_IMPERSONATE=$(GCP_TF_IMPERSONATE)

.PHONY: gcp-tf-up
gcp-tf-up: ## Deploy one environment end to end: plan, summarise, apply that exact plan, write the handoff (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_require_impersonation)
	$(gcp_tf_require_worktree_state)
	@# Refuse to apply a plan this run did not create.
	@#
	@# Removing any existing plan file up front is the mechanism: after the plan
	@# step returns, a plan file exists if and only if this invocation produced
	@# it. The sentinel is the second half, and it is not redundant — it catches
	@# the case where the removal succeeded, the plan produced nothing, and
	@# something else (a concurrent run, a stale copy restored by an editor)
	@# dropped a file in between. Applying a plan file of unknown provenance is
	@# applying a diff nobody read.
	@rm -f '$(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)'
	@mkdir -p '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)'
	@rm -f '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/.up-sentinel'
	@touch '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/.up-sentinel'
	@echo "==> gcp-tf-up [1/4] init + plan $(ENV)"
	$(MAKE) --no-print-directory gcp-tf-plan $(GCP_TF_FORWARD)
	@if [ ! -f '$(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)' ]; then \
		echo "ERROR: the plan step produced no plan file at"; \
		echo "       $(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)."; \
		echo "       Refusing to apply a plan this run did not create."; \
		exit 3; \
	fi
	@if [ ! '$(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE)' -nt '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/.up-sentinel' ]; then \
		echo "ERROR: the plan file at $(TF_ROOT_ENV)/$(GCP_TF_PLAN_FILE) predates this run."; \
		echo "       It was not written by the plan step that just ran, so it is a diff"; \
		echo "       nobody in this invocation has seen. Refusing to apply it."; \
		exit 3; \
	fi
	@echo "==> gcp-tf-up [2/4] summarise the saved plan"
	@TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) show -no-color '$(GCP_TF_PLAN_FILE)' \
		> '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/$(ENV).plan.txt'
	@summary="$$(grep -E '^(Plan:|No changes\.)' '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/$(ENV).plan.txt' | tail -1)"; \
	if [ -n "$$summary" ]; then \
		echo "    $$summary"; \
	else \
		echo "    (no 'Plan:' summary line in the rendered plan)"; \
	fi; \
	echo "    full plan text: $(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/$(ENV).plan.txt"
	@echo "==> gcp-tf-up [3/4] apply the saved plan"
	$(MAKE) --no-print-directory gcp-tf-apply $(GCP_TF_FORWARD)
	@echo "==> gcp-tf-up [4/4] write the hand-off"
	$(MAKE) --no-print-directory gcp-tf-handoff $(GCP_TF_FORWARD)

.PHONY: gcp-tf-handoff
.PHONY: gcp-tf-worktree-bootstrap
gcp-tf-worktree-bootstrap: ## Copy this repo's untracked operational state (deploy-sa, tfvars, hand-offs, .keys) from the source checkout into this worktree.
	@if [ ! -x '$(GCP_TF_WORKTREE_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_WORKTREE_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	@'$(GCP_TF_WORKTREE_SCRIPT)' provision

.PHONY: gcp-tf-worktree-check
gcp-tf-worktree-check: ## Report whether this worktree carries the untracked state it needs, naming what is absent (ENV=<key> also requires that hand-off).
	@if [ ! -x '$(GCP_TF_WORKTREE_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_WORKTREE_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	@ENV='$(ENV)' '$(GCP_TF_WORKTREE_SCRIPT)' check

.PHONY: gcp-tf-worktree-status
gcp-tf-worktree-status: ## Per-item table of this worktree's untracked state against the source checkout, read-only.
	@if [ ! -x '$(GCP_TF_WORKTREE_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_WORKTREE_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	@'$(GCP_TF_WORKTREE_SCRIPT)' status

gcp-tf-handoff: ## Regenerate deploy/gcp/<env>.handoff.json from current state, read-only (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_state_bucket)
	$(gcp_tf_init_env)
	@mkdir -p '$(GCP_TF_HANDOFF_DIR)'
	@set -e; \
	outputs="$$(TF_DATA_DIR=$(GCP_TF_DATA_DIR) $(GCP_TF_IMPERSONATE_ENV) $(TF) -chdir=$(TF_ROOT_ENV) output -json)"; \
	if [ -z "$$outputs" ]; then \
		echo "ERROR: 'terraform output -json' produced nothing for ENV=$(ENV)."; \
		echo "       There is no applied state to hand off. Run: make gcp-tf-up ENV=$(ENV)"; \
		exit 3; \
	fi; \
	printf '%s' "$$outputs" | jq -e . >/dev/null 2>&1 || { \
		echo "ERROR: 'terraform output -json' did not return valid JSON for ENV=$(ENV)."; \
		exit 3; \
	}; \
	v() { printf '%s' "$$outputs" | jq -r --arg env '$(ENV)' "$$1 // empty" 2>/dev/null || true; }; \
	project_id="$$(v '.project_id.value // .integration_inputs.value.project_id')"; \
	environment_key="$$(v '.target_env.value')"; \
	region="$$(v '.target_environment.value.region')"; \
	zone="$$(v '.target_environment.value.zone')"; \
	app_port="$$(v '.target_environment.value.app_port')"; \
	hostname="$$(v '.target_environment.value.hostname')"; \
	access_mode="$$(v '.access_mode.value // .integration_inputs.value.access_mode')"; \
	instance_name="$$(v '.instance_name.value // .instance_names.value[$$env] // .compute.value[$$env].instance_name')"; \
	internal_ip="$$(v '.internal_ip.value // .internal_ips.value[$$env] // .compute.value[$$env].internal_ip')"; \
	operator_sa="$$(v '.operator_sa.value')"; \
	deploy_sa='$(strip $(GCP_TF_IMPERSONATE))'; \
	missing=''; \
	[ -n "$$project_id" ]      || missing="$$missing project_id(.integration_inputs.value.project_id)"; \
	[ -n "$$environment_key" ] || missing="$$missing environment_key(.target_env)"; \
	[ -n "$$region" ]          || missing="$$missing region(.target_environment.value.region)"; \
	[ -n "$$zone" ]            || missing="$$missing zone(.target_environment.value.zone)"; \
	[ -n "$$app_port" ]        || missing="$$missing app_port(.target_environment.value.app_port)"; \
	[ -n "$$access_mode" ]     || missing="$$missing access_mode(.integration_inputs.value.access_mode)"; \
	[ -n "$$instance_name" ]   || missing="$$missing instance_name(.instance_name|.instance_names[<env>])"; \
	[ -n "$$internal_ip" ]     || missing="$$missing internal_ip(.internal_ip|.internal_ips[<env>])"; \
	[ -n "$$operator_sa" ]     || missing="$$missing operator_sa(.operator_sa)"; \
	[ -n '$(strip $(TF_STATE_BUCKET))' ] || missing="$$missing state_bucket(TF_STATE_BUCKET)"; \
	[ -n "$$deploy_sa" ]       || missing="$$missing deploy_sa(GCP_TF_IMPERSONATE / $(GCP_TF_DEPLOY_SA_FILE))"; \
	if [ -n "$$missing" ]; then \
		echo "ERROR: the terraform outputs do not carry every value the hand-off contract requires."; \
		echo "       Unresolved (field, and the output that would supply it):"; \
		for m in $$missing; do echo "         - $$m"; done; \
		echo; \
		echo "       Nothing was written. A hand-off with a blank field is worse than no"; \
		echo "       hand-off at all: the test suite reads it, finds a field it can parse,"; \
		echo "       and reports on an estate it never reached."; \
		echo "       Every value here is derived from 'terraform output -json', which reads"; \
		echo "       APPLIED STATE — not the .tf files. So there are TWO causes and they"; \
		echo "       look identical from here:"; \
		echo; \
		echo "         a) the root does not declare the output. Add the block to"; \
		echo "            $(TF_ROOT_ENV)/outputs.tf."; \
		echo "         b) the root DECLARES it and the state predates it. An output added"; \
		echo "            but never applied is invisible to 'terraform output'. Check"; \
		echo "            first, or you will spend the afternoon re-adding a block that is"; \
		echo "            already there:"; \
		echo "               grep -n 'output \"<name>\"' $(TF_ROOT_ENV)/outputs.tf"; \
		echo "            If it is present, the fix is an apply, not an edit:"; \
		echo "               make gcp-tf-up ENV=$(ENV) TF_STATE_BUCKET=$(TF_STATE_BUCKET)"; \
		echo; \
		echo "       Do not hand-edit the hand-off."; \
		exit 3; \
	fi; \
	case "$$app_port" in \
		''|*[!0-9]*) \
			echo "ERROR: app_port resolved to '$$app_port', which is not a port number."; \
			exit 3;; \
	esac; \
	jq -n \
		--argjson schema_version 1 \
		--arg schema '$(GCP_TF_HANDOFF_SCHEMA)' \
		--arg project_id "$$project_id" \
		--arg environment_key "$$environment_key" \
		--arg region "$$region" \
		--arg zone "$$zone" \
		--arg instance_name "$$instance_name" \
		--arg internal_ip "$$internal_ip" \
		--argjson app_port "$$app_port" \
		--arg state_bucket '$(strip $(TF_STATE_BUCKET))' \
		--arg state_prefix '$(GCP_TF_PREFIX)' \
		--arg deploy_sa "$$deploy_sa" \
		--arg operator_sa "$$operator_sa" \
		--arg access_mode "$$access_mode" \
		--arg hostname "$$hostname" \
		--arg generated_at "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{schema: $$schema, schema_version: $$schema_version, project_id: $$project_id, environment_key: $$environment_key, env: $$environment_key, region: $$region, zone: $$zone, instance_name: $$instance_name, internal_ip: $$internal_ip, app_port: $$app_port, state_bucket: $$state_bucket, state_prefix: $$state_prefix, deploy_sa: $$deploy_sa, operator_sa: $$operator_sa, access_mode: $$access_mode, hostname: $$hostname, generated_at: $$generated_at}' \
		> '$(GCP_TF_HANDOFF_FILE)'; \
	echo "hand-off written: $(GCP_TF_HANDOFF_FILE)"; \
	echo "The test suite reads this one file and needs no flags. It is untracked:"; \
	echo "every field in it names a real project."

# --- The demo lane: from an applied estate to a browser -----------------------
#
# `gcp-tf-up` finishes with a hardened, IAP-only VM and a hand-off file. These
# three targets are what turn that into something a human can look at:
#
#   gcp-tf-demo-up    deliver this checkout, stand the estate up, test it
#   gcp-tf-demo-test  re-run the tests only, against a cluster already standing
#   gcp-tf-connect    open the tunnel, claim the Dex origin, print the URL and
#                     the login — the thing the operator actually wants
#
# All three delegate to scripts/gcp-tf/demo-up.sh. The guards stay HERE, in the
# same `define`s every other target in this block uses, because a guard in the
# Makefile cannot be bypassed by invoking the Makefile — and because two
# implementations of "is ENV valid" drift the moment one of them is corrected.
#
# The script reads deploy/gcp/<env>.handoff.json for the project, zone,
# instance and ports. Nothing about the estate is passed on the command line and
# nothing is hardcoded in either file.
GCP_TF_DEMO_SCRIPT ?= scripts/gcp-tf/demo-up.sh

# Forwarded explicitly for the same reason GCP_TF_FORWARD is: a value with a
# computed default does not reach a sub-process through MAKEFLAGS, and an
# impersonation target that silently fails to arrive is the failure this whole
# block exists to prevent.
GCP_TF_DEMO_ENVIRONMENT = ENV='$(ENV)' GCP_TF_DEMO_ENV='$(ENV)' GCP_TF_HANDOFF_DIR='$(GCP_TF_HANDOFF_DIR)'

.PHONY: gcp-tf-demo-up
gcp-tf-demo-up: ## Stand the whole demo up on the VM: deliver, build, test, collect (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	@# Not `&&`-chained with the guard above: this must run in its own recipe
	@# line so a non-zero exit propagates as make's exit status rather than
	@# being consumed by a conditional.
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' up

.PHONY: gcp-tf-demo-test
gcp-tf-demo-test: ## Re-run the demo tests against a cluster that is already standing (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' test

# ── The SECOND test surface: remote, over the tailnet ──────────────────────
#
# gcp-tf-demo-test above runs the suite ON the VM, over 127.0.0.1. This runs a
# much smaller suite from HERE, over the tailnet, and asserts only the things
# where the transport is the subject: the node, the real TLS certificate, Dex's
# issuer, a token minted across the wire, and an authenticated API call through
# the same nginx a browser uses. The driver's own header explains at length why
# the on-VM suite is blind to all five by construction.
#
# ─── NO gcp_tf_require_impersonation, and that is deliberate ────────────────
#
# Every other target in this family carries that guard because every other
# target makes a gcloud call. This one makes none: no tunnel, no SSH, no
# project. It is curl against a MagicDNS name, which is exactly what Andy's
# phone does. Adding the guard would mean the user journey could only be tested
# by someone holding credentials the journey does not use — and a test that
# cannot be run the way the user runs it is testing something else.
#
# ENV is still guarded, and still rejects a production-shaped key.
#
# Safe to run for all four lanes at once: it binds no local port, and every
# receipt path carries the environment key.
.PHONY: gcp-tf-ts-test
gcp-tf-ts-test: ## REMOTE surface: test the lane from here, over the tailnet. No cloud credentials (ENV=<key>).
	$(gcp_tf_require_env)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ts-test

# Asserts the PROPERTY, rather than trusting whoever typed the two commands.
#
# "Run the tests on the VM and also over the tailnet" is a claim about two runs,
# and neither run can make it alone. This reads both receipts and passes only
# when both are present, both name this lane, both are recent and both passed.
# A surface that never ran is reported as an unanswered question, never as a
# pass and never as a skip.
.PHONY: gcp-tf-test-surfaces
gcp-tf-test-surfaces: ## Assert that BOTH the on-VM and the tailnet surfaces ran and passed (ENV=<key>).
	$(gcp_tf_require_env)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' test-surfaces

# The composition, and the target a human actually wants to type.
#
# Three separate recipe lines, NOT `&&`-chained: each must propagate its own
# exit status as make's, which a conditional would consume. The surfaces verdict
# runs last and is what decides the overall result — if either surface above
# failed to file a receipt, this target fails even though both commands ran.
.PHONY: gcp-tf-test-both
gcp-tf-test-both: ## Run BOTH surfaces for one lane — on the VM, then over the tailnet — and assert both ran (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	$(MAKE) --no-print-directory gcp-tf-demo-test ENV='$(ENV)'
	$(MAKE) --no-print-directory gcp-tf-ts-test ENV='$(ENV)'
	$(MAKE) --no-print-directory gcp-tf-test-surfaces ENV='$(ENV)'

.PHONY: gcp-tf-ssh
gcp-tf-ssh: ## SSH into the demo VM for debugging via IAP (resumes if suspended, ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ssh $(SSH_ARGS)

.PHONY: gcp-tf-connect
gcp-tf-connect: ## Open the IAP tunnel to the demo dashboard and print the URL and login (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' connect

# ── Publishing the demo, mirroring the `public` family ─────────────────────
#
# Named for `public` / `public-down` / `public-status` because it is the same
# verb for the same job — put the dashboard in front of a human — and an
# operator who knows one should not have to learn the other. It is prefixed
# gcp-tf- rather than ci- because it belongs to the v2 Terraform demo lane, not
# to the shared v1 CI VMs that own the ci-* namespace.
#
# The difference from gcp-tf-connect, which remains for the tunnel-only case:
# connect proves the local port BINDS. That is not the same as a demo that
# works, because gcloud binds locally before it has proven anything about the
# far side, and the VM-side kubectl forward is the part that actually dies.
# gcp-tf-public claims the Dex origin, ensures the VM is publishing, opens the
# tunnel, waits for the bind, and then fetches /readyz at the EXACT URL it is
# about to hand over. It prints that URL only after a 200.
#
# It used to probe with `curl --resolve` against the Gateway's SNI hostname, so a
# healthy probe said nothing about whether a browser here could reach the same
# address — which is what the /etc/hosts preflight existed to cover. The tunnel
# reaches the dashboard's nginx now and the URL is http://localhost:<port>, so
# the probe and the browser cannot diverge and the preflight is gone.
.PHONY: gcp-tf-public
gcp-tf-public: ## Publish the demo dashboard and prove it answers before printing the URL (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' public

.PHONY: gcp-tf-public-down
gcp-tf-public-down: ## Stop the VM-side forward that publishes the demo dashboard (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' public-down

.PHONY: gcp-tf-public-status
gcp-tf-public-status: ## Whether the VM is publishing and whether a healthy tunnel exists here (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' public-status

.PHONY: gcp-tf-surfaces-report
gcp-tf-surfaces-report: ## Report EVERY lane on BOTH surfaces in one table; STALE and MISSING both fail (LANES=, COMMIT=).
	@# No ENV guard: sweeping every lane is the whole point, and requiring ENV
	@# here would make the one target that answers "which lanes are good?"
	@# answerable only one lane at a time — which is the gap it exists to close.
	@if [ ! -x 'scripts/gcp-tf/surfaces-report.sh' ]; then \
		echo "ERROR: scripts/gcp-tf/surfaces-report.sh is missing or not executable."; \
		exit 2; \
	fi
	@scripts/gcp-tf/surfaces-report.sh \
		$(if $(strip $(LANES)),--lanes '$(strip $(LANES))',) \
		$(if $(strip $(COMMIT)),--commit '$(strip $(COMMIT))',) \
		$(if $(strip $(JSON)),--json,)

.PHONY: gcp-tf-demo-status
gcp-tf-demo-status: ## What the demo VM's state is and what the last run decided, read-only (ENV=<key>).
	$(gcp_tf_require_env)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' status

# ── Tailscale: the PRIMARY access path ──────────────────────────────────────
#
# `gcp-tf-public` and `gcp-tf-connect` above are NOT deprecated and are not
# going anywhere — they are the tested fallback, and they are the only path
# that works for an operator who cannot join the tailnet. Tailscale leads
# because it removes the foreground tunnel and works from a phone, which are the
# two things that make handing this demo to someone else awkward. The /etc/hosts
# line used to be a third; it is gone from BOTH paths now that every access
# method forwards to the dashboard's nginx rather than to the Envoy Gateway.
#
# Same guards, same `define`s, same shape as the family above. That is
# deliberate: two implementations of "is ENV valid" drift the moment one of
# them is corrected, and a guard living in the Makefile cannot be bypassed by
# invoking the Makefile.
#
# All four require impersonation, gcp-tf-ts-status included. It reads the VM's
# state and asks the VM whether it is publishing, so it reaches the cloud —
# unlike gcp-tf-demo-status, which only reads local files when the VM is
# unreachable.
.PHONY: gcp-tf-ts-status
gcp-tf-ts-status: ## Is the demo's Tailscale node up, what is its MagicDNS name, is the dashboard answering (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ts-status

# Release the tailnet device record. Called by gcp-tf-destroy before the
# destroy, and exposed as a target so it can be run by hand after a teardown
# that went around this Makefile.
#
# NOT guarded by gcp_tf_require_impersonation, unlike its siblings. That guard
# `exit 2`s, and the driver treats missing impersonation as one more best-effort
# miss rather than as an error.
#
# This target PROPAGATES the driver's status, unlike the copy of this call
# inside gcp-tf-destroy. The two callers want opposite things and that is the
# whole point of the guard: a destroy must never be blocked, and a human
# running this by hand on a live node must be STOPPED. `tailscale logout` wipes
# the serve config, so on a standing demo this takes the URL down while leaving
# the node online and correctly named. FORCE=1 is the way to say you meant it.
.PHONY: gcp-tf-ts-logout
gcp-tf-ts-logout: ## Release the demo's Tailscale device record so the next build reclaims the name (ENV=<key>, FORCE=1 to override the live-serve refusal).
	$(gcp_tf_require_env)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		echo "       The tailnet name was NOT released. Reporting that rather than"; \
		echo "       exiting 0, because a silent skip here is how a stale device"; \
		echo "       survives to rename the next build."; \
		exit 2; \
	fi
	@FORCE=$(FORCE) $(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ts-logout

.PHONY: gcp-tf-ts-up
gcp-tf-ts-up: ## PRIMARY: serve the demo on the tailnet and prove it answers before printing the URL (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' ts-up

# The only target in this repo that creates a listener the public internet can
# reach. Everything else is closed by construction — no external IP, IAP behind
# a Google identity, Tailscale behind tailnet membership. It is a separate
# target from gcp-tf-ts-up for exactly that reason: going public should be an
# act, not a side effect of asking for a URL.
.PHONY: gcp-tf-funnel-up
gcp-tf-funnel-up: ## PUBLIC INTERNET: expose the demo via Tailscale Funnel. Deliberate, and off by default (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' funnel-up

.PHONY: gcp-tf-funnel-down
gcp-tf-funnel-down: ## Remove the public Funnel listener. The tailnet-only demo stays up (ENV=<key>).
	$(gcp_tf_require_env)
	$(gcp_tf_require_impersonation)
	@if [ ! -x '$(GCP_TF_DEMO_SCRIPT)' ]; then \
		echo "ERROR: $(GCP_TF_DEMO_SCRIPT) is missing or not executable."; \
		exit 2; \
	fi
	$(GCP_TF_DEMO_ENVIRONMENT) '$(GCP_TF_DEMO_SCRIPT)' funnel-down

# ===========================================================================
# END GCP Terraform platform block
# ===========================================================================

.PHONY: vm-state-check
vm-state-check: ## Assert the VM facts the pipeline depends on. Run ON the VM, BEFORE the pipeline.
	@# OUTSIDE the gcp-tf block, deliberately, and it was placed inside first —
	@# test/terraform-make-contract.bats caught it as "unprefixed target inside
	@# the block". Renaming it gcp-tf-vm-state-check would have satisfied that
	@# guard while making the name a lie: this gate is not a terraform target,
	@# takes no ENV, touches no state and needs no credentials. It describes the
	@# machine the pipeline runs ON. The guard was right about the namespace and
	@# the fix is the namespace, not the name.
	@#
	@# No $(GCP_TF_NOCREDS) wrapper for the same reason: unlike every terraform
	@# target, this one is meant to run on the machine it is describing, and
	@# stripping the environment there would tell you about a machine nobody uses.
	@#
	@# Deliberately NOT wired into scripts/ci/** or scripts/gcp-tf/** — those are
	@# frozen or owned by another agent and the insertion point needs sequencing.
	@# The proposed call site is documented in the gate's own header.
	./scripts/vm-state/vm-state-contract.sh $(if $(FORMAT),--format $(FORMAT))

.PHONY: where
where: ## Where is Signal Loom right now, and what URL do I hand someone? Read-only, no args.
	@./scripts/where.sh

.PHONY: where-probe
where-probe: ## Same as 'where', but also curls each address and reports the status code.
	@./scripts/where.sh --probe

# ===========================================================================
# Agent Swarm infrastructure
# ===========================================================================

KNATIVE_VERSION ?= v1.16.0

.PHONY: swarm-infra-up
swarm-infra-up: ## Apply Knative + agent namespace + RBAC for the agent swarm.
	@echo "--- Applying agent swarm namespace + RBAC ---"
	kubectl apply -k d2-signalloom/infra/agent-swarm/
	@echo "--- Applying Knative Serving CRDs ---"
	kubectl apply -f "https://github.com/knative/serving/releases/download/knative-$(KNATIVE_VERSION)/serving-crds.yaml" 2>/dev/null || \
		echo "WARNING: Knative Serving CRDs not available — skipping (install manually)"
	kubectl patch crd services.serving.knative.dev configurations.serving.knative.dev --type=json -p '[{"op": "add", "path": "/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/template/properties/spec/properties/volumes/items/properties/csi", "value": {"type": "object", "x-kubernetes-preserve-unknown-fields": true}}]' 2>/dev/null || true
	@echo "--- Applying Knative Serving core ---"
	kubectl apply -f "https://github.com/knative/serving/releases/download/knative-$(KNATIVE_VERSION)/serving-core.yaml" 2>/dev/null || \
		echo "WARNING: Knative Serving core not available — skipping"
	@echo "--- Applying Knative Eventing CRDs ---"
	kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-$(KNATIVE_VERSION)/eventing-crds.yaml" 2>/dev/null || \
		echo "WARNING: Knative Eventing CRDs not available — skipping"
	@echo "--- Applying Knative Eventing core ---"
	kubectl apply -f "https://github.com/knative/eventing/releases/download/knative-$(KNATIVE_VERSION)/eventing-core.yaml" 2>/dev/null || \
		echo "WARNING: Knative Eventing core not available — skipping"
	@echo "--- Applying Knative local manifests (broker, github-source template) ---"
	kubectl apply -k d2-signalloom/infra/knative/ 2>/dev/null || \
		echo "WARNING: Knative local manifests need Knative CRDs — apply after CRDs are ready"
	@echo "--- Agent swarm infrastructure applied ---"

.PHONY: swarm-infra-down
swarm-infra-down: ## Tear down agent swarm infrastructure (keeps the cluster).
	@echo "--- Removing Knative local manifests ---"
	-kubectl delete -k d2-signalloom/infra/knative/ 2>/dev/null
	@echo "--- Removing agent swarm namespace + RBAC ---"
	-kubectl delete -k d2-signalloom/infra/agent-swarm/ 2>/dev/null
	@echo "--- Agent swarm infrastructure removed ---"

# swarm-kagent-up / swarm-kagent-down are defined once, above, under
# "Kagent Cloud-Native AI Agents (D5)". A second pair used to be declared here
# with the same names and different help text; make silently kept whichever
# came last, so the documented target and the executed target were different
# objects. Left as a pointer rather than a duplicate.

.PHONY: swarm-openbao-role
swarm-openbao-role: ## Configure the glob-bound JWT auth role for agent swarm in OpenBao.
	@echo "--- Applying OpenBao agent generic role ---"
	kubectl apply -f d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml -n inf-bao
	@echo "--- Waiting for setup job ---"
	. scripts/lib/wait.sh && wait_job openbao-agent-generic-role-setup -n inf-bao 60 || \
		echo "WARNING: Job not complete yet — check with: kubectl logs job/openbao-agent-generic-role-setup -n inf-bao"

# ── Agent Swarm (Tier 1 + Tier 2) ──────────────────────────────────────

.PHONY: swarm-prompt-summarizer-image
swarm-prompt-summarizer-image: ## Build prompt-commit-summarizer image (Tier 1 stateless prompt function).
	docker build -t prompt-commit-summarizer:latest d2-signalloom/apps/prompt-commit-summarizer
	kind load docker-image --name $(CLUSTER_NAME) prompt-commit-summarizer:latest

.PHONY: swarm-triage-worker-image
swarm-triage-worker-image: ## Build triage-ci-worker image (Tier 2 deterministic worker).
	docker build -t triage-ci-worker:latest d2-signalloom/apps/triage-ci-worker
	kind load docker-image --name $(CLUSTER_NAME) triage-ci-worker:latest

.PHONY: swarm-prompt-triage-images
swarm-prompt-triage-images: swarm-prompt-summarizer-image swarm-triage-worker-image ## Build both Tier 1+2 agent swarm images.

# ── Agent Swarm — Flux Deploy/Remove ────────────────────────────────

.PHONY: swarm-deploy
swarm-deploy: ## Deploy all 11 swarm agents via Flux reconciliation.
	scripts/swarm-deploy.sh deploy

.PHONY: swarm-deploy-%
swarm-deploy-%: ## Deploy a specific swarm agent (e.g., make swarm-deploy-cpai-engineer).
	scripts/swarm-deploy.sh deploy "$*"

.PHONY: swarm-remove
swarm-remove: ## Remove all swarm agents (suspend Flux + delete workloads).
	scripts/swarm-deploy.sh remove

.PHONY: swarm-remove-%
swarm-remove-%: ## Remove a specific agent (e.g., make swarm-remove-cpai-engineer).
	scripts/swarm-deploy.sh remove "$*"

.PHONY: swarm-status
swarm-status: ## Show Flux reconciliation status for all swarm agents.
	scripts/swarm-deploy.sh status

# ─── Security scanning ───────────────────────────────────────────────────────────
# Run on demand and in CI, never on every commit. A pre-commit gate on these is too
# slow to survive contact with normal work, which is how repositories end up with the
# hook disabled and the scan never run at all.
#
# Scope is `git archive HEAD`, i.e. exactly the committed tree. Three reasons: an
# unscoped working-tree scan returns ~994 findings against ~0 for committed content,
# almost all of it inside gitignored container tarballs and CI archives; a push gate
# should judge what is being pushed rather than whatever is lying in the worktree; and
# extraction costs 0.4s, so there is no reason to approximate.
#
# SEMGREP_HOME is set explicitly because semgrep aborts with
# "Permission denied open ~/.semgrep/settings.yml" under any sandbox profile that does
# not grant that path. Setting it here means these targets work whether or not the
# `sec-tooling` nono profile is installed.

SCAN_TMP           := $(shell mktemp -d -t osramp-scan.XXXXXX)
SEMGREP_HOME       ?= $(CURDIR)/.cache/semgrep-home
SEMGREP_CONFIG     ?= p/default
# Gate on ERROR only. The full ruleset reports ~175 findings (19 ERROR, 127 WARNING,
# 29 INFO); blocking on all of them would fail every push from day one, which trains
# people to bypass the gate. WARNING and INFO are reported, not enforced.
SEMGREP_SEVERITY   ?= ERROR
TRUFFLEHOG_EXCLUDE := $(CURDIR)/.trufflehog-exclude-paths

.PHONY: scan scan-secrets scan-secrets-worktree scan-sast scan-sast-baseline scan-sast-all scan-lint install-git-hooks

scan: scan-secrets scan-sast ## Run the full security scan set (secrets + SAST) over the committed tree.

scan-secrets: ## Scan the committed tree for secrets. Fails on any finding.
	@command -v trufflehog >/dev/null || { echo "scan-secrets: trufflehog not on PATH"; exit 127; }
	@echo "==> trufflehog: committed tree at HEAD"
	@git archive HEAD | tar -x -C "$(SCAN_TMP)"
	@cd "$(SCAN_TMP)" && trufflehog filesystem --no-update --fail \
		--exclude-detectors=Lob \
		--exclude-paths="$(TRUFFLEHOG_EXCLUDE)" . ; \
	  rc=$$?; rm -rf "$(SCAN_TMP)"; \
	  if [ $$rc -ne 0 ]; then \
	    echo ""; \
	    echo "scan-secrets: findings above are NOT in the declared-fixture baseline."; \
	    echo "  Baseline:   $(TRUFFLEHOG_EXCLUDE)"; \
	    echo "  If a finding is a deliberate test fixture, add it there WITH a reason."; \
	    echo "  If it is a real credential, rotate it first — the baseline is not a fix."; \
	    exit $$rc; \
	  fi
	@echo "==> trufflehog: clean"

scan-secrets-worktree: ## Scan the working tree too, including untracked files. Advisory, does not gate.
	@git archive HEAD >/dev/null 2>&1 || true
	@trufflehog filesystem --no-update --exclude-detectors=Lob \
		--exclude-paths="$(TRUFFLEHOG_EXCLUDE)" . || true

scan-sast: ## Static analysis. Fails only on NEW ERROR-severity findings above the declared baseline.
	@command -v semgrep >/dev/null || { echo "scan-sast: semgrep not on PATH"; exit 127; }
	@mkdir -p "$(SEMGREP_HOME)"
	@SEMGREP_HOME="$(SEMGREP_HOME)" SEMGREP_CONFIG=$(SEMGREP_CONFIG) \
		node scripts/semgrep-gate.mjs --severity $(SEMGREP_SEVERITY)

scan-sast-baseline: ## Regenerate .semgrep-baseline.json. Review the diff — every entry needs a reason.
	@mkdir -p "$(SEMGREP_HOME)"
	@SEMGREP_HOME="$(SEMGREP_HOME)" SEMGREP_CONFIG=$(SEMGREP_CONFIG) \
		node scripts/semgrep-gate.mjs --severity $(SEMGREP_SEVERITY) --update

scan-sast-all: ## Full SAST report at every severity. Advisory, does not gate.
	@mkdir -p "$(SEMGREP_HOME)"
	@HOME="$(SEMGREP_HOME)" semgrep --config=$(SEMGREP_CONFIG) --metrics=off \
		d2-signalloom d2-osramp-apps scripts test || true

scan-lint: ## Shell and Dockerfile lint. Advisory until the existing findings are cleared.
	@command -v shellcheck >/dev/null && \
	  git ls-files -z '*.sh' | xargs -0 -r shellcheck -S warning || \
	  echo "scan-lint: shellcheck not on PATH, skipped"
	@command -v hadolint >/dev/null && \
	  git ls-files -z '*Dockerfile*' | xargs -0 -r hadolint || \
	  echo "scan-lint: hadolint not on PATH, skipped"

install-git-hooks: ## Install the pre-push hook that runs scan-secrets.
	@mkdir -p .git/hooks
	@printf '%s\n' \
	  '#!/usr/bin/env bash' \
	  '# Installed by `make install-git-hooks`.' \
	  '#' \
	  '# Secrets only, and on push rather than commit. The SAST scan takes minutes and' \
	  '# belongs in CI; a slow hook gets disabled and then nothing runs at all.' \
	  '#' \
	  '# Bypass with `git push --no-verify`, or SKIP_SECRET_SCAN=1.' \
	  'set -uo pipefail' \
	  '[ "$${SKIP_SECRET_SCAN:-}" = "1" ] && { echo "pre-push: secret scan skipped via SKIP_SECRET_SCAN"; exit 0; }' \
	  'command -v trufflehog >/dev/null || { echo "pre-push: trufflehog not installed, skipping"; exit 0; }' \
	  'exec make -s scan-secrets' \
	  > .git/hooks/pre-push
	@chmod +x .git/hooks/pre-push
	@echo "installed .git/hooks/pre-push -> make scan-secrets"
	@echo "  bypass: git push --no-verify   or   SKIP_SECRET_SCAN=1 git push"
