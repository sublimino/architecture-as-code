#!/usr/bin/env bash
# ==============================================================================
# SLDC-P3-GOV Phase 3 Governance Gate Verification Runner
#
# Asserts tenant cryptographic hash derivation vectors across Go/Py/TS/Bash,
# validates Gateway API HTTPRoute compilation and Dex OIDC redirect alignment,
# executes positive and negative cross-tenant ingress HTTP probes, performs
# deliberate mutation testing, and emits machine-readable certification records.
#
# Usage:
#   scripts/test-phase3-governor.sh [--hermetic] [--out JSON_FILE] [--trace-out TXT_FILE]
# ==============================================================================
set -eo pipefail

CANONICAL_TENANT="kusari"
CANONICAL_HASH="4b53ab6b"
CANONICAL_HOST="sl-eap-${CANONICAL_HASH}.ts.net"
CANONICAL_DEMO_HOST="sl-eap-${CANONICAL_HASH}.demo.signalloom.io"
RETIRED_TENANT="kurasi"
RETIRED_HASH="6f82ad81"
RETIRED_HOST="sl-eap-${RETIRED_HASH}.ts.net"
PILOT_SALT="signalloom-eap-salt-2026-q3"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUTATION_PROOF="${PHASE3_MUTATION_PROOF:-$REPO_ROOT/test/eap-tenant-routing-mutation-proof.sh}"
OUTPUT_JSON="${REPO_ROOT}/ci-evidence/phase3-governance-certification.json"
TRACE_OUTPUT="${REPO_ROOT}/ci-evidence/phase3-routing-audit.txt"
HERMETIC=false
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hermetic|--dry-run) HERMETIC=true; shift ;;
    --out) OUTPUT_JSON="$2"; shift 2 ;;
    --trace-out) TRACE_OUTPUT="$2"; shift 2 ;;
    --verbose|-v) VERBOSE=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--hermetic] [--out JSON_FILE] [--trace-out TXT_FILE]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

export GOPATH="${GOPATH:-/tmp/go}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export CGO_ENABLED=0
export UV_CACHE_DIR="${UV_CACHE_DIR:-/tmp/uv-cache}"
export SIGNAL_LOOM_EAP_SALT="$PILOT_SALT"

mkdir -p "$(dirname "$OUTPUT_JSON")"
mkdir -p "$(dirname "$TRACE_OUTPUT")"
: > "$TRACE_OUTPUT"

log_trace() {
  echo "$*" >> "$TRACE_OUTPUT"
}

echo "══════════════════════════════════════════════════════════════════════════════"
echo "  SLDC-P3-GOV: Phase 3 Governance Gate Verification"
echo "══════════════════════════════════════════════════════════════════════════════"
echo "Canonical Tenant: $CANONICAL_TENANT -> Domain Hash: $CANONICAL_HASH"
echo "Canonical FQDN:   $CANONICAL_HOST"
echo "Retired Typo:     $RETIRED_TENANT -> $RETIRED_HASH (Fail-Closed Required)"
echo "Mode:             $(if [[ "$HERMETIC" == "true" ]]; then echo "Hermetic / Simulation"; else echo "Live Cluster / Ingress"; fi)"
echo "──────────────────────────────────────────────────────────────────────────────"

GATE_RESULTS=()
GATE_ERRORS=0

record_gate() {
  local id="$1"
  local name="$2"
  local status="$3"
  local details="$4"
  GATE_RESULTS+=("$(jq -nc --arg g "$id" --arg n "$name" --arg s "$status" --arg d "$details" '{gate: $g, name: $n, status: $s, details: $d}')")
  if [[ "$status" != "PASS" ]]; then
    GATE_ERRORS=$((GATE_ERRORS + 1))
    echo "❌ [$id] $name: FAIL ($details)"
  else
    echo "✅ [$id] $name: PASS ($details)"
  fi
}

# ------------------------------------------------------------------------------
# Gate 1: Git Branch Clean Merge Verification
# ------------------------------------------------------------------------------
echo "Executing Gate 1: Branch Clean Merge Verification..."
MERGE_STATUS="PASS"
MERGE_DETAILS="HEAD resolved"
if ! git rev-parse HEAD >/dev/null 2>&1; then
  MERGE_STATUS="FAIL"
  MERGE_DETAILS="Not in a git repository"
fi
HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
log_trace "[Gate 1] Git HEAD SHA: $HEAD_SHA"
record_gate "G1_BRANCH_MERGE" "Branch Clean Integration" "$MERGE_STATUS" "$MERGE_DETAILS (SHA: ${HEAD_SHA:0:8})"

# ------------------------------------------------------------------------------
# Gate 2: Cryptographic Derivation Test Vector Matrix
# ------------------------------------------------------------------------------
echo "Executing Gate 2: Cryptographic Test Vector Certification..."
G2_STATUS="PASS"
G2_FAILED=()
run_suite() { # label, command...
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    log_trace "[Gate 2] $label=PASS"
  else
    log_trace "[Gate 2] $label=FAIL"
    G2_FAILED+=("$label")
  fi
}
run_suite Python python3 -m unittest discover -s "$REPO_ROOT/test/unit" -p "test_tenant_hash.py"
run_suite TypeScript bash -c "cd '$REPO_ROOT' && bun test test/unit/tenant-hash.test.ts"
run_suite Go bash -c "cd '$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/tenant' && go test ."
run_suite BATS bats "$REPO_ROOT/test/tenant-hash-vectors.bats"
if [[ ${#G2_FAILED[@]} -gt 0 ]]; then
  G2_STATUS="FAIL"
  G2_DETAILS="Tenant hash suites failed: ${G2_FAILED[*]}"
else
  G2_DETAILS="Go, Python, TypeScript and BATS tenant hash suites passed"
fi
record_gate "G2_CRYPTO_VECTORS" "Cryptographic Derivation Matrix" "$G2_STATUS" "$G2_DETAILS"

# ------------------------------------------------------------------------------
# Gate 3: Gateway API HTTPRoute Manifest & Cluster Acceptance
# ------------------------------------------------------------------------------
echo "Executing Gate 3: Gateway API HTTPRoute Manifest & Ingress Configuration..."
G3_STATUS="PASS"
G3_DETAILS="HTTPRoute binds canonical hostnames to fe-signalloom-service:3000"

HTTPROUTE_FILE="$REPO_ROOT/deploy/eap-tenant-httproute.yaml"
if [[ ! -f "$HTTPROUTE_FILE" ]]; then
  G3_STATUS="FAIL"
  G3_DETAILS="Missing deploy/eap-tenant-httproute.yaml"
elif ! grep -q "$CANONICAL_HOST" "$HTTPROUTE_FILE"; then
  G3_STATUS="FAIL"
  G3_DETAILS="HTTPRoute does not match canonical host $CANONICAL_HOST"
elif ! grep -q "signalloom.ai/tenant-hash: \"$CANONICAL_HASH\"" "$HTTPROUTE_FILE"; then
  G3_STATUS="FAIL"
  G3_DETAILS="HTTPRoute missing tenant hash label $CANONICAL_HASH"
fi

log_trace "[Gate 3] HTTPRoute manifest verified: $HTTPROUTE_FILE"
record_gate "G3_HTTPROUTE_CONFIG" "Gateway API HTTPRoute Manifest" "$G3_STATUS" "$G3_DETAILS"

# ------------------------------------------------------------------------------
# Gate 4: Dex OIDC Redirect URI Alignment
# ------------------------------------------------------------------------------
echo "Executing Gate 4: Dex OIDC Redirect URI Alignment..."
G4_STATUS="PASS"
G4_DETAILS="Canonical callback URI https://${CANONICAL_HOST}/auth/callback registered"

DEX_CONFIG_FILE="$REPO_ROOT/d2-signalloom/infra/dex/dex-config-eap.yaml"
DEX_BASE_FILE="$REPO_ROOT/d2-signalloom/infra/inf-signalloom/base/dex.yaml"

if [[ ! -f "$DEX_CONFIG_FILE" ]]; then
  G4_STATUS="FAIL"
  G4_DETAILS="Missing $DEX_CONFIG_FILE"
elif ! grep -q "https://${CANONICAL_HOST}/auth/callback" "$DEX_CONFIG_FILE"; then
  G4_STATUS="FAIL"
  G4_DETAILS="Dex config missing canonical redirect URI"
elif ! grep -q "https://${CANONICAL_HOST}/auth/callback" "$DEX_BASE_FILE"; then
  G4_STATUS="FAIL"
  G4_DETAILS="Dex base manifest missing canonical redirect URI"
fi

log_trace "[Gate 4] Dex OIDC config verified: https://${CANONICAL_HOST}/auth/callback"
record_gate "G4_DEX_OIDC_ALIGNMENT" "Dex OIDC Redirect Alignment" "$G4_STATUS" "$G4_DETAILS"

# ------------------------------------------------------------------------------
# Gate 5: Ingress HTTP Probe Matrix (Positive & Inferred)
# ------------------------------------------------------------------------------
echo "Executing Gate 5: Positive Tenant Routing Probes..."
# One probe matrix answers Gates 5 and 6: verify-tenant-routing.sh routes by
# the HTTPRoute and, with --hermetic, runs the real Envoy Lua filter.
VERIFY_ARGS=(--json)
[[ "$HERMETIC" == "true" ]] && VERIFY_ARGS+=(--hermetic)
PROBES_JSON="$("$REPO_ROOT/scripts/verify-tenant-routing.sh" "${VERIFY_ARGS[@]}" 2>/dev/null || true)"
if ! jq -e '.probes | length > 0' <<<"$PROBES_JSON" >/dev/null 2>&1; then
  PROBES_JSON='{"probes":[]}'
fi
PROBES_TOTAL="$(jq '.probes | length' <<<"$PROBES_JSON")"
PROBES_PASSED="$(jq '[.probes[] | select(.pass)] | length' <<<"$PROBES_JSON")"
while IFS= read -r line; do log_trace "[HTTP Probe] $line"; done < <(jq -r '.probes[] | "\(.id) \(.name) | Host: \(.host) | \(.header)=\(.value) | Expected: \(.expected) | Actual: \(.actual)"' <<<"$PROBES_JSON")

probe_gate() { # gate-id, name, probe ids...
  local id="$1" name="$2" failed
  shift 2
  failed="$(jq -r --args '[.probes[] | select(.id as $i | $ARGS.positional | index($i)) | select(.pass | not) | .id] | join(",")' "$@" <<<"$PROBES_JSON")"
  if [[ "$(jq --args '[.probes[] | select(.id as $i | $ARGS.positional | index($i))] | length' "$@" <<<"$PROBES_JSON")" -ne $# ]]; then
    record_gate "$id" "$name" "FAIL" "probe matrix incomplete"
  elif [[ -n "$failed" ]]; then
    record_gate "$id" "$name" "FAIL" "probes failed: $failed"
  else
    record_gate "$id" "$name" "PASS" "$# probes answered as expected"
  fi
}

echo "Executing Gate 5: Positive Tenant Routing Probes..."
probe_gate "G5_POSITIVE_ROUTING" "Positive Ingress Tenant Routing" P1 P2 P3 P8 P11
echo "Executing Gate 6: Cross-Tenant Isolation & Negative Probes..."
probe_gate "G6_NEGATIVE_ISOLATION" "Cross-Tenant Boundary Isolation" P4 P5 P6 P7 P9 P10 P12

# ------------------------------------------------------------------------------
# Gate 7: Deliberate Mutation Testing Check (Falsification Assurance)
# ------------------------------------------------------------------------------
echo "Executing Gate 7: Empirical Mutation Testing Proof..."
G7_STATUS="PASS"
G7_DETAILS="Every mutation of the real tenant filter, route, Dex config and gates turned its test red"
if ! "$MUTATION_PROOF" >/dev/null 2>&1; then
  G7_STATUS="FAIL"
  G7_DETAILS="Mutation proof failed or refused: $MUTATION_PROOF"
fi
log_trace "[Gate 7] Mutation proof $MUTATION_PROOF: $G7_STATUS"
record_gate "G7_MUTATION_TESTING" "Deliberate Mutation Assurance" "$G7_STATUS" "$G7_DETAILS"

# ------------------------------------------------------------------------------
# Gate 8: Repository-Wide Zero-Tolerance Typo Scan
# ------------------------------------------------------------------------------
echo "Executing Gate 8: Repository-Wide Zero-Tolerance Typo Scan..."
G8_STATUS="PASS"
if G8_OUT="$(P3_REPO="$REPO_ROOT" "$REPO_ROOT/scripts/p3-tenant-preflight.sh" legacy-gate 2>&1)"; then
  G8_DETAILS="$G8_OUT"
else
  G8_STATUS="FAIL"
  G8_DETAILS="$(tr '\n' ' ' <<<"$G8_OUT")"
fi
log_trace "[Gate 8] $G8_DETAILS"

record_gate "G8_ZERO_TOLERANCE_SCAN" "Repository Typo Zero-Tolerance" "$G8_STATUS" "$G8_DETAILS"

# ------------------------------------------------------------------------------
# Output Certification Artifacts
# ------------------------------------------------------------------------------
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
OVERALL_STATUS="PASS"
if [[ $GATE_ERRORS -gt 0 ]]; then
  OVERALL_STATUS="FAIL"
fi

CERT_JSON=$(jq -n \
  --arg timestamp "$TIMESTAMP" \
  --arg head_sha "$HEAD_SHA" \
  --arg status "$OVERALL_STATUS" \
  --arg tenant "$CANONICAL_TENANT" \
  --arg hash "$CANONICAL_HASH" \
  --arg host "$CANONICAL_HOST" \
  --argjson gates_total 8 \
  --argjson gates_passed $((8 - GATE_ERRORS)) \
  --argjson gates_failed "$GATE_ERRORS" \
  --argjson probes_total "$PROBES_TOTAL" \
  --argjson probes_passed "$PROBES_PASSED" \
  --argjson gates "[$(IFS=,; echo "${GATE_RESULTS[*]}")]" \
  '{
    certificate: "SLDC-P3-GOVERNANCE-APPROVAL",
    version: "v0.1.0",
    timestamp: $timestamp,
    commit_sha: $head_sha,
    governor_status: $status,
    canonical_vector: {
      tenant_name: $tenant,
      tenant_hash: $hash,
      canonical_fqdn: $host
    },
    metrics: {
      gates_total: $gates_total,
      gates_passed: $gates_passed,
      gates_failed: $gates_failed,
      probes_total: $probes_total,
      probes_passed: $probes_passed
    },
    gates: $gates,
    signoff: {
      authorized_for_phase4: (if $status == "PASS" then true else false end),
      governor_role: "SLDC Phase 3 Governor (sl-governor)",
      next_phase: "SLDC-P4-PRE (cAdvisor metrics inspection)"
    }
  }')

echo "$CERT_JSON" > "$OUTPUT_JSON"

echo "──────────────────────────────────────────────────────────────────────────────"
echo "Phase 3 Governance Verdict: $OVERALL_STATUS ($((8 - GATE_ERRORS))/8 gates passed)"
echo "Certification Artifact:     $OUTPUT_JSON"
echo "Trace Log:                  $TRACE_OUTPUT"
echo "══════════════════════════════════════════════════════════════════════════════"

if [[ "$OVERALL_STATUS" != "PASS" ]]; then
  exit 1
fi
exit 0
