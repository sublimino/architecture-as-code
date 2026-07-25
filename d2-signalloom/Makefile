SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test bootstrap-drift
test: ## Validate the split-ready topology and local Kustomize entry points.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	@if command -v bats >/dev/null 2>&1; then bats test/topology.bats; fi
	@if command -v bats >/dev/null 2>&1; then bats test/bootstrap.bats; fi

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh
