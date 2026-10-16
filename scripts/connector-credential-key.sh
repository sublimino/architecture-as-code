#!/usr/bin/env bash
#
# connector-credential-key.sh - mint the fe-signalloom connector credential key.
#
# @id     connector-credential-key
# @tests  test/connector-credential-key.bats
# @doc    d2-signalloom/apps/fe-signalloom/src/connector_credentials.py
#
# fe-signalloom seals every tenant's connector credentials (Anthropic API key,
# GitHub token, ...) with AES-256-GCM before they reach Postgres
# (public.tenant_connectors, migration 070). The 32-byte key is read from the
# file named by CONNECTOR_CREDENTIAL_KEY_FILE, which the Deployment mounts from
# Secret fe-signalloom/fe-signalloom-connector-credential-key (data key `key`,
# 64 hex characters). Without it, saving or using connector credentials
# answers 503 credential_store_unavailable; nothing falls back to plaintext.
#
# Idempotent: an existing key is NEVER replaced. Replacing it would make every
# stored credential undecryptable, so there is deliberately no --rotate.
# The key never appears on argv: it reaches kubectl on stdin.
#
# Usage: scripts/connector-credential-key.sh --context CONTEXT
set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
NAMESPACE="fe-signalloom"
SECRET="fe-signalloom-connector-credential-key"

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'connector-credential-key: %s\n' "$1" >&2; exit "${2:-1}"; }

main() {
  local context=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (the key is per cluster)" 2
  ${KUBECTL} --context "${context}" cluster-info >/dev/null 2>&1 \
    || die "cluster context ${context} is unreachable" 1

  local existing
  existing="$(${KUBECTL} --context "${context}" -n "${NAMESPACE}" get secret "${SECRET}" \
    -o 'jsonpath={.data.key}' 2>/dev/null || true)"
  if [ -n "${existing}" ]; then
    printf 'connector credential key kept on %s (%s/%s)\n' "${context}" "${NAMESPACE}" "${SECRET}"
    return 0
  fi

  local key_hex
  key_hex="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ "${#key_hex}" -eq 64 ] || die "could not generate 32 bytes of key material" 1

  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  key: %s\n' \
    "${SECRET}" "${NAMESPACE}" "$(printf '%s' "${key_hex}" | base64 | tr -d '\n')" \
    | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1
  printf 'connector credential key created on %s (%s/%s)\n' "${context}" "${NAMESPACE}" "${SECRET}"
}

main "$@"
