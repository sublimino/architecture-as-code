SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test bootstrap-drift
test: ## Validate the D2 topology, dependency components, and Discovery Portal package.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	@if command -v bats >/dev/null 2>&1; then bats test/topology.bats test/portal-package.bats test/bootstrap.bats; fi

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh
