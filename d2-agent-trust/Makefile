SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test render
test: ## Run deterministic contract and A2A unit tests.
	python3 -m unittest discover -s test -v

render: ## Validate Kubernetes YAML can be rendered when kubectl is available.
	kubectl kustomize manifests >/dev/null
