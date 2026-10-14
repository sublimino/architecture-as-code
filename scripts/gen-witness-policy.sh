#!/usr/bin/env bash
# Generate a signed Witness policy for one step and one functionary key.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "${REPO_ROOT}"
# shellcheck source=scripts/lib/witness-local.sh
source "${REPO_ROOT}/scripts/lib/witness-local.sh"

STEP_NAME="${1:-artifact-build}"
OUT_DIR="${2:-policy/out}"
FUNCTIONARY_KEY="${3:-.keys/witness.pem}"
FUNCTIONARY_PUB="${4:-.keys/witness-pub.pem}"
POLICY_KEY="${POLICY_KEY:-.keys/policy.pem}"
POLICY_PUB="${POLICY_PUB:-.keys/policy-pub.pem}"
OUT_DIR=$(mkdir -p "${OUT_DIR}" && cd "${OUT_DIR}" && pwd)
case "${FUNCTIONARY_KEY}" in /*) ;; *) FUNCTIONARY_KEY="${REPO_ROOT}/${FUNCTIONARY_KEY}" ;; esac
case "${FUNCTIONARY_PUB}" in /*) ;; *) FUNCTIONARY_PUB="${REPO_ROOT}/${FUNCTIONARY_PUB}" ;; esac
case "${POLICY_KEY}" in /*) ;; *) POLICY_KEY="${REPO_ROOT}/${POLICY_KEY}" ;; esac
case "${POLICY_PUB}" in /*) ;; *) POLICY_PUB="${REPO_ROOT}/${POLICY_PUB}" ;; esac

test -f "${FUNCTIONARY_KEY}" || { echo "functionary key missing: ${FUNCTIONARY_KEY}" >&2; exit 1; }
test -f "${FUNCTIONARY_PUB}" || { echo "functionary public key missing: ${FUNCTIONARY_PUB}" >&2; exit 1; }
command -v witness >/dev/null || { echo "witness not installed" >&2; exit 1; }

if [ ! -f "${POLICY_KEY}" ]; then
  mkdir -p "$(dirname "${POLICY_KEY}")"
  openssl genpkey -algorithm ed25519 -out "${POLICY_KEY}"
  openssl pkey -in "${POLICY_KEY}" -pubout -out "${POLICY_PUB}"
fi

TEMP_DIR=$(mktemp -d)
export WITNESS_LOCAL_HOME="${TEMP_DIR}/home"
trap 'rm -rf "${TEMP_DIR}"' EXIT
mkdir -p "${WITNESS_LOCAL_HOME}"
PROBE_DIR="${TEMP_DIR}/probe"
witness_local_prepare "${PROBE_DIR}"
witness_local_run "${PROBE_DIR}" --step keyid-probe \
  -o "${TEMP_DIR}/keyid-probe.json" -k "${FUNCTIONARY_KEY}" \
  -- bash -c 'printf probe > keyid-probe.product' >/dev/null
KEY_ID=$(jq -er '.signatures[0].keyid' "${TEMP_DIR}/keyid-probe.json" | tr -d '\r')
KEY_B64=$(base64 -w0 < "${FUNCTIONARY_PUB}" 2>/dev/null || base64 < "${FUNCTIONARY_PUB}" | tr -d '\n')
EXPIRES=$(date -u -d "+1 year" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+1y +"%Y-%m-%dT%H:%M:%SZ")

cat > "${OUT_DIR}/promotion-policy.json" <<POLICY
{
  "expires": "${EXPIRES}",
  "steps": {
    "${STEP_NAME}": {
      "name": "${STEP_NAME}",
      "attestations": [
        { "type": "https://witness.dev/attestations/material/v0.1" },
        { "type": "https://witness.dev/attestations/command-run/v0.1" },
        { "type": "https://witness.dev/attestations/product/v0.1" }
      ],
      "functionaries": [
        { "type": "publickey", "publickeyid": "${KEY_ID}" }
      ]
    }
  },
  "publickeys": {
    "${KEY_ID}": { "keyid": "${KEY_ID}", "key": "${KEY_B64}" }
  }
}
POLICY

witness sign -f "${OUT_DIR}/promotion-policy.json" -k "${POLICY_KEY}" \
  -o "${OUT_DIR}/promotion-policy.signed.json"
printf '%s\n' "policy signed: ${OUT_DIR}/promotion-policy.signed.json" "functionary keyid: ${KEY_ID}"
