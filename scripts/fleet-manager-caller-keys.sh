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
#   fe-signalloom/fleet-manager-caller-keys      keys: stun-sentinel, signalloom-warden, warden, fe-signalloom, dashboard, operator
#   fe-signalloom-agents/stun-sentinel-fleet-key key:  token (= the stun-sentinel key)
#   fe-signalloom-agents/signalloom-warden-fleet-key key: token (= the signalloom-warden key)
#
# A key that already exists is kept, so re-running is a no-op; --rotate
# replaces every key. Keys are 32 random bytes, base64. They never appear in
# argv (they reach kubectl on stdin), in a ConfigMap, or on this script's
# output.
#
# --emit-remote-secrets DIR writes, as YAML files for `kubectl apply` on a
# REMOTE cluster, the two Secrets a remote warden needs. Nothing is applied.
#
# Usage: scripts/fleet-manager-caller-keys.sh --context CONTEXT [--rotate]
#                                             [--emit-remote-secrets DIR]
#
# ── The `warden` caller, and why it is not `signalloom-warden` ───────────────
#
# `signalloom-warden` is the LOCAL warden on the central cluster. Its scope is
# `stun`: it records a freeze its own correlator already performed.
#
# `warden` is a REMOTE cluster's warden (docs/EAP/remote-contract.md). Its
# scope is `report`: it posts a workload report, reads stun state and
# acknowledges it. It never calls /stun, because a remote stun is requested by
# an operator at the hub, not by the node.
#
# Two callers rather than one, because the two scopes are disjoint and a key
# that carries both lets a remote node request stuns on the hub's own agents.
# The scope vocabulary itself lives in fleet-manager's deployment
# (FLEET_MANAGER_KEY_WARDEN_SCOPES) and in callerauth.go.
#
# ── What --emit-remote-secrets writes, and what it reads ────────────────────
#
#   DIR/signalloom-warden-fleet-key.yaml    the `warden` caller key
#   DIR/signalloom-warden-ingest-token.yaml the signal-ingest named key
#                                           `signalloom-warden`
#
# Both land in namespace fe-signalloom-agents, both under key `token`, both
# under the names the remote-tenant overlay's DaemonSet reads. The REMOTE
# cluster's signalloom-warden-fleet-key therefore carries the `warden` value
# while the CENTRAL cluster's carries the `signalloom-warden` value. That is
# deliberate: one Secret name, one env var, and the scope follows the cluster
# the Secret is on.
#
# The ingest key is READ, never minted here: scripts/sldc-ingest-bearer.sh is
# its issuer. With fe-signalloom/signal-ingest-key-signalloom-warden absent
# this exits 1 and names the command that creates it.
#
# DIR is created mode 0700 and each file is written mode 0600. The files hold
# key material in clear base64. Hand them over on an agreed secure channel and
# delete them.

set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
FLEET_NS="fe-signalloom"
AGENTS_NS="fe-signalloom-agents"
WARDEN_NS="${WARDEN_NS:-inf-signalloom-warden}"
# Caller names, in the order they appear in the issuer Secret.
CALLERS=(stun-sentinel signalloom-warden warden fe-signalloom dashboard operator)
# The signal-ingest issuer Secret --emit-remote-secrets reads the warden's
# ingest key from. Written by scripts/sldc-ingest-bearer.sh.
INGEST_ISSUER_SECRET="signal-ingest-key-signalloom-warden"

usage() { sed -n '3,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'fleet-manager-caller-keys: %s\n' "$1" >&2; exit "${2:-1}"; }

# secret_doc NAMESPACE NAME KEY=B64... -> one Secret document on stdout.
# printf is a builtin, so no value is ever an argument to an exec'd process.
secret_doc() {
  local ns="$1" name="$2"; shift 2
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n' "${name}" "${ns}"
  local kv
  for kv in "$@"; do printf '  %s: %s\n' "${kv%%=*}" "${kv#*=}"; done
}

main() {
  local context="" rotate=0 emit_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      --emit-remote-secrets)
        emit_dir="${2:-}"; shift 2 || die "--emit-remote-secrets needs a directory" 2
        [ -n "${emit_dir}" ] || die "--emit-remote-secrets needs a directory" 2 ;;
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

  for ns in "${FLEET_NS}" "${AGENTS_NS}" "${WARDEN_NS}"; do
    ${KUBECTL} --context "${context}" get namespace "${ns}" >/dev/null 2>&1 || \
      ${KUBECTL} --context "${context}" create namespace "${ns}" >/dev/null 2>&1 || true
  done

  # kubectl apply reads the manifest from stdin: printf is a builtin, so no key
  # is ever an argument to an exec'd process.
  {
    secret_doc "${FLEET_NS}" fleet-manager-caller-keys \
      "stun-sentinel=${key[stun-sentinel]}" \
      "signalloom-warden=${key[signalloom-warden]}" \
      "warden=${key[warden]}" \
      "fe-signalloom=${key[fe-signalloom]}" \
      "dashboard=${key[dashboard]}" \
      "operator=${key[operator]}"
    printf -- '---\n'
    secret_doc "${AGENTS_NS}" stun-sentinel-fleet-key "token=${key[stun-sentinel]}"
    printf -- '---\n'
    secret_doc "${AGENTS_NS}" signalloom-warden-fleet-key "token=${key[signalloom-warden]}"
    printf -- '---\n'
    secret_doc "${WARDEN_NS}" signalloom-warden-fleet-key "token=${key[signalloom-warden]}"
  } | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  printf 'fleet-manager caller keys %s on %s: %s (sentinel and warden mirrored to %s and %s)\n' \
    "$([ "${rotate}" -eq 1 ] && echo rotated || echo ensured)" "${context}" "${CALLERS[*]}" "${AGENTS_NS}" "${WARDEN_NS}"

  [ -n "${emit_dir}" ] && emit_remote_secrets "${context}" "${emit_dir}" "${key[warden]}"
  return 0
}

# emit_remote_secrets CONTEXT DIR WARDEN_KEY_B64
emit_remote_secrets() {
  local context="$1" dir="$2" warden_b64="$3" ingest_b64=""

  ingest_b64="$(${KUBECTL} --context "${context}" -n "${FLEET_NS}" get secret "${INGEST_ISSUER_SECRET}" \
    -o 'jsonpath={.data.token}' 2>/dev/null)" || ingest_b64=""
  [ -n "${ingest_b64}" ] || die "no ${FLEET_NS}/${INGEST_ISSUER_SECRET} on ${context}; mint it first with: scripts/sldc-ingest-bearer.sh --context ${context} --key signalloom-warden" 1

  # 0700 on the directory and 0600 on each file: the content is key material.
  ( umask 077
    mkdir -p "${dir}" || exit 1
    secret_doc "${WARDEN_NS}" signalloom-warden-fleet-key "token=${warden_b64}" \
      >"${dir}/signalloom-warden-fleet-key.yaml" || exit 1
    secret_doc "${WARDEN_NS}" signalloom-warden-ingest-token "token=${ingest_b64}" \
      >"${dir}/signalloom-warden-ingest-token.yaml" || exit 1
  ) || die "could not write the remote Secrets to ${dir}" 1
  chmod 700 "${dir}" 2>/dev/null || true

  printf 'remote Secrets written to %s: signalloom-warden-fleet-key.yaml (caller key warden, scope report), signalloom-warden-ingest-token.yaml\n' "${dir}"
  printf 'apply them on the REMOTE cluster BEFORE the overlay, then delete them\n'
}

main "$@"
