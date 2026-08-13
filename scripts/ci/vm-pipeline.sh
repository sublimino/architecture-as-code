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

# ── Pull latest code (or use SCP'd code) ─────────────────────────────
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
echo "==> [2/7] Cleaning previous cluster..."
make teardown 2>/dev/null || true

# ── Create cluster + registry + Flux bootstrap ──────────────────────
# Use individual targets instead of `make up` because the shared `wait`
# target expects OSRAMP-demo ResourceSets (policies, infra) that the
# signalloom-only path doesn't create until later. signalloom-local.sh
# has its own dependency waits.
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
echo "==> [4/7] Building containers → local Zot..."
retry 3 make push-local-signalloom
retry 3 make signalloom-spire-helper
retry 3 make signalloom-images

# ── Activate Flux tenants ────────────────────────────────────────────
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

# Stage 2: API contracts (pytest → JUnit XML)
run_stage \
  "API contracts and persistence" \
  "stage2-api.txt" \
  "cd ${WORK_DIR}/d2-signalloom/apps/fe-signalloom/src && \
   uv run --python 3.12 --with pytest --with pytest-asyncio \
     --with-requirements requirements.txt \
     python -m pytest tests -q --junit-xml=${REPORT_DIR}/stage2-api.xml"

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

# Stage 7: Runtime negatives (BATS TAP)
run_stage \
  "Gateway, probes, Dex, and NetworkPolicy runtime negatives" \
  "stage7-runtime.tap" \
  "cd ${WORK_DIR} && bats --tap \
     d2-signalloom/test/runtime.bats \
     d2-signalloom/test/test-1-runtime.bats"

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
