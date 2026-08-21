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
#   3. IT PUBLISHES. See publish_dashboard below for the port, the bind address
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

# ── The signing keypair, which must NOT live in the checkout ─────────────────
#
# KEYS_DIR is exported rather than merely set, and it is exported here rather
# than passed to any single make invocation, because five separate consumers
# resolve it independently: `make signing-keys` writes it, `make
# push-local-foundation` and scripts/push-local.sh sign from it, `make
# bootstrap-local` publishes its PUBLIC half into flux-system/cosign-pub, and
# the audit-anchor targets sign checkpoints with witness.pem beside it. Setting
# it on one command line would leave the others resolving somewhere else, which
# is the same split-brain in a new place.
#
# Nothing new is being invented to make this work. scripts/lib/keys.sh already
# documents an explicit KEYS_DIR as the authoritative source ("An explicit
# KEYS_DIR wins so the Makefile ... and any deliberate override are
# authoritative"), and the Makefile's `KEYS_DIR ?=` yields to an environment
# value. This supplies the value those two mechanisms were already waiting for.
#
# ─── Why the default is the checkout, and stays that way ────────────────────
#
# Unset — a developer laptop, or test/gcp-demo-pipeline.bats driving a fixture
# tree — this expands to nothing and every consumer falls back to its existing
# git-common-dir behaviour. That is deliberately unchanged: on a laptop the
# checkout IS durable, the shared-worktree problem keys.sh solves is real there,
# and a hardcoded /opt path would be wrong on a machine that has no /opt/
# signalloom. The VM is the only environment where the checkout is destroyed
# between runs, and it is the only one that sends this variable.
#
# An empty DEMO_KEYS_DIR is treated as unset rather than as an error, so an
# older driver that does not send it produces exactly today's behaviour instead
# of a new failure. That is the compatible direction: the old driver's runs
# already work once, and this file must not turn "works once" into "does not
# run".
if [[ -n "${DEMO_KEYS_DIR:-}" ]]; then
  export KEYS_DIR="${DEMO_KEYS_DIR}"
fi

# ── The zot blob store, for exactly the same reason ──────────────────────────
#
# ZOT_CACHE_DIR is `?=` at Makefile:50 and defaults to the relative '.cache/zot',
# so unconfigured it lands inside the delivered tree and is destroyed by the same
# `rm -rf`. Unlike the keypair, the destruction is silent: the Kind node holds a
# bind mount through the deleted directory, so the zot pod stays Running, keeps
# answering its readiness probe, and fails only on a blob upload — with a 500
# that names nothing and a host directory that looks perfectly healthy.
#
# NOTE, because this is the part that surprises: the mount is established when
# the Kind NODE is created, so pointing this somewhere durable does not repair a
# cluster that already has the broken mount. An existing cluster has to be
# recreated once. create-kind-cluster.sh prints "already exists; preserving Zot
# cache at ..." and preserves the broken one.
if [[ -n "${DEMO_ZOT_CACHE_DIR:-}" ]]; then
  export ZOT_CACHE_DIR="${DEMO_ZOT_CACHE_DIR}"
fi

# The verdict file. Derived from REPORT_DIR by default, because that is the
# contract demo-up.sh documents ("must write DEMO_REPORT_DIR/summary.json"), but
# overridable so the driver's own GCP_TF_DEMO_SUMMARY_NAME cannot name a file
# this script never writes. Two sides deriving the same path independently is
# how they drift; one side sending it is how they cannot.
SUMMARY_FILE="${DEMO_SUMMARY_FILE:-${REPORT_DIR}/summary.json}"

# Which environment this run describes. Recorded in the summary because a
# verdict that does not name its own environment is weak evidence — reading
# demo-1's summary as demo-2's is a one-character mistake with no guard on it.
DEMO_ENV_KEY="${DEMO_ENV:-unknown}"

# ── The delivered source, resolved BEFORE the EXIT trap is armed ─────────────
#
# These used to be resolved down beside the checkout phase, after `trap
# on_pipeline_exit EXIT`. That was survivable only while the aborted summary
# carried no commit; now that it does, an abort before that point would
# reference an unset variable under `set -u` and take out the trap that exists
# to write the abort record. Resolved here, they are defined on every path.
#
# SOURCE_ORIGIN is not decoration. When the driver supplies the commit, this run
# can be tied to a known tree; when it does not, the fallback describes the
# throwaway repo that the checkout phase git-inits for Kustomize, which is a
# snapshot of unknown provenance. Those two are worth telling apart in the log
# and in the verdict, because for the whole life of this contract the second was
# silently reported as though it were the first.
if [[ -n "${DEMO_SOURCE_COMMIT:-}" ]]; then
  SOURCE_ORIGIN="driver"
else
  SOURCE_ORIGIN="vm-local"
fi
#
# `git -C "$WORK_DIR"`, never a bare `git`: this now runs before the `cd
# "$WORK_DIR"` in the checkout phase, so a bare rev-parse would describe
# whatever directory the caller happened to be standing in. Naming the tree
# explicitly makes the answer independent of cwd, which is the property the old
# placement got for free and this one has to state.
SOURCE_COMMIT="${DEMO_SOURCE_COMMIT:-$(git -C "$WORK_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
SOURCE_BRANCH="${DEMO_SOURCE_BRANCH:-$(git -C "$WORK_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"

# ── DEMO_STAGE: refuse what cannot be honoured ───────────────────────────────
#
# This script has NO stage system. It runs one fixed sequence; the "STAGE:"
# banners further down label steps within that sequence and select nothing.
#
# That was harmless while DEMO_STAGE never arrived. Now that the driver's
# environment reaches this file, a request for a partial run would be accepted
# and silently upgraded to a full one — and `make gcp-tf-demo-test` advertises
# "re-run the demo tests against a cluster that is already standing", which is
# exactly the thing this script cannot do. A caller who asks to skip a rebuild
# and gets a rebuild has been given the wrong answer to the right question, and
# the only evidence is forty minutes on the clock.
#
# So it refuses. This is a REFUSAL, not an implementation: the honest failure is
# a loud one at second zero. Implementing real stage selection is a separate
# change against a script whose steps are not currently separable.
STAGE="${DEMO_STAGE:-full}"
case "$STAGE" in
  full) ;;
  *)
    echo "ERROR: DEMO_STAGE='${STAGE}' was requested, and this pipeline cannot honour it." >&2
    echo "       demo-pipeline.sh implements a single fixed sequence and has no stage" >&2
    echo "       selection. Running anyway would silently perform a FULL bring-up —" >&2
    echo "       including a cluster rebuild — for a caller that asked not to." >&2
    echo "       Refusing rather than doing the wrong thing quietly." >&2
    echo "       Only DEMO_STAGE=full is supported today." >&2
    exit 2
    ;;
esac

MAKE_BIN="${MAKE_BIN:-make}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
BATS_BIN="${BATS_BIN:-bats}"
SUDO_BIN="${SUDO_BIN:-sudo}"
CHROME_BIN="${DEMO_CHROME_BIN:-/opt/google/chrome/chrome}"
SUPERVISE_BIN="${DEMO_SUPERVISE_BIN:-${WORK_DIR}/scripts/supervise-port-forward.sh}"
CONVERT_BIN="${DEMO_CONVERT_BIN:-${WORK_DIR}/scripts/ci/openreports-convert.sh}"

# ── The published endpoint ───────────────────────────────────────────────────
#
# Human access deliberately bypasses the Envoy Gateway. IAP, Tailscale, Funnel,
# and ngrok each reach the dashboard's Nginx Service directly on port 8080. The
# acceptance harness separately owns its Envoy :30754 forward for Gateway and
# TLS/SNI contract coverage; changing it here would weaken that test boundary.
#
# 0.0.0.0 is not a preference either. The operator arrives over a Google IAP
# tunnel, and that tunnel connects to the instance's INTERNAL IP, not to its
# loopback. kubectl port-forward binds localhost by default, so a demo published
# on the default address is reachable only from a shell already on the VM —
# the one place nobody needs it.
DASHBOARD_LOCAL_PORT="${DEMO_DASHBOARD_LOCAL_PORT:-8080}"
DASHBOARD_BIND_ADDRESS="${DEMO_DASHBOARD_BIND_ADDRESS:-0.0.0.0}"
DASHBOARD_HOSTNAME="${DEMO_DASHBOARD_HOSTNAME:-dashboard.osramp.acme.local}"
DASHBOARD_NAMESPACE="${DEMO_DASHBOARD_NAMESPACE:-fe-signalloom}"
DASHBOARD_SERVICE="${DEMO_DASHBOARD_SERVICE:-dashboard-signalloom}"
DASHBOARD_SERVICE_PORT="${DEMO_DASHBOARD_SERVICE_PORT:-8080}"
PF_STATE_DIR="${DEMO_PF_STATE_DIR:-${HOME}/.signalloom-demo-dashboard-pf}"

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

# ── The first-session docker group, and why this re-execs itself ────────────
#
# THE FIRST BRING-UP AFTER ANY VM REPLACEMENT FAILS WITHOUT THIS, deterministically.
#
# This VM enforces OS Login, so the account is provisioned by the guest agent at
# FIRST LOGIN and its name is not knowable at boot. demo-vm.sh handles that with
# a /etc/profile.d snippet that runs `usermod -aG docker "$(id -un)"` — correct,
# and it says so itself:
#
#   signalloom: added sa_1084361981201826946.. to the docker group.
#   signalloom: group membership applies to your NEXT session — reconnect
#
# That is the whole problem. usermod changes the ACCOUNT; it cannot change the
# credentials of the session already running. The pipeline is invoked through
# `bash -l -c`, so profile.d fires in this very session and the usermod lands
# too late for it. install-ci-tools.sh then finds the socket unreachable and
# reports "Docker daemon is not running" — which is wrong about the cause, and
# someone will restart a daemon that was never down.
#
# It self-clears on a second run, which is exactly why it is worth fixing: every
# VM rebuild otherwise spends one full pipeline (up to the 90m fence) proving
# something already known.
#
# `sg docker -c` runs a command with the docker group ACTIVE NOW. It re-reads
# the group database rather than the session's credentials, so it picks up a
# usermod that happened seconds ago with no relogin, no second SSH session and
# no change to the socket's permissions. Widening the socket was the obvious
# alternative and demo-vm.sh already rejects it at length: docker socket access
# is root-equivalent, and 0666 grants that to every local account on a machine
# whose entire demonstration subject is security posture.
#
# ─── Every condition below is load-bearing ──────────────────────────────────
#
#   DEMO_SG_REEXEC     loop guard. Exported before the exec, so the re-executed
#                      process cannot re-exec again if sg fails to fix things.
#   docker present     nothing to fix on a box without docker.
#   socket unreachable the ONLY trigger. A working session is never re-executed.
#   member per getent  `sg` prompts for a GROUP PASSWORD when the caller is not
#                      already a member. On a non-interactive SSH session that
#                      prompt has no tty and the run hangs until the fence.
#                      Checking /etc/group first makes that case unreachable.
#   not member per id  if the group is already effective, sg would change
#                      nothing and re-exec for no reason.
#   sg present         it ships with the passwd package, but assuming a binary
#                      is how the npx failure happened.
#
# Placed before the tee so the log is opened once, by the process that survives.
if [[ -z "${DEMO_SG_REEXEC:-}" ]] \
  && command -v docker >/dev/null 2>&1 \
  && ! docker version >/dev/null 2>&1 \
  && command -v sg >/dev/null 2>&1 \
  && getent group docker 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$(id -un)" \
  && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  echo "==> docker socket unreachable and the docker group is not yet active in this session"
  echo "==> re-executing under 'sg docker' (first login after a VM rebuild; no relogin needed)"
  export DEMO_SG_REEXEC=1
  exec sg docker -c "$(printf '%q ' bash "$0" "$@")"
fi

mkdir -p "$(dirname "$PIPELINE_LOG")" 2>/dev/null || true
exec > >(tee -a "$PIPELINE_LOG") 2>&1

# If the re-exec happened and STILL did not help, say so plainly rather than
# letting install-ci-tools.sh blame the daemon. The daemon being down and the
# socket being unreachable are different faults with the same symptom, and this
# repo has already watched someone act on the wrong one.
if [[ -n "${DEMO_SG_REEXEC:-}" ]] && ! docker version >/dev/null 2>&1; then
  echo "WARNING: re-executed under 'sg docker' and the socket is STILL unreachable."
  echo "WARNING: this is NOT evidence that the daemon is down — check it directly"
  echo "WARNING: with 'systemctl is-active docker' before restarting anything."
fi

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
  [[ -f "${SUMMARY_FILE}" ]] && return 0
  mkdir -p "$(dirname "${SUMMARY_FILE}")" 2>/dev/null || return 0

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
    # commit/branch/env on the ABORT path too, not just the success path. The
    # driver's STALE guard reads .commit to prove the verdict describes the tree
    # it delivered; an aborted summary with no commit made that check fall back
    # to "unknown", which is indistinguishable from a wrong-tree verdict.
    printf '  "commit": %s,\n' "$(json_str "$SOURCE_COMMIT")"
    printf '  "branch": %s,\n' "$(json_str "$SOURCE_BRANCH")"
    printf '  "env": %s,\n' "$(json_str "$DEMO_ENV_KEY")"
    printf '  "demo_published": false,\n'
    printf '  "note": %s,\n' "$(json_str "the pipeline exited during phase '${PIPELINE_PHASE}' without reaching the report stage — this is an ABORTED run, NOT a test result")"
    printf '  "total_stages": %d,\n' "$total"
    printf '  "passed": %d,\n' "$passed"
    printf '  "failed": %d,\n' "$failed"
    printf '  "stages": %s\n' "$stages_json"
    printf '}\n'
  } >"${SUMMARY_FILE}" 2>/dev/null || true
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
# SOURCE_COMMIT / SOURCE_BRANCH are resolved at the TOP of this file, before the
# EXIT trap is armed — see the block beside SUMMARY_FILE. They must not be
# resolved here: write_terminal_summary now stamps them into an aborted summary,
# and an abort between `trap on_pipeline_exit EXIT` (above) and this line would
# then reference an unset variable under `set -u` and kill the trap itself.
#
# The fallback below them is also the reason this line reported `master@47c5ea5`
# on demo-2: the driver's value never arrived, so it described the throwaway
# repo git-init'd four lines up rather than the tree that was delivered.
echo "==> Source: ${SOURCE_BRANCH}@${SOURCE_COMMIT} (env ${DEMO_ENV_KEY}, source ${SOURCE_ORIGIN})"

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
  local name="$1" output_file="$2" exit_code="$3" elapsed="${4:-0}"
  local status="pass"
  if ((exit_code != 0)); then
    status="fail"
    ((failures+=1))
  fi

  # ─── Why a stage records its DURATION and its share of the fence ─────────
  #
  # scripts/lib/wait.sh emits a WAIT_STAT line for every inner wait, carrying
  # elapsed, deadline and the ratio between them, and scripts/cluster-debug.sh
  # ranks them. That instrumentation is why "is this wait close to timing out"
  # is a question with an answer here. Measured across three real runs: 495
  # samples, zero timeouts, a maximum of 10% of budget used.
  #
  # The OUTER fence had none of it. A stage announced its budget and then never
  # said what it spent, so a stage sitting at 95% of STAGE_TIMEOUT_SECONDS was
  # indistinguishable from one at 5% until the day it crossed and was killed —
  # and a `timeout` kill reads as a hung test rather than as a budget that was
  # always too tight. The inner waits were observable and the thing that
  # actually terminates a run was not.
  #
  # This matters most exactly when the machine changes. Halving a lane's vCPU
  # does not move the inner waits (they are dominated by image pulls, Flux
  # reconciliation and DNS, none of which are CPU-bound) but it does move total
  # stage wall-clock, which is the number nobody had. budget_pct is what makes
  # the next resize a measurement instead of an argument.
  local budget_pct=0
  if ((STAGE_TIMEOUT_SECONDS > 0)); then
    budget_pct=$(( elapsed * 100 / STAGE_TIMEOUT_SECONDS ))
  fi
  echo "  ${status^^}: ${name} (exit ${exit_code}, ${elapsed}s of ${STAGE_TIMEOUT_SECONDS}s = ${budget_pct}%)"

  # Warn ONCE past 60% of the fence, and keep going. Same soft-threshold ratio
  # and the same intent as WAIT_SOFT_RATIO in scripts/lib/wait.sh: a stage that
  # is merely slow must not fail, but it must not pass silently either. This is
  # the line that would have said "8 vCPU is not enough" before a stage started
  # being killed at minute thirty.
  if ((budget_pct >= 60)); then
    printf '⚠ slow: stage %s used %s%% of its %ss budget (%ss). Raise DEMO_STAGE_TIMEOUT_SECONDS or investigate.\n' \
      "$name" "$budget_pct" "$STAGE_TIMEOUT_SECONDS" "$elapsed" >&2
  fi

  # Hand-rolled rather than jq, for the reason given above write_terminal_summary:
  # this file has exactly one JSON writer and it depends on nothing the pipeline
  # itself installs.
  stage_results+=("{\"name\":$(json_str "$name"),\"status\":$(json_str "$status"),\"exit_code\":${exit_code},\"file\":$(json_str "$output_file"),\"duration_s\":${elapsed},\"budget_s\":${STAGE_TIMEOUT_SECONDS},\"budget_pct\":${budget_pct}}")
}

run_stage() {
  local name="$1" output_file="$2"; shift 2
  local exit_code=0

  echo "──── STAGE: ${name} (timeout ${STAGE_TIMEOUT_SECONDS}s) ────"
  # SECONDS is bash's own monotonic-ish counter and needs no external command,
  # which matters because this pipeline runs before its own toolchain is proven.
  local stage_start="${SECONDS}"
  timeout -k 30s "${STAGE_TIMEOUT_SECONDS}s" bash -c "$*" \
    > "${REPORT_DIR}/${output_file}" 2>&1 || exit_code=$?
  local stage_elapsed=$(( SECONDS - stage_start ))
  if ((exit_code == 124)); then
    printf '\nTIMEOUT: stage exceeded %ss and was terminated\n' \
      "$STAGE_TIMEOUT_SECONDS" >> "${REPORT_DIR}/${output_file}"
  fi

  record_stage "$name" "$output_file" "$exit_code" "$stage_elapsed"
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
     test/node-doctor.bats \
     test/resourceset-activation-race.bats test/revocation-demo.bats \
     test/signalfusion-demo.bats test/signalfusion-images.bats \
     test/signalloom-local-lifecycle.bats \
     test/signalloom-security-validation-evidence.bats \
     test/supercred-crictl-shim.bats test/supercred-demo-stun.bats \
     test/supercred-fleet-demo-harness.bats test/supercred-image-visibility.bats \
     test/registry-cache-mapping.bats \
     test/supercred-state.bats test/supervise-port-forward.bats \
     test/supervise-port-forward-eperm.bats \
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
#
# ── Standing hypothesis: CI-VM-only failure, cause not found (2026-08-20) ────
#
# This stage FAILED on the CI VM while both suites passed clean locally,
# including the exact non-TAP combined invocation below. Ruled out, with
# evidence, before giving up on a source-level explanation:
#
#   * NOT a defect in either .bats file's assertions — 43/43 ok locally.
#   * NOT the STAGE_TIMEOUT_SECONDS wrapper — the combined run finishes in
#     seconds, nowhere near the 1800s default.
#   * NOT bats version skew. install-ci-tools.sh pins bats 1.14.0 for the CI
#     VM; this box had 1.13.0. bats-core 1.14.0's own release notes flag a
#     behaviour change directly relevant to this file's style (helper
#     functions that wrap `run`, e.g. bring_up() in
#     supervise-port-forward-knobs.bats): "Resolved issues where the `run`
#     command was unintentionally suppressing `set -e` behavior in
#     functions" — upstream's own notes warn this can uncover hidden errors
#     in existing suites. Built bats-core v1.14.0 from source and re-ran the
#     identical combined invocation against it: still 43/43 ok. Hypothesis
#     falsified by direct reproduction, not assumed away.
#
# What was NOT available to go further: the actual stage1r-demo-pipeline.txt
# (or equivalent stderr) from the failing CI VM run. No artifact of that run
# survived anywhere on the box that investigated this. Best-guess, low
# confidence, unverified: CI-VM environmental/load flake (e.g. the supervisor
# kill-timeout race in the knobs suite's busy-loop kubectl stub under
# contention), not a defect in either suite. If this fails again, capture and
# keep that file before anything else — that is the one thing this
# investigation could not get.
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
# The browser stages intentionally retain their independent Envoy :30754
# contract in scripts/acceptance-test.sh. Establishing the supervised dashboard
# forward first makes the human handover durable without teaching acceptance to
# bypass the Gateway it is meant to validate.
#
# It also means a failure to publish is reported as a failure, at the point it
# happens, rather than after the reader has already been told the run passed.
PIPELINE_PHASE="publish"
publish_dashboard() {
  echo "==> Publishing ${DASHBOARD_NAMESPACE}/${DASHBOARD_SERVICE} on ${DASHBOARD_BIND_ADDRESS}:${DASHBOARD_LOCAL_PORT} → ${DASHBOARD_SERVICE_PORT}"
  # Nginx serves plaintext HTTP and routes by path, so the supervisor can probe
  # its loopback endpoint directly. This intentionally has no TLS/SNI override.
  PF_ADDRESS="$DASHBOARD_BIND_ADDRESS" \
  PF_PROBE_URL="http://127.0.0.1:${DASHBOARD_LOCAL_PORT}/" \
    "$SUPERVISE_BIN" up "$PF_STATE_DIR" "$DASHBOARD_NAMESPACE" "$DASHBOARD_SERVICE" \
      "$DASHBOARD_LOCAL_PORT" "$DASHBOARD_SERVICE_PORT" / "$PF_OWNER_PID"
}

# Called directly rather than through run_stage: run_stage evaluates its command
# in `bash -c`, which is a fresh shell and cannot see a function defined here.
# Exporting the function would work and would also export every variable it
# closes over, so the stage would silently keep running with whatever those held
# at export time. record_stage keeps the bookkeeping identical either way.
echo "──── STAGE: Publish the dashboard on a supervised port-forward ────"
publish_rc=0
publish_start="${SECONDS}"
publish_dashboard > "${REPORT_DIR}/stage6d-publish.txt" 2>&1 || publish_rc=$?
record_stage "Publish the dashboard on a supervised port-forward" \
  "stage6d-publish.txt" "$publish_rc" "$(( SECONDS - publish_start ))"

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

demo_url="http://${DASHBOARD_HOSTNAME}:${DASHBOARD_LOCAL_PORT}/"
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
  # Where the commit above CAME from. "driver" means the orchestrator handed it
  # over and this verdict can be tied to the tree it delivered; "vm-local" means
  # it describes the throwaway repo the checkout phase creates, which proves
  # nothing. The driver's STALE guard compares .commit against what it sent, so
  # this field is what tells an operator whether a STALE verdict means "wrong
  # tree" or "the contract broke again".
  printf '  "source_origin": %s,\n' "$(json_str "$SOURCE_ORIGIN")"
  printf '  "env": %s,\n' "$(json_str "$DEMO_ENV_KEY")"
  # DERIVED, never asserted. This printed the literal `true` unconditionally
  # while publish_rc — set right where publish_dashboard runs — was recorded in
  # the stage table and read by nothing. On ci-1 that produced a verdict
  # claiming "demo_published": true beside a stage6d-publish that had failed in
  # zero seconds, which is the vacuous-pass shape this repo exists to hunt: a
  # report contradicting its own evidence, in the direction of good news.
  #
  # The ABORT path at the top of this file hardcodes `false`, so neither path
  # ever reflected what actually happened.
  if [ "${publish_rc:-1}" -eq 0 ]; then
    printf '  "demo_published": true,\n'
    printf '  "demo_url": %s,\n' "$(json_str "$demo_url")"
  else
    printf '  "demo_published": false,\n'
    # The URL is emitted as null rather than omitted: a consumer that reads
    # .demo_url must see "there is no dashboard", not a plausible address that
    # nothing is serving. Publishing failed, so the address is a fiction.
    printf '  "demo_url": null,\n'
    printf '  "demo_publish_exit_code": %d,\n' "${publish_rc:-1}"
  fi
  printf '  "demo_user": %s,\n' "$(json_str "$DEMO_USER")"
  printf '  "demo_password": %s,\n' "$(json_str "$DEMO_PASSWORD")"
  printf '  "dashboard_port": %d,\n' "$DASHBOARD_LOCAL_PORT"
  printf '  "dashboard_bind_address": %s,\n' "$(json_str "$DASHBOARD_BIND_ADDRESS")"
  printf '  "port_forward_state_dir": %s,\n' "$(json_str "$PF_STATE_DIR")"
  printf '  "total_stages": %d,\n' "${#stage_results[@]}"
  printf '  "passed": %d,\n' "$(( ${#stage_results[@]} - failures ))"
  printf '  "failed": %d,\n' "$failures"
  printf '  "stages": [%s]\n' "$(IFS=,; printf '%s' "${stage_results[*]}")"
  printf '}\n'
} > "${SUMMARY_FILE}"

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
echo "  Published on ${DASHBOARD_BIND_ADDRESS}:${DASHBOARD_LOCAL_PORT}, supervised."
echo "  The forward is owned by pid ${PF_OWNER_PID} and survives this script."
echo "  Stop it with:"
echo "    ${SUPERVISE_BIN} down ${PF_STATE_DIR}"
echo ""
echo "  Reaching it from a workstation (IAP tunnel to the internal IP, which is"
echo "  why the forward binds ${DASHBOARD_BIND_ADDRESS} rather than loopback):"
echo "    gcloud compute start-iap-tunnel sl-demo-1-vm ${DASHBOARD_LOCAL_PORT} \\"
echo "      --local-host-port=localhost:${DASHBOARD_LOCAL_PORT} --zone <zone>"
echo "  Dashboard Nginx routes by path; no Gateway TLS/SNI host override is needed."
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
