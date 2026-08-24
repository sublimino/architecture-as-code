#!/usr/bin/env bats

# Unit tests for spire-trust-anchor.sh error paths.
#
# These run locally with stubbed kubectl — no cluster needed. They verify that
# spire_jwt_svid_keys and sync_openbao_jwt_validation propagate errors with
# actionable messages instead of silently succeeding with empty output.
#
# The live membership tests are in test/spire-openbao-trust-drift.bats. This
# suite covers the code paths that only fire when something is broken.

setup_file() {
  export ANCHOR_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

setup() {
  root="$ANCHOR_ROOT"
  stub="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub"
}

# ── spire_jwt_svid_keys error paths ──────────────────────────────────────────

@test "spire_jwt_svid_keys fails with clear message when SPIRE is unreachable" {
  printf '#!/usr/bin/env bash\necho "error: unable to connect" >&2; exit 1\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"SPIRE server unreachable"* ]]
}

@test "spire_jwt_svid_keys fails when bundle has no JWT-SVID keys" {
  # kubectl succeeds but returns a bundle with only x509 keys (no jwt-svid)
  printf '#!/usr/bin/env bash\n' >"$stub/kubectl"
  cat >>"$stub/kubectl" <<'KUBECTL'
cat <<'JSON'
{"keys":[{"kty":"EC","crv":"P-256","x":"abc","y":"def","use":"x509-svid"}]}
JSON
KUBECTL
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"no P-256 JWT-SVID validation key"* ]]
}

@test "spire_jwt_svid_keys fails when bundle is not valid JSON" {
  printf '#!/usr/bin/env bash\necho "not json at all"\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    spire_jwt_svid_keys inf-bao
  "
  [ "$status" -ne 0 ]
}

# ── sync_openbao_jwt_validation error paths ──────────────────────────────────

@test "sync_openbao_jwt_validation fails with clear message when SPIRE is unreachable" {
  printf '#!/usr/bin/env bash\necho "connection refused" >&2; exit 1\n' >"$stub/kubectl"
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot read SPIRE JWT-SVID keys"* ]]
}

@test "sync_openbao_jwt_validation refuses to write empty key set" {
  # kubectl succeeds, returns a valid bundle, but with zero jwt-svid keys
  printf '#!/usr/bin/env bash\n' >"$stub/kubectl"
  cat >>"$stub/kubectl" <<'KUBECTL'
cat <<'JSON'
{"keys":[{"kty":"RSA","use":"x509-svid","n":"abc","e":"AQAB"}]}
JSON
KUBECTL
  chmod +x "$stub/kubectl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
  [ "$status" -ne 0 ]
  # The error should come from spire_jwt_svid_keys (no P-256 JWT-SVID keys),
  # then sync propagates it as "cannot read SPIRE JWT-SVID keys"
  [[ "$output" == *"cannot read SPIRE"* ]] || [[ "$output" == *"no P-256 JWT-SVID"* ]]
}

@test "sync_openbao_jwt_validation fails when OpenBao write fails" {
  # kubectl stub: first call returns a valid SPIRE bundle, subsequent calls fail
  # (simulating openbao unreachable for the write)
  cat >"$stub/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
if [[ "$*" == *"spire-server"* ]]; then
  cat <<'JSON'
{"keys":[{"kty":"EC","crv":"P-256","x":"f83OJ3D2xF1Bg8vub9tLe1gHMzV76e8Tus9uPHvRVEU","y":"x_FEzRu9m36HLN_tue659LNpXW6pCyStikYjKIWI5a0","use":"jwt-svid","kid":"test-kid-1"}]}
JSON
  exit 0
elif [[ "$*" == *"openbao"* ]]; then
  echo "Error writing data to auth/jwt/config: connection refused" >&2
  exit 2
fi
exit 0
KUBECTL
  chmod +x "$stub/kubectl"

  # openssl stub for PEM conversion
  cat >"$stub/openssl" <<'OPENSSL'
#!/usr/bin/env bash
echo "-----BEGIN PUBLIC KEY-----"
echo "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE"
echo "-----END PUBLIC KEY-----"
OPENSSL
  chmod +x "$stub/openssl"

  run env PATH="$stub:$PATH" bash -c "
    source '$root/scripts/lib/spire-trust-anchor.sh'
    sync_openbao_jwt_validation inf-bao signalloom-demo-root-token
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"OpenBao refused the key write"* ]]
}

# ── CronJob manifest validation ─────────────────────────────────────────────

@test "CronJob manifest exists with expected schedule and policy" {
  local manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"
  [ -f "$manifest" ]

  # Schedule: every 8 hours
  grep -q 'schedule:.*0 \*/8' "$manifest"

  # backoffLimit: 1
  grep -q 'backoffLimit: 1' "$manifest"

  # concurrencyPolicy: Forbid
  grep -q 'concurrencyPolicy: Forbid' "$manifest"
}

@test "CronJob sync script is syntactically valid bash" {
  local manifest="$root/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-sync-cronjob.yaml"

  # Extract the sync.sh content from the ConfigMap
  # The script is between 'sync.sh: |' and the next '---' separator
  local script
  script="$(sed -n '/^  sync\.sh: |$/,/^---$/{ /^  sync\.sh: |$/d; /^---$/d; s/^    //; p; }' "$manifest")"
  [ -n "$script" ]

  # bash -n checks syntax without executing
  echo "$script" | bash -n
}

@test "CronJob is registered in kustomization.yaml" {
  local kustomization="$root/d2-signalloom/infra/inf-bao/controllers/base/kustomization.yaml"
  grep -q 'spire-openbao-sync-cronjob.yaml' "$kustomization"
}

# ── No new vacuous mapfile patterns ──────────────────────────────────────────

@test "no test file uses the vacuous mapfile pattern" {
  # The pattern `mapfile -t arr < <(cmd) || return 1` is vacuous: mapfile
  # always returns 0 regardless of cmd's exit status.
  local count
  count="$(grep -rn 'mapfile.*< <(' "$root/test/" --include='*.bats' 2>/dev/null | wc -l)"
  [ "$count" -eq 0 ]
}
