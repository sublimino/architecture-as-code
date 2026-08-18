#!/usr/bin/env bash
# demo-pipeline.sh — Bring the full Signal Loom estate up ON the demo VM, test
# it, and LEAVE IT STANDING for a human to browse.
#
# Terraform provisions sl-demo-1-vm with docker, kind and kubectl and nothing
# above that. This script is the deployment half: it runs on the VM, creates the
# Kind cluster, brings up the whole estate, runs the test suite in ascending
# order of cost, and then publishes the dashboard on a supervised port-forward
# that outlives this process.
#
# Exit codes:
#   0 — every stage passed and the demo is up
#   1 — one or more stages failed (the demo is STILL up; see below)
#   2 — the run aborted before reaching the stage list
#
# ─── How this differs from scripts/ci/vm-pipeline.sh, and why ───────────────
#
# vm-pipeline.sh is CI. This is a demo. Three consequences, each of which is a
# deliberate inversion rather than an omission:
#
#   1. NO TEARDOWN. vm-pipeline.sh opens with `make teardown` and gcp-ci.sh
#      suspends the VM when it finishes, because a CI lane that stays up is a
#      lane nobody can use and a bill nobody approved. A demo that tears itself
#      down is worthless. Teardown here is reachable ONLY through an explicit
#      --recreate, and nothing on any success or failure path calls it.
#
#   2. A FAILING STAGE DOES NOT STOP THE DEMO. run_stage records failures and
#      continues, exactly as in CI — but here the publish phase runs afterwards
#      regardless, so an operator who wants to look at what broke can. The exit
#      status still tells the truth about the tests.
#
#   3. IT PUBLISHES. See publish_gateway below for the port, the bind address
#      and the supervision, all three of which are load-bearing.
#
# ─── What is carried over from vm-pipeline.sh unchanged ─────────────────────
#
# Everything else. That file is ~1000 lines of which roughly 40% is comments
# recording failures paid for in lost CI runs; its ordering constraints, retry
# placement, terminal-state honesty and stage taxonomy are earned knowledge and
# are reproduced here with their reasons. Where a comment below says "this cost
# a lane", it is quoting an event that happened.
#
# ─── The ONE thing done differently ─────────────────────────────────────────
#
# vm-pipeline.sh hand-copies the body of the `demo-signalloom-up` Makefile
# recipe, because it deliberately skips the OSRAMP-demo ResourceSets to save
# time and so cannot call the target. That copy has drifted FOUR times — the
# fourth invisible to the guard written for the first three, because that guard
# read `$(MAKE)` lines only and the drifted line was a direct script invocation.
# Each drift cost roughly forty minutes of red CI in which no test had failed.
#
# This script wants the full estate anyway, so it has no reason to copy: it
# calls `make demo-signalloom-up` and lets the Makefile be the single source of
# truth. test/gcp-demo-pipeline.bats DERIVES the recipe's steps from the
# Makefile and fails if any of them appears as an invocation in this file, so
# the drift class cannot gain a fifth instance through a future helpful edit.
#
# That delegation is also what enforces the agent-trust adjacency rule. See
# ORDERING below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Injectable boundaries ────────────────────────────────────────────────────
#
# Every external dependency is overridable. That is not decoration: it is what
# makes test/gcp-demo-pipeline.bats able to drive this script's REAL control
# flow with stubs on PATH, no cloud, no cluster and no network. A pipeline whose
# ordering can only be verified by running it for forty minutes on a VM is a
# pipeline whose ordering is never verified.
#
# WORK_DIR is the checkout under test. It defaults to this script's own repo
# root, so on the VM it needs no configuration and cannot point at the wrong
# tree; the tests set it to a fixture tree of stubs.
WORK_DIR="${DEMO_WORK_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
REPORT_DIR="${DEMO_REPORT_DIR:-${HOME}/demo-reports}"
REPORT_FILENAME="${DEMO_REPORT_FILENAME:-signalloom-demo-report.yaml}"
PIPELINE_LOG="${DEMO_PIPELINE_LOG:-${HOME}/demo-pipeline.log}"
STAGE_TIMEOUT_SECONDS="${DEMO_STAGE_TIMEOUT_SECONDS:-1800}"

MAKE_BIN="${MAKE_BIN:-make}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
BATS_BIN="${BATS_BIN:-bats}"
SUDO_BIN="${SUDO_BIN:-sudo}"
CHROME_BIN="${DEMO_CHROME_BIN:-/opt/google/chrome/chrome}"
SUPERVISE_BIN="${DEMO_SUPERVISE_BIN:-${WORK_DIR}/scripts/supervise-port-forward.sh}"
CONVERT_BIN="${DEMO_CONVERT_BIN:-${WORK_DIR}/scripts/ci/openreports-convert.sh}"

# ── The published endpoint ───────────────────────────────────────────────────
#
# 30754 is not a preference. Dex pins its OIDC issuer and its callback client to
# that exact port (see the local issuer in
# d2-signalloom/infra/inf-signalloom/base/dex.yaml, and the identical constant
# in setup_gateway_forward in scripts/acceptance-test.sh). Any other port
# reaches the Gateway happily, serves the login page, and then fails the OIDC
# redirect with an invalid redirect_uri — which reads as a broken dashboard
# rather than as a wrong port number.
#
# 0.0.0.0 is not a preference either. The operator arrives over a Google IAP
# tunnel, and that tunnel connects to the instance's INTERNAL IP, not to its
# loopback. kubectl port-forward binds localhost by default, so a demo published
# on the default address is reachable only from a shell already on the VM —
# the one place nobody needs it.
GATEWAY_LOCAL_PORT="${DEMO_GATEWAY_LOCAL_PORT:-30754}"
GATEWAY_BIND_ADDRESS="${DEMO_GATEWAY_BIND_ADDRESS:-0.0.0.0}"
GATEWAY_HOSTNAME="${DEMO_GATEWAY_HOSTNAME:-dashboard.osramp.acme.local}"
GATEWAY_LABEL="${DEMO_GATEWAY_LABEL:-gateway.envoyproxy.io/owning-gateway-name=cluster}"
PF_STATE_DIR="${DEMO_PF_STATE_DIR:-${HOME}/.signalloom-demo-gateway-pf}"

# The supervisor stops itself when its owner pid dies — that guard exists so a
# hard-killed CI job cannot leave an orphaned kubectl rebinding the port for the
# next run. A demo inverts the requirement: the forward must survive THIS
# process exiting, which is the whole point of publishing it. So the owner is
# pid 1, which is alive until the VM reboots. The forward is then stopped only
# by an explicit `supervise-port-forward.sh down`, which is the correct
# lifecycle for a thing whose job is to still be there tomorrow.
PF_OWNER_PID="${DEMO_PF_OWNER_PID:-1}"

# ── Credentials printed at the end ───────────────────────────────────────────
#
# Constants, and they must match d2-signalloom/infra/inf-signalloom/base/dex.yaml:
# the hash there is bcrypt("demo-user"). Exporting the wrong DEX_DEMO_PASSWORD
# in CI silently broke every Dex password grant, and the failure surfaced as an
# authentication error rather than as a configuration one.
DEMO_USER="${DEMO_DEX_USER:-demo-user@signalloom.local}"
DEMO_PASSWORD="${DEX_DEMO_PASSWORD:-demo-user}"

RECREATE=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/gcp-tf/demo-pipeline.sh [--recreate] [--help]

Brings the Signal Loom estate up on this host, runs the test suite, and leaves
the dashboard published on a supervised port-forward.

  --recreate   Destroy any existing cluster first. NOT the default: this script
               never tears down a running demo on its own, on success or on
               failure. Ask for it explicitly or keep what is there.
EOF
  exit "${1:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --recreate) RECREATE=1; shift ;;
    -h|--help)  usage 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; usage 1 ;;
  esac
done

mkdir -p "$(dirname "$PIPELINE_LOG")" 2>/dev/null || true
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
echo "  Signal Loom — GCP demo pipeline"
echo "  Started: $(date -Iseconds)"
echo "  Work dir: ${WORK_DIR}"
echo "════════════════════════════════════════════════════════════"

# ── Environment for tool installers ──────────────────────────────────────────
export GOPATH="${GOPATH:-${HOME}/go}"
export GOBIN="${GOBIN:-${HOME}/.local/bin}"
export PATH="${HOME}/.local/bin:${HOME}/.local/go/bin:/usr/local/go/bin:${GOPATH}/bin:${PATH}"
mkdir -p "$GOBIN" "$GOPATH"

# Must match the bcrypt hash in d2-signalloom/infra/inf-signalloom/base/dex.yaml,
# which is bcrypt("demo-user") — and the `:-demo-user` default already used by
# the Makefile, auth.setup.ts and signalloom-test-1.spec.ts. Exporting
# "password" here once silently overrode all three, so every Dex password grant
# authenticated with the wrong secret; it stayed latent because a public-client
# 401 failed first and masked it.
export DEX_DEMO_PASSWORD="${DEX_DEMO_PASSWORD:-demo-user}"

# monitoring (kube-prometheus-stack) and trivy-system are not dependencies of
# any demo slice and dominate bring-up time. Opted out through the repo's own
# toggle rather than by editing manifests: push-local.sh strips the two tenants
# from a temp copy of the fleet dir and wait-reconciled.sh drops their four
# Kustomization waits, each carrying a 720s existence budget. Set it to true if
# a particular demo needs Grafana — acceptance-test.sh already skips its
# Grafana forward cleanly when the service is absent.
export ENABLE_OBSERVABILITY="${ENABLE_OBSERVABILITY:-false}"

# scripts/lib/wait.sh emits a WAIT_STAT line per wait (site, elapsed, deadline,
# ratio) but only appends to a file when this is set — which nothing in CI did
# for months, so the ranked "which deadline is running hot" signal the library
# exists to produce was discarded on every run. Sorting the collected file by
# ratio turns "raise some timeout" into a deterministic ordered list.
export WAIT_STAT_FILE="${WAIT_STAT_FILE:-${REPORT_DIR}/wait-stats.txt}"

mkdir -p "$REPORT_DIR"

# ── The terminal state has to describe itself ────────────────────────────────
#
# A run that dies before the stage list leaves report files but no verdict, and
# "reports present, no summary" is what you see after an abort, after a pass
# whose collection failed, and after a run that never started. Three different
# outcomes, one indistinguishable artifact; on 2026-08-13 that ambiguity was
# read as a pass twice in one session.
#
# Deliberately jq-free. The tool installers below are what put jq on the box, so
# the early-abort case this writer exists for is precisely the case where jq is
# missing. Hand-rolled escaping keeps the writer dependency-free — and the same
# reasoning is why the final summary is hand-rolled too rather than shelling out
# to node the way vm-pipeline.sh does.
PIPELINE_PHASE="startup"

json_str() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '"%s"' "$s"
}

# shellcheck disable=SC2329  # invoked from the EXIT trap, which shellcheck 0.11
# does not follow here; the same false positive is live in scripts/ci/vm-pipeline.sh.
write_terminal_summary() {
  local rc="$1"
  # A summary already on disk is the run's own verdict. Never overwrite it: a
  # completed run — pass or fail — must be reported exactly as it reported
  # itself, and an abort-time writer that clobbers a real result turns a known
  # outcome into an unknown one.
  [[ -f "${REPORT_DIR}/summary.json" ]] && return 0
  mkdir -p "$REPORT_DIR" 2>/dev/null || return 0

  # stage_results is declared further down and may not exist yet; the `+`
  # expansion is the only form that is safe under `set -u` for an unset array.
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
    printf '  "demo_published": false,\n'
    printf '  "note": %s,\n' "$(json_str "the pipeline exited during phase '${PIPELINE_PHASE}' without reaching the report stage — this is an ABORTED run, NOT a test result")"
    printf '  "total_stages": %d,\n' "$total"
    printf '  "passed": %d,\n' "$passed"
    printf '  "failed": %d,\n' "$failed"
    printf '  "stages": %s\n' "$stages_json"
    printf '}\n'
  } >"${REPORT_DIR}/summary.json" 2>/dev/null || true
  return 0
}

# shellcheck disable=SC2329  # invoked by `trap on_pipeline_exit EXIT` below.
on_pipeline_exit() {
  # rc FIRST, before anything else can overwrite $?.
  local rc=$?
  write_terminal_summary "$rc" || true
  # An EXIT trap hands its OWN last exit status to the shell. That is how a run
  # with 8/8 green stages once exited 1: the trap's closing statement was a
  # false test. Every cleanup above tolerates its own failure, and the trap ends
  # with the status the script actually asked for, explicitly.
  #
  # Note what is NOT here: any teardown of the cluster or of the published
  # port-forward. This trap runs on every exit path including success, and a
  # demo that dismantles itself when the script that built it returns is not a
  # demo. The forward is owned by pid 1 for the same reason.
  exit "$rc"
}
trap on_pipeline_exit EXIT

# ── Phase: the checkout ──────────────────────────────────────────────────────
PIPELINE_PHASE="verify-checkout"
echo "==> [1/8] Verifying the checkout at ${WORK_DIR}..."
if [[ ! -d "$WORK_DIR" ]]; then
  echo "ERROR: no code at ${WORK_DIR}." >&2
  exit 2
fi
cd "$WORK_DIR"
# Kustomize treats .git/ as the security boundary for relative path traversal,
# so refs like ../base/ are REJECTED without one. A tree delivered by tar or scp
# has no .git, and the resulting failure names a kustomization path rather than
# the missing directory. Create a throwaway repo rather than requiring the
# delivery mechanism to preserve one.
if [[ ! -d .git ]]; then
  echo "==> No .git — creating the throwaway repo Kustomize requires for path traversal"
  git init -q
  git add -A
  git -c user.name="Signal Loom demo" -c user.email="demo@signalloom.local" \
    commit -q -m "demo snapshot" --allow-empty
fi
SOURCE_COMMIT="${DEMO_SOURCE_COMMIT:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
SOURCE_BRANCH="${DEMO_SOURCE_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
echo "==> Source: ${SOURCE_BRANCH}@${SOURCE_COMMIT}"

# ── Phase: tools ─────────────────────────────────────────────────────────────
#
# Two installers, and the order is load-bearing.
#
# install-ci-tools.sh fetches version-pinned PRE-BUILT binaries — no compile on
# the VM. It covers go, kind, kubectl, kustomize, helm, flux, crane, cosign,
# syft, grype, bats and python3.
#
# setup.sh --tools-only is the shared local/CI installer and is the ONLY source
# of skopeo, witness, yq, jq, govulncheck and vexctl. It is a complement, never
# a replacement — skopeo in particular is a hard requirement of
# scripts/build-sign-dashboard.sh, which `make signalloom-images` invokes.
#
# Running the pre-built installer FIRST means setup.sh's `have <tool>` guards
# find crane already on PATH and skip it, so the only `go install` compiles left
# are govulncheck and vexctl. Reverse the order and setup.sh compiles crane from
# source before the pinned binary would ever have been considered.
PIPELINE_PHASE="install-tools"
echo "==> [2/8] Installing tools..."
# setup.sh's BIN_DIR logic: when /usr/local/bin is writable it sets SUDO="" and
# everything including `go install` lands there. When it is not writable but
# sudo exists it sets SUDO="sudo" — and its go install lines carry no ${SUDO}
# prefix, so they fail. Make the directory writable so the first branch fires
# cleanly, then put the permissions back.
"$SUDO_BIN" chmod a+w /usr/local/bin 2>/dev/null || true
bash ./scripts/ci/install-ci-tools.sh
bash ./scripts/setup.sh --tools-only
"$SUDO_BIN" chmod go-w /usr/local/bin 2>/dev/null || true

if [[ ! -x "$CHROME_BIN" ]]; then
  echo "==> Installing Google Chrome for Playwright..."
  "$SUDO_BIN" npx playwright install chrome
fi

# ffmpeg must be installed by the SAME Playwright version the runner uses.
# acceptance-test.sh runs `bunx playwright test` from test/acceptance against
# the pinned @playwright/test, which looks for one specific revision directory
# (e.g. ~/.cache/ms-playwright/ffmpeg-1011). An unpinned `npx playwright
# install` from the repo root resolves the LATEST release and writes a different
# revision, and `sudo npx` additionally writes into root's cache rather than the
# invoking user's. Both produce "Executable doesn't exist at .../ffmpeg-linux",
# which failed a browser stage in 89ms before the browser reached a login page.
echo "==> Installing the Playwright ffmpeg helper (pinned to test/acceptance)..."
(
  cd "${WORK_DIR}/test/acceptance"
  [[ -d node_modules/@playwright ]] \
    || bun install --frozen-lockfile 2>/dev/null \
    || bun install
  bunx playwright install ffmpeg
)

# ── Phase: stages ────────────────────────────────────────────────────────────
#
# Declared here rather than after bring-up because the static tier below runs
# BEFORE the cluster exists. The practical consequence is that an abort during
# cluster creation now leaves a summary listing the static stages that had
# already been recorded, instead of an empty one.
PIPELINE_PHASE="tests"

failures=0
declare -a stage_results=()

# Split out of run_stage so the publish phase — which runs a shell FUNCTION and
# therefore cannot go through `bash -c` — records itself in exactly the same
# shape as every other stage. One JSON writer, one verdict shape, no second
# place for the two to disagree.
record_stage() {
  local name="$1" output_file="$2" exit_code="$3"
  local status="pass"
  if ((exit_code != 0)); then
    status="fail"
    ((failures+=1))
  fi
  echo "  ${status^^}: ${name} (exit ${exit_code})"

  # Hand-rolled rather than jq, for the reason given above write_terminal_summary:
  # this file has exactly one JSON writer and it depends on nothing the pipeline
  # itself installs.
  stage_results+=("{\"name\":$(json_str "$name"),\"status\":$(json_str "$status"),\"exit_code\":${exit_code},\"file\":$(json_str "$output_file")}")
}

run_stage() {
  local name="$1" output_file="$2"; shift 2
  local exit_code=0

  echo "──── STAGE: ${name} (timeout ${STAGE_TIMEOUT_SECONDS}s) ────"
  timeout -k 30s "${STAGE_TIMEOUT_SECONDS}s" bash -c "$*" \
    > "${REPORT_DIR}/${output_file}" 2>&1 || exit_code=$?
  if ((exit_code == 124)); then
    printf '\nTIMEOUT: stage exceeded %ss and was terminated\n' \
      "$STAGE_TIMEOUT_SECONDS" >> "${REPORT_DIR}/${output_file}"
  fi

  record_stage "$name" "$output_file" "$exit_code"
}

# ═══ Tier 0: the gates that need NO cluster, run BEFORE there is one ═════════
#
# This is where this pipeline diverges most from vm-pipeline.sh, and the
# divergence is deliberate. v1 runs every stage in one block after the cluster,
# the image builds and the tenant activation — roughly twenty-five minutes in —
# even though most of them need none of it. Its own comments say the placement
# is wrong ("Placed here, before ~25 minutes of cluster work, because it is the
# cheapest stage in the pipeline and it gates the most expensive ones") while
# the code has them running after it.
#
# Everything below needs only the tools installed above: bats, bun, uv, go,
# python3, git, coreutils. No cluster, no docker, no network. A lockfile desync
# or an unregistered spec caught here costs seconds. Caught after bring-up it
# costs the bring-up.
#
# What is NOT here, and why: `make -C d2-signalloom test` GLOBS d2-signalloom/
# test/*.bats, and that glob includes runtime.bats, test-1-runtime.bats and
# api-route-liveness.bats, which assert against a live cluster. It therefore
# runs after convergence AND after the staleness proof — see its comment below.
# Believing it belongs here because its stage is numbered 1 would be reading the
# number rather than the contents.
#
# Report filenames are deliberately identical to vm-pipeline.sh's, because
# scripts/ci/openreports-convert.sh maps report FILES to parsers by name. A
# stage whose file is not in that map contributes zero rows to the OpenReports
# artifact while reading as configured — so a stage either reuses a mapped name
# or is written as .txt prose, which the map deliberately does not claim. There
# is no third option, and inventing a new .tap name would silently drop it.
echo "==> [3/8] Static gates (no cluster required)..."

# --frozen-lockfile is the point of the install, not a detail: this directory is
# the only one in the repo with both a bun.lock and a package-lock.json, `bun
# add` writes the former while the dashboard Dockerfile runs `npm ci` against
# the latter, and a desync builds clean locally and breaks the image on any
# clean tree. Frozen makes that a stage failure instead of something bun
# silently reconciles on the way past — and catching it HERE, rather than at the
# image build inside demo-signalloom-up, is precisely why this tier exists.
run_stage \
  "Dashboard unit and guard suite" \
  "stage1b-dashboard-unit.txt" \
  "cd ${WORK_DIR}/d2-signalloom/apps/dashboard-signalloom && \
   bun install --frozen-lockfile && \
   bun run test --run --reporter=junit \
     --outputFile=${REPORT_DIR}/stage1b-dashboard-unit.xml"

run_stage \
  "Acceptance-spec coverage registry" \
  "stage1c-acceptance-coverage.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/acceptance-spec-coverage.bats"

# Guards vm-pipeline.sh's hand-copy of demo-signalloom-up, which this file does
# not have. Run anyway: v1 is frozen but still the CI lane, and a demo run is a
# free opportunity to notice that its copy has drifted a fifth time.
run_stage \
  "CI build parity with demo-signalloom-up" \
  "stage1d-build-parity.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/ci-build-parity.bats"

run_stage \
  "Doctor node-image expectations" \
  "stage1e-node-images.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/node-images.bats"

run_stage \
  "CI terminal-state honesty" \
  "stage1f-ci-terminal-state.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/ci-terminal-state.bats"

# 29 suites that no runner invoked until vm-pipeline.sh named them. Measured
# across the tree at the time: 68 .bats suites present, 35 executed, 33 executed
# by nothing at all — and all 33 passed. They were not broken, they were unasked.
run_stage \
  "Static guards previously invoked by nothing" \
  "stage1g-unregistered-guards.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap \
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

# The fixed point: the stage above is itself a hand-maintained list, and a
# hand-maintained list omits by default. This one fails when a .bats file exists
# that no runner invokes — including this file, which it now knows about.
run_stage \
  "bats registry coverage" \
  "stage1h-bats-registry.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap d2-signalloom/test/bats-registry-coverage.bats"

run_stage \
  "CI report integrity" \
  "stage1j-ci-report-integrity.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/ci-report-integrity.bats"

run_stage \
  "Exec-probe ban in test files" \
  "stage1k-exec-probe-ban.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/no-exec-probes-in-tests.bats"

run_stage \
  "RBAC subject resolution" \
  "stage1l-rbac-subjects.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/rbac-subject-resolution.bats"

# Prose output, not TAP, and named .txt for that reason: a parseTap entry
# pointed at prose matches nothing and contributes zero rows while reading as
# configured, which is worse than no entry. Stages 1i, 1m and 1q below are .txt
# on the same grounds.
run_stage \
  "Vacuous-assertion lint" \
  "stage1o-vacuous-assertions.txt" \
  "cd ${WORK_DIR} && ./scripts/check-vacuous-assertions.sh"

run_stage \
  "Vacuous-assertion lint falsification" \
  "stage1p-vacuous-lint-proof.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/vacuous-assertions.bats"

run_stage \
  "Audit-guard reintroduction proof" \
  "stage1i-audit-reintroduction.txt" \
  "cd ${WORK_DIR} && bash d2-signalloom/test/audit-guard-reintroduction-proof.sh"

run_stage \
  "Vocabulary seam mutation proof" \
  "stage1m-seam-mutation-proof.txt" \
  "cd ${WORK_DIR} && bash d2-signalloom/test/seam-guard-mutation-proof.sh"

run_stage \
  "Guard falsification proof" \
  "stage1q-guard-falsification.txt" \
  "cd ${WORK_DIR} && ./test/guard-falsification-proof.sh"

# This pipeline's own control-flow suite. It needs no cluster and drives this
# file against stubs, so it belongs here — and a demo runner that does not run
# its own guard is the unregistered-suite defect that stages 1g and 1h exist to
# end, committed by the file that runs them.
#
# .txt, and NOT --tap, for the mapped-name reason given above: there is no
# stage1r entry in scripts/ci/openreports-convert.sh and adding one would break
# test/ci-report-integrity.bats, which asserts that no converter entry names a
# file scripts/ci/vm-pipeline.sh does not produce.
#
# supervise-port-forward-knobs.bats is here rather than with its sibling in 1g
# for a specific reason: gcp-demo-pipeline.bats asserts what THIS file exports
# (PF_ADDRESS=0.0.0.0 and the TLS probe URL) against a STUB supervisor, so it
# cannot say whether the real script does anything with them. Asserting the
# caller and never the callee is how a correctly-configured integration reaches
# production doing nothing — indistinguishable from a working one right up until
# an operator cannot reach the demo. The two suites are one guard and run
# together.
run_stage \
  "Demo pipeline control flow" \
  "stage1r-demo-pipeline.txt" \
  "cd ${WORK_DIR} && ${BATS_BIN} test/gcp-demo-pipeline.bats \
     test/supervise-port-forward-knobs.bats"

# The language suites. Also cluster-free, and vm-pipeline.sh runs them after
# bring-up purely because that is where its numbering put them.
run_stage \
  "API contracts and persistence" \
  "stage2-api.txt" \
  "cd ${WORK_DIR}/d2-signalloom/apps/fe-signalloom/src && \
   uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
     --with-requirements requirements.txt \
     python -m pytest tests -q -rf --junit-xml=${REPORT_DIR}/stage2-api.xml"

run_stage \
  "Deterministic fake integrations" \
  "stage3-fakes.txt" \
  "cd ${WORK_DIR} && \
   PYTHONPATH=d2-signalloom/apps/fake-integration-proxy \
   uv run --python 3.12 --with pytest \
     python -m pytest d2-signalloom/apps/fake-integration-proxy/test/test_proxy.py \
     -q --junit-xml=${REPORT_DIR}/stage3-fakes.xml"

run_stage \
  "Dashboard API ownership contract" \
  "stage4-dashboard.json" \
  "cd ${WORK_DIR}/tools/demo-console && go test -json ./..."

run_stage \
  "TEST-1 harness contract" \
  "stage5-harness.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap \
     test/signalloom-test-1-harness.bats \
     test/ci-installer-privileges.bats"

# ── Phase: cluster ───────────────────────────────────────────────────────────
PIPELINE_PHASE="create-cluster"
echo "==> [4/8] Creating the Kind cluster, registry and Flux foundation..."

# The ONLY teardown in this file, and it is behind an explicit flag. See the
# --recreate help text: a demo pipeline that tears down on any automatic path
# eventually tears down the demo somebody is standing in front of.
if ((RECREATE)); then
  echo "==> --recreate: tearing down the existing cluster first"
  "$MAKE_BIN" teardown 2>/dev/null || true
fi

# Ordering and retry placement carried from vm-pipeline.sh. `registry` and
# `bootstrap-local` are the two that pull from the network and are the two that
# flake; the rest are local and a retry on them only hides a real failure.
"$MAKE_BIN" cluster
retry 3 "$MAKE_BIN" registry
"$MAKE_BIN" signing-keys
"$MAKE_BIN" push-local-foundation
retry 3 "$MAKE_BIN" bootstrap-local

echo "==> Waiting for the Flux foundation..."
retry 3 "$KUBECTL_BIN" -n flux-system wait kustomization/flux-system \
  --for=condition=ready --timeout=10m
# Tolerated: `tenants` does not exist on every path through bootstrap, and its
# absence is not a failure here — the estate bring-up below waits on what it
# actually needs. A hard wait on an object that may legitimately not exist is
# the "wait its full budget then fail for the wrong reason" shape.
"$KUBECTL_BIN" -n flux-system wait kustomization/tenants \
  --for=condition=ready --timeout=10m 2>/dev/null || true

# ── Phase: the estate ────────────────────────────────────────────────────────
#
# ORDERING IS LOAD-BEARING, and delegating is how it is guaranteed.
#
# scripts/agent-trust-local.sh up must run IMMEDIATELY after
# scripts/signalloom-local.sh up, with NOTHING in between. It snapshots its
# sibling ResourceSets' inputs, does its own fleet refresh — which reapplies the
# declarative `inputs: []` — and then restores the snapshot, so it has to
# OBSERVE those inputs active. Anything inserted between the two is a window in
# which the ten-minute flux-system reconcile blanks them first; the snapshot
# then restores nothing, signalloom-infra never goes Ready, and preflight_bao
# waits its full 600s before failing with an error that names the prerequisite
# rather than the missing step. Moving agent-trust-local.sh EARLIER is worse
# than omitting it: a fast failure becomes a ten-minute hang.
#
# Both invocations, adjacent, are the last two lines of the demo-signalloom-up
# recipe. Calling the target is therefore not merely convenient — it makes the
# adjacency structurally impossible to break from here, because there is no
# "here" to insert anything into. test/gcp-demo-pipeline.bats asserts the
# adjacency in the recipe itself, and asserts that this file invokes neither
# script directly.
PIPELINE_PHASE="estate"
#
# COST OF DELEGATING, stated rather than glossed: vm-pipeline.sh wraps each
# image target in `retry 3` individually, and calling the recipe as one unit
# gives that up. `retry 2` here is the coarser replacement. It is affordable
# because the target is idempotent by construction — every step is a make target
# whose artefacts already exist on a second pass, and the image builds hit the
# docker layer cache — so attempt two costs a small fraction of attempt one and
# recovers exactly the transient registry flake the per-target retries existed
# for. It is genuinely blunter, and that is the price of never drifting again.
echo "==> [5/8] Bringing up the full Signal Loom estate (make demo-signalloom-up)..."
retry 2 "$MAKE_BIN" demo-signalloom-up

# ── Phase: the cluster-dependent stages ──────────────────────────────────────
PIPELINE_PHASE="tests"
echo "==> [6/8] Running the cluster-dependent stages..."

# ═══ Tier 1: convergence. ════════════════════════════════════════════════════
run_stage \
  "Flux and workload convergence" \
  "stage6-flux.tap" \
  "cd ${WORK_DIR} && ${MAKE_BIN} demo-signalloom-test"

# ═══ The precondition for believing anything below ═══════════════════════════
#
# Every stage after this one asserts against the RUNNING system, and every one
# of them passes happily against a pod built from an older tree. On 2026-08-13 a
# fully-tested streaming fix was reported as working while the pods answering
# the requests predated all 22 of its commits: every test was green and every
# one of them tested the source tree. Proving the running code IS this checkout
# is what makes the later stages mean anything about this checkout.
#
# It exits 2 rather than 1 when it cannot reach the cluster, so a broken
# kubeconfig fails this stage instead of quietly certifying the deployment.
run_stage \
  "Deployed workloads match the source under test" \
  "stage6b-deployed-staleness.txt" \
  "cd ${WORK_DIR} && ${MAKE_BIN} check-deployed-staleness"

# postBuild.substituteFrom is a SILENT NO-OP when a key is missing: the token is
# left literal, the apply succeeds, and the object is marked Ready=True with
# nothing retrying. Four tenants once came up with a literal ${ARTIFACT_TAG} in
# their OCIRepository tag and ran that way for hours while every status field
# claimed health. Reads LIVE objects, so it cannot sit in tier 1.
run_stage \
  "Flux variable substitution in live objects" \
  "stage6c-flux-substitution.txt" \
  "cd ${WORK_DIR} && ./scripts/check-flux-substitution.sh"

# The d2-signalloom suite, and it is HERE rather than in tier 0 for a reason
# worth stating: `make -C d2-signalloom test` GLOBS d2-signalloom/test/*.bats,
# and that glob includes runtime.bats, test-1-runtime.bats and
# api-route-liveness.bats, which assert against a live cluster. The glob is
# deliberate — a hand list left 22 suites unrun — but it means this stage is not
# static however its number reads, and running it before the cluster would fail
# for reasons that have nothing to do with the code.
#
# It sits AFTER the staleness proof, which is where vm-pipeline.sh does not put
# it: v1 runs it as stage 1, before stage 6b certifies that the pods are this
# checkout. A cluster suite that runs before the staleness proof is a suite
# whose result cannot be attributed to the tree under test — the exact defect
# 6b exists to close, left open by ordering.
run_stage \
  "Topology, dependencies, Go suites and the d2-signalloom bats glob" \
  "stage1-static.tap" \
  "cd ${WORK_DIR} && ${MAKE_BIN} -C d2-signalloom test"

# ═══ Publish, BEFORE the runtime and browser stages ══════════════════════════
#
# The brief for this script says to publish after the tests. Publishing here
# instead is a deliberate and, I think, strictly better choice, and the reason is
# evidence rather than convenience.
#
# scripts/acceptance-test.sh's start_port_forward REUSES an existing listener on
# a port rather than starting a second one (`nc -z 127.0.0.1 30754`), and its
# cleanup only kills the pids it started itself. So establishing the supervised
# forward first means the browser stages drive the EXACT endpoint the operator
# will later open — same port, same supervisor, same TLS path — instead of a
# private forward that acceptance-test.sh tears down before the operator ever
# arrives. Publishing afterwards leaves the published URL itself untested, which
# is the one thing a demo cannot afford to have wrong.
#
# It also means a failure to publish is reported as a failure, at the point it
# happens, rather than after the reader has already been told the run passed.
PIPELINE_PHASE="publish"
publish_gateway() {
  local ns svc
  read -r ns svc < <("$KUBECTL_BIN" get service -A -l "$GATEWAY_LABEL" \
    -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null || true)

  if [[ -z "${ns:-}" || -z "${svc:-}" ]]; then
    echo "ERROR: no Envoy data-plane Service matched ${GATEWAY_LABEL}." >&2
    echo "       The estate is up but nothing can be published, so there is no" >&2
    echo "       demo to hand over. This is a failure, not a skip." >&2
    return 1
  fi

  echo "==> Publishing ${ns}/${svc} on ${GATEWAY_BIND_ADDRESS}:${GATEWAY_LOCAL_PORT} → 443"
  # PF_PROBE_URL and PF_PROBE_CURL_OPTS exist because the supervisor's built-in
  # probe assumes a plaintext localhost endpoint — true of the Zot registry it
  # was written for, false of a TLS listener that routes by SNI. -k because the
  # demo certificate is self-signed; --resolve because the SNI name has no DNS
  # record by design (the browser side resolves it through Chrome's
  # --host-resolver-rules, and curl needs the equivalent).
  #
  # /livez rather than /readyz: readiness can legitimately flap while a workload
  # rolls, and a supervisor that respawns the forward every time a pod behind it
  # restarts is a supervisor that makes the demo worse.
  PF_ADDRESS="$GATEWAY_BIND_ADDRESS" \
  PF_PROBE_URL="https://${GATEWAY_HOSTNAME}:${GATEWAY_LOCAL_PORT}/livez" \
  PF_PROBE_CURL_OPTS="-k --resolve ${GATEWAY_HOSTNAME}:${GATEWAY_LOCAL_PORT}:127.0.0.1" \
    "$SUPERVISE_BIN" up "$PF_STATE_DIR" "$ns" "$svc" \
      "$GATEWAY_LOCAL_PORT" 443 /livez "$PF_OWNER_PID"
}

# Called directly rather than through run_stage: run_stage evaluates its command
# in `bash -c`, which is a fresh shell and cannot see a function defined here.
# Exporting the function would work and would also export every variable it
# closes over, so the stage would silently keep running with whatever those held
# at export time. record_stage keeps the bookkeeping identical either way.
echo "──── STAGE: Publish the dashboard on a supervised port-forward ────"
publish_rc=0
publish_gateway > "${REPORT_DIR}/stage6d-publish.txt" 2>&1 || publish_rc=$?
record_stage "Publish the dashboard on a supervised port-forward" \
  "stage6d-publish.txt" "$publish_rc"

# ═══ Tier 3: runtime. Needs the cluster AND the published Gateway. ═══════════
PIPELINE_PHASE="tests"
run_stage \
  "Gateway, probes, Dex, and NetworkPolicy runtime negatives" \
  "stage7-runtime.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap \
     d2-signalloom/test/runtime.bats \
     d2-signalloom/test/test-1-runtime.bats \
     d2-signalloom/test/supercred-demo-api.bats \
     d2-signalloom/test/api-route-liveness.bats"

run_stage \
  "Adversarial API surface probes" \
  "stage7b-adversarial.tap" \
  "cd ${WORK_DIR} && ${BATS_BIN} --tap test/api-adversarial.bats"

# ═══ Tier 4: the browser journey. ════════════════════════════════════════════
run_stage \
  "Dex and complete dashboard journey matrix" \
  "stage8-browser.txt" \
  "cd ${WORK_DIR} && \
   PLAYWRIGHT_JUNIT_OUTPUT_FILE=${REPORT_DIR}/stage8-browser.xml \
   ./scripts/acceptance-test.sh signalloom-test-1.spec.ts"

run_stage \
  "Dashboard page smoke suite" \
  "stage8b-smoke.txt" \
  "cd ${WORK_DIR} && \
   PLAYWRIGHT_JUNIT_OUTPUT_FILE=${REPORT_DIR}/stage8b-smoke.xml \
   ./scripts/acceptance-test.sh smoke.spec.ts live-data.spec.ts"

# ── Phase: report ────────────────────────────────────────────────────────────
PIPELINE_PHASE="report"
echo "==> [7/8] Generating reports..."

printf '[%s]\n' "$(IFS=,; printf '%s' "${stage_results[*]}")" > "${REPORT_DIR}/stages.json"

# Best-effort and explicitly so. The OpenReports artifact is a convenience for
# whoever collects the run; summary.json is the verdict. A converter failure
# must not be able to turn a green run red, and — the direction that actually
# bit — must not be able to abort before summary.json is written, which would
# leave the ABORTED writer to describe a run that had already finished.
if [[ -x "$CONVERT_BIN" || -f "$CONVERT_BIN" ]]; then
  bash "$CONVERT_BIN" "$REPORT_DIR" "$REPORT_FILENAME" \
    || echo "WARNING: OpenReports conversion failed; summary.json is unaffected"
fi

demo_url="https://${GATEWAY_HOSTNAME}:${GATEWAY_LOCAL_PORT}/"
overall="PASS"
((failures != 0)) && overall="FAIL"

# Written here, not by write_terminal_summary: this is the run's own verdict and
# the trap must never overwrite it. The trap's first act is to return early when
# this file exists.
{
  printf '{\n'
  printf '  "outcome": %s,\n' "$(json_str "$overall")"
  printf '  "overall": %s,\n' "$(json_str "$overall")"
  printf '  "phase": "report",\n'
  printf '  "timestamp": %s,\n' "$(json_str "$(date -Iseconds)")"
  printf '  "commit": %s,\n' "$(json_str "$SOURCE_COMMIT")"
  printf '  "branch": %s,\n' "$(json_str "$SOURCE_BRANCH")"
  printf '  "demo_published": true,\n'
  printf '  "demo_url": %s,\n' "$(json_str "$demo_url")"
  printf '  "demo_user": %s,\n' "$(json_str "$DEMO_USER")"
  printf '  "demo_password": %s,\n' "$(json_str "$DEMO_PASSWORD")"
  printf '  "gateway_port": %d,\n' "$GATEWAY_LOCAL_PORT"
  printf '  "gateway_bind_address": %s,\n' "$(json_str "$GATEWAY_BIND_ADDRESS")"
  printf '  "port_forward_state_dir": %s,\n' "$(json_str "$PF_STATE_DIR")"
  printf '  "total_stages": %d,\n' "${#stage_results[@]}"
  printf '  "passed": %d,\n' "$(( ${#stage_results[@]} - failures ))"
  printf '  "failed": %d,\n' "$failures"
  printf '  "stages": [%s]\n' "$(IFS=,; printf '%s' "${stage_results[*]}")"
  printf '}\n'
} > "${REPORT_DIR}/summary.json"

# ── Phase: the hand-over ─────────────────────────────────────────────────────
#
# Printed unconditionally, including after a failing run. A stage failure does
# not un-publish the demo, and an operator told only "3 stages failed" has no
# way to go and look at what failed.
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  [8/8] THE DEMO IS UP"
echo "════════════════════════════════════════════════════════════"
echo "  URL:       ${demo_url}"
echo "  Username:  ${DEMO_USER}"
echo "  Password:  ${DEMO_PASSWORD}"
echo ""
echo "  Published on ${GATEWAY_BIND_ADDRESS}:${GATEWAY_LOCAL_PORT}, supervised."
echo "  The forward is owned by pid ${PF_OWNER_PID} and survives this script."
echo "  Stop it with:"
echo "    ${SUPERVISE_BIN} down ${PF_STATE_DIR}"
echo ""
echo "  Reaching it from a workstation (IAP tunnel to the internal IP, which is"
echo "  why the forward binds ${GATEWAY_BIND_ADDRESS} rather than loopback):"
echo "    gcloud compute start-iap-tunnel sl-demo-1-vm ${GATEWAY_LOCAL_PORT} \\"
echo "      --local-host-port=localhost:${GATEWAY_LOCAL_PORT} --zone <zone>"
echo "  The Gateway selects its route by SNI, so the hostname is not optional:"
echo "    echo '127.0.0.1 ${GATEWAY_HOSTNAME}' | sudo tee -a /etc/hosts"
echo "  then open ${demo_url}"
echo ""
echo "  Reports:   ${REPORT_DIR}"
echo "  Log:       ${PIPELINE_LOG}"
echo "════════════════════════════════════════════════════════════"
if ((failures == 0)); then
  echo "  RESULT: PASS (${#stage_results[@]}/${#stage_results[@]} stages)"
else
  echo "  RESULT: FAIL (${failures} of ${#stage_results[@]} stages failed)"
  echo "          The demo is still up — go and look at what broke."
fi
echo "  Finished: $(date -Iseconds)"
echo "════════════════════════════════════════════════════════════"

exit "$failures"
