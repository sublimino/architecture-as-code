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

# 2. Test case insensitivity
h_upper="$("$BIN" hash Kusari)"
assert_eq "Case insensitive hash" "$h_upper" "$EXPECTED_HASH"
h_ws="$("$BIN" hash '  kusari  ')"
assert_eq "Whitespace trimmed hash" "$h_ws" "$EXPECTED_HASH"

# 3. Test urls command output
urls="$("$BIN" urls kusari)"
assert_contains "URL output has hostname" "$urls" "\"hostname\": \"sl-eap-${EXPECTED_HASH}\""
assert_contains "URL output has mesh URL" "$urls" "\"internal_mesh_url\": \"https://sl-eap-${EXPECTED_HASH}.tailscale\""
assert_contains "URL output has external FQDN" "$urls" "\"external_fqdn\": \"https://sl-eap-${EXPECTED_HASH}.ts.net\""

# 4. Test mock provision
prov_out="$("$BIN" provision kusari)"
assert_contains "Provision output confirms mock join" "$prov_out" "successfully provisioned"
assert_eq "Mock state directory created" "$([[ -f "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}/state.json" ]] && echo yes)" "yes"

# 5. Test mock serve
serve_out="$("$BIN" serve kusari 9090)"
assert_contains "Serve output confirms proxy port" "$serve_out" "proxying to 127.0.0.1:9090"
assert_eq "Mock serve file created" "$([[ -f "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}/serve.json" ]] && echo yes)" "yes"

# 6. Test mock status
status_out="$("$BIN" status kusari)"
assert_contains "Status output contains IPv4" "$status_out" '"ipv4": "100.64.0.'
assert_contains "Status output contains running state" "$status_out" '"state": "Running"'

# 7. Test mock teardown
teardown_out="$("$BIN" teardown kusari)"
assert_contains "Teardown clears mock state" "$teardown_out" "cleared cleanly"
assert_eq "Mock directory removed" "$([[ -d "$TEST_MOCK_DIR/sl-eap-${EXPECTED_HASH}" ]] && echo yes || echo no)" "no"

# 8. Test idempotent teardown
teardown_again="$("$BIN" teardown kusari)"
assert_contains "Repeated teardown is idempotent" "$teardown_again" "cleared cleanly"

# 9. Test teardown addressed by customer hash (SLED-P3-1 Stage 2 contract)
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

# 10. Malformed hash is rejected with exit 2, never mapped to a node
set +e
bad_out="$("$BIN" teardown --hash 'ZZ;rm' 2>&1)"; bad_rc=$?
set -e
assert_eq "Malformed hash exits 2" "$bad_rc" "2"
assert_contains "Malformed hash error is explicit" "$bad_out" "8-char lowercase hex"

echo ""
echo "=== Summary: $PASSED passed, $FAILED failed ==="
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
echo "All CLI automation tests completed successfully!"
