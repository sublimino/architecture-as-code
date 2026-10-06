#!/usr/bin/env bash
# scripts/anthropic-key-prompt.sh — Prompt for ANTHROPIC_API_KEY and store it in .env.
#
# @id      anthropic-key-prompt
# @doc     docs/kagent-d5.md
# @tests   d2-signalloom/test/anthropic-key-prompt.bats
# @lib     scripts/lib/env-file.sh
#
# The kagent swarm needs a real model credential. scripts/kagent-credentials.sh
# already reads ANTHROPIC_API_KEY from the main checkout's .env and mediates it
# through OpenBao into Secret/kagent-anthropic-key. This script is the missing
# front door: it asks for the key without echoing it, writes it into that .env
# (gitignored, mode 600), and optionally runs the projection.
#
# Usage:
#   scripts/anthropic-key-prompt.sh            # prompt, write .env
#   scripts/anthropic-key-prompt.sh --apply    # ...then make demo-kagent-credentials
#   printf '%s\n' "$KEY" | scripts/anthropic-key-prompt.sh   # non-interactive
#
# The key never reaches argv, stdout or xtrace.

set -euo pipefail
set +x

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/env-file.sh
. "${REPO_ROOT}/scripts/lib/env-file.sh"

readonly MIN_KEY_LEN=20
readonly RETIRED_MOCK="mock-anthropic-key""-for-local-demo"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

APPLY=""
case "${1:-}" in
  "") ;;
  --apply) APPLY=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  *) fail "unknown option: $1" ;;
esac

ENV_FILE="$(signalloom_env_file)"

key=""
if [ -t 0 ]; then
  printf 'Anthropic API key (input hidden): ' >&2
  IFS= read -rs key
  printf '\n' >&2
else
  IFS= read -r key || true
fi
# Strip surrounding whitespace and a trailing CR from pasted input.
key="${key//$'\r'/}"
key="${key#"${key%%[![:space:]]*}"}"
key="${key%"${key##*[![:space:]]}"}"

[ -n "$key" ] || fail "no key entered; .env unchanged"
[ "$key" != "$RETIRED_MOCK" ] || fail "that is the retired mock placeholder, not a key"
[ "${#key}" -ge "$MIN_KEY_LEN" ] || fail "key is ${#key} characters; looks truncated"
case "$key" in
  *[[:space:]]*) fail "key contains whitespace" ;;
  sk-ant-*) ;;
  *) printf 'WARN: key does not start with sk-ant-; storing anyway\n' >&2 ;;
esac

# Refuse to write a .env that git would track.
if git -C "$(dirname "$ENV_FILE")" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$(dirname "$ENV_FILE")" check-ignore -q "$ENV_FILE" \
    || fail "$ENV_FILE is not gitignored; refusing to write a credential into it"
fi

umask 077
touch "$ENV_FILE"
tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
# Drop any existing ANTHROPIC_API_KEY line, keep everything else verbatim.
grep -v '^ANTHROPIC_API_KEY=' "$ENV_FILE" > "$tmp" || true
printf 'ANTHROPIC_API_KEY=%s\n' "$key" >> "$tmp"
chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
trap - EXIT
unset key

printf 'Wrote ANTHROPIC_API_KEY to %s (mode 600, gitignored).\n' "$ENV_FILE"

if [ -n "$APPLY" ]; then
  make -C "$REPO_ROOT" demo-kagent-credentials
else
  printf 'Next: make demo-kagent-credentials   (OpenBao + Secret/kagent-anthropic-key)\n'
fi
