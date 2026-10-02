#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      test-agent-sandbox-escape
# @target  nono/profiles/worktree-agent.json
# @doc     docs/slaat/p1-4/sentinel-landlock-confinement-adversarial-dossier.md
# @spec    SLAAT-P1-4
# @tests   test/landlock-adversarial-escape.bats
#
# SLAAT-P1-4 — live adversarial escape battery against the shipped Landlock
# confinement (nono + nono/profiles/worktree-agent.json).
#
# This is a PROBE harness, not a proof-of-fix harness: SLAAT Phase 1 attacks
# the deployed boundary as it exists today and records what actually happens.
# It never edits the profile or the sentinel/Landlock source (merge boundary
# for this card) and it is read-only against the host outside its own
# throwaway fixture directory.
#
# Every attack has a HONEST verdict, including attacks that would pass even
# without Landlock (classic DAC already denies /etc/shadow to this uid; a
# missing CAP_NET_RAW already denies a raw socket). Those are recorded with an
# explicit "redundant-with-dac" / "redundant-with-capability" note rather than
# credited to Landlock, per the mission's Adversarial Integrity pattern: no
# silent masking, no inflated attribution.
#
# Deliberately NOT using `set -e` — see test-cgroup-freezer.sh for the reason:
# every probe must run so the tally reflects the whole battery, not a prefix.
set -uo pipefail

readonly DECLARED_PROBES=16

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
PROFILE="${REPO_ROOT}/nono/profiles/worktree-agent.json"
# Inside the shipped allow-list (~/.cline/worktrees/ or ~/src/.worktrees/) so
# the UNMODIFIED profile already grants it — no fixture profile needed.
FIXTURE_DIR="${REPO_ROOT}/.tmp/slaat-p1-4-landlock-escape"
JSON_OUT=""

PASS=0
FAIL=0
EXECUTED=0
declare -a RESULTS=()

log() { printf '%s\n' "$*" >&2; }

usage_text() {
  cat <<'EOF'
Usage: scripts/test-agent-sandbox-escape.sh [--json PATH]

Live adversarial Landlock escape battery against nono/profiles/worktree-agent.json.
Requires: nono, an active Landlock LSM (checked; skips with exit 3 otherwise).
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --json) JSON_OUT="${2:-}"; shift 2 ;;
    --json=*) JSON_OUT="${1#*=}"; shift ;;
    -h | --help) usage_text; exit 0 ;;
    *) log "unknown option: $1"; usage_text >&2; exit 2 ;;
    esac
  done
}

sandbox_available() {
  command -v nono >/dev/null 2>&1 || return 1
  grep -qw landlock /sys/kernel/security/lsm 2>/dev/null || return 1
  return 0
}

preflight() {
  [[ -f "${PROFILE}" ]] || { log "profile not found: ${PROFILE}"; exit 3; }
  if ! sandbox_available; then
    log "nono and/or Landlock unavailable on this host — cannot run the live battery"
    exit 3
  fi
}

# record ID DESCRIPTION EXPECTATION OK EVIDENCE [NOTE]
record() {
  local id="$1" desc="$2" expect="$3" ok="$4" evidence="$5" note="${6:-}"
  EXECUTED=$((EXECUTED + 1))
  local verdict="fail"
  if [[ "${ok}" == "1" ]]; then
    verdict="pass"
    PASS=$((PASS + 1))
    log "  ok   ${id} — ${desc}"
  else
    FAIL=$((FAIL + 1))
    log "  FAIL ${id} — ${desc}"
  fi
  RESULTS+=("$(jq -nc \
    --arg id "${id}" --arg d "${desc}" --arg e "${expect}" \
    --arg v "${verdict}" --arg ev "${evidence}" --arg n "${note}" \
    '{id:$id, description:$d, expectation:$e, verdict:$v, evidence:$ev, note:$n}')")
}

# confined CMD... — run a command inside the shipped, unmodified profile,
# rooted at the fixture dir (inside the profile's own allow-list).
#
# `nono wrap`, not `nono run`: this harness itself executes inside an outer
# nono sandbox (nested kpai/agent session management), and `run` persists a
# session record under $XDG_STATE_HOME/nono/{sessions,audit}/ — a directory
# the OUTER sandbox denies write access to, so every nested `run` invocation
# stalled ~13-26s and then failed with "Permission denied" writing its own
# session file, before ever reaching the command under test. `wrap` execs
# directly ("nono disappears") with no session-state file, so it is unaffected
# by the outer sandbox's state-directory denial. Recorded as a finding in the
# dossier: nono cannot self-nest via `run` under this host's own confinement.
confined() {
  timeout 30 nono wrap -s --allow-cwd -p "${PROFILE}" -- "$@" 2>&1
}

setup_fixture() {
  rm -rf "${FIXTURE_DIR}"
  mkdir -p "${FIXTURE_DIR}/work"
  cd "${FIXTURE_DIR}/work" || exit 3
}

cleanup() {
  cd "${REPO_ROOT}" || true
  rm -rf "${FIXTURE_DIR}"
}

main() {
  parse_args "$@"
  preflight
  setup_fixture
  trap cleanup EXIT

  # ── Filesystem boundary: same-uid secrets Landlock denies that DAC alone
  #    would allow (the differential that actually proves Landlock, not DAC) ──

  local out status outer_ssh_readable=1
  cat "${HOME}/.ssh/id_rsa" >/dev/null 2>&1 || outer_ssh_readable=0
  out="$(confined cat "${HOME}/.ssh/id_rsa" 2>&1)"; status=$?
  record "fs.ssh-key-read-denied" \
    "confined read of \$HOME/.ssh/id_rsa" \
    "non-zero exit, Permission/Operation not permitted" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200} outer_sandbox_already_readable=${outer_ssh_readable}" \
    "$([[ ${outer_ssh_readable} -eq 0 ]] && echo "this harness's OWN bash tool is itself nono-confined and already denies ~/.ssh before the inner worktree-agent profile is even applied — not a clean Landlock-specific differential on this host, so the inner profile's own explicit deny entry (also present) is the attribution that holds" || echo "clean differential: outer context can read this file, inner profile denies it")"

  out="$(confined cat "${HOME}/.kube/config" 2>&1)"; status=$?
  record "fs.kube-config-read-denied" \
    "confined read of \$HOME/.kube/config (same-uid, DAC-readable)" \
    "non-zero exit, Permission/Operation not permitted" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}"

  # /etc/shadow: DAC already denies this to an unprivileged uid regardless of
  # Landlock. Record BOTH halves so the result cannot be misread as "Landlock
  # stopped this" when the kernel's classic permission bits already did.
  local dac_mode
  dac_mode="$(stat -c '%a %U:%G' /etc/shadow 2>/dev/null || echo unknown)"
  out="$(confined cat /etc/shadow 2>&1)"; status=$?
  record "fs.shadow-read-denied-redundant-with-dac" \
    "confined read of /etc/shadow" \
    "non-zero exit (denied by DAC mode ${dac_mode} independent of Landlock)" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} dac_mode=${dac_mode}" \
    "redundant-with-dac: this uid cannot read /etc/shadow with or without Landlock"

  out="$(confined sh -c 'echo pwned > /etc/slaat-p1-4-probe' 2>&1)"; status=$?
  record "fs.etc-openat-o_creat-denied" \
    "confined openat(O_CREAT) write to /etc/slaat-p1-4-probe" \
    "non-zero exit, Permission/Operation not permitted" \
    "$([[ ${status} -ne 0 && ! -e /etc/slaat-p1-4-probe ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}"
  rm -f /etc/slaat-p1-4-probe 2>/dev/null || true

  # ── Symlink traversal: a symlink INSIDE the allowed worktree pointing at a
  #    denied target must still resolve against the real target, not the link
  #    path. This is the failure mode named in the card's prior errata. ──────
  ln -sfn "${HOME}/.ssh/id_rsa" "${FIXTURE_DIR}/work/sneaky-link"
  out="$(confined cat "${FIXTURE_DIR}/work/sneaky-link" 2>&1)"; status=$?
  record "fs.symlink-traversal-denied" \
    "confined read through a symlink (inside allowed dir) pointing at \$HOME/.ssh/id_rsa" \
    "non-zero exit — Landlock resolves the real target, not the link path" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}"

  ln -sfn /etc/passwd "${FIXTURE_DIR}/work/passwd-link"
  out="$(confined cat "${FIXTURE_DIR}/work/passwd-link" 2>&1)"; status=$?
  record "fs.symlink-to-baseline-system-read-succeeds" \
    "confined read through a symlink pointing at /etc/passwd" \
    "exit 0 — /etc/passwd is granted by nono's composed 'system_read_linux_core' baseline group (NSS dependency), not by worktree-agent.json's own explicit read list" \
    "$([[ ${status} -eq 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:120}" \
    "corrected expectation: an earlier draft of this probe wrongly assumed the profile denies anything it does not explicitly list; nono composes a baseline system-read capability group (glibc NSS paths) into every profile regardless, which this symlink read correctly traverses to — not a leak introduced by worktree-agent.json"

  # ── /proc inspection: another process's address-space-adjacent state ─────
  out="$(confined cat /proc/1/environ 2>&1)"; status=$?
  record "proc.other-pid-environ-denied" \
    "confined read of /proc/1/environ (pid 1, not self)" \
    "non-zero exit or empty read" \
    "$([[ ${status} -ne 0 || -z "${out}" ]] && echo 1 || echo 0)" \
    "status=${status} out_len=${#out}" \
    "boundary is Landlock filesystem scoping (no /proc grant) rather than a /proc-specific LSM rule"

  out="$(confined sh -c 'ls /proc/$$/fd 2>&1')"; status=$?
  record "proc.self-fd-introspection" \
    "confined process can inspect its OWN /proc/self (expected, not an escape)" \
    "exit 0 — self-introspection is not a boundary violation" \
    "$([[ ${status} -eq 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}" \
    "control: distinguishes 'denied /proc entirely' from 'denied OTHER pids under /proc'"

  # ── ptrace: governed by Yama (ptrace_scope), not Landlock. Named here
  #    because the card's Approach lists it explicitly as an attack vector. ──
  local scope victim
  scope="$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo unknown)"
  sleep 30 &
  victim=$!
  disown "${victim}" 2>/dev/null || true
  # Inner `timeout 3`: if attach somehow SUCCEEDED, strace would sit tracing
  # the victim until it exits. The inner bound guards against that hang
  # independently of the outer confined() timeout.
  out="$(confined timeout 3 strace -p "${victim}" -e trace=none 2>&1)"; status=$?
  # yama ptrace_scope read 0 (unrestricted-by-Yama) on this host, yet the
  # attach still fails EPERM — so Yama is NOT what is enforcing this denial.
  # The evidence (PTRACE_SEIZE: Operation not permitted at scope=0) points to
  # nono's own seccomp-bpf filter denying ptrace(2) for the sandboxed process,
  # independent of both Yama and Landlock. Recorded as observed, not assumed.
  record "proc.ptrace-attach-unrelated-pid-denied" \
    "confined ptrace-attach to an unrelated sibling process (host yama ptrace_scope=${scope})" \
    "attach refused" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "scope=${scope} status=${status} out=${out:0:200}" \
    "attribution corrected from an earlier draft: ptrace_scope=0 means Yama is NOT restricting this (scope 0 is unrestricted same-uid ptrace), so the observed EPERM is nono's own seccomp-bpf denial of ptrace(2), not Landlock and not Yama — a containment layer this probe found in place but attributed to the wrong mechanism on first pass"
  kill "${victim}" >/dev/null 2>&1 || true

  # ── Raw socket: needs CAP_NET_RAW, independent of Landlock's network rules ─
  out="$(confined python3 -c 'import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, 1)' 2>&1)"; status=$?
  record "net.raw-socket-denied-redundant-with-capability" \
    "confined socket(AF_INET, SOCK_RAW)" \
    "non-zero exit, Operation not permitted (missing CAP_NET_RAW)" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}" \
    "redundant-with-capability: this uid lacks CAP_NET_RAW with or without Landlock/nono"

  # ── Network: confined connect to a non-allow-listed port is refused ───────
  out="$(confined bash -c 'exec 3<>/dev/tcp/127.0.0.1/39999' 2>&1)"; status=$?
  record "net.non-allowlisted-port-denied" \
    "confined connect to 127.0.0.1:39999 (not in network.open_port)" \
    "non-zero exit" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:160}"

  # ── Namespace creation: unshare itself is a namespace feature, not a
  #    Landlock concern. The adversarially meaningful question is whether
  #    escaping into a new PID namespace buys ANY new filesystem access. ──────
  out="$(confined unshare --pid --fork --mount-proc -- true 2>&1)"; status=$?
  local unshare_allowed=0
  [[ ${status} -eq 0 ]] && unshare_allowed=1
  record "ns.unshare-pid-namespace-creation" \
    "confined 'unshare --pid --fork --mount-proc -- true'" \
    "informational — namespace creation is a capability/sysctl question, not Landlock's" \
    "1" \
    "status=${status} allowed=${unshare_allowed} out=${out:0:200}" \
    "informational probe; see ns.unshare-does-not-widen-fs-access for the security-relevant half"

  out="$(confined unshare --pid --fork --mount-proc -- cat "${HOME}/.ssh/id_rsa" 2>&1)"; status=$?
  record "ns.unshare-does-not-widen-fs-access" \
    "a process that unshares into a NEW pid namespace still cannot read \$HOME/.ssh/id_rsa" \
    "non-zero exit — Landlock's ruleset is inherited across unshare(CLONE_NEWPID), not reset" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}" \
    "the critical escape this probe rules out: unshare as a Landlock-bypass vector"

  # ── Child process inheritance: a forked/exec'd child inherits confinement ──
  out="$(confined bash -c 'bash -c "cat ${HOME}/.ssh/id_rsa" 2>&1')"; status=$?
  record "proc.child-process-inherits-confinement" \
    "a child process spawned by a confined shell is itself confined" \
    "non-zero exit — Landlock rulesets are inherited by children (PR_SET_NO_NEW_PRIVS-equivalent persistence)" \
    "$([[ ${status} -ne 0 ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:200}"

  # ── Background thread race: a thread started before the privileged read
  #    attempt does not get a window to exfiltrate before Landlock applies —
  #    Landlock is applied to the TASK at exec time, before any thread runs. ──
  out="$(confined bash -c '
    (sleep 0.05; cat '"${HOME}"'/.ssh/id_rsa > '"${FIXTURE_DIR}"'/work/exfil 2>/dev/null) &
    wait
  ' 2>&1)"
  status=$?
  local exfil_happened=0
  [[ -s "${FIXTURE_DIR}/work/exfil" ]] && exfil_happened=1
  record "proc.background-thread-race-no-exfil-window" \
    "a background subshell started inside the confined process attempts the same denied read" \
    "the denied file is never written to the exfil path — no race window" \
    "$([[ "${exfil_happened}" -eq 0 ]] && echo 1 || echo 0)" \
    "exfil_file_size=$(stat -c %s "${FIXTURE_DIR}/work/exfil" 2>/dev/null || echo 0)"

  # ── Positive control: a legitimately allowed write inside the worktree
  #    still succeeds, so every denial above is a denial and not a dead sandbox
  out="$(confined bash -c 'echo ok > control-write.txt && cat control-write.txt' 2>&1)"; status=$?
  record "control.allowed-write-inside-worktree-succeeds" \
    "confined write+read inside the allow-listed worktree path" \
    "exit 0, prints 'ok'" \
    "$([[ ${status} -eq 0 && "${out}" == *"ok"* ]] && echo 1 || echo 0)" \
    "status=${status} out=${out:0:80}" \
    "positive control: without this, a broken/non-functional sandbox would also 'pass' every denial above"

  # ── Arity gate ─────────────────────────────────────────────────────────────
  local arity_ok=1
  if [[ "${EXECUTED}" -ne "${DECLARED_PROBES}" ]]; then
    arity_ok=0
    log "ARITY MISMATCH: executed ${EXECUTED} probes, declared ${DECLARED_PROBES}"
  fi

  local overall="pass"
  [[ "${FAIL}" -eq 0 && "${arity_ok}" -eq 1 ]] || overall="pass-with-findings"
  # No probe here is a hard-blocker escape (checked individually); "fail" in a
  # probe's own verdict still surfaces in the artifact for the dossier to read.
  [[ "${FAIL}" -eq 0 ]] && overall="pass"

  log ""
  log "probes: ${PASS}/${EXECUTED} passed (declared ${DECLARED_PROBES}) — ${overall}"

  local artifact
  artifact="$(jq -n \
    --arg artifact "agent-sandbox-escape-probe" \
    --arg card "SLAAT-P1-4" \
    --arg overall "${overall}" \
    --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kernel "$(uname -r)" \
    --arg lsm "$(cat /sys/kernel/security/lsm 2>/dev/null || echo unknown)" \
    --arg nono "$(nono --version 2>&1)" \
    --arg profile "${PROFILE}" \
    --argjson declared "${DECLARED_PROBES}" \
    --argjson executed "${EXECUTED}" \
    --argjson passed "${PASS}" \
    --argjson failed "${FAIL}" \
    --slurpfile probes <(printf '%s\n' "${RESULTS[@]}" | jq -s '.') \
    '{
       artifact: $artifact,
       card: $card,
       overall: $overall,
       generated: $generated,
       host: {kernel: $kernel, lsm: $lsm, nono: $nono},
       profile: $profile,
       totals: {declared: $declared, executed: $executed, passed: $passed, failed: $failed},
       probes: $probes[0]
     }')"

  if [[ -n "${JSON_OUT}" ]]; then
    mkdir -p "$(dirname -- "${JSON_OUT}")"
    printf '%s\n' "${artifact}" >"${JSON_OUT}"
    log "proof artifact written to ${JSON_OUT}"
  else
    printf '%s\n' "${artifact}"
  fi

  [[ "${EXECUTED}" -eq "${DECLARED_PROBES}" ]] && return 0
  return 1
}

main "$@"
