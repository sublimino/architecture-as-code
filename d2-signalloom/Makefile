SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: test test-netassert bootstrap-drift bao-test-config netassert-config-drift
test: ## Validate the D2 topology, dependency components, and Discovery Portal package.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	bash ./test/check-netassert-config-drift.sh
	cd proof-helper && go test ./...
	cd apps/cardvault && go test ./...
	cd apps/policy-engine && go test ./...
	cd apps/cardvault-agent && go test ./...
	@if command -v bats >/dev/null 2>&1; then bats test/topology.bats test/portal-package.bats test/bootstrap.bats test/bao-spire.bats test/least-privilege.bats test/gateway-routing.bats test/dex-auth.bats test/dex-runtime.bats test/dex-config-reload.bats test/supercred-runner-contract.bats; fi

bao-test-config: ## Render and validate bounded OpenBao/SPIRE configuration.
	./test/validate-bao-spire.sh
	kubectl kustomize infra/inf-bao/controllers/local >/dev/null
	kubectl kustomize infra/inf-bao/configs/local >/dev/null

test-netassert: ## Validate NetworkPolicy enforcement with netassert (needs running cluster).
	@command -v netassert >/dev/null 2>&1 || { echo "netassert not installed — see https://github.com/controlplaneio/netassert"; exit 1; }
	@AGENT_POD=$$(kubectl get pod -n fe-signalloom-agents -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && \
	  [ -n "$$AGENT_POD" ] || { echo "no agent pod found in fe-signalloom-agents"; exit 1; } && \
	  sed "s/name: agent-patsy/name: $$AGENT_POD/g" test/netassert-signalloom.yaml > /tmp/netassert-signalloom-run.yaml && \
	  netassert run -f /tmp/netassert-signalloom-run.yaml -P 3

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh

netassert-config-drift: ## Compare the committed netassert config against its ConfigMap-generator copy.
	bash ./test/check-netassert-config-drift.sh
