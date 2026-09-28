#!/usr/bin/env bash
# ==============================================================================
# Acceptance and Unit Test Suite for scripts/eap/tailscale-eap-env.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/tailscale-eap-env.sh"
TEST_MOCK_DIR="/tmp/test-tailscale-eap-$$"

export TAILSCALE_MOCK=1
export TAILSCALE_MOCK_DIR="$TEST_MOCK_DIR"
export SIGNAL_LOOM_EAP_SALT="test-eap-salt-2026"

cleanup() {
  rm -rf "$TEST_MOCK_DIR"
}
trap cleanup EXIT INT TERM

PASSED=0
FAILED=0

assert_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  [PASS] $label"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $label: expected '$expected', got '$actual'" >&2
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  [PASS] $label"
    PASSED=$((PASSED + 1))
  else
    echo "  [FAIL] $label: '$haystack' did not contain '$needle'" >&2
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Running Tailscale EAP Automation CLI Tests ==="

# 0. Test missing salt fails with exit code 2
set +e
(unset SIGNAL_LOOM_EAP_SALT; unset BAO_ADDR; "$BIN" hash kusari >/dev/null 2>&1)
missing_salt_rc=$?
set -e
assert_eq "Missing salt exits with code 2" "$missing_salt_rc" "2"

EXPECTED_HASH="a0314bec"

# 1. Test canonical kusari hash
h="$("$BIN" hash kusari)"
assert_eq "Canonical hash for kusari" "$h" "$EXPECTED_HASH"

# 2. Cross-implementation test: verify shell hash matches Python derive_customer_hash
py_hash="$(python3 -c "import sys, hashlib; print(hashlib.sha256(b'test-eap-salt-2026:kusari').hexdigest()[:8])")"
assert_eq "Shell hash equals Python derive_customer_hash for kusari" "$h" "$py_hash"

# 3. Test injection resistance: company names with quotes or backslashes must exit 2
set +e
inj_out="$("$BIN" hash "kusari'; import os; os.system('id')" 2>&1)"; inj_rc=$?
set -e
assert_eq "Quote injection in company name exits 2" "$inj_rc" "2"
assert_contains "Quote injection yields invalid company name error" "$inj_out" "Invalid company name"

set +e
inj2_out="$("$BIN" hash "kusari' OR '1'='1" 2>&1)"; inj2_rc=$?
set -e
assert_eq "SQL-style quote injection exits 2" "$inj2_rc" "2"

# 4. Test empty company name exits with code 2
set +e
empty_out="$("$BIN" hash "" 2>&1)"; empty_rc=$?
set -e
assert_eq "Empty company name exits 2" "$empty_rc" "2"
assert_contains "Empty company name error message" "$empty_out" "cannot be empty"

set +e
ws_only_out="$("$BIN" hash "   " 2>&1)"; ws_only_rc=$?
set -e
assert_eq "Whitespace-only company name exits 2" "$ws_only_rc" "2"

# 5. Test case insensitivity and whitespace trimming
h_upper="$("$BIN" hash Kusari)"
assert_eq "Case insensitive hash" "$h_upper" "$EXPECTED_HASH"
h_ws="$("$BIN" hash '  kusari  ')"
assert_eq "Whitespace trimmed hash" "$h_ws" "$EXPECTED_HASH"

# 6. Test urls command output
urls="$("$BIN" urls kusari)"
assert_contains "URL output has hostname" "$urls" "\"hostname\": \"sl-eap-${EXPECTED_HASH}\""
assert_contains "URL output has mesh URL" "$urls" "\"internal_mesh_url\": \"https://sl-eap-${EXPECTED_HASH}.tailscale\""
assert_contains "URL output has external FQDN" "$urls" "\"external_fqdn\": \"https://sl-eap-${EXPECTED_HASH}.ts.net\""

# 7. Test mock provision
prov_out="$("$BIN" provision kusari)"
assert_contains "Provision output confirms mock join" "$prov_out" "successfully provisioned"
assert_eq "Mock state directory created" "$([[ -f "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}/state.json" ]] && echo yes)" "yes"

# 8. Test mock serve
serve_out="$("$BIN" serve kusari 9090)"
assert_contains "Serve output confirms proxy port" "$serve_out" "proxying to 127.0.0.1:9090"
assert_eq "Mock serve file created" "$([[ -f "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}/serve.json" ]] && echo yes)" "yes"

# 9. Test mock status
status_out="$("$BIN" status kusari)"
assert_contains "Status output contains IPv4" "$status_out" '"ipv4": "100.64.0.'
assert_contains "Status output contains running state" "$status_out" '"state": "Running"'

# 10. Test mock teardown
teardown_out="$("$BIN" teardown kusari)"
assert_contains "Teardown clears mock state" "$teardown_out" "cleared cleanly"
assert_eq "Mock directory removed" "$([[ -d "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}" ]] && echo yes || echo no)" "no"

# 11. Test idempotent teardown
teardown_again="$("$BIN" teardown kusari)"
assert_contains "Repeated teardown is idempotent" "$teardown_again" "cleared cleanly"

# 12. Test teardown addressed by customer hash (SLED-P3-1 Stage 2 contract)
"$BIN" provision kusari >/dev/null
"$BIN" serve kusari >/dev/null
"$BIN" funnel kusari >/dev/null
assert_eq "Serve+funnel mock files exist before hash teardown" \
  "$([[ -f "$TEST_MOCK_DIR/sl-eap-$EXPECTED_HASH/serve.json" && -f "$TEST_MOCK_DIR/sl-eap-$EXPECTED_HASH/funnel.json" ]] && echo yes)" "yes"
hash_out="$("$BIN" teardown --hash "$EXPECTED_HASH")"
assert_contains "Hash teardown names the node" "$hash_out" "sl-eap-$EXPECTED_HASH"
assert_eq "Hash teardown purges serve/funnel state" \
  "$([[ -d "$TEST_MOCK_DIR/sl-eap-$EXPECTED_HASH" ]] && echo yes || echo no)" "no"
hash_again="$("$BIN" teardown --hash "$EXPECTED_HASH")"
assert_contains "Repeated hash teardown is idempotent" "$hash_again" "cleared cleanly"
assert_eq "Status reports node gone after eviction" \
  "$("$BIN" status kusari | grep -c NotProvisioned)" "1"

# 13. Malformed hash is rejected with exit 2, never mapped to a node
set +e
bad_out="$("$BIN" teardown --hash 'ZZ;rm' 2>&1)"; bad_rc=$?
set -e
assert_eq "Malformed hash exits 2" "$bad_rc" "2"
assert_contains "Malformed hash error is explicit" "$bad_out" "8-char lowercase hex"

# 14. Test no-mock fallback when tailscale binary is missing (exit 3)
NO_TS_BIN_DIR="/tmp/test-no-ts-$$"
mkdir -p "$NO_TS_BIN_DIR"
for tool in bash sh env sed tr awk sha256sum shasum python3 python dirname basename cat rm mkdir date grep xargs; do
  tool_path="$(which "$tool" 2>/dev/null || true)"
  if [[ -n "$tool_path" && -x "$tool_path" ]]; then
    ln -sf "$tool_path" "$NO_TS_BIN_DIR/$tool"
  fi
done

set +e
no_bin_out="$(TAILSCALE_MOCK=0 PATH="$NO_TS_BIN_DIR" "$BIN" status kusari 2>&1)"; no_bin_rc=$?
set -e
rm -rf "$NO_TS_BIN_DIR"
assert_eq "Missing tailscale binary exits 3 when TAILSCALE_MOCK=0" "$no_bin_rc" "3"
assert_contains "Missing binary error message is explicit" "$no_bin_out" "tailscale binary not found"

# 15. Positive control: with a fake tailscale on PATH, command succeeds
FAKE_BIN_DIR="/tmp/test-fake-ts-$$"
mkdir -p "$FAKE_BIN_DIR"
cat > "$FAKE_BIN_DIR/tailscale" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "status" ]]; then
  echo '{"Self": {"HostName": "test-node"}}'
  exit 0
fi
exit 0
EOF
chmod +x "$FAKE_BIN_DIR/tailscale"

set +e
fake_out="$(TAILSCALE_MOCK=0 PATH="$FAKE_BIN_DIR:/usr/bin:/bin" "$BIN" status 2>&1)"; fake_rc=$?
set -e
rm -rf "$FAKE_BIN_DIR"
assert_eq "Fake tailscale binary on PATH succeeds with rc 0" "$fake_rc" "0"

echo ""
echo "=== Summary: $PASSED passed, $FAILED failed ==="
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
echo "All CLI automation tests completed successfully!"
