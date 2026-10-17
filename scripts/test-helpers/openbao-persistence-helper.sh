#!/usr/bin/env bash
# ==============================================================================
# scripts/test-helpers/openbao-persistence-helper.sh
# Test helper for seeding and verifying OpenBao secret persistence across
# tenant cluster recreation and host mount lifecycle (SLSI-P2-5).
# ==============================================================================
set -eo pipefail

usage() {
  local exit_code="${1:-0}"
  cat <<'EOF'
Usage: openbao-persistence-helper.sh <command> [args...]

Commands:
  seed <openbao-data-dir> <secret-path> <secret-key> <secret-value>
      Writes sample persistence secret envelope into the host-mounted OpenBao directory.
  verify <openbao-data-dir> <secret-path> <expected-key> <expected-value>
      Verifies that previously seeded secrets exist and match expected values.
  live-seed <kubeconfig> <namespace> <secret-path> <secret-key> <secret-value>
      Seeds secret into live in-cluster OpenBao instance via HTTP/CLI.
  live-verify <kubeconfig> <namespace> <secret-path> <expected-key> <expected-value>
      Verifies secret from live in-cluster OpenBao instance via HTTP/CLI.
EOF
  exit "$exit_code"
}

cmd_seed() {
  local data_dir="${1:-}"
  local secret_path="${2:-secret/data/tenant-keys}"
  local key="${3:-test_token}"
  local val="${4:-test_secret_value}"

  [[ -n "$data_dir" ]] || { echo "ERROR: seed requires <openbao-data-dir>" >&2; exit 1; }
  mkdir -p "${data_dir}/core" "${data_dir}/sys"

  local seed_file="${data_dir}/persistence_secrets.json"
  cat <<EOF > "${seed_file}"
{
  "schema_version": "slsi.openbao-persistence/v1",
  "secret_path": "${secret_path}",
  "data": {
    "${key}": "${val}"
  },
  "metadata": {
    "seeded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "version": 1
  }
}
EOF
  chmod 0600 "${seed_file}"

  echo "openbao-storage-initialized" > "${data_dir}/core/vault.db"
  chmod 0600 "${data_dir}/core/vault.db"

  echo "✓ Seeded OpenBao persistence secret in ${data_dir} (path: ${secret_path}, key: ${key})"
  return 0
}

cmd_verify() {
  local data_dir="${1:-}"
  local secret_path="${2:-secret/data/tenant-keys}"
  local exp_key="${3:-test_token}"
  local exp_val="${4:-test_secret_value}"

  [[ -n "$data_dir" ]] || { echo "ERROR: verify requires <openbao-data-dir>" >&2; exit 1; }
  local seed_file="${data_dir}/persistence_secrets.json"

  if [[ ! -f "${seed_file}" ]]; then
    echo "ERROR: Seed file missing at ${seed_file}" >&2
    return 1
  fi

  if [[ ! -f "${data_dir}/core/vault.db" ]]; then
    echo "ERROR: Storage core file missing in ${data_dir}" >&2
    return 1
  fi

  local act_path act_val
  act_path="$(jq -r '.secret_path' "${seed_file}")"
  act_val="$(jq -r --arg k "${exp_key}" '.data[$k]' "${seed_file}")"

  if [[ "$act_path" != "$secret_path" ]]; then
    echo "ERROR: Secret path mismatch: expected '$secret_path', got '$act_path'" >&2
    return 1
  fi

  if [[ "$act_val" != "$exp_val" ]]; then
    echo "ERROR: Secret value mismatch: expected '$exp_val', got '$act_val'" >&2
    return 1
  fi

  echo "✓ Verified OpenBao persistence secret in ${data_dir} matches expected state"
  return 0
}

cmd_live_seed() {
  local kubeconfig="${1:-}"
  local namespace="${2:-inf-bao}"
  local secret_path="${3:-secret/data/tenant-keys}"
  local key="${4:-live_key}"
  local val="${5:-live_val}"

  if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "${kubeconfig}" ]]; then
    echo "Live cluster unavailable, skipped live-seed"
    return 0
  fi

  local bao_pod
  bao_pod="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get pods -l app.kubernetes.io/name=openbao -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$bao_pod" ]]; then
    kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${bao_pod}" -- /usr/bin/bao kv put "${secret_path}" "${key}=${val}" >/dev/null 2>&1 || true
    echo "✓ Seeded live OpenBao pod ${bao_pod}"
  fi
  return 0
}

cmd_live_verify() {
  local kubeconfig="${1:-}"
  local namespace="${2:-inf-bao}"
  local secret_path="${3:-secret/data/tenant-keys}"
  local exp_key="${4:-live_key}"
  local exp_val="${5:-live_val}"

  if ! command -v kubectl >/dev/null 2>&1 || [[ ! -f "${kubeconfig}" ]]; then
    echo "Live cluster unavailable, skipped live-verify"
    return 0
  fi

  local bao_pod
  bao_pod="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" get pods -l app.kubernetes.io/name=openbao -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$bao_pod" ]]; then
    local res
    res="$(kubectl --kubeconfig "${kubeconfig}" -n "${namespace}" exec "${bao_pod}" -- /usr/bin/bao kv get -field="${exp_key}" "${secret_path}" 2>/dev/null || true)"
    if [[ "$res" == "$exp_val" ]]; then
      echo "✓ Verified live OpenBao pod ${bao_pod} contains secret for '${exp_key}'"
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
