SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

KUBECONFIG ?= /tmp/osramp-kubeconfig.yaml
GOCACHE ?= /tmp/gocache
GOMODCACHE ?= /tmp/gomodcache
CGO_ENABLED ?= 0
HELM_CACHE_HOME ?= /tmp/helm/cache
HELM_CONFIG_HOME ?= /tmp/helm/config
HELM_DATA_HOME ?= /tmp/helm/data
UV_CONFIG_FILE ?= /dev/null
UV_CACHE_DIR ?= /tmp/uv-cache
BATS_JOBS ?= 1
export KUBECONFIG GOCACHE GOMODCACHE CGO_ENABLED HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME UV_CONFIG_FILE UV_CACHE_DIR BATS_JOBS

.PHONY: test test-netassert bootstrap-drift bao-test-config netassert-config-drift
test: ## Validate the D2 topology, dependency components, and Discovery Portal package.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	bash ./test/check-netassert-config-drift.sh
	cd proof-helper && go test ./...
	cd apps/cardvault && go test ./...
	cd apps/policy-engine && go test ./...
	cd apps/cardvault-agent && go test ./...
	cd apps/cpai-engineer && go test ./...
	cd apps/signalloom-stun-sentinel && go test ./...
	@# Executes the Dex web templates against mirrors of the structs Dex passes
	@# them. Nothing else in this repo ever executes those templates -- they are
	@# YAML strings mounted into an upstream image -- so a field name Dex does
	@# not supply was invisible until a user hit the page. error.html rendered
	@# {{ .Error }}, which dex has never passed it, and because templates.err()
	@# writes the 4xx status BEFORE Execute and skips the writeRecorder guard,
	@# the client got a truncated 1.2KB page reading only "Error".
	cd test/dex-templates && go test ./...
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
		BATS_PARALLEL_OPT=""; \
		if [ "$${BATS_JOBS:-1}" -gt 1 ] 2>/dev/null && command -v parallel >/dev/null 2>&1; then \
			BATS_PARALLEL_OPT="--jobs $${BATS_JOBS} --no-parallelize-within-files"; \
		fi; \
		bats $$BATS_PARALLEL_OPT $$(ls test/*.bats | grep -vxF -f <(printf '%s\n' $(EXCLUDED_BATS))); \
	fi
	@# The falsification half of test/spire-server-durability.bats. That suite
	@# asserts spire-server's CA is on a PVC and its Deployment is Recreate;
	@# this injects each defect in turn and requires the suite to go RED, so a
	@# guard that has quietly stopped being able to fail cannot keep reporting
	@# durability the cluster no longer has.
	@#
	@# Registered here rather than in a pipeline on purpose. The two sibling
	@# proofs live in scripts/ci/vm-pipeline.sh (frozen) and
	@# scripts/gcp-tf/demo-pipeline.sh (a live bring-up); this one is a static
	@# manifest guard with no cluster dependency, so it belongs with the other
	@# static gates and costs ~20s. A Makefile target counts as a runner for
	@# test/bats-registry-coverage.bats, which is what fails if this line is
	@# ever removed -- an unregistered proof is reported, not silently dropped.
	@#
	@# It mutates three tracked manifests and restores them from a backup keyed
	@# on full relative path, verifying sha256 equality before it exits, with
	@# the restore on an EXIT/INT/TERM trap so a kill does not leave the tree
	@# mutated.
	@if command -v bats >/dev/null 2>&1; then \
		bash ./test/spire-durability-mutation-proof.sh; \
	fi
	@# The falsification half of test/kagent-credentials.bats, registered for the
	@# same reason as the spire proof directly above: a proof nothing runs proves
	@# nothing, and test/bats-registry-coverage.bats fails when one is orphaned.
	@# It was orphaned -- it arrived with the credential work and no runner named
	@# it, which turned guard 7 red on a tree where it had been green.
	@#
	@# Same discipline as its sibling: it mutates tracked files, restores them
	@# from a path-keyed backup on an EXIT trap, and verifies sha256 equality
	@# before exiting, so an interrupt cannot leave the tree mutated.
	@if command -v bats >/dev/null 2>&1; then \
		bash ./test/falsify-kagent-credentials.sh; \
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
#
#   test/supercred-demo-api.bats - port-forwards svc/dex and
#                               svc/dashboard-signalloom in setup() and drives
#                               the demo runner over HTTP. It is a RUNTIME
#                               suite that the stage-1 glob was pulling into the
#                               STATIC contract stage, where no port-forward
#                               exists. It passed on the warm CI VM and failed
#                               on the cold one (curl exit 56, then
#                               `wait_tcp 127.0.0.1:15557` timing out) -- the
#                               warm pass was timing luck, not a property.
#                               Moved to stage 7, which runs after Flux has
#                               converged; NOT dropped.
#
#   test/supercred-step1-runtime.bats - a pure RUNTIME probe, and its own header
#                               says so: it waits on deployment/cardvault in
#                               inf-signalloom and pod/agent-cardvault in
#                               fe-signalloom-agents, and deploys neither.
#                               Those two objects are created in exactly ONE
#                               place in this repository —
#                               scripts/supercred-demo.sh step 1 (`kubectl apply
#                               -k apps/cardvault/base` and `kubectl apply -f
#                               agents-cardvault.yaml`), reached via `make
#                               demo-signalloom-supercred-1`. Neither
#                               scripts/ci/vm-pipeline.sh nor
#                               scripts/gcp-tf/demo-pipeline.sh ever calls
#                               either one: they build the supercred IMAGES
#                               (`make demo-signalloom-supercred-images`) and
#                               stop there.
#
#                               Nor does Flux supply them. apps/cardvault/base
#                               is named by no kustomization at all, and the
#                               agent POD is deliberately excluded from
#                               apps/fe-signalloom/base/kustomization.yaml —
#                               only agents-cardvault-sa.yaml is there, because
#                               that Kustomization's targetNamespace would
#                               relocate the pod out of the namespace its SPIFFE
#                               ID, SPIRE selectors and OpenBao role all name.
#                               The comment there states it outright: "the fix is
#                               to have exactly one creator, and it must be the
#                               demo script."
#
#                               So the glob was running a probe for objects that
#                               nothing in the pipeline creates, in TWO stages —
#                               stage1-static, and stage6-flux via
#                               demo-signalloom-test → demo-signalloom-test-config
#                               → `$(MAKE) -C d2-signalloom test`. One defect,
#                               two stage failures, twice per run.
#
#                               NOT dropped, and NOT moved to stage 7: stage 7
#                               does not deploy SuperCred step 1 either, so
#                               relocating it there would move the failure rather
#                               than fix it. It keeps its existing owner, the
#                               root target `demo-signalloom-supercred-runtime-test`
#                               (Makefile: "cluster required; does not deploy"),
#                               which is an explicit operator entry point run
#                               after `make demo-signalloom-supercred-1`. That
#                               is the only context in which its precondition
#                               holds, and it is the contract the file's own
#                               header already asks for.
EXCLUDED_BATS = test/dashboard-image.bats test/supercred-demo.bats test/supercred-demo-api.bats test/supercred-step1-runtime.bats

bao-test-config: ## Render and validate bounded OpenBao/SPIRE configuration.
	./test/validate-bao-spire.sh
	kubectl kustomize infra/inf-bao/controllers/local >/dev/null
	kubectl kustomize infra/inf-bao/configs/local >/dev/null

test-netassert: ## Validate NetworkPolicy enforcement with netassert (needs running cluster).
	@command -v netassert >/dev/null 2>&1 || { echo "netassert not installed — see https://github.com/controlplaneio/netassert"; exit 1; }
	@AGENT_POD=$$(kubectl get pod -n fe-signalloom-agents -l netassert.signalloom.ai/fixture=generic-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) ; \
	  [ -n "$$AGENT_POD" ] || AGENT_POD=$$(kubectl get pod -n fe-signalloom-agents -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) ; \
	  [ -n "$$AGENT_POD" ] || { echo "no agent pod found in fe-signalloom-agents"; exit 1; } && \
	  sed "s/name: agent-patsy/name: $$AGENT_POD/g" test/netassert-signalloom.yaml > /tmp/netassert-signalloom-run.yaml && \
	  netassert run -f /tmp/netassert-signalloom-run.yaml -P 3

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh

netassert-config-drift: ## Compare the committed netassert config against its ConfigMap-generator copy.
	bash ./test/check-netassert-config-drift.sh

# --- Swarm interactive agent images ---

swarm-zulip-image: ## Build zulip-chat-agent image
	docker build -t zulip-chat-agent:latest apps/zulip-chat-agent

swarm-governor-image: ## Build swarm-governor image
	docker build -t swarm-governor:latest apps/swarm-governor

swarm-deploy-gate-image: ## Build prod-deploy-gate image
	docker build -t prod-deploy-gate:latest apps/prod-deploy-gate

swarm-interactive-images: swarm-zulip-image swarm-governor-image swarm-deploy-gate-image ## Build all swarm interactive agent images

# ─────────────────────────────────────────────────────────────────────────────
# Agent Swarm — Security, Identity & Containment Validation Fleet
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: swarm-nono-probe-image swarm-stun-sentinel-image swarm-security-images swarm-test

swarm-nono-probe-image: ## Build nono-containment-probe image
	docker build -t nono-containment-probe:latest apps/nono-containment-probe/

swarm-stun-sentinel-image: ## Build signalloom-stun-sentinel DaemonSet image
	docker build -t stun-sentinel:latest apps/signalloom-stun-sentinel/

swarm-security-images: swarm-nono-probe-image swarm-stun-sentinel-image ## Build all security fleet images

swarm-test: ## Run unit tests for all swarm agents
	cd apps/cardvault-agent && go test ./...
	cd apps/nono-containment-probe && go test ./...
	cd apps/signalloom-stun-sentinel && go test ./...
