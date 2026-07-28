#!/usr/bin/env bash
# signalloom-data.sh — Manage demo data in the Signal Loom PostgreSQL instance.
#
# Usage:
#   scripts/signalloom-data.sh reset [SERVICE]   # truncate tables (optional: agents|compliance|audit|nhi|settings)
#   scripts/signalloom-data.sh mock              # reset + populate with demo data
#   scripts/signalloom-data.sh migrate           # run all migrations in order
#   scripts/signalloom-data.sh status            # show table row counts
#
# Connection: uses kubectl port-forward to reach PostgreSQL in the
# inf-signalloom namespace. Alternatively set PGHOST/PGPORT/PGUSER/PGPASSWORD
# to connect directly (e.g. from within the cluster).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DB_DIR="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src/db"
MIGRATIONS_DIR="${DB_DIR}/migrations"

# PostgreSQL connection defaults (in-cluster)
PG_NAMESPACE="${PG_NAMESPACE:-inf-signalloom}"
PG_SERVICE="${PG_SERVICE:-postgresql}"
PG_PORT="${PG_PORT:-5432}"
PG_DATABASE="${PG_DATABASE:-signalloom}"
PG_USER="${PG_USER:-signalloom}"
PG_PASSWORD="${PG_PASSWORD:-signalloom}"
LOCAL_PORT="${LOCAL_PORT:-54320}"

# Colour helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { printf "${GREEN}[signalloom-data]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[signalloom-data]${NC} %s\n" "$*" >&2; }
err()  { printf "${RED}[signalloom-data]${NC} %s\n" "$*" >&2; exit 1; }

# ── Port-forward management ──────────────────────────────────────────────────

PF_PID=""

start_port_forward() {
    # Skip if PGHOST is already set (direct connection)
    if [[ -n "${PGHOST:-}" ]]; then
        log "Using direct connection to ${PGHOST}:${PGPORT:-$PG_PORT}"
        return
    fi

    log "Starting port-forward to ${PG_NAMESPACE}/${PG_SERVICE}:${PG_PORT} on localhost:${LOCAL_PORT}..."
    kubectl port-forward -n "${PG_NAMESPACE}" "svc/${PG_SERVICE}" "${LOCAL_PORT}:${PG_PORT}" >/dev/null 2>&1 &
    PF_PID=$!

    # Wait for port-forward to be ready
    local retries=0
    while ! nc -z localhost "${LOCAL_PORT}" 2>/dev/null; do
        retries=$((retries + 1))
        if [[ $retries -ge 30 ]]; then
            kill "${PF_PID}" 2>/dev/null || true
            err "Port-forward failed to start after 30 attempts"
        fi
        sleep 0.5
    done
    log "Port-forward ready on localhost:${LOCAL_PORT}"

    export PGHOST="localhost"
    export PGPORT="${LOCAL_PORT}"
}

stop_port_forward() {
    if [[ -n "${PF_PID}" ]]; then
        kill "${PF_PID}" 2>/dev/null || true
        wait "${PF_PID}" 2>/dev/null || true
        log "Port-forward stopped"
    fi
}

trap stop_port_forward EXIT

# ── psql wrapper ─────────────────────────────────────────────────────────────

run_sql() {
    local file="$1"
    PGPASSWORD="${PG_PASSWORD}" psql \
        -h "${PGHOST:-localhost}" \
        -p "${PGPORT:-$LOCAL_PORT}" \
        -U "${PG_USER}" \
        -d "${PG_DATABASE}" \
        -v ON_ERROR_STOP=1 \
        -f "${file}"
}

run_sql_cmd() {
    local cmd="$1"
    PGPASSWORD="${PG_PASSWORD}" psql \
        -h "${PGHOST:-localhost}" \
        -p "${PGPORT:-$LOCAL_PORT}" \
        -U "${PG_USER}" \
        -d "${PG_DATABASE}" \
        -v ON_ERROR_STOP=1 \
        -c "${cmd}"
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_reset() {
    local focus="${1:-all}"
    log "Resetting tables (focus: ${focus})..."

    if [[ "${focus}" != "all" ]]; then
        run_sql_cmd "SET app.data_reset_focus = '${focus}';"
    fi

    run_sql "${DB_DIR}/data-reset.sql"
    log "Reset complete"
}

cmd_mock() {
    log "Running full data reset + mock population..."
    run_sql "${DB_DIR}/data-reset.sql"
    log "Tables reset"
    run_sql "${DB_DIR}/data-mock.sql"
    log "Mock data loaded"
}

cmd_migrate() {
    log "Running migrations from ${MIGRATIONS_DIR}..."
    for migration in "${MIGRATIONS_DIR}"/*.sql; do
        local name
        name="$(basename "${migration}")"
        log "  Applying: ${name}"
        run_sql "${migration}"
    done
    log "All migrations applied"
}

cmd_status() {
    log "Table row counts:"
    local tables=(
        agent_registry lifecycle_transitions agent_violations
        governance_frameworks governance_controls agent_compliance_results
        audit_events tenant_settings tenant_api_keys
        nhi_scans nhi_discovered_accounts consent_events support_requests
        discovery_scan_sessions discovered_agents platform_backends
    )
    for t in "${tables[@]}"; do
        local count
        count=$(run_sql_cmd "SELECT COUNT(*) FROM public.${t};" 2>/dev/null | sed -n '3p' | tr -d ' ') || count="N/A"
        printf "  %-30s %s\n" "${t}" "${count}"
    done
}

# ── Main ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  reset [SERVICE]   Truncate tables. SERVICE: agents|compliance|audit|nhi|settings|all (default: all)
  mock              Reset + populate with demo data
  migrate           Run all SQL migrations in order
  status            Show table row counts
EOF
    exit 1
}

main() {
    local cmd="${1:-}"
    shift || true

    case "${cmd}" in
        reset)   start_port_forward; cmd_reset "$@" ;;
        mock)    start_port_forward; cmd_mock ;;
        migrate) start_port_forward; cmd_migrate ;;
        status)  start_port_forward; cmd_status ;;
        *)       usage ;;
    esac
}

main "$@"
