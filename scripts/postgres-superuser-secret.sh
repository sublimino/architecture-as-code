#!/usr/bin/env bash
#
# postgres-superuser-secret.sh - mint the inf-signalloom Postgres superuser password.
#
# @id     postgres-superuser-secret
# @tests  test/postgres-superuser-secret.bats
# @doc    docs/signalloom/security-architecture-todos.md
#
# The in-cluster Postgres (inf-signalloom/postgresql) reads POSTGRES_PASSWORD
# from Secret inf-signalloom/postgresql-superuser (keys `username`,
# `password`). The portal and signal-ingest read the same credential from
# fe-signalloom/discovery-portal-database-credentials (DATABASE_URL,
# POSTGRES_USER, POSTGRES_PASSWORD). No manifest carries the password.
#
# Idempotent: an existing password is NEVER replaced. The portal Secret is
# rewritten from it on every run. If the Postgres Deployment is ready, the
# role password is set with ALTER ROLE, sent to psql on stdin, so a server
# initialised with an older password converges. Restart the consumers after
# the first run on a live cluster. The password never appears on argv.
#
# Usage: scripts/postgres-superuser-secret.sh --context CONTEXT
set -o pipefail

KUBECTL="${SLDC_KUBECTL:-kubectl}"
PG_NAMESPACE="inf-signalloom"
PG_SECRET="postgresql-superuser"
PORTAL_NAMESPACE="fe-signalloom"
PORTAL_SECRET="discovery-portal-database-credentials"
PG_USER="signalloom"
PG_DB="signalloom"
PG_HOST="postgresql.inf-signalloom.svc.cluster.local"

usage() { sed -n '3,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'postgres-superuser-secret: %s\n' "$1" >&2; exit "${2:-1}"; }
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
  [ -n "${context}" ] || die "--context is required (the password is per cluster)" 2
  local k=(${KUBECTL} --context "${context}")
  "${k[@]}" cluster-info >/dev/null 2>&1 || die "cluster context ${context} is unreachable" 1

  local password state
  password="$("${k[@]}" -n "${PG_NAMESPACE}" get secret "${PG_SECRET}" \
    -o 'jsonpath={.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [ -n "${password}" ]; then
    state="kept"
  else
    password="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    [ "${#password}" -eq 32 ] || die "could not generate 16 bytes of password material" 1
    state="created"
    printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  username: %s\n  password: %s\n' \
      "${PG_SECRET}" "${PG_NAMESPACE}" "$(b64 "${PG_USER}")" "$(b64 "${password}")" \
      | "${k[@]}" apply -f - >/dev/null || die "kubectl apply failed for ${PG_NAMESPACE}/${PG_SECRET}" 1
  fi
  printf 'postgres superuser password %s on %s (%s/%s)\n' "${state}" "${context}" "${PG_NAMESPACE}" "${PG_SECRET}"

  local dsn="postgresql://${PG_USER}:${password}@${PG_HOST}:5432/${PG_DB}"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\ndata:\n  DATABASE_URL: %s\n  POSTGRES_USER: %s\n  POSTGRES_PASSWORD: %s\n' \
    "${PORTAL_SECRET}" "${PORTAL_NAMESPACE}" "$(b64 "${dsn}")" "$(b64 "${PG_USER}")" "$(b64 "${password}")" \
    | "${k[@]}" apply -f - >/dev/null || die "kubectl apply failed for ${PORTAL_NAMESPACE}/${PORTAL_SECRET}" 1
  printf 'portal database credentials written (%s/%s)\n' "${PORTAL_NAMESPACE}" "${PORTAL_SECRET}"

  local ready
  ready="$("${k[@]}" -n "${PG_NAMESPACE}" get deployment postgresql \
    -o 'jsonpath={.status.readyReplicas}' 2>/dev/null || true)"
  if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
    printf "ALTER ROLE %s PASSWORD '%s';\n" "${PG_USER}" "${password}" \
      | "${k[@]}" -n "${PG_NAMESPACE}" exec -i deployment/postgresql -- \
          psql -q -v ON_ERROR_STOP=1 -U "${PG_USER}" -d "${PG_DB}" >/dev/null \
      || die "ALTER ROLE failed on the running server" 1
    printf 'role %s password set on the running server; restart its consumers\n' "${PG_USER}"
  else
    printf 'postgresql is not ready; its first start reads the Secret\n'
  fi
}

main "$@"
