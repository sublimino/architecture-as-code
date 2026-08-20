#!/usr/bin/env bash
#
# vm-state-contract.sh — assert the eight VM facts the pipeline depends on,
# BEFORE the pipeline spends twenty minutes discovering one of them the hard way.
#
# ── Why this file exists, and why a static test could not have prevented it ──
#
# test/ci-installer-privileges.bats already guards this bug class at the source
# level, and its header is worth reading. It says the installers run on three
# privilege shapes, that only the container shape is exercised locally, and that
# "a write into /usr/local/bin that forgets ${SUDO} passes every local test and
# then fails on a cold VM". It then says, correctly:
#
#     # These are static assertions over the installer sources. They need no VM.
#
# That is the whole problem. The fact that decides the outcome IS NOT IN THE
# SOURCE. Whether /usr/local/bin is writable by this user on this machine is a
# property of the machine, not of the script that writes to it. No amount of
# grepping the installer can answer it. Confirmed by construction: ZERO bats
# suites in this repo connect to a VM.
#
# So the guard was real, it was well argued, it was green — and the same class
# of defect recurred anyway, because it was pointed at the wrong surface.
#
# ── Why this is a shell script and not a goss contract ───────────────────────
#
# goss (github.com/goss-org/goss) was the proposed mechanism and it is a good
# tool. It is the wrong tool HERE, for four measured reasons:
#
#  1. SIX OF THE EIGHT FACTS ARE CAPABILITY PROBES, NOT STATE. goss is excellent
#     at declarative state — package installed, port listening, file present
#     with mode 0755, service running. It expresses "can THIS process create a
#     file in THIS directory right now" as a `command:` block, which is a shell
#     snippet embedded in YAML. The declarative win evaporates precisely where
#     these checks live, and what is left is bash with heredoc quoting hazards.
#
#  2. CIRCULAR DEPENDENCY ON FACT 6. goss is a binary that has to be installed
#     somewhere. Install it into ${BIN_DIR} and the exact condition fact 6
#     detects — ${BIN_DIR} not writable — prevents the detector from installing.
#     Installing it elsewhere fixes that, but a gate whose bootstrap can fail
#     for the same reason as the thing it gates is a gate you cannot trust on
#     the one run where it matters.
#
#  3. IT IS A NEW SUPPLY-CHAIN INTAKE ON THE VM, added in order to check the
#     supply chain. Fact 2 exists because kubectl resolved dl.k8s.io/stable.txt
#     at boot. Pulling a fresh third-party binary to police that is defensible
#     with a pin and a checksum, but it is a cost, and it buys less than it
#     looks (see 1).
#
#  4. IT IS THE HARDEST THING IN THIS REPO TO MUTATION-PROVE, and CONTRACT §7b
#     is built on mutation-proving REAL files. Mutating a YAML contract proves a
#     schema test noticed the YAML changed. Mutating this script proves the
#     GATE'S LOGIC goes red. The second is the proof §7b is asking for; the
#     first is the fixture-only mutation §7b spent three dead assertions
#     learning to reject.
#
# What goss would genuinely have bought is kept here deliberately:
#   - every failure reported, never just the first (see run_fact / FAILED)
#   - machine-readable output (--format json)
#   - the facts read as a table, not as control flow
#   - every boundary injectable, so the whole thing is testable with no VM
#
# ── Offline testability ──────────────────────────────────────────────────────
#
# Every external boundary below is overridable by environment variable. That is
# not decoration: test/terraform-vm-state-contract.bats runs this entire file
# against temporary directories and stub binaries with no VM, no network and no
# privileges, and test/vm-state-contract-mutation-proof.sh mutates THIS file to
# prove each fact can go red.
#
# Usage:
#   scripts/vm-state/vm-state-contract.sh                 # human output
#   scripts/vm-state/vm-state-contract.sh --format json   # machine output
#   make vm-state-check [FORMAT=json]                     # same, from the repo
#
# Exit: 0 every fact holds. 1 one or more failed. 2 the harness could not run.
#
# ── PROPOSED CALL SITE — not wired, needs sequencing ─────────────────────────
#
# scripts/gcp-tf/demo-pipeline.sh, at the END of stage [2/8] install-tools,
# immediately after line 421:
#
#     "$SUDO_BIN" chmod a+w /usr/local/bin 2>/dev/null || true
#     bash ./scripts/ci/install-ci-tools.sh
#     bash ./scripts/setup.sh --tools-only
#     "$SUDO_BIN" chmod go-w /usr/local/bin 2>/dev/null || true
#  +  bash ./scripts/vm-state/vm-state-contract.sh || exit 1
#
# AFTER the chmod go-w, not before. Between the two chmods /usr/local/bin is
# deliberately world-writable, so fact 6 measured there would describe a state
# that exists for four lines and is then reverted — it would report the SUDO
# branch the rest of the pipeline will NOT take.
#
# After stage 2 rather than before it, because five of the nine facts are about
# tools stage 2 installs. Placing it earlier would assert them against a machine
# that has not been given them yet.
#
# The gate belongs here specifically because install-ci-tools.sh is BEST-EFFORT
# BY CONSTRUCTION. Every install in it is shaped:
#
#     if <download && verify && install>; then log "installed"; else
#       log "ERROR: <tool> failed verification or install"; fi
#
# It never exits. Nothing downstream converts those ERROR lines into a stop, so
# a failed install is a log line the pipeline walks straight past — and the
# consequence surfaces stages later as `bun: command not found`. This gate is
# the missing conversion from "logged an error" to "stopped".
#
# Measured on sl-demo-1-vm and sl-demo-2-vm, 2026-08-20: bun and uv are ABSENT
# from both, while node is present at its exact pin (v22.23.2) on demo-2. So the
# installer demonstrably ran and demonstrably did not fail as a unit.
#
# Note that on demo-1 the failure of fact 7a DESTROYS THE EVIDENCE for all the
# others: demo-up.sh:111 puts REMOTE_LOG at /opt/signalloom/demo-pipeline.log,
# /opt/signalloom is root-owned and unwritable by the login user, so the
# pipeline log cannot be created at all. There is nothing to read afterwards.
# That is the strongest argument for gating rather than diagnosing.

set -o pipefail

# ── Injectable boundaries ────────────────────────────────────────────────────
#
# Defaults are the real VM's paths. Every one is overridable so the suite can
# point the whole gate at a mktemp sandbox.

VMSC_BIN_DIR="${VMSC_BIN_DIR:-/usr/local/bin}"
VMSC_WORK_ROOT="${VMSC_WORK_ROOT:-/opt/signalloom}"

# demo-up.sh:110-111 own these two paths. Kept as separate variables rather than
# derived from VMSC_WORK_ROOT because demo-up.sh derives them from its OWN
# GCP_TF_DEMO_REMOTE_* overrides, and a gate that assumed the layout would stop
# agreeing with the driver the moment either is repointed.
VMSC_REPORT_DIR="${VMSC_REPORT_DIR:-${VMSC_WORK_ROOT}/reports}"
VMSC_PIPELINE_LOG="${VMSC_PIPELINE_LOG:-${VMSC_WORK_ROOT}/demo-pipeline.log}"

# The pin source. Derived, never copied. A version literal in this file would be
# a second copy of a number that already has an owner, and the copy is the one
# that goes stale — the exact failure demo-vm.sh:39 warns about ("THESE MUST
# MATCH scripts/ci/install-ci-tools.sh AND scripts/setup.sh").
VMSC_REPO_ROOT="${VMSC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
VMSC_PIN_FILE="${VMSC_PIN_FILE:-${VMSC_REPO_ROOT}/terraform/modules/compute/startup/demo-vm.sh}"

# The sudo probe, as a whole command line. `sudo -n true` succeeds only with
# passwordless sudo and never blocks on a password prompt — a blocking prompt in
# a gate invoked over `gcloud compute ssh --command` hangs until the SSH timeout
# and reports as a VM fault.
VMSC_SUDO_PROBE="${VMSC_SUDO_PROBE:-sudo -n true}"

VMSC_FORMAT="text"

# ── Result accumulation ──────────────────────────────────────────────────────
#
# NOTHING below exits early. A gate that stops at the first failure turns an
# eight-fact report into a one-fact report, and the operator then fixes that one
# thing and burns another forty-minute run discovering the next. Every fact is
# probed, every failure is named, and the exit status is decided at the end.

FACT_IDS=()
FACT_STATUS=()
FACT_DETAIL=()
FACT_REMEDY=()
FAILED=0

record() { # id status detail remedy
  FACT_IDS+=("$1")
  FACT_STATUS+=("$2")
  FACT_DETAIL+=("$3")
  FACT_REMEDY+=("$4")
  [ "$2" = "FAIL" ] && FAILED=$((FAILED + 1))
  return 0
}

# ── Probes ───────────────────────────────────────────────────────────────────

# The pinned version of one tool, read from the startup script that owns it,
# with any leading `v` stripped.
#
# The `v` normalisation is load-bearing and is the same rule
# test/helpers/toolchain-contract.bash applies: install-ci-tools.sh stores kind
# as "0.29.0" and prefixes it at the URL, demo-vm.sh stores "v0.29.0". A
# comparison that did not normalise would report those as different, be
# dismissed as a false positive, and get the check deleted.
#
# Anchored to the start of the line (allowing `readonly`) so a version quoted
# inside a COMMENT cannot satisfy it. demo-vm.sh:53 contains the literal
# "v0.24.0" in prose explaining the old defect; without the anchor that sentence
# would be a valid source for kind's pin, and the gate would assert the very
# version it exists to reject.
pin_for() { # var_name
  local var="$1" line
  line="$(grep -E "^(readonly[[:space:]]+)?${var}=" "${VMSC_PIN_FILE}" 2>/dev/null | head -1)" || return 1
  [ -n "$line" ] || return 1
  line="${line#*=}"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '"'"'"' \t\r')"
  printf '%s' "${line#v}"
}

# A tool is at its pin when the version it REPORTS contains the pinned triple.
#
# Substring and not equality, deliberately: `kind --version` prints "kind
# version 0.29.0" and `kubectl version --client` prints a multi-line block. The
# triple is anchored on both sides so that a pin of 1.33.2 is not satisfied by a
# reported 1.33.20 — the trap a bare substring match walks into.
fact_pinned_tool() { # id tool version_cmd pin_var
  local id="$1" tool="$2" cmd="$3" pin_var="$4" pin out rc

  if ! command -v "$tool" >/dev/null 2>&1; then
    record "$id" FAIL "${tool}: ABSENT from PATH" \
      "install ${tool}; on a demo VM that is terraform/modules/compute/startup/demo-vm.sh at boot"
    return 0
  fi

  pin="$(pin_for "$pin_var")"
  if [ -z "$pin" ]; then
    record "$id" FAIL "${tool}: no ${pin_var} pin found in ${VMSC_PIN_FILE}" \
      "declare ${pin_var} in ${VMSC_PIN_FILE}; this gate derives pins and never carries a copy"
    return 0
  fi

  # Status read from the command itself. Piping into head/tail and reading THAT
  # status is how a failed probe reports success — the trap that produced a
  # "WRITABLE" verdict against a failed touch while diagnosing this very bug.
  out="$($cmd 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    record "$id" FAIL "${tool}: present but '${cmd}' exited ${rc}" \
      "reinstall ${tool}; a binary that will not report its own version will not run the pipeline either"
    return 0
  fi

  if printf '%s' "$out" | grep -qE "(^|[^0-9.])${pin}([^0-9.]|$)"; then
    record "$id" PASS "${tool}: ${pin}" ""
  else
    record "$id" FAIL "${tool}: pinned ${pin}, found '$(printf '%s' "$out" | head -1)'" \
      "install_${tool}() in demo-vm.sh early-returns on PRESENCE, not version — a warm VM keeps the old binary forever. Remove ${tool} and re-run the installer, or let install-ci-tools.sh (which IS version-gated) correct it."
  fi
}

# Present and actually executable. Not `[ -x ]` on a path: a binary can be
# present, executable and still fail to run (wrong arch, missing loader,
# truncated download). Running it is the only honest question.
fact_runnable_tool() { # id tool version_cmd
  local id="$1" tool="$2" cmd="$3" out rc

  if ! command -v "$tool" >/dev/null 2>&1; then
    record "$id" FAIL "${tool}: ABSENT from PATH" \
      "scripts/ci/install-ci-tools.sh installs ${tool} pinned and checksum-verified, but it is BEST-EFFORT: it logs 'ERROR: ${tool} failed verification or install' and CARRIES ON. Check the installer output for that line."
    return 0
  fi

  out="$($cmd 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$id" PASS "${tool}: $(printf '%s' "$out" | head -1)" ""
  else
    record "$id" FAIL "${tool}: on PATH at $(command -v "$tool") but '${cmd}' exited ${rc}" \
      "the binary is present and broken — remove it and re-run scripts/ci/install-ci-tools.sh"
  fi
}

# ── Fact 6. The one where the obvious check is wrong. ────────────────────────
#
# THE OBVIOUS CHECK IS `[ -w /usr/local/bin ]`, AND IT IS WRONG IN BOTH
# DIRECTIONS. Measured on sl-demo-1-vm, 2026-08-20:
#
#     drwxr-xr-x 2 root root /usr/local/bin
#     touch /usr/local/bin/.probe  ->  Permission denied, rc=1
#     sudo -n true                 ->  rc=0
#
# That VM is HEALTHY. `[ -w ]` is false and the installers work anyway, because
# install-ci-tools.sh:26-27 does exactly this:
#
#     SUDO=""
#     [ -w "${BIN}" ] || SUDO="sudo"
#
# It ESCALATES when the directory is not writable. So a gate asserting bare
# writability fails on a correctly-provisioned machine — a false alarm, and a
# false alarm is how a check gets deleted. Andy's fact 6 as briefed ("writable
# by the invoking user") would have done exactly that.
#
# Reading the MODE BITS is worse still. `drwxr-xr-x` plus owner `root` says
# nothing until you resolve it against the invoking uid AND its supplementary
# groups AND any ACL. The brief also records this directory as
# `drwxr-xr-x 2 1001 google-sudoers` on a fresh VM and root:root here — the
# owner is not stable across rebuilds, so a mode-and-owner rule would encode a
# fact that changes underneath it. Probe the CAPABILITY. It is one syscall and
# it cannot be wrong.
#
# The real contract is: a binary can be PLACED here by the means the installers
# actually use. That is (directory writable) OR (passwordless sudo). Both are
# probed, both are reported, and the DISAGREEMENT is reported too, because the
# disagreement is what selects the ${SUDO} branch and therefore which of the two
# code paths the next twenty minutes will run.
fact_bin_placeable() { # id
  local id="$1" probe dir_w=0 sudo_ok=0 rc

  probe="${VMSC_BIN_DIR}/.vmsc-probe.$$"
  # rc read from touch, not from a pipeline. See the note in fact_pinned_tool.
  touch "$probe" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    dir_w=1
    rm -f "$probe" 2>/dev/null
  fi

  $VMSC_SUDO_PROBE >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] && sudo_ok=1

  if [ "$dir_w" -eq 1 ]; then
    # install-ci-tools.sh's install_binary unlinks before installing, and
    # unlinking needs write on the DIRECTORY, not on the file. So a writable
    # directory full of root-owned binaries is workable — but it is the state
    # that made `curl -o` fail on sl-demo-2-vm, so it is reported, not hidden.
    record "$id" PASS "${VMSC_BIN_DIR}: writable by $(id -un) (SUDO will be empty), sudo -n $([ "$sudo_ok" -eq 1 ] && echo available || echo unavailable)" ""
  elif [ "$sudo_ok" -eq 1 ]; then
    record "$id" PASS "${VMSC_BIN_DIR}: not writable by $(id -un), escalation available (SUDO will be 'sudo')" ""
  else
    record "$id" FAIL "${VMSC_BIN_DIR}: NOT writable by $(id -un) and 'sudo -n' is unavailable — no path to place a binary" \
      "this is the state that produces \"install: cannot create regular file '${VMSC_BIN_DIR}/bun': Permission denied\". Either grant the OS Login user passwordless sudo, or chmod a+w ${VMSC_BIN_DIR} as demo-pipeline.sh:418 attempts (it suppresses its own failure with 2>/dev/null || true, so check whether that chmod actually landed)."
  fi
}

# Fact 7. Existence AND writability, probed separately so the failure names
# which of the two is missing — "reports/ does not exist" and "reports/ exists
# and you cannot write to it" have different fixes.
fact_dir_writable() { # id path label
  local id="$1" path="$2" label="$3" probe rc

  if [ ! -d "$path" ]; then
    record "$id" FAIL "${label} ${path}: DOES NOT EXIST" \
      "demo-up.sh expects it (REMOTE_REPORT_DIR / REMOTE_WORK_DIR / REMOTE_LOG, demo-up.sh:109-111). Create it and chown it to the OS Login user."
    return 0
  fi

  probe="${path}/.vmsc-probe.$$"
  touch "$probe" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$probe" 2>/dev/null
    record "$id" PASS "${label} ${path}: exists, writable by $(id -un)" ""
  else
    record "$id" FAIL "${label} ${path}: exists but is NOT writable by $(id -un) ($(ls -ld "$path" 2>/dev/null | awk '{print $1, $3, $4}'))" \
      "chown it to the OS Login user. Unlike ${VMSC_BIN_DIR}, nothing escalates for this path — demo-up.sh writes here as the login user."
  fi
}

# ── Fact 8. The other one where the obvious check is wrong. ──────────────────
#
# THE OBVIOUS CHECK IS `getent group docker`, AND IT PASSES WHILE DOCKER FAILS.
#
# Group membership is granted on FIRST OS Login. /etc/group is updated
# immediately, so `getent group docker` lists the user straight away — but the
# RUNNING session's credentials were fixed at login, before the grant, and a
# process's supplementary groups cannot be changed after the fact. So there is a
# window, exactly one session wide, in which:
#
#     getent group docker  ->  docker:x:988:sa_1084...    (the user IS listed)
#     id -nG               ->  sa_1084...                 (docker ABSENT)
#     docker info          ->  permission denied on /var/run/docker.sock
#
# `id -nG` is better than getent and still not enough: it reads the same
# credential set, but it cannot see a stopped daemon, a missing socket, or a
# socket whose group is not `docker`. demo-vm.sh:810-818 records this precise
# shape — `systemctl is-active docker` reporting `active` while `docker info`
# returns permission denied.
#
# So probe the capability. `docker info` asks the only question that matters:
# can THIS process, with THESE credentials, right now, talk to the daemon.
fact_docker_usable() { # id
  local id="$1" out rc

  if ! command -v docker >/dev/null 2>&1; then
    record "$id" FAIL "docker: ABSENT from PATH" \
      "demo-vm.sh install_docker() runs at boot; check the signalloom-bootstrap journal"
    return 0
  fi

  out="$(docker info 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$id" PASS "docker: usable in THIS session (groups: $(id -nG))" ""
  else
    record "$id" FAIL "docker: present but unusable in THIS session — 'docker info' exited ${rc}: $(printf '%s' "$out" | grep -iE 'permission|cannot connect|denied' | head -1)" \
      "if 'getent group docker' lists $(id -un) but 'id -nG' does not, the group was granted AFTER this session started — reconnect the SSH session rather than re-running usermod. Otherwise check that the daemon is running and that /var/run/docker.sock is group-owned by docker."
  fi
}

# ── Reporting ────────────────────────────────────────────────────────────────

report_text() {
  local i n
  n=${#FACT_IDS[@]}
  echo "=== VM state contract — ${VMSC_BIN_DIR}, ${VMSC_WORK_ROOT}, $(id -un)@$(hostname) ==="
  for ((i = 0; i < n; i++)); do
    printf '  [%s] %-22s %s\n' "${FACT_STATUS[$i]}" "${FACT_IDS[$i]}" "${FACT_DETAIL[$i]}"
  done
  echo ""
  if [ "$FAILED" -eq 0 ]; then
    echo "PASS: ${n}/${n} facts hold. The pipeline's preconditions are met."
    return 0
  fi
  echo "FAIL: ${FAILED} of ${n} facts do not hold. The pipeline WILL fail on these."
  echo ""
  for ((i = 0; i < n; i++)); do
    [ "${FACT_STATUS[$i]}" = "FAIL" ] || continue
    printf '  %s\n      %s\n      -> %s\n' "${FACT_IDS[$i]}" "${FACT_DETAIL[$i]}" "${FACT_REMEDY[$i]}"
  done
}

json_escape() {
  # Minimal and sufficient: these strings are our own messages plus command
  # output. Backslash first, or it re-escapes the escapes.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\n\r'
}

report_json() {
  local i n first=1
  n=${#FACT_IDS[@]}
  printf '{"failed":%d,"total":%d,"facts":[' "$FAILED" "$n"
  for ((i = 0; i < n; i++)); do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"id":"%s","status":"%s","detail":"%s","remedy":"%s"}' \
      "$(json_escape "${FACT_IDS[$i]}")" \
      "$(json_escape "${FACT_STATUS[$i]}")" \
      "$(json_escape "${FACT_DETAIL[$i]}")" \
      "$(json_escape "${FACT_REMEDY[$i]}")"
  done
  printf ']}\n'
}

# ── Entry point ──────────────────────────────────────────────────────────────

main() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --format) VMSC_FORMAT="${2:-text}"; shift 2 ;;
      --format=*) VMSC_FORMAT="${1#*=}"; shift ;;
      -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; return 0 ;;
      *) echo "unknown argument: $1" >&2; return 2 ;;
    esac
  done

  case "$VMSC_FORMAT" in
    text|json) ;;
    *) echo "unknown --format '${VMSC_FORMAT}' (want text or json)" >&2; return 2 ;;
  esac

  # The pin file is a hard precondition, not a fact. Without it facts 1 and 2
  # cannot be evaluated at all, and a gate that silently downgrades two of its
  # eight assertions to "skipped" is the vacuous pass this repo keeps finding.
  if [ ! -f "${VMSC_PIN_FILE}" ]; then
    echo "HARNESS ERROR: pin source not found at ${VMSC_PIN_FILE}" >&2
    echo "               Facts 1 and 2 derive their versions from it and cannot run." >&2
    return 2
  fi

  fact_pinned_tool  F1-kind-pinned    kind    "kind --version"           KIND_VERSION
  fact_pinned_tool  F2-kubectl-pinned kubectl "kubectl version --client" KUBECTL_VERSION
  fact_runnable_tool F3-node-runnable node "node --version"
  fact_runnable_tool F4-bun-runnable  bun  "bun --version"
  fact_runnable_tool F5-uv-runnable   uv   "uv --version"
  fact_bin_placeable F6-bin-placeable
  fact_dir_writable  F7a-work-root-writable "${VMSC_WORK_ROOT}"  "work root"
  fact_dir_writable  F7b-reports-writable   "${VMSC_REPORT_DIR}" "report dir"
  fact_docker_usable F8-docker-usable

  if [ "$VMSC_FORMAT" = "json" ]; then
    report_json
  else
    report_text
  fi

  [ "$FAILED" -eq 0 ] || return 1
  return 0
}

main "$@"
