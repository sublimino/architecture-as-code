#!/usr/bin/env bash
# scripts/lib/env-file.sh — resolve and load the repo's local .env
#
# @id      env-file
# @tests   d2-signalloom/test/env-file.bats
# @doc     .env.example
#
# THE BUG THIS EXISTS TO FIX
#
# `.env` is gitignored, so it is never checked out into a linked worktree — it
# exists ONLY in the main checkout. The obvious idiom, used by every .env reader
# in this repo before this file existed:
#
#     if [ -f .env ]; then set -a; . ./.env; set +a; fi
#
# resolves against $PWD. Run from a worktree it finds nothing, takes the
# "no credentials configured" branch, prints a helpful message and exits 0.
#
# That is a fake success. The operator supplied a key; the tooling reports there
# is no key; nothing anywhere indicates the file was sitting two directories
# away the whole time. It is the same class of defect as the placeholder
# credential this branch removes: a check that passes while the thing it checks
# for is absent.
#
# THE FIX
#
# Resolve from the MAIN checkout via git, not from $PWD. `git rev-parse
# --git-common-dir` returns the main worktree's .git from anywhere inside any
# linked worktree.
#
# Two traps handled below, both real:
#   - it returns a RELATIVE path (".git") from the main worktree root and an
#     absolute one from a linked worktree, so it must be normalised;
#   - it fails outside a git repo, which must degrade rather than explode.
#
# PRECEDENCE
#
# A variable already set and non-empty in the environment WINS over the file.
# This is a deliberate, documented deviation from the previous behaviour (a bare
# `set -a; . ./.env` clobbers the environment). Reason: `ANTHROPIC_API_KEY=x make
# …` must do what it says, and CI sets variables directly. It changes nothing
# for anyone who does not export the variable. Callers should print
# `signalloom_env_provenance` so the source is never a guess.
#
# OVERRIDE
#
# $SIGNALLOOM_ENV_FILE points the whole mechanism at an explicit path, for CI
# and the GCP lanes where there may be no git repo at all.

# Absolute path of the .env this repo should use. Always prints something; the
# file is not required to exist.
signalloom_env_file() {
  if [ -n "${SIGNALLOOM_ENV_FILE:-}" ]; then
    printf '%s' "$SIGNALLOOM_ENV_FILE"
    return 0
  fi

  local common="" root=""

  # git >= 2.31 normalises for us. Confirmed present locally (2.54.0), but the
  # flag is probed rather than assumed — an unknown flag makes git exit non-zero
  # and print usage, which would otherwise land in $common as garbage.
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""

  if [ -z "$common" ]; then
    # Older git: normalise by hand. `cd`+`pwd` turns ".git" into an absolute
    # path and resolves any symlinks on the way.
    common="$(git rev-parse --git-common-dir 2>/dev/null)" || common=""
    if [ -n "$common" ] && [ -d "$common" ]; then
      common="$(cd "$common" 2>/dev/null && pwd)" || common=""
    else
      common=""
    fi
  fi

  if [ -n "$common" ]; then
    root="$(dirname "$common")"
    if [ -n "$root" ] && [ "$root" != "." ]; then
      printf '%s/.env' "$root"
      return 0
    fi
  fi

  # Not a git repo, or git is unavailable. Fall back to the historical
  # behaviour rather than failing: this helper must never be the reason a
  # best-effort target stops working.
  printf '%s/.env' "$PWD"
}

# Loads the resolved .env into the environment without clobbering variables the
# caller already set. Sets two globals the caller can report on:
#   SIGNALLOOM_ENV_FILE_RESOLVED  the path consulted
#   SIGNALLOOM_ENV_LOADED         1 if it existed and was read, else 0
signalloom_load_env() {
  local f held="" line name
  declare -A _sig_preset=()

  f="$(signalloom_env_file)"
  SIGNALLOOM_ENV_FILE_RESOLVED="$f"
  SIGNALLOOM_ENV_LOADED=0
  [ -f "$f" ] || return 0

  # Values are about to be expanded. `bash -x` on a script that sources a file
  # of credentials prints every one of them; that is how a key reaches a
  # terminal scrollback and then a pasted bug report.
  case "$-" in
    *x*) held=1; set +x ;;
  esac

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Za-z_]*=*) name="${line%%=*}" ;;
      *) continue ;;
    esac
    if [ -n "${!name:-}" ]; then _sig_preset["$name"]="${!name}"; fi
  done <"$f"

  set -a
  # shellcheck disable=SC1090  # path is resolved at run time, by design.
  . "$f"
  set +a

  # Put back anything the environment had already provided, and record which
  # names those were. Without this record, provenance cannot tell "the file
  # supplied it" from "the file mentions it but the environment won" — the two
  # look identical from outside, and reporting the wrong one is precisely the
  # confusion this helper exists to remove.
  SIGNALLOOM_ENV_FROM_ENVIRONMENT=""
  for name in "${!_sig_preset[@]}"; do
    printf -v "$name" '%s' "${_sig_preset[$name]}"
    export "${name?}"
    SIGNALLOOM_ENV_FROM_ENVIRONMENT="${SIGNALLOOM_ENV_FROM_ENVIRONMENT} ${name}"
  done

  SIGNALLOOM_ENV_LOADED=1
  if [ -n "$held" ]; then set -x; fi
  return 0
}

# Where a given variable's value came from. Callers print this so "no key
# configured" and "key came from somewhere you did not expect" are always
# distinguishable without printing the value.
signalloom_env_provenance() {
  local name="$1" held="" empty=""

  # This function tests the VALUE for emptiness, and `[ -z "$secret" ]` under
  # `bash -x` prints the secret. Any expansion does; the shield is the only
  # answer, and it has to wrap the test itself, not just the assignment.
  # Found by the xtrace-leak test, which is the entire reason it exists.
  case "$-" in
    *x*) held=1; set +x ;;
  esac
  [ -z "${!name:-}" ] && empty=1
  if [ -n "$held" ]; then set -x; fi

  if [ -n "$empty" ]; then
    printf 'unset'
    return 0
  fi
  # The environment is checked FIRST because it has precedence. Asking the file
  # first reports the file for any name it merely mentions, even when the
  # environment supplied the value that is actually in use.
  case " ${SIGNALLOOM_ENV_FROM_ENVIRONMENT:-} " in
    *" ${name} "*) printf 'environment'; return 0 ;;
  esac
  if [ "${SIGNALLOOM_ENV_LOADED:-0}" = "1" ] \
     && grep -qE "^${name}=" "${SIGNALLOOM_ENV_FILE_RESOLVED:-/dev/null}" 2>/dev/null; then
    printf '%s' "${SIGNALLOOM_ENV_FILE_RESOLVED}"
  else
    printf 'environment'
  fi
}
