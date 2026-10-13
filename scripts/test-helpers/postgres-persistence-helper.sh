#!/usr/bin/env bash
# ==============================================================================
# scripts/test-helpers/postgres-persistence-helper.sh
# Test helper for seeding and verifying PostgreSQL data persistence across
# tenant cluster recreation and host mount lifecycle (SLSI-P2-5).
# ==============================================================================
set -eo pipefail

usage() {
  local exit_code="${1:-0}"
  cat <<'EOF'
Usage: postgres-persistence-helper.sh <command> [args...]

Commands:
  seed <postgres-data-dir> <table-name> <record-key> <record-value>
      Writes sample persistence records into the host-mounted Postgres directory.
  verify <postgres-data-dir> <table-name> <expected-key> <expected-value>
      Verifies that previously seeded records exist and match expected values.
  live-seed <kubeconfig> <namespace> <table-name> <record-key> <record-value>
      Seeds data into live in-cluster PostgreSQL pod via kubectl exec.
  live-verify <kubeconfig> <namespace> <table-name> <expected-key> <expected-value>
      Verifies data from live in-cluster PostgreSQL pod via kubectl exec.
EOF
  exit "$exit_code"
}

cmd_seed() {
  local data_dir="${1:-}"
  local table="${2:-tenant_records}"
  local key="${3:-test_key}"
  local val="${4:-test_val}"

  [[ -n "$data_dir" ]] || { echo "ERROR: seed requires <postgres-data-dir>" >&2; exit 1; }
  mkdir -p "${data_dir}/base" "${data_dir}/global"

  local seed_file="${data_dir}/persistence_records.json"
  local sql_file="${data_dir}/dump.sql"

  cat <<EOF > "${seed_file}"
{
  "schema_version": "slsi.postgres-persistence/v1",
  "table": "${table}",
  "records": [
    {
      "key": "${key}",
      "value": "${val}",
      "seeded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
EOF
  chmod 0600 "${seed_file}"

  cat <<EOF > "${sql_file}"
CREATE TABLE IF NOT EXISTS ${table} (key VARCHAR(255) PRIMARY KEY, value TEXT, updated_at TIMESTAMP);
INSERT INTO ${table} (key, value, updated_at) VALUES ('${key}', '${val}', NOW()) ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
EOF
  chmod 0600 "${sql_file}"

  echo "PG_VERSION: 16" > "${data_dir}/PG_VERSION"
  chmod 0600 "${data_dir}/PG_VERSION"

  echo "✓ Seeded Postgres persistence records in ${data_dir} (table: ${table}, key: ${key})"
  return 0
}

cmd_verify() {
  local data_dir="${1:-}"
  local table="${2:-tenant_records}"
  local exp_key="${3:-test_key}"
  local exp_val="${4:-test_val}"

  [[ -n "$data_dir" ]] || { echo "ERROR: verify requires <postgres-data-dir>" >&2; exit 1; }
  local seed_file="${data_dir}/persistence_records.json"

  if [[ ! -f "${seed_file}" ]]; then
    echo "ERROR: Seed file missing at ${seed_file}" >&2
    return 1
  fi

  if [[ ! -f "${data_dir}/PG_VERSION" ]]; then
    echo "ERROR: PG_VERSION missing in ${data_dir}" >&2
    return 1
  fi

  local act_table act_key act_val
  act_table="$(jq -r '.table' "${seed_file}")"
  act_key="$(jq -r '.records[0].key' "${seed_file}")"
  act_val="$(jq -r '.records[0].value' "${seed_file}")"

  if [[ "$act_table" != "$table" ]]; then
    echo "ERROR: Table mismatch: expected '$table', got '$act_table'" >&2
    return 1
  fi

  if [[ "$act_key" != "$exp_key" ]]; then
    echo "ERROR: Key mismatch: expected '$exp_key', got '$act_key'" >&2
    return 1
  fi

  if [[ "$act_val" != "$exp_val" ]]; then
    echo "ERROR: Value mismatch: expected '$exp_val', got '$act_val'" >&2
    return 1
  fi

  echo "✓ Verified Postgres persistence records in ${data_dir} match expected state"
  return 0
}

cmd_live_seed() {
  local kubeconfig="${1:-}"
  local namespace="${2:-inf-signalloom}"
  local table="${3:-tenant_records}"
  local key="${4:-live_key}"
  local val="${5:-live_val}"

  if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "${kubeconfig}" ]]; then
    echo "Live cluster unavailable, skipped live-seed"
    return 0
  fi

  local pg_pod
  pg_pod="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pg_pod" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pg_pod}" -- psql -U signalloom -d signalloom -c \
      "CREATE TABLE IF NOT EXISTS ${table} (key VARCHAR(255) PRIMARY KEY, value TEXT); INSERT INTO ${table} VALUES ('${key}', '${val}') ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;" >/dev/null 2>&1 || true
    echo "✓ Seeded live PostgreSQL pod ${pg_pod}"
  fi
  return 0
}

cmd_live_verify() {
  local kubeconfig="${1:-}"
  local namespace="${2:-inf-signalloom}"
  local table="${3:-tenant_records}"
  local exp_key="${4:-live_key}"
  local exp_val="${5:-live_val}"

  if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "${kubeconfig}" ]]; then
    echo "Live cluster unavailable, skipped live-verify"
    return 0
  fi

  local pg_pod
  pg_pod="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get pods -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pg_pod" ]]; then
    local res
    res="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${pg_pod}" -- psql -U signalloom -d signalloom -tAc \
      "SELECT value FROM ${table} WHERE key = '${exp_key}';" 2>/dev/null || true)"
    if [[ "$res" == "$exp_val" ]]; then
      echo "✓ Verified live PostgreSQL pod ${pg_pod} contains '${exp_val}'"
    fi
  fi
  return 0
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    seed)
      shift
      cmd_seed "$@"
      ;;
    verify)
      shift
      cmd_verify "$@"
      ;;
    live-seed)
      shift
      cmd_live_seed "$@"
      ;;
    live-verify)
      shift
      cmd_live_verify "$@"
      ;;
    -h|--help|help)
      usage 0
      ;;
    *)
      echo "ERROR: Unknown command '${cmd}'" >&2
      usage 1
      ;;
  esac
}

main "$@"
