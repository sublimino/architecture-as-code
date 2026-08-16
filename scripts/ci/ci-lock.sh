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
# Retry parameters for the transport-failure path. Tests override these to avoid
# sleeping in a tight loop; production uses the defaults (3 attempts, 1s base).
LOCK_RETRY_MAX="${CI_LOCK_RETRY_MAX:-3}"
LOCK_RETRY_DELAY="${CI_LOCK_RETRY_DELAY:-1}"
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

# Bare word on purpose: it is interpolated into a remote snippet that gcp-ci.sh
# passes through `bash -c "$1"`, so anything needing quoting would not survive.
readonly LOCK_FREE_SENTINEL="__CI_LOCK_FREE__"

# Read the holder record. Three outcomes, deliberately distinguishable:
#   held        — prints the record, returns 0
#   free        — prints nothing,   returns 0
#   unreachable — prints nothing,   returns 2
#
# The previous `|| true` collapsed the third case into the second, and an
# unreachable VM is the opposite of a free lock. It made `status` answer "free"
# to anyone whose IAP tunnel hiccupped while another agent was mid-run — the
# green light for exactly the collision this file exists to prevent — and made
# `release` print "already free" and exit 0 without releasing anything.
#
# The far side echoes a sentinel for "no lock", so empty stdout can only mean
# the transport never ran the snippet.
read_lock() {
  local out
  out="$(remote "cat '${LOCK_PATH}/holder' 2>/dev/null || echo ${LOCK_FREE_SENTINEL}" 2>/dev/null)" \
    || return 2
  [ -n "$out" ] || return 2
  if printf '%s\n' "$out" | grep -qF "$LOCK_FREE_SENTINEL"; then
    return 0
  fi
  printf '%s\n' "$out"
  return 0
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
  local record held_since age rc=0
  record="$(read_lock)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Never answer "free" for a question we could not ask. A caller who acts on
    # a false "free" runs `rm -rf` and `make teardown` on someone else's work.
    echo "unknown — could not reach the VM to read the lock" >&2
    return 2
  fi
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

  # Held, OR the far side is unreachable — the mkdir above cannot tell those
  # apart on its own. Separate them here, before any branch that would write a
  # holder record: an unreachable VM must never be mistaken for a stale lock
  # and reclaimed, and --force past a VM we cannot talk to acquires nothing.
  local record held_since age holder rc=0
  record="$(read_lock)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    die "cannot reach the VM to read the lock — refusing to assume it is free"
  fi

  # ─── Transport-failure retry ──────────────────────────────────────────────
  #
  # read_lock returned 0 with an empty record: the lock is FREE. But the mkdir
  # above failed — its SSH never ran (return 255 from a VM still booting, a
  # flaky IAP tunnel, etc.). The combination is conclusive: nobody holds the
  # lock, but we could not create it because the transport was down.
  #
  # The transport just worked (read_lock succeeded), so retry the mkdir with a
  # short bounded backoff. If the retry succeeds, acquire normally. If it
  # fails but read_lock still shows free, tell the operator what actually
  # happened — never say "the CI VM is in use" when nobody is using it.
  if [ -z "$record" ]; then
    local attempt
    for attempt in $(seq 1 "$LOCK_RETRY_MAX"); do
      sleep "$((LOCK_RETRY_DELAY * attempt))"  # linear backoff, bounded
      if remote "mkdir '${LOCK_PATH}' 2>/dev/null && echo ACQUIRED" | grep -q ACQUIRED; then
        write_holder "$reason"
        echo "ci-lock: acquired by ${LOCK_HOLDER} (retry ${attempt}/${LOCK_RETRY_MAX})"
        return 0
      fi
      # Re-read: someone may have acquired between our attempts.
      rc=0
      record="$(read_lock)" || rc=$?
      if [ "$rc" -ne 0 ]; then
        die "cannot reach the VM to read the lock — refusing to assume it is free"
      fi
      if [ -n "$record" ]; then
        # Someone else acquired the lock while we were retrying. Fall through
        # to the normal held-lock path below with their record.
        break
      fi
    done
    # Exhausted retries and the lock is still free but we cannot create it.
    # Two explanations remain:
    #   (a) The lock directory exists but has no holder file — half-written
    #       state from a crash during acquire. This is a lock, not free.
    #   (b) SSH transport is genuinely flaky for mkdir while read_lock works.
    # Distinguish by probing whether the directory exists.
    if [ -z "$record" ]; then
      local dir_exists=""
      dir_exists="$(remote "[ -d '${LOCK_PATH}' ] && echo EXISTS || echo ABSENT" 2>/dev/null)" || true
      if [ "$dir_exists" = "EXISTS" ]; then
        # The lock directory exists but has no holder file. A crash during
        # acquire produces this state. It is still a lock — the safe reading
        # is "held by someone unknown", which is what the REFUSING block
        # below will produce (holder="", held_since="", age=0).
        : # fall through to the REFUSING block with empty record fields
      else
        cat >&2 <<EOF
ci-lock: TRANSPORT ERROR — the lock is free but we cannot acquire it.

  The mkdir that creates the lock failed ${LOCK_RETRY_MAX} times, but every
  read_lock confirmed the lock is free. The SSH transport to the VM is
  unstable — likely a VM still booting or a flaky IAP tunnel.

  Nobody holds the lock. Wait a moment for the VM to finish booting
  and try again.
EOF
        return 2
      fi
    fi
  fi

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
  local record token rc=0
  record="$(read_lock)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Say the lock is still held, because it is. "already free" here was the
    # exact wording a suspended VM produced on every successful run, while the
    # lock sat on disk for its whole 4h TTL.
    printf 'ci-lock: could not reach the VM — the lock was NOT released and is still held by %s\n' \
      "$LOCK_HOLDER" >&2
    printf '        It expires on its own after %sm, or: %s release\n' \
      "$LOCK_TTL_MINUTES" "$(basename "$0")" >&2
    return 1
  fi
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
