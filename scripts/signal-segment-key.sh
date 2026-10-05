#!/usr/bin/env bash
#
# signal-segment-key.sh - mint the signal-ingest segment pseudonymisation key.
#
# @id     signal-segment-key
# @tests  test/signal-segment-key.bats
# @doc    docs/signalloom/sldp-downstream-contract.md
#
# signal-ingest with SIGNAL_STORE=frostdb refuses to start without
# SIGNAL_SEGMENT_PSEUDONYM_KEY (store/segment_pseudonymiser.go: at least 32
# bytes of hex-encoded root key material) and an epoch. The Deployment reads
# both from Secret fe-signalloom/signal-ingest-segment-pseudonym, which this
# script creates. The key never appears on argv: it reaches kubectl on stdin.
#
# A Secret that already exists is kept (re-running is a no-op); --rotate
# writes a fresh key and bumps the epoch, which starts a new pseudonym domain
# (the downstream contract, section 2): rotate only with that consequence in
# mind.
#
# Usage: scripts/signal-segment-key.sh --context CONTEXT [--rotate]
set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
NS="fe-signalloom"
SECRET="signal-ingest-segment-pseudonym"

usage() { sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'signal-segment-key: %s\n' "$1" >&2; exit "${2:-1}"; }

main() {
  local context="" rotate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (the key is per cluster)" 2
  ${KUBECTL} --context "${context}" cluster-info >/dev/null 2>&1 \
    || die "cluster context ${context} is unreachable" 1

  local existing_key epoch="1"
  existing_key="$(${KUBECTL} --context "${context}" -n "${NS}" get secret "${SECRET}" \
    -o 'jsonpath={.data.SIGNAL_SEGMENT_PSEUDONYM_KEY}' 2>/dev/null || true)"
  if [ -n "${existing_key}" ] && [ "${rotate}" -eq 0 ]; then
    printf 'segment pseudonym key kept on %s (%s/%s)\n' "${context}" "${NS}" "${SECRET}"
    return 0
  fi
  if [ -n "${existing_key}" ]; then
    local old_epoch
    old_epoch="$(${KUBECTL} --context "${context}" -n "${NS}" get secret "${SECRET}" \
      -o 'jsonpath={.data.SIGNAL_SEGMENT_PSEUDONYM_EPOCH}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    case "${old_epoch}" in ''|*[!0-9]*) epoch="2" ;; *) epoch="$((old_epoch + 1))" ;; esac
  fi

  local key_hex key_b64 epoch_b64
  key_hex="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [ "${#key_hex}" -eq 64 ] || die "could not generate 32 bytes of key material" 1
  key_b64="$(printf '%s' "${key_hex}" | base64 | tr -d '\n')"
  epoch_b64="$(printf '%s' "${epoch}" | base64 | tr -d '\n')"

  # kubectl apply reads the manifest from stdin: printf is a builtin, so the
  # key is never an argument to an exec'd process.
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  SIGNAL_SEGMENT_PSEUDONYM_KEY: %s\n  SIGNAL_SEGMENT_PSEUDONYM_EPOCH: %s\n' \
    "${SECRET}" "${NS}" "${key_b64}" "${epoch_b64}" \
    | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  printf 'segment pseudonym key %s on %s (%s/%s, epoch %s)\n' \
    "$([ "${rotate}" -eq 1 ] && echo rotated || echo created)" "${context}" "${NS}" "${SECRET}" "${epoch}"
}

main "$@"
