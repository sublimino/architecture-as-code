#!/usr/bin/env bash
#
# fleet-manager-caller-keys.sh - create or rotate fleet-manager's named caller keys.
#
# @id     fleet-manager-caller-keys
# @tests  test/fleet-manager-caller-keys.bats
# @doc    d2-signalloom/apps/fleet-manager/callerauth.go
#
# fleet-manager answers its mutating routes only to a named caller key
# (callerauth.go). This writes, per cluster:
#
#   fe-signalloom/fleet-manager-caller-keys      keys: stun-sentinel, fe-signalloom, dashboard, operator
#   fe-signalloom-agents/stun-sentinel-fleet-key key:  token (= the stun-sentinel key)
#
# A key that already exists is kept, so re-running is a no-op; --rotate
# replaces every key. Keys are 32 random bytes, base64. They never appear in
# argv (they reach kubectl on stdin), in a ConfigMap, or on this script's
# output.
#
# Usage: scripts/fleet-manager-caller-keys.sh --context CONTEXT [--rotate]

set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
FLEET_NS="fe-signalloom"
AGENTS_NS="fe-signalloom-agents"
CALLERS=(stun-sentinel fe-signalloom dashboard operator)

usage() { sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'fleet-manager-caller-keys: %s\n' "$1" >&2; exit "${2:-1}"; }

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

  local -A key=()
  local c existing
  for c in "${CALLERS[@]}"; do
    existing=""
    if [ "${rotate}" -eq 0 ]; then
      existing="$(${KUBECTL} --context "${context}" -n "${FLEET_NS}" get secret fleet-manager-caller-keys \
        -o "jsonpath={.data.${c}}" 2>/dev/null)" || existing=""
    fi
    if [ -n "${existing}" ]; then
      key[${c}]="${existing}"   # already base64, as stored
    else
      key[${c}]="$(head -c 32 /dev/urandom | base64 | tr -d '\n' | base64 | tr -d '\n')" \
        || die "could not generate a key" 1
    fi
  done

  # kubectl apply reads the manifest from stdin: printf is a builtin, so no key
  # is ever an argument to an exec'd process.
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: fleet-manager-caller-keys\n  namespace: %s\ntype: Opaque\ndata:\n  stun-sentinel: %s\n  fe-signalloom: %s\n  dashboard: %s\n  operator: %s\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: stun-sentinel-fleet-key\n  namespace: %s\ntype: Opaque\ndata:\n  token: %s\n' \
    "${FLEET_NS}" "${key[stun-sentinel]}" "${key[fe-signalloom]}" "${key[dashboard]}" "${key[operator]}" \
    "${AGENTS_NS}" "${key[stun-sentinel]}" \
    | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  printf 'fleet-manager caller keys %s on %s: %s (stun-sentinel mirrored to %s/stun-sentinel-fleet-key)\n' \
    "$([ "${rotate}" -eq 1 ] && echo rotated || echo ensured)" "${context}" "${CALLERS[*]}" "${AGENTS_NS}"
}

main "$@"
