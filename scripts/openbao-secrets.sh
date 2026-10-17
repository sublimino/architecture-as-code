#!/usr/bin/env bash
#
# openbao-secrets.sh - mint the two secrets OpenBao needs before it can start.
#
# @id     openbao-secrets
# @tests  test/openbao-secrets.bats
# @doc    docs/signalloom/security-architecture-todos.md
#
# 1. inf-bao/openbao-seal-key (data key `key`): 32 random bytes, the static
#    seal key. The server unseals itself with it (seal "static"). Without it
#    every byte in the storage backend is unreadable, so it is NEVER replaced.
# 2. inf-bao/openbao-storage (keys `password`, `connection_url`): the
#    credential of Postgres role `openbao`, owner of database `openbao` on the
#    inf-signalloom server. The role and database are created idempotently by
#    SQL sent to psql on stdin, and the role password is converged each run.
#
# Both are SA-TODO exceptions: OpenBao cannot hold the secrets it needs to
# start. Values never appear on argv.
#
# Usage: scripts/openbao-secrets.sh --context CONTEXT
set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
BAO_NAMESPACE="inf-bao"
SEAL_SECRET="openbao-seal-key"
STORAGE_SECRET="openbao-storage"
PG_NAMESPACE="inf-signalloom"
PG_HOST="postgresql.inf-signalloom.svc.cluster.local"
PG_SUPERUSER="signalloom"
PG_WAIT="${OPENBAO_SECRETS_PG_WAIT:-300s}"

usage() { sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'openbao-secrets: %s\n' "$1" >&2; exit "${2:-1}"; }
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

main() {
  local context=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (the secrets are per cluster)" 2
  local k=(${KUBECTL} --context "${context}")
  "${k[@]}" cluster-info >/dev/null 2>&1 || die "cluster context ${context} is unreachable" 1

  # ── seal key ───────────────────────────────────────────────────────────────
  local existing
  existing="$("${k[@]}" -n "${BAO_NAMESPACE}" get secret "${SEAL_SECRET}" \
    -o 'jsonpath={.data.key}' 2>/dev/null || true)"
  if [ -n "${existing}" ]; then
    printf 'openbao seal key kept on %s (%s/%s)\n' "${context}" "${BAO_NAMESPACE}" "${SEAL_SECRET}"
  else
    local key_b64
    key_b64="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
    [ "$(printf '%s' "${key_b64}" | base64 -d | wc -c | tr -d ' ')" = "32" ] \
      || die "could not generate 32 bytes of seal key material" 1
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  key: %s\n' \
      "${SEAL_SECRET}" "${BAO_NAMESPACE}" "${key_b64}" \
      | "${k[@]}" apply -f - >/dev/null || die "kubectl apply failed for ${BAO_NAMESPACE}/${SEAL_SECRET}" 1
    printf 'openbao seal key created on %s (%s/%s)\n' "${context}" "${BAO_NAMESPACE}" "${SEAL_SECRET}"
  fi

  # ── storage credential ─────────────────────────────────────────────────────
  local password state
  password="$("${k[@]}" -n "${BAO_NAMESPACE}" get secret "${STORAGE_SECRET}" \
    -o 'jsonpath={.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "${password}" ]; then
    state="kept"
  else
    password="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    [ "${#password}" -eq 32 ] || die "could not generate 16 bytes of password material" 1
    state="created"
  fi
  local url="postgres://openbao:${password}@${PG_HOST}:5432/openbao?sslmode=disable"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  password: %s\n  connection_url: %s\n' \
    "${STORAGE_SECRET}" "${BAO_NAMESPACE}" "$(b64 "${password}")" "$(b64 "${url}")" \
    | "${k[@]}" apply -f - >/dev/null || die "kubectl apply failed for ${BAO_NAMESPACE}/${STORAGE_SECRET}" 1
  printf 'openbao storage password %s on %s (%s/%s)\n' "${state}" "${context}" "${BAO_NAMESPACE}" "${STORAGE_SECRET}"

  # ── role and database ──────────────────────────────────────────────────────
  "${k[@]}" -n "${PG_NAMESPACE}" rollout status deployment/postgresql --timeout="${PG_WAIT}" >/dev/null 2>&1 \
    || die "postgresql in ${PG_NAMESPACE} is not ready; run make postgres-superuser-secret first" 1
  {
    printf "SELECT 'CREATE ROLE openbao LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'openbao')\\\\gexec\n"
    printf "ALTER ROLE openbao WITH LOGIN PASSWORD '%s';\n" "${password}"
    printf "SELECT 'CREATE DATABASE openbao OWNER openbao' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'openbao')\\\\gexec\n"
  } | "${k[@]}" -n "${PG_NAMESPACE}" exec -i deployment/postgresql -- \
        psql -q -v ON_ERROR_STOP=1 -U "${PG_SUPERUSER}" -d postgres >/dev/null \
    || die "creating role/database openbao failed" 1
  printf 'postgres role and database openbao ready\n'
}

main "$@"
