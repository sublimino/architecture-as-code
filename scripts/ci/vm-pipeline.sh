#!/usr/bin/env bash
# vm-pipeline.sh — Runs the Signalloom D2 e2e pipeline on the CI VM.
#
# Called via SSH from gcp-ci.sh or GitHub Actions. Pulls latest code,
# rebuilds the cluster, runs the 8-stage test suite, and generates an
# OpenReports-format report.
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more test stages failed

set -euo pipefail

readonly WORK_DIR="/home/ci/osramp-demo"
readonly REPORT_DIR="/home/ci/reports"
readonly PIPELINE_LOG="/home/ci/ci-pipeline.log"

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
export PATH="${HOME}/.local/bin:${GOPATH}/bin:${PATH}"
mkdir -p "$GOBIN" "$GOPATH"

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
  echo "==> Using SCP'd code (no git remote)"
fi

# ── Ensure all tools are present (idempotent — only installs missing) ─
# setup.sh's BIN_DIR logic: if /usr/local/bin is writable → SUDO="" and
# everything (including go install) writes there directly. If not writable
# but sudo available → SUDO="sudo" but go install lines lack ${SUDO} prefix.
# Fix: make /usr/local/bin writable so the first branch fires cleanly.
sudo chmod a+w /usr/local/bin 2>/dev/null || true
echo "==> Ensuring CI tools..."
bash ./scripts/setup.sh --tools-only
sudo chmod go-w /usr/local/bin 2>/dev/null || true

# ── Tear down any existing cluster ───────────────────────────────────
echo "==> [2/7] Cleaning previous cluster..."
make teardown 2>/dev/null || true

# ── Create cluster + registry + Flux bootstrap ──────────────────────
echo "==> [3/7] Creating Kind cluster + Zot + Flux..."
make up

# ── Build and push containers ────────────────────────────────────────
echo "==> [4/7] Building containers → local Zot..."
retry 3 make push-local-signalloom
retry 3 make signalloom-spire-helper
retry 3 make signalloom-images

# ── Activate Flux tenants ────────────────────────────────────────────
echo "==> [5/7] Activating Flux tenants..."
SIGNALLOOM_SKIP_PREPARE=1 ./scripts/signalloom-local.sh up

# ── Run 8-stage test suite ───────────────────────────────────────────
echo "==> [6/7] Running 8-stage test suite..."

failures=0
declare -a stage_results=()

run_stage() {
  local name="$1" output_file="$2"; shift 2
  local exit_code=0

  echo "──── TEST: ${name} ────"
  bash -c "$*" > "${REPORT_DIR}/${output_file}" 2>&1 || exit_code=$?

  local status="pass"
  if ((exit_code != 0)); then
    status="fail"
    ((failures++))
  fi
  echo "  ${status^^}: ${name}$(( exit_code != 0 ? 1 : 0 )) (exit ${exit_code})"

  stage_results+=("$(jq -nc \
    --arg n "$name" --arg s "$status" --argjson c "$exit_code" --arg f "$output_file" \
    '{name:$n, status:$s, exit_code:$c, file:$f}')")
}

# Stage 1: Static contracts (BATS TAP)
run_stage \
  "Static topology, Gateway, probes, Dex, and policy contracts" \
  "stage1-static.tap" \
  "cd ${WORK_DIR} && make -C d2-signalloom test"

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
  "cd ${WORK_DIR} && bats --tap test/signalloom-test-1-harness.bats"

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

# Write stage results JSON
printf '%s\n' "${stage_results[@]}" | jq -s '.' > "${REPORT_DIR}/stages.json"

# ── Generate OpenReports + summary ───────────────────────────────────
echo "==> [7/7] Generating OpenReports report..."
bash "${WORK_DIR}/scripts/ci/openreports-convert.sh" "$REPORT_DIR"

# Summary JSON
node -e "
  const fs = require('fs');
  const stages = JSON.parse(fs.readFileSync('${REPORT_DIR}/stages.json', 'utf-8'));
  const summary = {
    timestamp: new Date().toISOString(),
    commit: '$(git -C ${WORK_DIR} rev-parse --short HEAD)',
    branch: '$(git -C ${WORK_DIR} rev-parse --abbrev-ref HEAD)',
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
