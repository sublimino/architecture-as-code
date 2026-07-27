SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test bootstrap-drift bao-test-config
test: ## Validate the D2 topology, dependency components, and Discovery Portal package.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	cd proof-helper && go test ./...
	@if command -v bats >/dev/null 2>&1; then bats test/topology.bats test/portal-package.bats test/bootstrap.bats test/bao-spire.bats test/least-privilege.bats test/gateway-routing.bats test/dex-auth.bats test/dex-runtime.bats; fi

bao-test-config: ## Render and validate bounded OpenBao/SPIRE configuration.
	./test/validate-bao-spire.sh
	kubectl kustomize infra/inf-bao/controllers/local >/dev/null
	kubectl kustomize infra/inf-bao/configs/local >/dev/null

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh
