NAME ?= osramp

CLUSTER_NAME := $(NAME)
DOCKER_BUILD_NETWORK ?= host
ZOT_IMAGE_BASE ?= zot.registry.svc.cluster.local:5000/acme/images/osramp
ZOT_PUSH_BASE ?= localhost:5001/acme/images/osramp
IMAGE_TAG ?= latest
PUSH_LOCAL_IMAGE ?= ../scripts/push-local-image.sh

ARCH := $(shell uname -m | sed 's/x86_64/amd64/')
OS := $(shell uname -s | tr '[:upper:]' '[:lower:]')

.EXPORT_ALL_VARIABLES:

.PHONY: build
build: ## Build the three app images and persist them in Zot (single shared port-forward).
	../scripts/with-zot-portforward.sh $(MAKE) archiver-build listener-build processor-build

##@ Kind

## clusters are bootstrapped from the fleet repo
## this is just here as a helper to show that localdev cluster name should match the target cluster
.PHONY: cluster-up
cluster-up: ## Create the kind cluster
	kind create cluster --name $(CLUSTER_NAME)

.PHONY: cluster-down
cluster-down: ## Delete the kind cluster
	-kind delete cluster --name $(CLUSTER_NAME)

.PHONY: local-dev
local-dev: ## Pause Flux kustomizations + force apply local config
	kubectl api-versions | grep -c flux >/dev/null || flux install

	flux suspend -n frontend kustomization apps 2>/dev/null || true
	flux suspend -n backend kustomization apps 2>/dev/null || true

	kubectl create ns frontend 2>/dev/null || true
	kubectl create ns backend 2>/dev/null || true

	kustomize build components/backend/staging \
		| kubectl apply \
			-n backend \
			--field-manager=flux-client-side-apply \
			--server-side --force-conflicts \
			-f -

	kustomize build components/frontend/local \
		| kubectl apply \
			-n frontend \
			--field-manager=flux-client-side-apply \
			--server-side --force-conflicts \
			-f -

.PHONY: resume
resume: ## Un-pause Flux kustomizations
	flux resume -n frontend kustomization apps
	flux resume -n backend kustomization apps

.PHONY: signing-key
signing-key:
	@echo Checking if signing key already exists...
	@if ! kubectl get secret -n frontend signing-key; then \
  		cd "$$(mktemp -d)"; \
		docker run -v $${PWD}:$${PWD} -w $${PWD} alpine/openssl genpkey -algorithm ed25519 -outform PEM -out - > signing-private.pem; \
		docker run -v $${PWD}:$${PWD} -w $${PWD} alpine/openssl pkey -in signing-private.pem -pubout > signing-public.pem; \
		kubectl create secret generic signing-key -n frontend \
			--from-file=signing-private.pem --from-file=signing-public.pem; \
		rm signing-private.pem signing-public.pem; \
	fi

##@ Infra

.PHONY: archiver-build
archiver-build: ## Build and persist the archiver container in Zot
	docker build --network=$(DOCKER_BUILD_NETWORK) -t $(ZOT_IMAGE_BASE)/archiver:$(IMAGE_TAG) apps/archiver
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/archiver:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/archiver:$(IMAGE_TAG)
	kubectl -n frontend delete po -l app=osramp-archiver --wait=false

.PHONY: listener-build
listener-build: ## Build and persist the listener container in Zot
	docker build --network=$(DOCKER_BUILD_NETWORK) -t $(ZOT_IMAGE_BASE)/listener:$(IMAGE_TAG) apps/listener
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/listener:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/listener:$(IMAGE_TAG)
	kubectl -n frontend delete po -l app=osramp-multipurpose --wait=false
	kubectl -n frontend delete po -l app=osramp-purl --wait=false

.PHONY: processor-build
processor-build: ## Build and persist the processor container in Zot
	docker build --network=$(DOCKER_BUILD_NETWORK) -t $(ZOT_IMAGE_BASE)/processor:$(IMAGE_TAG) apps/processor
	$(PUSH_LOCAL_IMAGE) $(ZOT_IMAGE_BASE)/processor:$(IMAGE_TAG) $(ZOT_PUSH_BASE)/processor:$(IMAGE_TAG)
	kubectl -n frontend delete po -l app=osramp-multipurpose --wait=false
	kubectl -n frontend delete po -l app=osramp-purl --wait=false

.PHONY: postgres-shell
postgres-shell: ## Connect to the backend postgres dynamically using in-cluster frontend settings
	kubectl exec -it -n backend postgres -- \
		$$(kubectl exec -n frontend deploy/osramp-archiver -- \
			sh -c 'echo psql "$${DB_NAME}" "$${DB_USER}"')

.PHONY: processor-shell
processor-shell: ## Exec into to the multipurpose processor
	kubectl exec -it -n frontend deploy/osramp-multipurpose --container processor -- bash

.PHONY: test test-config
test: ## Run the bats test suite
	cd test && bats osramp.bats

test-config: ## Run deterministic backend manifest checks
	cd test && bats backend-config.bats


.PHONY: gen-archivista
gen-archivista: ## Generate the backend kubernetes manifests for an Archivista deployment
	helm repo add in-toto https://in-toto.github.io/helm-charts
	helm template osramp in-toto/archivista \
		--set ingress.enabled=false \
		--set 'deployment.envFrom[0].secretRef.name=osramp-archivista' \
		> components/backend/base/archivista.yaml

# TODO add to Infra repo -- (needs cluster-admin flux SA), should live in its own namespaces
#  							for now, we'll just use a single minio container
# .PHONY: gen-minio
# gen-minio: ## Generate the backend kubernetes manifests for a Minio Operator and Tenant instance
# 	kustomize build github.com/minio/operator\?ref=v7.1.1 \
# 		> components/backend/base/minio-operator.yaml
# 	kustomize build github.com/minio/operator/examples/kustomization/base \
# 		> components/backend/base/minio-tenant.yaml

##@ Tools

.PHONY: help
help: ## parse jobs and descriptions from this Makefile
	@grep -E '^[ a-zA-Z0-9_-]+:([^=]|$$)' $(MAKEFILE_LIST) \
	| grep -Ev '^help\b[[:space:]]*:' \
	| sort \
	| awk 'BEGIN {FS = ":.*?##"}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
