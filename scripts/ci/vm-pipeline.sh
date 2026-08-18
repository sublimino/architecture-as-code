#!/usr/bin/env bash
# vm-pipeline.sh — Runs the Signalloom D2 e2e pipeline on the CI VM.
#
# Called via SSH from gcp-ci.sh or GitHub Actions. Pulls latest code,
# rebuilds the cluster, runs the 10-stage test suite, and generates an
# OpenReports-format report.
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more test stages failed

set -euo pipefail

readonly WORK_DIR="${CI_WORK_DIR:-/home/ci/osramp-demo}"
readonly REPORT_DIR="${CI_REPORT_DIR:-/home/ci/reports}"
readonly REPORT_FILENAME="${CI_REPORT_FILENAME:-signalloom-ci-report.yaml}"
readonly PIPELINE_LOG="${CI_PIPELINE_LOG:-/home/ci/ci-pipeline.log}"
readonly STAGE_TIMEOUT_SECONDS="${CI_STAGE_TIMEOUT_SECONDS:-900}"

exec > >(tee -a "$PIPELINE_LOG") 2>&1

retry() {
  local max_attempts="$1"; shift
  local attempt=1
  while ((attempt <= max_attempts)); do
    if "$@"; then return 0; fi
    echo "RETRY: attempt ${attempt}/${max_attempts} failed: $*" >&2
    ((attempt++))
    sleep $((attempt * 10))
  done
  return 1
}

echo "════════════════════════════════════════════════════════════"
echo "  Signalloom D2 E2E CI — Pipeline"
echo "  Started: $(date -Iseconds)"
echo "════════════════════════════════════════════════════════════"

# ── Environment for tool installers ──────────────────────────────────
export GOPATH="${HOME}/go"
export GOBIN="${HOME}/.local/bin"
export PATH="${HOME}/.local/bin:${HOME}/.local/go/bin:/usr/local/go/bin:${GOPATH}/bin:${PATH}"
mkdir -p "$GOBIN" "$GOPATH"

# ── CI environment for Playwright / Dex ──────────────────────────────
# Must match the bcrypt hash in d2-signalloom/infra/inf-signalloom/base/dex.yaml,
# which is bcrypt("demo-user") — and the `:-demo-user` default already used by
# the Makefile, auth.setup.ts, and signalloom-test-1.spec.ts. Exporting
# "password" here silently overrode all three, so every Dex password grant in CI
# authenticated with the wrong secret. Latent until now: the public-client 401
# (fixed upstream in 34852b6) failed first and masked it.
export DEX_DEMO_PASSWORD="${DEX_DEMO_PASSWORD:-demo-user}"

# monitoring (kube-prometheus-stack) + trivy-system are not dependencies of any
# demo slice and dominate cluster build time. Opt out via the repo's own toggle
# rather than editing manifests: push-local.sh strips the two tenants from a
# temp copy of the fleet dir, and wait-reconciled.sh drops their four
# Kustomization waits (each carrying a 720s existence budget).
export ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-false}"

# wait.sh emits a WAIT_STAT line per wait (site, elapsed, deadline, ratio) but
# only appends to a file when WAIT_STAT_FILE is set — which nothing in CI did,
# so the ranked "which deadline is running hot" signal the library exists to
# produce was discarded on every run. Collect it into the report dir; sorting by
# ratio turns "raise some timeout" into a deterministic ordered list.
export WAIT_STAT_FILE="${WAIT_STAT_FILE:-${REPORT_DIR}/wait-stats.txt}"

# ── Clean state ──────────────────────────────────────────────────────
rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR"

# ── The terminal state has to describe itself ────────────────────────
#
# A run that died before stage 1 left no summary.json at all, so the report
# directory said nothing about what happened. "Reports present, no summary" is
# what you see after an abort, after a pass whose collection failed, and after a
# run that never started — three different outcomes, one indistinguishable
# artifact. On 2026-08-13 that ambiguity was read as a pass twice in one
# session, and the only thing that separated the cases was a gcloud timestamp
# query nobody should have to reach for.
#
# Every exit path now leaves a machine-readable verdict behind. PIPELINE_PHASE
# records how far the run got; the trap writes ONLY when the real summary is
# absent, so a completed run — pass or fail — is reported exactly as before.
#
# Deliberately jq-free: setup.sh installs jq further down this file, so the
# early-abort case is precisely the one where jq is missing. Hand-rolled
# escaping keeps the writer dependency-free.
PIPELINE_PHASE="startup"

json_str() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

write_terminal_summary() {
  local rc="$1"
  # A summary already on disk is the run's own verdict. Never overwrite it.
  [[ -f "${REPORT_DIR}/summary.json" ]] && return 0
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0

  # stage_results is declared below and may not exist yet; the `+` expansion is
  # the only form that is safe under `set -u` for an unset array.
  local -a done_stages=()
  if [[ -n "${stage_results[*]+set}" ]]; then done_stages=("${stage_results[@]}"); fi
  local stages_json="[]"
  if ((${#done_stages[@]} > 0)); then
    stages_json="[$(IFS=,; printf '%s' "${done_stages[*]}")]"
  fi
  local total="${#done_stages[@]}" failed="${failures:-0}"
  local passed=$(( total - failed ))
  ((passed < 0)) && passed=0

  {
    printf '{\n'
    printf '  "outcome": "ABORTED",\n'
    printf '  "overall": "ABORTED",\n'
    printf '  "phase": %s,\n' "$(json_str "$PIPELINE_PHASE")"
    printf '  "exit_code": %d,\n' "$rc"
    printf '  "timestamp": %s,\n' "$(json_str "$(date -Iseconds)")"
    printf '  "commit": %s,\n' "$(json_str "${CI_SOURCE_COMMIT:-unknown}")"
    printf '  "branch": %s,\n' "$(json_str "${CI_SOURCE_BRANCH:-unknown}")"
    printf '  "note": %s,\n' "$(json_str "the pipeline exited during phase '${PIPELINE_PHASE}' without reaching the report stage — this is an ABORTED run, NOT a test result")"
    printf '  "total_stages": %d,\n' "$total"
    printf '  "passed": %d,\n' "$passed"
    printf '  "failed": %d,\n' "$failed"
    printf '  "stages": %s\n' "$stages_json"
    printf '}\n'
  } >"${REPORT_DIR}/summary.json" 2>/dev/null || true
  return 0
}

on_pipeline_exit() {
  local rc=$?
  write_terminal_summary "$rc" || true
  # An EXIT trap hands its own last exit status to the shell, which is how a run
  # with 8/8 stages green once exited 1 (see lock_release in gcp-ci.sh). Exit
  # with the status the script actually asked for, explicitly.
  exit "$rc"
}
trap on_pipeline_exit EXIT

# ── Pull latest code (or use SCP'd code) ─────────────────────────────
PIPELINE_PHASE="pull-code"
echo "==> [1/7] Pulling latest code..."
if [[ ! -d "$WORK_DIR" ]]; then
  echo "ERROR: No code at ${WORK_DIR}. Clone via deploy key or SCP the repo." >&2
  exit 2
fi
cd "$WORK_DIR"
if git remote get-url origin &>/dev/null; then
  git fetch origin 2>/dev/null && git reset --hard origin/main && git clean -fdx \
    || echo "WARNING: git pull failed — using existing code on disk"
else
  # CI_SOURCE_COMMIT / CI_SOURCE_BRANCH are passed by gcp-ci.sh from the machine
  # that owns the real checkout. Without them the summary records the SHA of the
  # throwaway `ci snapshot` commit created below, which is unrelated to the
  # branch under test — two runs of byte-identical code produced two different
  # SHAs (75d0435 and 48b2a62), so no report could be traced to its source.
  echo "==> Using SCP'd code (source: ${CI_SOURCE_BRANCH:-unknown}@${CI_SOURCE_COMMIT:-unknown})"
  # Kustomize uses .git/ as a security boundary for relative path traversal.
  # Without it, refs like ../base/ are rejected. Init a bare repo.
  if [[ ! -d .git ]]; then
    git init -q
    git add -A
    git -c user.name="SignalLoom CI" -c user.email="ci@signalloom.local" \
      commit -q -m "ci snapshot" --allow-empty
  fi
fi

# ── Ensure all tools are present (idempotent — only installs missing) ─
# setup.sh's BIN_DIR logic: if /usr/local/bin is writable → SUDO="" and
# everything (including go install) writes there directly. If not writable
# but sudo available → SUDO="sudo" but go install lines lack ${SUDO} prefix.
# Fix: make /usr/local/bin writable so the first branch fires cleanly.
sudo chmod a+w /usr/local/bin 2>/dev/null || true

# Two installers, and the order is load-bearing.
#
# install-ci-tools.sh fetches version-pinned PRE-BUILT binaries — no compile on
# the VM. It covers go, kind, kubectl, kustomize, helm, flux, crane, cosign,
# syft, grype, bats, python3.
#
# setup.sh --tools-only is the shared local/CI installer and is the ONLY source
# of skopeo, witness, yq, jq, govulncheck and vexctl. It is a complement, never
# a replacement — skopeo in particular is a hard requirement of
# scripts/build-sign-dashboard.sh, which `make signalloom-images` invokes.
#
# Running the pre-built installer FIRST means setup.sh's `have <tool>` guards
# find crane already on PATH and skip it, so the only `go install` compiles left
# are govulncheck and vexctl. Reverse the order and setup.sh compiles crane
# from source before the pinned binary would ever have been considered.
PIPELINE_PHASE="install-tools"
echo "==> Ensuring CI tools (pinned pre-built binaries)..."
bash ./scripts/ci/install-ci-tools.sh

echo "==> Ensuring CI tools (setup.sh — skopeo, witness, yq, jq, and friends)..."
bash ./scripts/setup.sh --tools-only
sudo chmod go-w /usr/local/bin 2>/dev/null || true

if [[ ! -x /opt/google/chrome/chrome ]]; then
  echo "==> Installing Google Chrome for Playwright..."
  sudo npx playwright install chrome
fi

# ffmpeg must be installed by the SAME Playwright version the runner uses.
# acceptance-test.sh runs `bunx playwright test` from test/acceptance against the
# pinned @playwright/test, which looks for one specific revision directory (e.g.
# ~/.cache/ms-playwright/ffmpeg-1011). An unpinned `npx playwright install` from
# the repo root resolves the LATEST release and writes a different revision, and
# `sudo npx` additionally writes into root's cache rather than the ci user's.
# Both produce: "Executable doesn't exist at .../ffmpeg-linux" — which failed
# stage 8 in 89ms on VM1, before the browser ever reached the login page.
echo "==> Installing Playwright ffmpeg helper (pinned to test/acceptance)..."
(
  cd "${WORK_DIR}/test/acceptance"
  [[ -d node_modules/@playwright ]] \
    || bun install --frozen-lockfile 2>/dev/null \
    || bun install
  bunx playwright install ffmpeg
)

# ── Tear down any existing cluster ───────────────────────────────────
PIPELINE_PHASE="clean-cluster"
echo "==> [2/7] Cleaning previous cluster..."
make teardown 2>/dev/null || true

# ── Create cluster + registry + Flux bootstrap ──────────────────────
# Use individual targets instead of `make up` because the shared `wait`
# target expects OSRAMP-demo ResourceSets (policies, infra) that the
# signalloom-only path doesn't create until later. signalloom-local.sh
# has its own dependency waits.
PIPELINE_PHASE="create-cluster"
echo "==> [3/7] Creating Kind cluster + Zot + Flux..."
make cluster
retry 3 make registry
make signing-keys
make push-local-foundation
retry 3 make bootstrap-local
echo "==> Waiting for Flux foundation (skipping demo-specific ResourceSets)..."
retry 3 kubectl -n flux-system wait kustomization/flux-system --for=condition=ready --timeout=10m
kubectl -n flux-system wait kustomization/tenants --for=condition=ready --timeout=10m 2>/dev/null || true

# ── Build and push containers ────────────────────────────────────────
PIPELINE_PHASE="build-images"
echo "==> [4/7] Building containers → local Zot..."
retry 3 make push-local-signalloom
retry 3 make signalloom-spire-helper
retry 3 make signalloom-images
# supercred-demo-runner/base is an unconditional member of
# apps/fe-signalloom/base/kustomization.yaml, so the activation below DEPLOYS
# it whether or not anything built it. Nothing here did, and because the
# workload carries a bare `supercred-demo-runner:local` tag with
# imagePullPolicy: IfNotPresent, containerd resolved it to docker.io/library
# and the kubelet reported
#   unexpected media type text/html ... : not found
# — a registry error for a missing build step.
#
# One missing line, three red stages ~40 minutes in: 6b refused (correctly) to
# certify a workload it could not read, and 8 and 8b failed on the preflight
# that calls 6b with every one of their own tests passing. Makefile:429 fixed
# this in demo-signalloom-up; this file hand-copies that recipe and did not get
# the fix. scripts/check-ci-build-parity.sh (stage 1d) now derives the
# comparison so the next copy cannot drift silently.
retry 3 make demo-signalloom-supercred-images
retry 3 make demo-signalloom-signalfusion-images
# Same shape as the paragraph above, one slice over: fleet-manager/base is now
# an unconditional member of apps/fe-signalloom/base/kustomization.yaml, so
# every bring-up deploys it, and its Deployment pulls a bare
# `fleet-manager:local` tag with imagePullPolicy: IfNotPresent. Without this
# line the CI VM deploys a workload it never built, and the Fleet page answers
# /fleet-api/* with a raw nginx 502.
retry 3 make demo-signalloom-fleet-image

# ── Activate Flux tenants ────────────────────────────────────────────
PIPELINE_PHASE="activate-tenants"
echo "==> [5/7] Activating Flux tenants..."
SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up || {
  echo "WARNING: signalloom-local.sh up exited non-zero — attempting direct ResourceSet activation"
  # Ensure signalloom-apps inputs are populated even if the sequential
  # activation timed out before reaching them.
  kubectl -n flux-system get resourceset signalloom-apps -o jsonpath='{.spec.inputs}' 2>/dev/null \
    | grep -q 'tenant' || {
    echo "==> Directly patching signalloom-apps inputs..."
    kubectl -n flux-system patch resourceset signalloom-apps --type=merge -p '{
      "spec": {
        "inputs": [
          {
            "tenant": "fe-signalloom",
            "component": "fe-signalloom",
            "tag": "latest",
            "environment": "fe-signalloom/local",
            "artifactSubjectWorkflow": "push-signalloom",
            "artifactSubjectGitRef": "refs/heads/main"
          }
        ]
      }
    }'
    echo "==> Waiting for signalloom-apps to reconcile..."
    kubectl -n flux-system wait resourceset/signalloom-apps --for=condition=ready --timeout=5m 2>/dev/null || true
  }

  # This fallback only ever repaired signalloom-APPS. If `up` died before
  # activating signalloom-INFRA, nothing here notices, and the run proceeds to
  # execute ten stages against a cluster whose infra was never brought up.
  # Stage 6 then waits its full budget for infra-controllers and stages 7-8b
  # fail behind it, so a SETUP abort is reported as three test failures — the
  # most expensive possible way to be wrong, because it sends the reader to the
  # tests.
  #
  # Half a recovery is worse than none. Say what actually happened and stop.
  if ! kubectl -n flux-system get resourceset signalloom-infra \
       -o jsonpath='{.spec.inputs}' 2>/dev/null | grep -q 'tenant'; then
    echo "ERROR: signalloom-infra was never activated — its inputs are empty." >&2
    echo "       This is a SETUP failure, not a test failure. The test stages" >&2
    echo "       would run against a cluster with no infra and report stages" >&2
    echo "       6, 7 and 8 as broken, which would be misleading." >&2
    echo "       Check the output of signalloom-local.sh up above." >&2
    exit 2
  fi
}

# ── Run 10-stage test suite ───────────────────────────────────────────
PIPELINE_PHASE="tests"
echo "==> [6/7] Running 10-stage test suite..."

failures=0
declare -a stage_results=()

run_stage() {
  local name="$1" output_file="$2"; shift 2
  local exit_code=0

  echo "──── TEST: ${name} (timeout ${STAGE_TIMEOUT_SECONDS}s) ────"
  timeout -k 30s "${STAGE_TIMEOUT_SECONDS}s" bash -c "$*" > "${REPORT_DIR}/${output_file}" 2>&1 || exit_code=$?
  if ((exit_code == 124)); then
    printf '\nTIMEOUT: stage exceeded %ss and was terminated\n' "$STAGE_TIMEOUT_SECONDS" >> "${REPORT_DIR}/${output_file}"
  fi

  local status="pass"
  if ((exit_code != 0)); then
    status="fail"
    ((failures+=1))
  fi
  echo "  ${status^^}: ${name} (exit ${exit_code})"

  stage_results+=("$(jq -nc \
    --arg n "$name" --arg s "$status" --argjson c "$exit_code" --arg f "$output_file" \
    '{name:$n, status:$s, exit_code:$c, file:$f}')")
}

# Stage 1: Static contracts (BATS TAP)
run_stage \
  "Static topology, Gateway, probes, Dex, and policy contracts" \
  "stage1-static.tap" \
  "cd ${WORK_DIR} && make -C d2-signalloom test"

# Stage 1b: Dashboard unit and guard suite (vitest)
#
# Numbered 1b rather than renumbering 2-8: openreports-convert.sh maps report
# FILES to parsers by name, so inserting a stage costs nothing as long as the
# existing filenames stay put.
#
# Placed here, before ~25 minutes of cluster work, because it is the cheapest
# stage in the pipeline (~12s) and it gates the most expensive ones.
#
# This suite ran nowhere in CI until now, which mattered more than it sounds:
# it carries lockfileSync.test.ts, the guard for this directory being the only
# one in the repo with both a bun.lock and a package-lock.json. `bun add`
# writes the former while the dashboard Dockerfile runs `npm ci` against the
# latter, so a desync builds clean locally and breaks the image on any clean
# tree. That drift has reached a cold VM once already. It was caught then by
# the Dockerfile's own `npm ci` failing, which is luck rather than a guard --
# and luck that only pays out after the image build stage, not here.
#
# --frozen-lockfile is the point of the install, not a detail: it makes a
# lockfile that disagrees with package.json a stage failure rather than
# something bun silently reconciles on the way past.
run_stage \
  "Dashboard unit and guard suite" \
  "stage1b-dashboard-unit.txt" \
  "cd ${WORK_DIR}/d2-signalloom/apps/dashboard-signalloom && \
   bun install --frozen-lockfile && \
   bun run test --run --reporter=junit \
     --outputFile=${REPORT_DIR}/stage1b-dashboard-unit.xml"

# Stage 1c: Acceptance-spec coverage guard (BATS TAP)
#
# Numbered 1c for the reason 1b was numbered 1b: openreports-convert.sh maps
# report FILES to parsers by name, so an inserted stage costs nothing as long as
# the existing filenames stay put.
#
# What it guards is this file. Until now stage 8 ran one of the 15 specs in
# test/acceptance, two more were reachable from make targets, and FOUR matched
# no `testMatch` in test/acceptance/playwright.config.ts at all -- so they ran
# nowhere, including under `make acceptance-test`. Playwright does not warn when
# no project claims a spec; it reports a smaller total and exits 0.
#
# That is the same silent-degradation shape as the missing junit reporter
# documented in playwright.config.ts, and it cost coverage the day this stage
# was added: d9d1d2f rewrote a test in smoke.spec.ts to assert the Collusion &
# Access page carries no page-specific background, and nothing would ever have
# run it.
#
# The guard reads test/acceptance/SPEC-REGISTRY.tsv and cross-checks it against
# the filesystem, playwright.config.ts, the Makefile and this file, in both
# directions. A spec added without a registry row fails here; so does a row
# claiming a CI stage that does not run it -- which is why adding stage 8b below
# and forgetting its row would be caught by the stage before it.
#
# python3 and coreutils only: no cluster, no node_modules, no network, ~1s. It
# sits here for the same reason 1b does, ahead of the expensive stages it gates.
run_stage \
  "Acceptance-spec coverage registry" \
  "stage1c-acceptance-coverage.tap" \
  "cd ${WORK_DIR} && bats --tap test/acceptance-spec-coverage.bats"

# Stage 1d: CI build parity (BATS TAP)
#
# Numbered 1d for the reason 1b and 1c were: openreports-convert.sh maps report
# FILES to parsers by name, so an inserted stage costs nothing as long as the
# existing filenames stay put.
#
# What it guards is this file, like 1c does — but stage [4/7] rather than the
# stage list. This file cannot call `make demo-signalloom-up`, so it hand-copies
# the recipe (see the "Use individual targets" comment above), and a copy drifts.
# It has drifted twice. The second time cost a whole lane: one missing
# `make demo-signalloom-supercred-images` left supercred-demo-runner in
# ImagePullBackOff, stage 6b correctly refused to certify a workload it could not
# read, and stages 8 and 8b failed on the preflight that calls 6b with all 29 of
# their own tests passing. Three red stages, no failing test, ~40 minutes in.
#
# scripts/check-ci-build-parity.sh derives the comparison from the Makefile
# recipe and from this file rather than checking a list, because a list is the
# same artefact as the copy: it drifts the moment someone edits one and not the
# other. Deliberate omissions live in its allowlist with a reason, and the
# allowlist is itself checked for entries that have gone stale or dead.
#
# bats and coreutils only: no cluster, no docker, no network, ~1s. It sits here
# with 1b and 1c, ahead of the ~25 minutes of cluster work it protects — the
# failure it catches is otherwise unreachable until stage 6b.
run_stage \
  "CI build parity with demo-signalloom-up" \
  "stage1d-build-parity.tap" \
  "cd ${WORK_DIR} && bats --tap test/ci-build-parity.bats"

# Stage 1e: Node-image expectations (BATS TAP)
#
# Numbered 1e for the reason 1b, 1c and 1d were: openreports-convert.sh maps
# report FILES to parsers by name, so an inserted stage costs nothing as long as
# the existing filenames stay put.
#
# What it guards is a diagnostic rather than a build: doctor's image check used
# to compare the node against a seven-element constant of OSRAMP and Olly
# images. This file deliberately skips the OSRAMP-demo ResourceSets, so on this
# path all seven are absent BY DESIGN and doctor reported "7 image(s) missing"
# on every run it made — green ones included. A lane agent read that constant as
# a variable during a genuinely failing run and built arithmetic on it; the
# number had been identical in the passing run an hour earlier.
#
# scripts/check-node-images.sh now derives the expected set from the images
# deployed workloads actually reference, so the profile is observed rather than
# declared, and the second defect — a whole-line regex that let a repo from one
# column meet a tag from another — is a columnar comparison.
#
# bats and coreutils only: no cluster, no docker, no network, ~1s. It sits with
# 1b, 1c and 1d because its fakes need nothing the VM has to build first.
run_stage \
  "Doctor node-image expectations" \
  "stage1e-node-images.tap" \
  "cd ${WORK_DIR} && bats --tap test/node-images.bats"

# Stage 1f: The harness reporting honestly about itself (BATS TAP)
#
# 1f rather than a second 1e: this stage and the node-image stage above were
# written in parallel and both took the next free suffix. The suffix convention
# only keeps insertion cheap while each suffix names exactly one stage, and
# openreports-convert.sh keys on the FILE, so two stages sharing a number is
# ambiguity waiting to be resolved wrongly by whoever touches this next.
#
# What it guards is the terminal state THIS FILE and gcp-ci.sh leave behind: an
# aborted run must announce itself in a file, and a report must never be
# readable as describing a run it does not describe. Those are the two failures
# that on 2026-08-13 were twice nearly reported as passes.
#
# It runs here, with the other static guards, because it needs no cluster and
# takes ~2s — and because a guard on how the pipeline reports should not itself
# depend on 25 minutes of the pipeline succeeding first.
run_stage \
  "CI terminal-state honesty" \
  "stage1f-ci-terminal-state.tap" \
  "cd ${WORK_DIR} && bats --tap test/ci-terminal-state.bats"

# Stage 1g: Static guards that no runner previously invoked (BATS TAP)
#
# Numbered 1g for the reason 1b-1f were: openreports-convert.sh maps report
# FILES to parsers by name, so an inserted stage costs nothing as long as the
# existing filenames stay put.
#
# WHY THIS STAGE EXISTS. Measured across the tree before it was added: 68 .bats
# suites present, 35 executed by a runner, **33 never executed by anything**.
# All 33 passed. They were not broken, they were unasked -- written, reviewed,
# committed, several of them documented as the guard for a thing, and providing
# exactly zero regression protection because no runner named them. Among them
# dashboard-route-collisions.bats, which TESTING.md, AGENTS.md and two docs all
# describe as THE enforcement mechanism for nginx prefix/SPA route collisions;
# and deployed-staleness.bats, keys-dir-path-safety.bats and
# audit-anchor-keys-path.bats, all three written within the last 115 commits.
#
# This is stage 1c's defect in a second runner. 1c exists because a Playwright
# spec matching no project's testMatch is silently skipped -- exit 0, no warning
# -- and four specs hid that way. The bats suite had the identical hole: a
# hand-maintained list in d2-signalloom/Makefile and hand-maintained run_stage
# lines here, both of which omit by default. The guard was invented for one
# runner and never carried across to the other.
#
# Two halves, and it needs both: d2-signalloom/Makefile now GLOBS test/*.bats so
# a new suite runs unless deliberately opted out, and
# d2-signalloom/test/bats-registry-coverage.bats (stage 1h) fails when a suite
# is unrun, when an opt-out has no reason, and -- importantly -- when the glob
# itself is replaced by a hand list again. Asserting only the outcome would pass
# happily against a tree that no longer contains the mechanism.
#
# All 29 below were verified green standalone before being added here. They are
# static: no cluster, no docker, no network. supercred-images.bats is NOT in the
# list -- it exceeded a 90s standalone budget without failing, so it belongs
# with the image stages rather than in a fast gate; it is declared in the
# guard's ledger with that reason rather than silently dropped.
run_stage \
  "Static guards previously invoked by nothing" \
  "stage1g-unregistered-guards.tap" \
  "cd ${WORK_DIR} && bats --tap \
     test/audit-anchor-keys-path.bats \
     test/bao-spire-proof.bats test/ci-lock.bats \
     test/ci-path-anchoring.bats test/ci-state-locality.bats \
     test/cosign-signing-consistency.bats test/demo-lifecycle.bats \
     test/flux-dynamic-labels.bats \
     test/flux-substitution.bats test/gcp-ci-ssh-diagnosis.bats \
     test/gcp-ci-vm-status.bats test/healthcheck.bats \
     test/k8s-afm-preflight.bats test/keys-dir-path-safety.bats \
     test/kind-config-heredoc.bats test/kind-load-verified.bats \
     test/resourceset-activation-race.bats test/revocation-demo.bats \
     test/signalfusion-demo.bats test/signalfusion-images.bats \
     test/signalloom-local-lifecycle.bats \
     test/signalloom-security-validation-evidence.bats \
     test/supercred-crictl-shim.bats test/supercred-demo-stun.bats \
     test/supercred-fleet-demo-harness.bats test/supercred-image-visibility.bats \
     test/supercred-state.bats test/supervise-port-forward.bats \
     test/zot-cache.bats"

# Stage 1h: bats registry coverage (BATS TAP)
#
# The fixed point. Stage 1g is itself a hand-maintained list, and a
# hand-maintained list is the artefact that caused this whole problem -- it omits
# by default and drifts the moment someone adds a suite. This stage is what makes
# 1g's list self-correcting: it fails when a .bats file exists that neither the
# d2-signalloom glob nor this file invokes.
#
# It is the direct analogue of stage 1c for bats, and it registers itself: it
# lives in d2-signalloom/test/ and is therefore covered by the same glob it
# asserts, so it cannot go unrun without failing.
#
# bats, sed and coreutils only: no cluster, no network, ~1s.
run_stage \
  "bats registry coverage" \
  "stage1h-bats-registry.tap" \
  "cd ${WORK_DIR} && bats --tap d2-signalloom/test/bats-registry-coverage.bats"

# Stage 1i: Audit-guard reintroduction proof (12 cases)
#
# Reintroduces, one at a time, each defect the audit provenance guard exists to
# catch, and requires the guard to go RED for every one. A guard suite that has
# never been shown to fail is a suite nobody has tested.
#
# It was invoked by NOTHING. Not by this pipeline, not by any Makefile target.
# It is a shell script rather than a .bats file, so stage 1h's registry guard
# could not see it either — the coverage hole has a third shape, and one orphan
# was hiding in it. That orphan happens to be the only thing in the repository
# that proves the audit guards work at all.
#
# It costs SEVEN SECONDS. Measured: `exit=0 elapsed=7s red=12 notfired=0`.
# There was never a runtime argument for leaving it out.
#
# It restores every file it mutates on the way out, including on failure, via
# its own EXIT trap — verified: `git status` is clean after a run.
run_stage \
  "Audit-guard reintroduction proof" \
  "stage1i-audit-reintroduction.txt" \
  "cd ${WORK_DIR} && \
   echo \"proof-script: \$(ls -l d2-signalloom/test/audit-guard-reintroduction-proof.sh 2>&1)\" && \
   echo \"python3: \$(command -v python3 || echo MISSING) \$(python3 -V 2>&1)\" && \
   echo \"pytest: \$(python3 -m pytest --version 2>&1 | head -1)\" && \
   bash d2-signalloom/test/audit-guard-reintroduction-proof.sh; \
   rc=\$?; echo \"proof-exit=\$rc\"; exit \$rc"

# Stage 1k: RBAC subject and roleRef resolution (BATS TAP)
#
# A RoleBinding naming a ServiceAccount that does not exist is legal. The API
# server stores it, Flux marks it Ready, and it grants nothing. Same for a
# roleRef pointing at a Role nobody created. The only symptom is a 403 on a call
# that should have been allowed, which in this estate mostly surfaces as fewer
# results rather than as an error — the agent discovery proxy shipped exactly
# that defect.
#
# Derives both sides from the manifests, INCLUDING objects nested inside Flux
# ResourceSet spec.resources[]. That nesting is not a detail: a top-level-only
# scan sees 2 Roles where there are 13 and reports a false positive against
# Role/fe-signalloom-health-reader.
#
# The suite also injects drift into fixture repos and requires the checker to
# exit non-zero, so it cannot decay into a checker that scans nothing.
#
# python3 + PyYAML and git only: no cluster, no network, ~2s.
run_stage \
  "RBAC subject resolution" \
  "stage1l-rbac-subjects.tap" \
  "cd ${WORK_DIR} && bats --tap test/rbac-subject-resolution.bats"

# Stage 1m: Vocabulary seam guard mutation proof (11 cases)
#
# The same argument as stage 1i, for the dashboard/API/database vocabulary
# guards. Injects each defect those guards exist to catch — an emitted event
# type with no filter option, a filter matching nothing the API emits, a
# lifecycle state the constraint forbids, a stale allowlist entry — and requires
# a RED test for every one, then requires recovery on restore.
#
# Two of those assertions were red against live code when written (21 of 22
# emitted audit event types had no filter; every agent is created in a state the
# fleet view could not select). The other nine were green from the first run,
# which is precisely the condition under which a guard that can never fail looks
# identical to one that works.
#
# Restores every mutated file through an EXIT trap, by cp from a backup rather
# than `git checkout --`, so an interrupted run cannot leave a defect behind or
# delete uncommitted work. Verified: `git status` is clean after a run.
#
# python3 + pytest only: no cluster, no network, ~12s.
run_stage \
  "Vocabulary seam mutation proof" \
  "stage1m-seam-mutation-proof.txt" \
  "cd ${WORK_DIR} && \
   bash d2-signalloom/test/seam-guard-mutation-proof.sh; \
   rc=\$?; echo \"proof-exit=\$rc\"; exit \$rc"

# Stage 1j: CI report integrity (BATS TAP)
#
# Asserts the CI reporting chain is internally consistent: every structured
# report the pipeline produces is mapped in the converter, no converter entry
# uses the wrong parser for its file format, and no entry names a file the
# pipeline does not produce. A missing or mismatched entry means results are
# silently dropped or contribute zero rows while looking configured.
#
# Also asserts test-count floors: the minimum number of tests each suite must
# execute to prove the runner actually ran. The floor for pytest is 500 (current
# 594), vitest is 1800 (current 2099), Go is 30 (current 45), bats d2 is 200
# (current ~234). A count at or near the floor means the runner is broken, not
# that the code is wrong.
#
# bats and grep only: no cluster, no network, no docker, ~1s.
run_stage \
  "CI report integrity" \
  "stage1j-ci-report-integrity.tap" \
  "cd ${WORK_DIR} && bats --tap test/ci-report-integrity.bats"

# Stage 1k: exec-probe ban (BATS TAP)
#
# Numbered 1k for the reason 1b through 1j were: openreports-convert.sh maps
# report FILES to parsers by name, so an inserted stage costs nothing as long
# as the existing filenames stay put.
#
# Bans `kubectl exec` as a probe in test files, outside a reasoned allowlist.
# The defect it ends is the most dangerous single item in the engineering note
# on this repo, because it made a SECURITY test pass: cardvault is distroless,
# so `kubectl exec ... wget` failed with "executable file not found" whether
# the endpoint demanded auth or served card data to anyone. The assertion was
# `[ "$status" -ne 0 ]`. Four sibling tests failed visibly for the same reason
# and were noticed; the auth one passed and was not.
#
# Placed with the other static gates, ahead of ~25 minutes of cluster work, for
# the reason 1b and 1c sit here: bats, find, sed and grep only -- no cluster,
# no network, no docker, ~2s.
run_stage \
  "Exec-probe ban in test files" \
  "stage1k-exec-probe-ban.tap" \
  "cd ${WORK_DIR} && bats --tap test/no-exec-probes-in-tests.bats"
# Stage 1o: Vacuous-assertion lint
#
# Item 3 on the leverage-ordered fix list in Andy's silent-failure note:
# "Lint for vacuous assertions -- observedGeneration >= 0, --for=condition=ready
# on a Deployment, bats tests whose only assertion is [ \"$status\" -ne 0 ]".
#
# The premise, from the same note: "A check that cannot fail is worse than no
# check, because it reads as coverage." That is not theoretical here --
# `readyExpr: status.observedGeneration >= 0` gated FIVE Flux dependencies while
# being trivially true, and had ALREADY been named an anti-pattern in
# d2-osramp-fleet/AGENTS.md before shipping five times. Documentation without an
# enforcing test is a suggestion.
#
# Six shapes (VAC001-VAC006). It found five real ones on its first run, every
# one the same family: a bare `[ "$status" -ne 0 ]` on a grep. grep reserves
# exit 1 for "ran fine, selected nothing" and 2 for "could not run", so `-ne 0`
# reads a MISSING FILE as "the forbidden pattern is absent" -- a pass earned by
# scanning nothing. Identical in shape to the cannot-verify/verified-clean
# conflation fixed in check-flux-substitution.sh at stage 6c.
#
# Static: bash, grep and python3 only. No cluster, no network.
run_stage \
  "Vacuous-assertion lint" \
  "stage1o-vacuous-assertions.txt" \
  "cd ${WORK_DIR} && ./scripts/check-vacuous-assertions.sh"

# Stage 1p: the vacuous lint's own falsification suite
#
# The lint is itself a check, so it is held to the rule it enforces: these 39
# tests inject each vacuous shape and require the lint to report it, then
# require a clean file to pass. A lint nobody has watched fail is exactly what
# it exists to ban.
run_stage \
  "Vacuous-assertion lint falsification" \
  "stage1p-vacuous-lint-proof.tap" \
  "cd ${WORK_DIR} && bats --tap test/vacuous-assertions.bats"

# Stage 1q: guard falsification proof -- prove the guards can actually fail
#
# Stage 1o is the STATIC cousin of this stage: it reads assertions and reports
# the ones whose shape cannot fail. It cannot see a guard that is correctly
# written and pointed at nothing, and it says so itself -- it is blind to a
# tautology inside a GENERATED script. That gap is what this stage covers.
#
# For each registered guard it mutates the REAL FILE the guard's real-tree
# assertion reads, requires the guard to go red for the RIGHT reason, restores
# the bytes and requires green again. Fixture tests like ci-build-parity.bats
# already prove the CHECKERS can go red; they prove nothing about whether the
# real-tree assertion is still WIRED to the real tree, which is precisely the
# check-flux-substitution.sh shape -- a correct checker, pointed at nothing,
# reporting success.
#
# A guard that stays green gets a POSITIVE CONTROL applied before any verdict is
# printed: a blunter form of the same defect. Control red means a blind spot in a
# live guard; control green means decoration. The distinction is not cosmetic --
# the first run of this harness called two working guards "decoration" and both
# went red under the control. Blind spots get widened, decoration gets rewritten.
#
# Exit codes: 0 all red as required; 1 a guard did not fire; 3 a case could not
# be run (UNKNOWN -- never counted as a pass); 4 the tree was not restored.
#
# Output is PROSE, not TAP, so there is deliberately NO entry for it in
# scripts/ci/openreports-convert.sh. A parseTap entry pointed at prose matches
# nothing and contributes zero rows while reading as configured -- worse than no
# entry, and the exact defect stage 1j exists to catch. Stages 1i and 1m are
# .txt for the same reason.
#
# Static: bash, bats, python3 and git only. No cluster, no network. The harness
# performs reads only against Kubernetes and no registered case invokes kubectl.
run_stage \
  "Guard falsification proof" \
  "stage1q-guard-falsification.txt" \
  "cd ${WORK_DIR} && ./test/guard-falsification-proof.sh"

# Stage 2: API contracts (pytest → JUnit XML)
run_stage \
  "API contracts and persistence" \
  "stage2-api.txt" \
  "cd ${WORK_DIR}/d2-signalloom/apps/fe-signalloom/src && \
   uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
     --with-requirements requirements.txt \
     python -m pytest tests -q -rf --junit-xml=${REPORT_DIR}/stage2-api.xml"

# Stage 3: Fake integrations (pytest → JUnit XML)
run_stage \
  "Deterministic fake integrations" \
  "stage3-fakes.txt" \
  "cd ${WORK_DIR} && \
   PYTHONPATH=d2-signalloom/apps/fake-integration-proxy \
   uv run --python 3.12 --with pytest \
     python -m pytest d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py \
     -q --junit-xml=${REPORT_DIR}/stage3-fakes.xml"

# Stage 4: Dashboard API (Go test → JSON)
run_stage \
  "Dashboard API ownership contract" \
  "stage4-dashboard.json" \
  "cd ${WORK_DIR}/tools/demo-console && go test -json ./..."

# Stage 5: Harness contract (BATS TAP)
run_stage \
  "TEST-1 harness contract" \
  "stage5-harness.tap" \
  "cd ${WORK_DIR} && bats --tap \
     test/signalloom-test-1-harness.bats \
     test/ci-installer-privileges.bats"

# Stage 6: Flux convergence
run_stage \
  "Flux and workload convergence" \
  "stage6-flux.tap" \
  "cd ${WORK_DIR} && make demo-signalloom-test"

# Stage 6b: Deployed-vs-source drift
#
# Placed immediately after convergence and before every stage that asserts
# against the running system. Stages 7, 8 and 8b all exercise workloads through
# the cluster, and each of them passes happily against a pod built from an older
# tree — which is how a fully-tested streaming fix was reported as working on
# 2026-08-13 while the pods answering the requests predated all 22 of its
# commits. Proving the running code IS this checkout is a precondition for
# reading anything the later stages say about this checkout.
#
# Exits 2 rather than 1 when it cannot reach the cluster, so a broken kubeconfig
# fails this stage instead of quietly certifying the deployment.
run_stage \
  "Deployed workloads match the source under test" \
  "stage6b-deployed-staleness.txt" \
  "cd ${WORK_DIR} && make check-deployed-staleness"

# Stage 6c: Flux variable substitution (live objects)
#
# Item 5 on the leverage-ordered fix list in Andy's silent-failure note --
# "move the substitution guard from `make healthcheck` into CI: catch at PR, not
# deploy" -- and it had never been done. `scripts/check-flux-substitution.sh`
# was reachable ONLY from `make healthcheck`, which no CI stage invokes, so a
# literal ${VAR} surviving into live Flux objects passed every CI run there has
# ever been.
#
# What it guards: `postBuild.substituteFrom` is a SILENT NO-OP when a key is
# missing. The token is left literal, the apply succeeds, and the object is
# marked Ready=True with nothing retrying. On 2026-08-02 cert-manager, ingress,
# monitoring and trivy-system all came up with a literal ${ARTIFACT_TAG} in their
# OCIRepository tag and ran that way for hours while every status field claimed
# health.
#
# Placed here, after stage 6 has converged Flux and before the runtime stages,
# because it reads LIVE objects -- it is not a static check and cannot run in the
# 1x gates.
#
# NOTE: moving this stage into CI was only worth doing after fixing the guard
# itself. It swallowed every kubectl failure in `2>/dev/null || true` and then
# reported "no unsubstituted ${VAR} tokens", so it printed success against NO
# CLUSTER AT ALL (reproduced: `KUBECONFIG=/nonexistent … ; EXIT=0`). Wiring that
# version in would have added a green stage that proves nothing -- worse than no
# stage, because it reads as coverage. It now exits 2 for "cannot verify",
# separately from 0 for "verified clean", and counts the objects it examined so
# that scanning nothing cannot report success.
run_stage \
  "Flux variable substitution in live objects" \
  "stage6c-flux-substitution.txt" \
  "cd ${WORK_DIR} && ./scripts/check-flux-substitution.sh"

# Stage 7: Runtime negatives (BATS TAP)
run_stage \
  "Gateway, probes, Dex, and NetworkPolicy runtime negatives" \
  "stage7-runtime.tap" \
  "cd ${WORK_DIR} && bats --tap \
     d2-signalloom/test/runtime.bats \
     d2-signalloom/test/test-1-runtime.bats \
     d2-signalloom/test/supercred-demo-api.bats \
     d2-signalloom/test/api-route-liveness.bats"

# Stage 7b: Adversarial API surface probes (BATS TAP)
#
# 15 hostile probes against the live Gateway: unauthenticated mutations, forged
# JWTs, path traversal, null bytes, oversized bodies/headers, CRLF injection,
# information leakage, and endpoint health. These need the cluster and the
# Gateway port-forward, so they sit here alongside the other runtime stages.
run_stage \
  "Adversarial API surface probes" \
  "stage7b-adversarial.tap" \
  "cd ${WORK_DIR} && bats --tap test/api-adversarial.bats"

# Stage 8: Browser journey (Playwright → JUnit XML)
run_stage \
  "Dex and complete dashboard journey matrix" \
  "stage8-browser.txt" \
  "cd ${WORK_DIR} && \
   PLAYWRIGHT_JUNIT_OUTPUT_FILE=${REPORT_DIR}/stage8-browser.xml \
   ./scripts/acceptance-test.sh signalloom-test-1.spec.ts"

# Stage 8b: Dashboard page smoke suite (Playwright → JUnit XML)
#
# The second browser stage, and the only one that walks every page in the
# sidebar. Stage 8 proves the Dex contracts and the TEST-1 journey matrix;
# smoke.spec.ts proves each of the ten nav destinations renders its heading and
# representative content with no uncaught page error, plus the page-level
# assertions nothing else covers: the DemoToggle, the Help & Support modal, the
# unknown-route redirect, the Agent Trust Topology denial evidence, and the
# Collusion & Access background assertion added in d9d1d2f -- which ran nowhere
# until this stage existed.
#
# Runtime, and why it is affordable. 18 tests. It is the only browser spec that
# needs no auth setup: the `smoke` project carries no storageState and no
# dependency on the setup project, so each test logs in through Dex itself and
# nothing serialises them. The CI VM is n2-standard-16, so Playwright's default
# worker count is 8 and the 18 run in roughly three waves. Budget a couple of
# minutes against a lane that already runs 40-60, with the 900s stage timeout as
# the ceiling that would catch a hang.
#
# Why the locators are safe here, which was the open question. smoke.spec.ts
# addresses nav links by accessible name with { exact: true }, the pattern
# signalloom-test-1.spec.ts explicitly avoids because the sidebar renders count
# badges that turn "Compliance" into "Compliance 7" on live data. That comment
# predates bd0ba7a, which put aria-hidden="true" on every badge span; the badges
# no longer contribute to the accessible name, so the exact-name locators hold
# against a live estate. If a badge ever loses that attribute this stage goes
# red, which is the correct outcome -- it is an accessibility regression too.
#
# Separate from stage 8 rather than appended to it so a failure names the page
# smoke suite instead of "the browser stage", and so the report keeps the two
# journeys distinct. Passing the filename takes the non-TEST-1 branch of
# acceptance-test.sh, which adds Grafana/Archivista/Olly port-forwards that skip
# cleanly when those services are absent.
run_stage \
  "Dashboard page smoke suite" \
  "stage8b-smoke.txt" \
  "cd ${WORK_DIR} && \
   PLAYWRIGHT_JUNIT_OUTPUT_FILE=${REPORT_DIR}/stage8b-smoke.xml \
   ./scripts/acceptance-test.sh smoke.spec.ts"

# Write stage results JSON
printf '%s\n' "${stage_results[@]}" | jq -s '.' > "${REPORT_DIR}/stages.json"

# ── Generate OpenReports + summary ───────────────────────────────────
PIPELINE_PHASE="report"
echo "==> [7/7] Generating OpenReports report..."
bash "${WORK_DIR}/scripts/ci/openreports-convert.sh" "$REPORT_DIR" "$REPORT_FILENAME"

# Summary JSON
node -e "
  const fs = require('fs');
  const stages = JSON.parse(fs.readFileSync('${REPORT_DIR}/stages.json', 'utf-8'));
  const summary = {
    timestamp: new Date().toISOString(),
    commit: '${CI_SOURCE_COMMIT:-$(git -C ${WORK_DIR} rev-parse --short HEAD)}',
    branch: '${CI_SOURCE_BRANCH:-$(git -C ${WORK_DIR} rev-parse --abbrev-ref HEAD)}',
    // \`outcome\` is the field a reader should branch on: it is the only one that
    // can also say ABORTED (written by write_terminal_summary above when the
    // pipeline never reached this line). \`overall\` is kept identical to what it
    // has always been so nothing that reads it changes meaning.
    outcome: stages.every(s => s.status === 'pass') ? 'PASS' : 'FAIL',
    phase: 'report',
    overall: stages.every(s => s.status === 'pass') ? 'PASS' : 'FAIL',
    total_stages: stages.length,
    passed: stages.filter(s => s.status === 'pass').length,
    failed: stages.filter(s => s.status === 'fail').length,
    stages: stages
  };
  fs.writeFileSync('${REPORT_DIR}/summary.json', JSON.stringify(summary, null, 2));
  console.log(JSON.stringify(summary, null, 2));
"

echo ""
echo "════════════════════════════════════════════════════════════"
if ((failures == 0)); then
  echo "  RESULT: PASS (${#stage_results[@]}/${#stage_results[@]} stages)"
else
  echo "  RESULT: FAIL (${failures} of ${#stage_results[@]} stages failed)"
fi
echo "  Finished: $(date -Iseconds)"
echo "════════════════════════════════════════════════════════════"

exit "$failures"
