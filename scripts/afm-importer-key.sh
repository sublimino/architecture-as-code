#!/usr/bin/env bash
#
# afm-importer-key.sh - create or rotate the AFM importer static Bearer key.
#
# @id     afm-importer-key
# @tests  test/afm-importer-key.bats
# @doc    docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
#
# Creates or rotates the AFM importer authentication Secret pair:
#   fe-signalloom/fe-signalloom-afm-importer-key (data: afm-importer, afm-importer.expires)
#   fe-signalloom-agents/signalloom-rbac-exporter-afm-key (data: token)
#
# A key that already exists is kept, so re-running is a no-op; --rotate
# replaces the key and extends expiration by 90 days. Keys are >= 32 random bytes.
# They never appear in argv (they reach kubectl on stdin), in a ConfigMap, or in
# this script's output.
#
# Usage: scripts/afm-importer-key.sh --context CONTEXT [--rotate]

set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
VERIFIER_NS="fe-signalloom"
CONSUMER_NS="fe-signalloom-agents"
VERIFIER_SECRET="fe-signalloom-afm-importer-key"
CONSUMER_SECRET="signalloom-rbac-exporter-afm-key"

usage() { sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'afm-importer-key: %s\n' "$1" >&2; exit "${2:-1}"; }

main() {
  local context="" rotate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (keys are per cluster)" 2

  # Check cluster connectivity before any write
  ${KUBECTL} --context "${context}" cluster-info >/dev/null 2>&1 \
    || die "cluster context ${context} is unreachable" 1

  local existing_b64=""
  if [ "${rotate}" -eq 0 ]; then
    existing_b64="$(${KUBECTL} --context "${context}" -n "${VERIFIER_NS}" get secret "${VERIFIER_SECRET}" \
      -o "jsonpath={.data.afm-importer}" 2>/dev/null)" || existing_b64=""
  fi

  if [ -n "${existing_b64}" ]; then
    printf 'afm-importer key kept on %s (already present in %s/%s)\n' \
      "${context}" "${VERIFIER_NS}" "${VERIFIER_SECRET}"
    return 0
  fi

  local token_b64=""
  if [ ! -t 0 ]; then
    # Read from stdin if available
    local stdin_token
    stdin_token="$(cat)"
    if [ -n "${stdin_token}" ]; then
      token_b64="$(printf '%s' "${stdin_token}" | base64 | tr -d '\n')"
    fi
  fi

  if [ -z "${token_b64}" ]; then
    # Generate 32 random bytes, base64-encoded
    token_b64="$(head -c 32 /dev/urandom | base64 | tr -d '\n' | base64 | tr -d '\n')" \
      || die "could not generate a key" 1
  fi

  local expires_ts expires_b64
  expires_ts="$(date -u -d '+90 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+90d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  expires_b64="$(printf '%s' "${expires_ts}" | base64 | tr -d '\n')"

  # kubectl apply reads the manifest from stdin: printf is a builtin, so no key
  # is ever an argument to an exec'd process.
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  afm-importer: %s\n  afm-importer.expires: %s\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  token: %s\n' \
    "${VERIFIER_SECRET}" "${VERIFIER_NS}" "${token_b64}" "${expires_b64}" \
    "${CONSUMER_SECRET}" "${CONSUMER_NS}" "${token_b64}" \
    | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  printf 'afm-importer key %s on %s (%s/%s and %s/%s)\n' \
    "$([ "${rotate}" -eq 1 ] && echo rotated || echo ensured)" "${context}" \
    "${VERIFIER_NS}" "${VERIFIER_SECRET}" "${CONSUMER_NS}" "${CONSUMER_SECRET}"
}

main "$@"
