#!/usr/bin/env bash
#
# fleet-operator-keys.sh - create or rotate the operator keypairs a governed
# resume is signed with, and publish their PUBLIC halves to fleet-manager.
#
# @id     fleet-operator-keys
# @tests  test/fleet-operator-keys.bats
# @doc    docs/EAP/enforcement.md
# @lib    scripts/lib/keys.sh
#
# fleet-manager releases a hold only for a resume token that carries enough
# operator signatures (resume_token.go). It verifies them against the public
# keys it loads at start from OPERATOR_KEYS_JSON, which base/deployment.yaml
# reads from ConfigMap fe-signalloom/fleet-manager-operator-keys, key
# keys.json. Nothing minted that ConfigMap before this script, so no governed
# resume could succeed on a fresh estate.
#
# Per cluster this writes:
#
#   <keys_dir>/fleet-operators/<name>.key   Ed25519 private key, hex, 0600,
#                                           NEVER applied to any cluster
#   <keys_dir>/fleet-operators/<name>.pub   the public key, hex
#   <keys_dir>/fleet-operators/<name>.json  the public entry keygen printed
#   <keys_dir>/fleet-operators/keys.json    the JSON array of every entry
#   fe-signalloom/fleet-manager-operator-keys  ConfigMap, key keys.json
#
# keys_dir() is scripts/lib/keys.sh: the .keys/ of the MAIN checkout, shared
# by every worktree, or $KEYS_DIR when set. An operator that already has a
# keypair on disk keeps it, so re-running is a no-op; --rotate replaces every
# keypair. Two operators by default, because the token policy asks for two
# signatures, and each is a SPIFFE ID under spiffe://signalloom.demo/operator/.
#
# Key material never appears in argv: keygen takes an output DIRECTORY and a
# NAME, and the ConfigMap is assembled by printf from the public entries only.
#
# The keypairs come from fleet-manager's own tool, cmd/resume-token, so the
# key id and encoding are the ones fleet-manager computes. It is built once
# into <keys_dir>/fleet-operators/resume-token; RESUME_TOKEN_BIN overrides
# that, which is also how the tests substitute a fake.
#
# Usage: scripts/fleet-operator-keys.sh --context CONTEXT [--rotate]
#                                       [--operators ID,ID...]
#
#   --operators  comma-separated. A bare name is taken under the default
#                prefix; a full spiffe:// ID is taken as is. The file name is
#                the last path segment. Default alice,bob.

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
# shellcheck source=scripts/lib/keys.sh
. "${SCRIPT_DIR}/lib/keys.sh"

KUBECTL="${SLDC_KUBECTL:-kubectl}"
FLEET_NS="fe-signalloom"
CONFIGMAP_NAME="fleet-manager-operator-keys"
CONFIGMAP_KEY="keys.json"
OPERATOR_PREFIX="spiffe://signalloom.demo/operator/"
DEFAULT_OPERATORS="alice,bob"
FM_DIR="${REPO_ROOT}/d2-signalloom/apps/fleet-manager"

usage() { sed -n '3,45p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'fleet-operator-keys: %s\n' "$1" >&2; exit "${2:-1}"; }

# resume_token_bin DIR -> the path of a usable resume-token binary on stdout,
# building it into DIR when nothing else provides one.
resume_token_bin() {
  local dir="$1"
  if [ -n "${RESUME_TOKEN_BIN:-}" ]; then
    [ -x "${RESUME_TOKEN_BIN}" ] || die "RESUME_TOKEN_BIN=${RESUME_TOKEN_BIN} is not executable" 1
    printf '%s' "${RESUME_TOKEN_BIN}"
    return 0
  fi
  if [ -x "${dir}/resume-token" ]; then
    printf '%s' "${dir}/resume-token"
    return 0
  fi
  command -v go >/dev/null 2>&1 || die "no go on PATH and no ${dir}/resume-token; set RESUME_TOKEN_BIN or install go" 1
  [ -d "${FM_DIR}/cmd/resume-token" ] || die "${FM_DIR}/cmd/resume-token is absent; it ships with fleet-manager's resume governance" 1
  (cd "${FM_DIR}" && go build -o "${dir}/resume-token" ./cmd/resume-token) >&2 \
    || die "go build ./cmd/resume-token failed" 1
  printf '%s' "${dir}/resume-token"
}

# configmap_doc KEYS_JSON_FILE -> the ConfigMap manifest on stdout. The JSON
# goes in as a block scalar, one indented line per source line, so the array
# keygen's entries were joined into is carried byte for byte.
configmap_doc() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: %s\n  namespace: %s\ndata:\n  %s: |\n' \
    "${CONFIGMAP_NAME}" "${FLEET_NS}" "${CONFIGMAP_KEY}"
  sed 's/^/    /' "$1"
}

main() {
  local context="" rotate=0 operators="${DEFAULT_OPERATORS}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="${2:-}"; shift 2 || die "--context needs a value" 2 ;;
      --rotate) rotate=1; shift ;;
      --operators) operators="${2:-}"; shift 2 || die "--operators needs a value" 2
        [ -n "${operators}" ] || die "--operators needs a value" 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" 2 ;;
    esac
  done
  [ -n "${context}" ] || die "--context is required (the ConfigMap is per cluster)" 2

  local dir
  dir="$(keys_dir_abs "${REPO_ROOT}")/fleet-operators"
  # 0700 from birth: the directory holds private keys.
  (umask 077 && mkdir -p -- "${dir}") || die "could not create ${dir}" 1
  chmod 700 "${dir}" 2>/dev/null || true

  local ids=() names=() parts=() id name
  IFS=',' read -r -a parts <<<"${operators}"
  for id in "${parts[@]}"; do
    [ -n "${id}" ] || continue
    case "${id}" in
      *://*) ;;
      */*) die "operator '${id}' is neither a bare name nor a spiffe:// ID" 2 ;;
      *) id="${OPERATOR_PREFIX}${id}" ;;
    esac
    name="${id##*/}"
    case "${name}" in
      ''|*[!A-Za-z0-9._-]*) die "operator '${id}' has no usable file name" 2 ;;
    esac
    ids+=("${id}"); names+=("${name}")
  done
  [ "${#ids[@]}" -ge 1 ] || die "--operators named nobody" 2

  local bin="" created=() kept=() i
  for i in "${!ids[@]}"; do
    id="${ids[$i]}"; name="${names[$i]}"
    if [ "${rotate}" -eq 0 ] && [ -s "${dir}/${name}.key" ] \
      && [ -s "${dir}/${name}.pub" ] && [ -s "${dir}/${name}.json" ]; then
      kept+=("${name}")
      continue
    fi
    [ -n "${bin}" ] || bin="$(resume_token_bin "${dir}")" || exit 1
    rm -f -- "${dir}/${name}.key" "${dir}/${name}.pub" "${dir}/${name}.json"
    # The private key is written by keygen itself into DIR: no key byte is an
    # argument here, and the entry on stdout is the PUBLIC record only.
    (umask 077 && "${bin}" keygen --operator "${id}" --out "${dir}" --name "${name}" >"${dir}/${name}.json") \
      || die "resume-token keygen failed for ${id}" 1
    [ -s "${dir}/${name}.key" ] && [ -s "${dir}/${name}.pub" ] && [ -s "${dir}/${name}.json" ] \
      || die "keygen for ${id} did not write ${name}.key, ${name}.pub and a public entry" 1
    chmod 600 "${dir}/${name}.key" || die "could not set 0600 on ${dir}/${name}.key" 1
    created+=("${name}")
  done

  # keys.json: a JSON array of the public entries, in operator order.
  {
    printf '['
    for i in "${!names[@]}"; do
      [ "${i}" -eq 0 ] || printf ','
      cat "${dir}/${names[$i]}.json"
    done
    printf ']\n'
  } >"${dir}/${CONFIGMAP_KEY}" || die "could not write ${dir}/${CONFIGMAP_KEY}" 1
  if command -v jq >/dev/null 2>&1; then
    jq -e --argjson n "${#names[@]}" 'type == "array" and length == $n and all(.[]; .operator_id != "" and .public_key != "")' \
      "${dir}/${CONFIGMAP_KEY}" >/dev/null \
      || die "${dir}/${CONFIGMAP_KEY} is not an array of ${#names[@]} public entries" 1
  fi

  # kubectl apply reads the manifest from stdin, assembled from the public
  # entries only. The private keys stay in DIR.
  configmap_doc "${dir}/${CONFIGMAP_KEY}" | ${KUBECTL} --context "${context}" apply -f - >/dev/null \
    || die "kubectl apply failed for context ${context}" 1

  local verb=ensured
  [ "${rotate}" -eq 1 ] && verb=rotated
  printf 'fleet operator keys %s on %s: %s -> ConfigMap %s/%s key %s\n' \
    "${verb}" "${context}" "${ids[*]}" "${FLEET_NS}" "${CONFIGMAP_NAME}" "${CONFIGMAP_KEY}"
  [ "${#created[@]}" -eq 0 ] || printf '  created: %s (private keys 0600 in %s, never applied)\n' "${created[*]}" "${dir}"
  [ "${#kept[@]}" -eq 0 ] || printf '  kept: %s (already in %s)\n' "${kept[*]}" "${dir}"
  if [ "${#created[@]}" -gt 0 ]; then
    printf '  fleet-manager reads OPERATOR_KEYS_JSON at start: kubectl --context %s -n %s rollout restart deploy/fleet-manager\n' \
      "${context}" "${FLEET_NS}"
  fi
  return 0
}

main "$@"
