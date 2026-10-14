SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

KUBECONFIG ?= /tmp/osramp-kubeconfig.yaml
ifeq ($(GOPATH),/usr/local/src/gocode)
  override GOPATH = /tmp/gopath
  override GOMODCACHE = /tmp/gomodcache
  override GOCACHE = /tmp/gocache
endif
GOPATH ?= /tmp/gopath
GOCACHE ?= /tmp/gocache
GOMODCACHE ?= /tmp/gomodcache
GONOSUMDB ?= *
CGO_ENABLED ?= 0
HELM_CACHE_HOME ?= /tmp/helm/cache
HELM_CONFIG_HOME ?= /tmp/helm/config
HELM_DATA_HOME ?= /tmp/helm/data
UV_CONFIG_FILE ?= /dev/null
UV_CACHE_DIR ?= /tmp/uv-cache
BATS_JOBS ?= 1
export KUBECONFIG GOPATH GOCACHE GOMODCACHE GONOSUMDB CGO_ENABLED HELM_CACHE_HOME HELM_CONFIG_HOME HELM_DATA_HOME UV_CONFIG_FILE UV_CACHE_DIR BATS_JOBS

.PHONY: test test-netassert bootstrap-drift bao-test-config netassert-config-drift
test: ## Validate the D2 topology, dependency components, and Discovery Portal package.
	./test/validate-topology.sh
	bash ./test/validate-dependencies.sh
	bash ./test/check-netassert-config-drift.sh
	cd proof-helper && go test ./...
	cd apps/cardvault && go test ./...
	cd apps/policy-engine && go test ./...
	@# GLOB, not a hand-maintained list, for the reason this file already states
	@# twice below. The line above cannot reach a NESTED go module: the externally
	@# anchored tiers live in their own modules (apps/policy-engine/oracle, which
	@# holds the CIS pack against upstream k8s.io/pod-security-admission, and
	@# apps/policy-engine/aigf-oracle) precisely so a test-only dependency cannot
	@# move the engine's signed-image dependency graph. The cost of that isolation
	@# is that `go test ./...` skips them, so for a while the only externally
	@# anchored verification in the repo ran when a human typed `make verify-cel`
	@# and in no CI path at all -- you could revert six admissibility fixes and
	@# every gate stayed green. Found by an adversarial audit, 2026-10-10.
	@set -e; mods=$$(find apps/policy-engine -mindepth 2 -name go.mod -not -path '*/node_modules/*' | sort); \
	  [ -n "$$mods" ] || { echo "nested policy-engine modules: none found -- the glob is broken, not the tree"; exit 2; }; \
	  for m in $$mods; do echo "==> $$(dirname $$m)"; (cd $$(dirname $$m) && go test ./... -count=1); done
	@# GLOB again, same reason. The policy packs carry their own anchoring gates --
	@# scripts that hold a pack's control identifiers against the PUBLISHER's
	@# machine-readable text (NIST's OSCAL catalogue, the Publications Office
	@# Cellar XHTML for the EU regulations) and its pricing against a
	@# declare-or-calibrate rule. They are plain sh+jq, need no cluster and run in
	@# about a second, and until now nothing automated ran them at all: a
	@# fabricated control ID or a silently unpriced check would ship green. Found
	@# by the worker that wrote the second one, 2026-10-10.
	@set -e; gates=$$(find ../policy/frameworks -name run-tests.sh -path '*/catalogue/*' | sort); \
	  [ -n "$$gates" ] || { echo "policy-pack catalogue gates: none found -- the glob is broken, not the tree"; exit 2; }; \
	  for g in $$gates; do echo "==> $$g"; (cd $$(dirname $$g)/.. && sh catalogue/run-tests.sh); done
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
	@# proofs live in scripts/gcp-tf/demo-pipeline.sh (frozen) and
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
#                               scripts/gcp-tf/demo-pipeline.sh nor
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
#
#   test/runtime.bats, test/test-1-runtime.bats and test/spire-jwks-live.bats
#                             - LIVE-cluster suites, and they write to it:
#                               runtime.bats and test-1-runtime.bats create and
#                               delete probe pods, all three `kubectl get/wait`
#                               against whatever context is current. The glob
#                               ran them from `make demo-signalloom-test-config`,
#                               the target documented as "without a cluster", so
#                               offline they failed 17 tests on connection
#                               refused, and with an operator's kubeconfig loaded
#                               they acted on the shared cluster from a config
#                               check. runtime.bats and test-1-runtime.bats keep
#                               their owners: stage 7 of scripts/gcp-tf/demo-pipeline.sh
#                               and the root `demo-signalloom-runtime-test`.
#                               spire-jwks-live.bats belongs in the same stage 7
#                               list; it had no other runner.
#
#   test/api-route-liveness.bats
#                             - LIVE-cluster suite: port-forwards the deployed
#                               fe-signalloom and signal-ingest services and
#                               queries their running route tables. Its runner is
#                               demo-signalloom-api-route-liveness in the root
#                               Makefile and stage 7 of the pipelines.
#
#   test/dashboard-fleet-gate.bats
#                             - needs docker and two images it refuses to pull
#                               (nginxinc/nginx-unprivileged:1.27-alpine,
#                               python:3.12-alpine), so in the glob it was red
#                               wherever they had not been pulled by hand. Its
#                               runner is stage 1c5 in both pipeline lanes,
#                               which pulls them first.
EXCLUDED_BATS = test/dashboard-image.bats test/supercred-demo.bats test/supercred-demo-api.bats test/supercred-step1-runtime.bats test/runtime.bats test/test-1-runtime.bats test/spire-jwks-live.bats test/api-route-liveness.bats test/dashboard-fleet-gate.bats

bao-test-config: ## Render and validate bounded OpenBao/SPIRE configuration.
	./test/validate-bao-spire.sh
	kubectl kustomize infra/inf-bao/controllers/local >/dev/null
	kubectl kustomize infra/inf-bao/configs/local >/dev/null

test-netassert: ## Validate NetworkPolicy enforcement with netassert (needs running cluster).
	./test/run-netassert.sh

bootstrap-drift: ## Regenerate bootstrap SQL and compare it with the committed contract.
	bash ./test/check-bootstrap-drift.sh

netassert-config-drift: ## Compare the committed netassert config against its ConfigMap-generator copy.
	bash ./test/check-netassert-config-drift.sh

.PHONY: test-openbao-agent-role-lab
test-openbao-agent-role-lab: ## Behavioural proof of the agent-swarm OpenBao generic role.
	bash ./test/openbao-agent-generic-role-lab.sh

# --- Swarm interactive agent images ---

swarm-governor-image: ## Build swarm-governor image
	docker build -t swarm-governor:latest apps/swarm-governor

swarm-deploy-gate-image: ## Build prod-deploy-gate image
	docker build -t prod-deploy-gate:latest apps/prod-deploy-gate

swarm-interactive-images: swarm-governor-image swarm-deploy-gate-image ## Build all swarm interactive agent images

# ─────────────────────────────────────────────────────────────────────────────
# Agent Swarm — Security, Identity & Containment Validation Fleet
# ─────────────────────────────────────────────────────────────────────────────

.PHONY: swarm-nono-probe-image swarm-stun-sentinel-image swarm-kusari-image swarm-kusari-nono-image swarm-cpai-engineer-nono-image swarm-agent-nono-evidenced-image swarm-security-images swarm-test

swarm-nono-probe-image: ## Build nono-containment-probe under REAL nono/Landlock (stages the host nono binary into the build context).
	@command -v nono >/dev/null || { echo "nono not on PATH; install from https://nono.sh" >&2; exit 1; }
	@v=$$(nono --version 2>/dev/null | awk '{print $$2}'); echo "staging real nono $$v into the build context"
	cp "$$(command -v nono)" apps/nono-containment-probe/nono.real && chmod +x apps/nono-containment-probe/nono.real
	docker build -t nono-containment-probe:latest apps/nono-containment-probe/

# Build context is apps/, NOT apps/signalloom-stun-sentinel/. The Dockerfile
# COPYs both apps/stun-sentinel (the library module providing pkg/{ebpf,correlator},
# unified in 6e50309f) and apps/signalloom-stun-sentinel (the main package), so a
# narrower context fails on the first COPY. Broken since that unification; the
# image had to be built by hand.
#
# THE TAG IS THE SOURCE FINGERPRINT, never a hand-picked version. `v0.2.0`
# was reused for about seven different builds and side-loaded each time, so
# the tag said nothing about the code inside and a node replacement or image
# GC left ImagePullBackOff with no way to rebuild "the same" image. The tag is
# now `src-` + 12 hex of scripts/lib/source-id.sh's fingerprint: a
# deterministic tar of exactly the paths the Dockerfile COPYs, the estate's
# one definition of "which source tree is this image" (signal-ingest also
# tags src-<content digest>, but over its `go list -deps` inputs and with 16
# hex). It tracks content, so a rebase or merge that rewrites commit
# hashes does not move it, and an edit to any COPYd file does. A build refuses
# uncommitted or untracked inputs, so a published tag is reproducible from git.
#
# Two references, one tag:
#   canonical  ghcr.io/...             the base daemonset.yaml, for a remote cluster
#   zot        zot.registry.svc...     the kind overlays; the in-cluster registry every
#                                      other estate image is published to
# test/sentinel-image-provenance.bats renders both overlays and fails when
# the deployed tag is mutable or is not the current source fingerprint.
# SENTINEL_IMAGE_INPUTS was here, naming the dirty-check path set by hand while
# the hash used the Dockerfile-derived set. Two declarations of "what goes into
# this image", and they had diverged: the hand-written one omitted the
# Dockerfile. scripts/sentinel-image-tag.sh now derives both from the Dockerfile.
SENTINEL_DOCKERFILE := signalloom-stun-sentinel/Dockerfile
SENTINEL_IMAGE_CANONICAL ?= ghcr.io/controlplaneio-in-toto/signalloom-warden
SENTINEL_IMAGE_ZOT ?= zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signalloom-warden
# The host-side address of the same zot repository (scripts/push-local-image.sh
# port-forwards svc/zot to localhost:5001).
SENTINEL_IMAGE_PUSH ?= localhost:5001/acme/images/signalloom/apps/signalloom-warden
SENTINEL_DAEMONSET := infra/agent-swarm/signalloom-warden/daemonset.yaml
# test/p6-teardown-preflight.bats checks every workload pins its catalogued
# image, so the pin rewrites the signalloom-warden row too (and only that row).
SENTINEL_CATALOG := ../test/fixtures/cold-start-manifests.tsv
CLUSTER_NAME ?= osramp

.PHONY: sentinel-image-source-id sentinel-image-tag sentinel-image-pin sentinel-image-publish

# The build context is apps/, so source-id.sh's COPY paths are relative to it.
# Its workload table assumes a context-relative Dockerfile only for context
# "."; the two primitives below are the shared hashing, called with this
# image's own context. A COPY of a missing path is refused, never hashed away.
# Both tags come from scripts/sentinel-image-tag.sh, and the recipes below call
# the script directly rather than `$(MAKE) -s sentinel-image-tag`: a recipe
# line containing $(MAKE) is executed even under `make -n`, and the sub-make
# inherits -n, so the build/load/push on that line ran for real against the
# sub-make's printed recipe text instead of a tag. The script reads the input
# definition from here so it stays single-sourced.
export SENTINEL_DOCKERFILE
SENTINEL_TAG_SH := ../scripts/sentinel-image-tag.sh

sentinel-image-source-id: ## Print the sentinel image tag, src-<12 hex> of the files the Dockerfile COPYs (no cleanliness check).
	@$(SENTINEL_TAG_SH) --no-dirty-check

sentinel-image-tag: ## Print the immutable sentinel image tag; refuses when the image's inputs have uncommitted changes.
	@$(SENTINEL_TAG_SH)

swarm-stun-sentinel-image: ## Build the one signalloom-stun-sentinel DaemonSet image, tagged with its source fingerprint.
	@tag=$$($(SENTINEL_TAG_SH)) || exit 1; \
	echo "building $(SENTINEL_IMAGE_ZOT):$$tag"; \
	docker build -t $(SENTINEL_IMAGE_ZOT):$$tag \
		-t $(SENTINEL_IMAGE_CANONICAL):$$tag \
		-f apps/signalloom-stun-sentinel/Dockerfile apps/

sentinel-image-pin: ## Point the base DaemonSet (and so both overlays) at the current source-fingerprint tag.
	@tag=$$($(SENTINEL_TAG_SH)) || exit 1; \
	perl -pi -e 's#^(\s*image: \Q$(SENTINEL_IMAGE_CANONICAL)\E:)\S+#$${1}'"$$tag"'#' $(SENTINEL_DAEMONSET); \
	grep -q "image: $(SENTINEL_IMAGE_CANONICAL):$$tag" $(SENTINEL_DAEMONSET) || { echo "sentinel-image-pin: $(SENTINEL_DAEMONSET) was not updated" >&2; exit 1; }; \
	perl -pi -e 's#^(signalloom-warden\t(?:[^\t]*\t){2})\Q$(SENTINEL_IMAGE_CANONICAL)\E:[^\t]+#$${1}$(SENTINEL_IMAGE_CANONICAL):'"$$tag"'#' $(SENTINEL_CATALOG); \
	awk -F'\t' -v want="$(SENTINEL_IMAGE_CANONICAL):$$tag" '$$1 == "signalloom-warden" { found = 1; if ($$4 != want) exit 1 } END { exit !found }' $(SENTINEL_CATALOG) \
		|| { echo "sentinel-image-pin: the signalloom-warden row of $(SENTINEL_CATALOG) was not updated" >&2; exit 1; }; \
	echo "pinned $(SENTINEL_DAEMONSET) and the $(SENTINEL_CATALOG) signalloom-warden row to :$$tag"

sentinel-image-publish: swarm-stun-sentinel-image ## Load the source-fingerprint image onto kind CLUSTER_NAME and publish it to zot (cluster required).
	@tag=$$($(SENTINEL_TAG_SH)) || exit 1; \
	CLUSTER_NAME=$(CLUSTER_NAME) ../scripts/kind-load-verified.sh $(SENTINEL_IMAGE_ZOT):$$tag && \
	../scripts/push-local-image.sh $(SENTINEL_IMAGE_ZOT):$$tag $(SENTINEL_IMAGE_PUSH):$$tag

swarm-kusari-image: ## Build kusari-agent stub image (Tier 9 Kusari pilot stand-in)
	docker build -t kusari-agent:latest apps/kusari-agent/

swarm-kusari-nono-image: ## Build the kusari agent under REAL nono/Landlock enforcement (stages the host nono binary into the build context).
	@command -v nono >/dev/null || { echo "nono not on PATH; install from https://nono.sh" >&2; exit 1; }
	@v=$$(nono --version 2>/dev/null | awk '{print $$2}'); echo "staging real nono $$v into the build context"
	cp "$$(command -v nono)" apps/kusari-agent/nono.real && chmod +x apps/kusari-agent/nono.real
	docker build -t kusari-agent-nono:latest -f apps/kusari-agent/Dockerfile.nono apps/kusari-agent/

swarm-cpai-engineer-nono-image: ## Build cpai-engineer wrapped in REAL nono/Landlock at PID 1 (stages the host nono binary into the build context).
	@command -v nono >/dev/null || { echo "nono not on PATH; install from https://nono.sh" >&2; exit 1; }
	@v=$$(nono --version 2>/dev/null | awk '{print $$2}'); echo "staging real nono $$v into the build context"
	cp "$$(command -v nono)" apps/cpai-engineer/nono.real && chmod +x apps/cpai-engineer/nono.real
	docker build -t cpai-engineer:latest apps/cpai-engineer/

swarm-agent-nono-evidenced-image: ## Build the SP-5 evidenced demo agent under REAL nono/Landlock (fail-closed; stages the host nono binary into the build context).
	@command -v nono >/dev/null || { echo "nono not on PATH; install from https://nono.sh" >&2; exit 1; }
	@v=$$(nono --version 2>/dev/null | awk '{print $$2}'); echo "staging real nono $$v into the build context"
	cp "$$(command -v nono)" infra/agent-swarm/agent-nono-evidenced/nono.real && chmod +x infra/agent-swarm/agent-nono-evidenced/nono.real
	docker build -t agent-nono-evidenced:latest -f infra/agent-swarm/agent-nono-evidenced/Dockerfile.nono .

swarm-security-images: swarm-nono-probe-image swarm-stun-sentinel-image swarm-kusari-image swarm-kusari-nono-image swarm-cpai-engineer-nono-image swarm-agent-nono-evidenced-image ## Build all security fleet images (all nono images use REAL Landlock)

swarm-test: ## Run unit tests for all swarm agents
	cd apps/cardvault-agent && go test ./...
	cd apps/nono-containment-probe && go test ./...
	cd apps/signalloom-stun-sentinel && go test ./...
	cd apps/kusari-agent && go test ./...

# ─── signal-ingest image provenance ──────────────────────────────────────────
#
# Same treatment as the sentinel: an immutable tag, published to the in-cluster
# zot, pinned in the manifest Flux reconciles. Never the side-loaded
# signal-ingest:local, which predated auth on the live cluster for weeks.
#
# The tag is src-<16 hex>, a digest of exactly the files the Dockerfile's
# `go build` compiles (go list -deps: non-test Go and //go:embed files of both
# local modules, their go.mod/go.sum, the Dockerfile). Not the last commit to
# touch apps/signal-ingest, as for the sentinel: the pin itself lives in
# apps/signal-ingest/base, so a commit tag would name the pin's own commit,
# and a test-only change would move it. A content digest is also stable across
# merges that leave the inputs identical.
# TestReconciledManifestRunsTheImageBuiltFromThisSource fails when stale.
SIGNAL_INGEST_IMAGE_ZOT ?= zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signal-ingest
# Host-side address of the same zot repository (scripts/push-local-image.sh
# port-forwards svc/zot to localhost:5001).
SIGNAL_INGEST_IMAGE_PUSH ?= localhost:5001/acme/images/signalloom/apps/signal-ingest
SIGNAL_INGEST_DEPLOYMENT := apps/signal-ingest/base/deployment.yaml

.PHONY: signal-ingest-image-tag signal-ingest-image signal-ingest-image-pin signal-ingest-image-publish

signal-ingest-image-tag: ## Print signal-ingest's immutable image tag; refuses when its inputs have uncommitted changes.
	@../scripts/signal-ingest-image-tag.sh

signal-ingest-image: ## Build the signal-ingest image under its immutable source tag.
	@tag=$$(../scripts/signal-ingest-image-tag.sh) || exit 1; \
	echo "building $(SIGNAL_INGEST_IMAGE_ZOT):$$tag"; \
	docker build -t $(SIGNAL_INGEST_IMAGE_ZOT):$$tag -f apps/signal-ingest/Dockerfile .

signal-ingest-image-pin: ## Point the signal-ingest Deployment at the current source tag.
	@tag=$$(../scripts/signal-ingest-image-tag.sh) || exit 1; \
	perl -pi -e 's#^(\s*image: \$$\{IMAGE_BASE\}/signalloom/apps/signal-ingest:)\S+#$${1}'"$$tag"'#' $(SIGNAL_INGEST_DEPLOYMENT); \
	grep -qF "/signalloom/apps/signal-ingest:$$tag" $(SIGNAL_INGEST_DEPLOYMENT) || { echo "signal-ingest-image-pin: $(SIGNAL_INGEST_DEPLOYMENT) was not updated" >&2; exit 1; }; \
	echo "pinned $(SIGNAL_INGEST_DEPLOYMENT) to :$$tag"

signal-ingest-image-publish: signal-ingest-image ## Load the source-tagged signal-ingest image onto kind CLUSTER_NAME and publish it to zot (cluster required).
	@tag=$$(../scripts/signal-ingest-image-tag.sh) || exit 1; \
	CLUSTER_NAME=$(CLUSTER_NAME) ../scripts/kind-load-verified.sh $(SIGNAL_INGEST_IMAGE_ZOT):$$tag && \
	../scripts/push-local-image.sh $(SIGNAL_INGEST_IMAGE_ZOT):$$tag $(SIGNAL_INGEST_IMAGE_PUSH):$$tag
