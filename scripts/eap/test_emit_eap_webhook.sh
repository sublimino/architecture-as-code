#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/test_emit_eap_webhook.sh
# Test suite for emit-eap-webhook.sh
# ==============================================================================
set -euo pipefail

PASS=0
FAIL=0

assert_eq() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label: expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] $label: expected to contain '$needle'"
        FAIL=$((FAIL + 1))
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMITTER="${SCRIPT_DIR}/emit-eap-webhook.sh"

echo "=== Running emit-eap-webhook.sh Test Suite ==="

# Test 1: Hash kurasi vector
out=$("$EMITTER" hash kurasi)
assert_eq "Kurasi hash is deterministic 6f82ad81" "$out" "6f82ad81"

# Test 2: Help flag exits 0
if "$EMITTER" --help >/dev/null; then
    echo "  [PASS] --help exits 0"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] --help failed"
    FAIL=$((FAIL + 1))
fi

# Test 3: Dry run github-pr output contains expected headers
out=$("$EMITTER" github-pr --company kurasi --pr 42 --action opened --dry-run)
assert_contains "Dry run contains X-Hub-Signature-256" "$out" "X-Hub-Signature-256: sha256="
assert_contains "Dry run contains kurasi repository" "$out" "kurasi-service"
assert_contains "Dry run contains action opened" "$out" '"action":"opened"'

# Test 4: Dry run generic webhook output contains expected headers
out=$("$EMITTER" generic --company kurasi --action provision --ttl 120 --dry-run)
assert_contains "Generic dry run contains X-SignalLoom-Signature" "$out" "X-SignalLoom-Signature: sha256="
assert_contains "Generic dry run contains X-SignalLoom-Timestamp" "$out" "X-SignalLoom-Timestamp:"
assert_contains "Generic dry run contains company_name kurasi" "$out" '"company_name":"kurasi"'

# Test 5: Tamper command modifies signature
out_normal=$("$EMITTER" github-pr --company kurasi --pr 42 --action opened --dry-run)
out_tampered=$("$EMITTER" tamper --company kurasi --pr 42 --action opened --dry-run)
sig_normal=$(echo "$out_normal" | grep "X-Hub-Signature-256" | awk '{print $2}')
sig_tampered=$(echo "$out_tampered" | grep "X-Hub-Signature-256" | awk '{print $2}')
if [[ "$sig_normal" != "$sig_tampered" ]]; then
    echo "  [PASS] Tamper mode produces altered signature"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] Tamper mode signature was not modified"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Test Summary: ${PASS} passed, ${FAIL} failed ==="
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
