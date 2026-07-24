#!/usr/bin/env bash
# Generate and sign the witness policy that gates promotion. The policy
# requires a vex-analysis step attested and signed by the workload witness
# key. The policy itself is signed with a separate policy key, modeling the
# security team as the policy authority and the pipeline as the functionary.
set -euo pipefail

cd "$(dirname "$0")/.."

test -f .keys/witness-pub.pem || { echo "run 'make signing-keys' first"; exit 1; }
command -v witness >/dev/null || { echo "witness not installed"; exit 1; }

mkdir -p policy/out

if [ ! -f .keys/policy.pem ]; then
  openssl genpkey -algorithm ed25519 -out .keys/policy.pem
  openssl pkey -in .keys/policy.pem -pubout -out .keys/policy-pub.pem
fi

# witness derives functionary key ids internally; a throwaway signed run is
# the reliable way to learn the id for our key
PROBE=$(mktemp)
witness run --step keyid-probe -o "${PROBE}" -k .keys/witness.pem -- bash -c true >/dev/null 2>&1
KEY_ID=$(jq -r '.signatures[0].keyid' "${PROBE}" | tr -d '\r')
rm -f "${PROBE}"
test -n "${KEY_ID}" || { echo "could not derive the witness key id"; exit 1; }
KEY_B64=$(base64 -w0 < .keys/witness-pub.pem 2>/dev/null || base64 < .keys/witness-pub.pem | tr -d '\n')
EXPIRES=$(date -u -d "+1 year" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v+1y +"%Y-%m-%dT%H:%M:%SZ")

cat > policy/out/promotion-policy.json <<POLICY
{
  "expires": "${EXPIRES}",
  "steps": {
    "vex-analysis": {
      "name": "vex-analysis",
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
    "${KEY_ID}": {
      "keyid": "${KEY_ID}",
      "key": "${KEY_B64}"
    }
  }
}
POLICY

witness sign -f policy/out/promotion-policy.json \
  -k .keys/policy.pem \
  -o policy/out/promotion-policy.signed.json

echo "policy signed: policy/out/promotion-policy.signed.json"
echo "functionary keyid: ${KEY_ID}"
