#!/usr/bin/env bash
# ci-lock.sh — exclusive advisory lock on the shared CI VM.
#
#   ci-lock.sh acquire [--force]   # take the lock, or refuse naming the holder
#   ci-lock.sh release             # release it, but only if we hold it
#   ci-lock.sh status              # print the current holder, or "free"
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# `gcp-ci.sh run` does two irreversible things to shared state before it runs a
# single test: `push_code` does `rm -rf /home/ci/osramp-demo`, and the pipeline
# does `make teardown`. Neither asks whether anyone is using the VM.
#
# On 2026-08-04 that landed on live work three times in one night. Each loss
# cost 20-40 minutes of cluster rebuild, and the third landed 25 seconds after
# the other party announced they were taking the VM — which is the point:
# announcing is not a control, because the race is shorter than the time it
# takes to read a message. Two agents each politely checking `ps` first will
# still collide.
#
# So the check moves into the tool. It is advisory rather than enforced — a
# determined caller can `--force` — but it converts a silent destructive race
# into an explicit decision by someone who has been told what they are about to
# destroy.
#
# ─── Why mkdir ─────────────────────────────────────────────────────────────
#
# `mkdir` is atomic and fails unambiguously when the directory exists, over NFS
# and every local filesystem, with no flock daemon and no helper binary on the
# far side. `[ -e ] && ...` is not atomic and is exactly the check-then-act race
# this file exists to remove. The holder metadata is written into the directory
# AFTER it is created, so a reader may briefly see an empty lock — treated as
# "held by someone unknown", which is the safe reading.
#
# ─── Testability ────────────────────────────────────────────────────────────
#
# Every remote call goes through CI_LOCK_REMOTE_EXEC, a command that takes a
# shell snippet as its final argument. gcp-ci.sh wires it to the IAP SSH
# invocation; the tests wire it to `bash -c`, which makes the whole lock
# protocol exercisable against a local temp directory with no VM, no gcloud and
# no network.
set -euo pipefail

LOCK_PATH="${CI_LOCK_PATH:-/home/ci/.ci-lock}"
# Four hours. Long enough that a legitimate long run is never stolen from --
# the pipeline's own outer fence is 180 minutes -- and short enough that a
# crashed holder does not wedge the VM until someone notices.
LOCK_TTL_MINUTES="${CI_LOCK_TTL_MINUTES:-240}"
LOCK_HOLDER="${CI_LOCK_HOLDER:-$(id -un 2>/dev/null || echo unknown)@$(hostname -s 2>/dev/null || echo host)}"
# Identifies THIS invocation, so release cannot remove a lock someone else took
# after ours expired and was stolen.
LOCK_TOKEN="${CI_LOCK_TOKEN:-${LOCK_HOLDER}:$$}"
REMOTE_EXEC="${CI_LOCK_REMOTE_EXEC:-}"

die() { printf 'ci-lock: %s\n' "$*" >&2; exit 2; }
[ -n "$REMOTE_EXEC" ] || die "CI_LOCK_REMOTE_EXEC is not set"

# Run a snippet on the far side. Word-split REMOTE_EXEC deliberately: it is a
# command plus its flags, supplied by the caller, not user input.
remote() {
  # shellcheck disable=SC2086
  $REMOTE_EXEC "$1"
}

now() { date +%s; }

# Read the holder record, or print nothing when the lock is free.
read_lock() {
  remote "cat '${LOCK_PATH}/holder' 2>/dev/null || true" 2>/dev/null || true
}

# holder|token|epoch|reason
lock_field() {
  local record="$1" index="$2"
  printf '%s' "$record" | awk -F'|' -v i="$index" 'NR==1 { print $i }'
}

human_age() {
  local secs="$1"
  if [ "$secs" -lt 90 ]; then printf '%ds' "$secs"
  elif [ "$secs" -lt 5400 ]; then printf '%dm' "$((secs / 60))"
  else printf '%dh%dm' "$((secs / 3600))" "$(((secs % 3600) / 60))"; fi
}

cmd_status() {
  local record held_since age
  record="$(read_lock)"
  if [ -z "$record" ]; then
    echo "free"
    return 0
  fi
  held_since="$(lock_field "$record" 3)"
  # A lock directory with no readable timestamp is still a lock. Reporting it
  # as free because the metadata is unreadable would be the worst possible
  # failure mode for a safety check.
  if [ -z "$held_since" ]; then
    echo "held by an unknown process (lock exists, metadata unreadable)"
    return 0
  fi
  age=$(( $(now) - held_since ))
  printf 'held by %s for %s' "$(lock_field "$record" 1)" "$(human_age "$age")"
  local reason
  reason="$(lock_field "$record" 4)"
  [ -n "$reason" ] && printf ' (%s)' "$reason"
  printf '\n'
}

write_holder() {
  local reason="${1:-}"
  remote "printf '%s|%s|%s|%s\n' '${LOCK_HOLDER}' '${LOCK_TOKEN}' '$(now)' '${reason}' > '${LOCK_PATH}/holder'"
}

cmd_acquire() {
  local force=0 reason=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force)  force=1 ;;
      --reason) shift; reason="${1:-}" ;;
      *) die "unknown argument: $1" ;;
    esac
    shift
  done

  if remote "mkdir '${LOCK_PATH}' 2>/dev/null && echo ACQUIRED" | grep -q ACQUIRED; then
    write_holder "$reason"
    echo "ci-lock: acquired by ${LOCK_HOLDER}"
    return 0
  fi

  # Held. Decide between refusing, stealing a stale lock, and forcing.
  local record held_since age holder
  record="$(read_lock)"
  holder="$(lock_field "$record" 1)"
  held_since="$(lock_field "$record" 3)"
  age=0
  [ -n "$held_since" ] && age=$(( $(now) - held_since ))

  if [ "$force" -eq 1 ]; then
    printf 'ci-lock: FORCING past a lock held by %s for %s\n' \
      "${holder:-an unknown process}" "$(human_age "$age")" >&2
    write_holder "$reason"
    echo "ci-lock: acquired by ${LOCK_HOLDER} (forced)"
    return 0
  fi

  if [ -n "$held_since" ] && [ "$age" -gt $((LOCK_TTL_MINUTES * 60)) ]; then
    printf 'ci-lock: reclaiming a STALE lock held by %s for %s (TTL %dm)\n' \
      "${holder:-an unknown process}" "$(human_age "$age")" "$LOCK_TTL_MINUTES" >&2
    write_holder "$reason"
    echo "ci-lock: acquired by ${LOCK_HOLDER} (stale lock reclaimed)"
    return 0
  fi

  # Refuse, and say what would have been destroyed. "Lock held" on its own
  # invites --force as a reflex; naming the blast radius does not.
  cat >&2 <<EOF
ci-lock: REFUSING — the CI VM is in use.

  Held by : ${holder:-an unknown process}
  For     : $(human_age "$age")
  Reason  : $(lock_field "$record" 4)

  Proceeding would run 'rm -rf ${GCP_CI_REMOTE_WORK_DIR:-/home/ci/osramp-demo}'
  and 'make teardown' on a cluster someone else is using. That has cost 20-40
  minutes of rebuild every time it has happened.

  If you are certain the holder is gone:
    $(basename "$0") acquire --force
  Locks older than ${LOCK_TTL_MINUTES}m are reclaimed automatically.
EOF
  return 1
}

cmd_release() {
  local record token
  record="$(read_lock)"
  if [ -z "$record" ]; then
    echo "ci-lock: already free"
    return 0
  fi
  token="$(lock_field "$record" 2)"
  # Only release our own. Without this, a run that overran its TTL and was
  # legitimately stolen would delete the new holder's lock on the way out --
  # turning a safety mechanism into a second, subtler race.
  if [ "$token" != "$LOCK_TOKEN" ]; then
    printf 'ci-lock: NOT releasing — the lock is now held by %s, not by us\n' \
      "$(lock_field "$record" 1)" >&2
    return 1
  fi
  remote "rm -rf '${LOCK_PATH}'"
  echo "ci-lock: released by ${LOCK_HOLDER}"
}

case "${1:-status}" in
  acquire) shift; cmd_acquire "$@" ;;
  release) cmd_release ;;
  status)  cmd_status ;;
  *) die "usage: $(basename "$0") {acquire [--force] [--reason TEXT]|release|status}" ;;
esac
