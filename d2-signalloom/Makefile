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
	@# GLOB, not a hand-maintained list. This line used to name ten .bats files
	@# explicitly while 32 sat in test/, so 22 suites -- roughly 300 passing
	@# assertions -- were committed, documented, and never executed by anything.
	@# Among them dashboard-route-collisions.bats, which TESTING.md, AGENTS.md and
	@# two docs all describe as THE enforcement mechanism for nginx route
	@# collisions.
	@#
	@# This is the failure mode the repo already fixed for Playwright: a spec
	@# matching no project's testMatch is silently skipped, exit 0, no warning
	@# (test/acceptance-spec-coverage.bats exists for exactly that, and runs as CI
	@# stage 1c). bats had the identical hole and no equivalent guard. Globbing
	@# inverts the default so a new suite runs unless someone opts it out, and
	@# test/bats-registry-coverage.bats fails on an opt-out with no reason -- and
	@# on any attempt to replace this glob with a list again.
	@if command -v bats >/dev/null 2>&1; then \
		bats $$(ls test/*.bats | grep -vxF "$(EXCLUDED_BATS)"); \
	fi

# Suites deliberately not run by `make test`, each with its reason. Asserted
# against reality by test/bats-registry-coverage.bats: an entry naming a file
# that does not exist is a failure, so this cannot rot into a list that silently
# pre-approves anything.
#
#   test/dashboard-image.bats - builds a container and runs it on a host port, so
#                               it needs docker and a populated .keys/. It belongs
#                               with the image stages, not with the static
#                               contracts. Verified green in a full checkout (3/3)
#                               before exclusion; not dropped silently.
EXCLUDED_BATS = test/dashboard-image.bats

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
