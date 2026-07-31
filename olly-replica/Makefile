NAME ?= osramp

CLUSTER_NAME := $(NAME)
DOCKER_BUILD_NETWORK ?= host
ZOT_IMAGE_BASE ?= zot.registry.svc.cluster.local:5000/acme/images/olly
ZOT_PUSH_BASE ?= localhost:5001/acme/images/olly
IMAGE_TAG ?= latest
PUSH_LOCAL_IMAGE ?= ../scripts/push-local-image.sh

SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

# One build context (this directory) for all three images so the contracts
# bake into each of them; the in-build unit tests make contract drift fail
# the image build itself.
.PHONY: build
build: sentinel-build elk-mcp-build stubs-build tenant-app-build authz-build llm-guard-build ## Build and persist all replica images in Zot.

.PHONY: sentinel-build
sentinel-build: ## Build and persist the sentinel image (Google ADK + A2A).
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/sentinel/Dockerfile -t $(ZOT_IMAGE_BASE)/sentinel:$(IMAGE_TAG) .
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/sentinel:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/sentinel:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l app=olly-sentinel --wait=false 2>/dev/null || true

.PHONY: authz-build
authz-build: ## Build and persist the olly-authz image (COIN / PlainID / EEMS chain).
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/authz/Dockerfile -t $(ZOT_IMAGE_BASE)/authz:$(IMAGE_TAG) apps/authz
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/authz:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/authz:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l app=olly-authz --wait=false 2>/dev/null || true

.PHONY: elk-mcp-build
elk-mcp-build: ## Build and persist the elk-search-mcp image.
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/Dockerfile --build-arg APP=elk-search-mcp -t $(ZOT_IMAGE_BASE)/elk-mcp:$(IMAGE_TAG) .
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/elk-mcp:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/elk-mcp:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l app=elk-search-mcp --wait=false 2>/dev/null || true

.PHONY: stubs-build
stubs-build: ## Build and persist the stubs image (mapping stub + replay producer).
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/Dockerfile --build-arg APP=mapping-stub -t $(ZOT_IMAGE_BASE)/stubs:$(IMAGE_TAG) .
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/stubs:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/stubs:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l app=io-mapping-stub --wait=false 2>/dev/null || true

.PHONY: tenant-app-build
tenant-app-build: ## Build and persist the tenant-app image (the 3 managed apps).
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/Dockerfile --build-arg APP=tenant-app -t $(ZOT_IMAGE_BASE)/tenant-app:$(IMAGE_TAG) .
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/tenant-app:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/tenant-app:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l osramp.acme.co/tenant-app=true --wait=false 2>/dev/null || true

.PHONY: llm-guard-build
llm-guard-build: ## Build and persist the LLM Guard scanner image (Security Sandbox).
	docker build --network=$(DOCKER_BUILD_NETWORK) -f apps/llm-guard/Dockerfile -t $(ZOT_IMAGE_BASE)/llm-guard:$(IMAGE_TAG) apps/llm-guard
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/llm-guard:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/llm-guard:$(IMAGE_TAG)
	kubectl -n olly-replica delete po -l app=llm-guard --wait=false 2>/dev/null || true

.PHONY: security-sandbox-up
security-sandbox-up: ## Start the promptfoo red-team UI (Security Sandbox) at http://localhost:3000.
	cd apps/security-sandbox && docker compose up -d

.PHONY: security-sandbox-down
security-sandbox-down: ## Stop the promptfoo red-team UI.
	cd apps/security-sandbox && docker compose down

.PHONY: security-sandbox-redteam
security-sandbox-redteam: ## Run a promptfoo red-team pass against Olly (MODE=baseline|guarded).
	cd apps/security-sandbox && ./redteam.sh $${MODE:-baseline}

.PHONY: authz-test
authz-test: ## Run the olly-authz control-plane checks (COIN/PlainID/EEMS + narrowing).
	cd apps/authz && python3 tests/test_authz.py

.PHONY: replay
replay: ## Emit one synthetic event through the pipeline (APP=inventory-service).
	kubectl -n olly-replica run replay-$$(date +%s) --rm -i --restart=Never \
		--image=$(ZOT_IMAGE_BASE)/stubs:$(IMAGE_TAG) --image-pull-policy=IfNotPresent \
		--env=KAFKA_BROKERS=redpanda.olly-replica.svc.cluster.local:9093 \
		--command -- /replay-producer -app $${APP:-inventory-service}

.PHONY: a2a-demo
a2a-demo: ## Fire one Olly -> Orbit A2A hand-off for the dashboard demo (APP=payments-api).
	@echo "Triggering the A2A flow with a restart-shaped incident (app=$${APP:-payments-api})."
	@echo "Watch the Agentic SRE dashboard A2A panel light up, or tail the bus:"
	@echo "  kubectl -n olly-replica exec redpanda-0 -c redpanda -- rpk topic consume olly.pipeline.decisions -o -20 -f '%v\\n' | grep orbit_a2a"
	@echo "(The input-required step needs Orbit's A2A server, which needs a model: run 'make olly-llm-secret' first. Without one, identity + hand-off still light and the proposal still parks.)"
	kubectl -n olly-replica run a2a-demo-$$(date +%s) --rm -i --restart=Never \
		--image=$(ZOT_IMAGE_BASE)/stubs:$(IMAGE_TAG) --image-pull-policy=IfNotPresent \
		--env=KAFKA_BROKERS=redpanda.olly-replica.svc.cluster.local:9093 \
		--command -- /replay-producer -app $${APP:-payments-api}

.PHONY: test
test: ## Run the olly bats suite against the running cluster.
	cd test && bats olly.bats

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
