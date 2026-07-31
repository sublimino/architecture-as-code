SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test kustomize-check
test: kustomize-check ## Validate the D2 CPAI topology.
	@if command -v bats >/dev/null 2>&1; then bats test/cpai-runtime.bats; fi

kustomize-check: ## Render and validate CPAI Kustomize overlays.
	kubectl kustomize apps/cpai-runtime/local >/dev/null
