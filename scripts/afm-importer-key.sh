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
#                                    [--cluster-id ID]
#
# ── --cluster-id, and why a key is bound to one cluster ─────────────────────
#
# The portal checks the cluster an import key is bound to, from the `cluster`
# field of AFM_IMPORT_KEYS (apps/fe-signalloom/base/deployment.yaml). The one
# committed row binds `afm-importer` to kind-osramp, so an RBAC export from any
# other cluster is refused however valid its key is.
#
# --cluster-id ID records the binding on the issuer Secret, in data key
# `afm-importer.cluster`, and prints the AFM_IMPORT_KEYS row to add to the
# portal. The default is kind-osramp, which is the committed row, so a run
# without the flag behaves as before and the new data key only states what was
# already true.
#
# A non-default ID also gets its OWN issuer Secret,
# fe-signalloom-afm-importer-key-<ID>. Two clusters exporting RBAC to one
# portal need two distinct keys, and one Secret name for both would mean the
# second mint silently replaced the first. The consumer Secret keeps its single
# name, because it is read by the exporter CronJob on whichever cluster that
# CronJob runs, and there is one of those per cluster.
#
# Nothing here changes AFM_IMPORT_KEYS. That is a manifest, so the row is
# printed and committed, never patched by a script.

set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
VERIFIER_NS="fe-signalloom"
CONSUMER_NS="fe-signalloom-agents"
VERIFIER_SECRET="fe-signalloom-afm-importer-key"
CONSUMER_SECRET="signalloom-rbac-exporter-afm-key"
# The cluster the committed AFM_IMPORT_KEYS row binds `afm-importer` to.
DEFAULT_CLUSTER_ID="kind-osramp"

usage() { sed -n '3,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'afm-importer-key: %s\n' "$1" >&2; exit "${2:-1}"; }

main() {
  local context="" rotate=0 cluster_id="${DEFAULT_CLUSTER_ID}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --cluster-id)
        cluster_id="${2:-}"; shift 2 || die "--cluster-id needs a value" 2
        [ -n "${cluster_id}" ] || die "--cluster-id needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (keys are per cluster)" 2
  # A Secret name must be a DNS subdomain, so an ID that cannot appear in one
  # is rejected here rather than by the API server after the key is generated.
  case "${cluster_id}" in
    *[^a-z0-9.-]*|-*|.*|*-|*.) die "--cluster-id must be a DNS label: ${cluster_id}" 2 ;;
  esac
  if [ "${cluster_id}" != "${DEFAULT_CLUSTER_ID}" ]; then
    VERIFIER_SECRET="${VERIFIER_SECRET}-${cluster_id}"
  fi

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

  local cluster_b64
  cluster_b64="$(printf '%s' "${cluster_id}" | base64 | tr -d '\n')"

  local expires_ts expires_b64
  expires_ts="$(date -u -d '+90 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v+90d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=90)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
  expires_b64="$(printf '%s' "${expires_ts}" | base64 | tr -d '\n')"

  # kubectl apply reads the manifest from stdin: printf is a builtin, so no key
  # is ever an argument to an exec'd process.
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  afm-importer: %s\n  afm-importer.expires: %s\n  afm-importer.cluster: %s\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  token: %s\n' \
    "${VERIFIER_SECRET}" "${VERIFIER_NS}" "${token_b64}" "${expires_b64}" "${cluster_b64}" \
    "${CONSUMER_SECRET}" "${CONSUMER_NS}" "${token_b64}" \
    | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  printf 'afm-importer key %s on %s for cluster %s (%s/%s and %s/%s)\n' \
    "$([ "${rotate}" -eq 1 ] && echo rotated || echo ensured)" "${context}" "${cluster_id}" \
    "${VERIFIER_NS}" "${VERIFIER_SECRET}" "${CONSUMER_NS}" "${CONSUMER_SECRET}"
  if [ "${cluster_id}" != "${DEFAULT_CLUSTER_ID}" ]; then
    printf 'add this row to AFM_IMPORT_KEYS in apps/fe-signalloom/base/deployment.yaml:\n'
    printf '  {"name":"afm-importer-%s","scopes":["afm:import"],"cluster":"%s"}\n' \
      "${cluster_id}" "${cluster_id}"
    printf 'and point the exporter CronJob on %s at AFM_CLUSTER_ID=%s\n' "${context}" "${cluster_id}"
  fi
}

main "$@"
