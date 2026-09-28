#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/seed-eap-salt.sh
# One-shot idempotent script to generate and seed a 32-byte cryptographic salt
# into OpenBao for Signal Loom EAP on-demand environments.
# ==============================================================================
set -euo pipefail

BAO_ADDR="${BAO_ADDR:-http://127.0.0.1:8200}"
export BAO_ADDR

if ! command -v bao >/dev/null 2>&1; then
  echo "ERROR: bao CLI not found in PATH" >&2
  exit 1
fi

if [[ -z "${BAO_TOKEN:-}" ]]; then
  echo "ERROR: BAO_TOKEN must be set to seed EAP salt into OpenBao" >&2
  exit 1
fi

# Check if salt already exists
existing_salt="$(bao kv get -field=salt secret/signalloom/eap 2>/dev/null || true)"
if [[ -n "${existing_salt}" ]]; then
  echo "EAP salt already provisioned in secret/signalloom/eap (length ${#existing_salt}). Refusing to overwrite."
  exit 0
fi

# Generate random 32-byte hex salt
if command -v openssl >/dev/null 2>&1; then
  NEW_SALT="$(openssl rand -hex 32)"
else
  NEW_SALT="$(head -c 32 /dev/urandom | xxd -p | tr -d '\n')"
fi

echo "Seeding 32-byte EAP salt into OpenBao at secret/signalloom/eap..."
bao kv put secret/signalloom/eap salt="${NEW_SALT}"
echo "Successfully provisioned EAP salt in OpenBao."
