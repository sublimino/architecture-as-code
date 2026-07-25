SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test
test: ## Validate the split-ready topology and Discovery Portal package.
	./test/validate-topology.sh
	@if command -v bats >/dev/null 2>&1; then bats test/topology.bats test/portal-package.bats; fi
