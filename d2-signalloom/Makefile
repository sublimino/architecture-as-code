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
	@# `-f -` with one pattern per line, NOT `grep -vxF "$(EXCLUDED_BATS)"`.
	@# That earlier form worked with a single exclusion and silently stopped
	@# working the moment a second was added: the variable expands to
	@# "test/a.bats test/b.bats" on ONE line, which -xF matches against no
	@# filename at all, so BOTH exclusions became no-ops. It was invisible
	@# locally, because the suite it was meant to exclude happened to pass on my
	@# box -- a port-forward from earlier work was still up. It failed on the CI
	@# VM, twice, in two different stages.
	@#
	@# Same shape as everything else this guard family exists for: a mechanism
	@# that silently does nothing, in a place where doing nothing looks like
	@# success. The exclusion list is verified as actually applied by
	@# test/bats-registry-coverage.bats.
	@if command -v bats >/dev/null 2>&1; then \
		bats $$(ls test/*.bats | grep -vxF -f <(printf '%s\n' $(EXCLUDED_BATS))); \
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
#
#   test/supercred-demo.bats  - needs a LIVE policy-engine on localhost:18081.
#                               Passes locally only because a port-forward from
#                               earlier work happened to be up. On the CI VM it
#                               failed at lines 150 and 164 with
#                               "reachable http://localhost:18081/healthz
#                               (deadline 10s)" -- 2 of 249 in stage 1. This
#                               target is the STATIC contract stage; a test that
#                               needs a running service belongs with the runtime
#                               stages, which already port-forward for it.
#                               Its passing locally was an accident of my
#                               environment, which is its own small lesson: a
#                               green run on a developer box is not evidence
#                               about a clean one.
EXCLUDED_BATS = test/dashboard-image.bats test/supercred-demo.bats

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
