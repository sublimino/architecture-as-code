#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/verify-teardown-prereqs.sh: verify host readiness for cold teardown and scratch standup
#
# @doc   docs/eap/SLDC-P6-PREFLIGHT.md
# @spec  test/fixtures/cold-start-manifests.tsv
# @lib   scripts/lib/cluster-reset-helpers.sh
#
# Usage:
#   scripts/verify-teardown-prereqs.sh [--dry-run] [--out PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=scripts/lib/cluster-reset-helpers.sh
source "$SCRIPT_DIR/lib/cluster-reset-helpers.sh"
# shellcheck source=scripts/lib/keys.sh
source "$SCRIPT_DIR/lib/keys.sh"

DRY_RUN=0
OUT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --out) shift; OUT_FILE="${1:-}" ;;
    -h|--help)
      echo "Usage: scripts/verify-teardown-prereqs.sh [--dry-run] [--out PATH]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -z "$OUT_FILE" ] && OUT_FILE="$REPO_ROOT/.evidence/phase6-preflight-readiness.json"

FAILED_CHECKS=0
TOTAL_CHECKS=0

check_pass() {
  local name="$1"
  local detail="${2:-}"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  printf 'OK   %s%s\n' "$name" "${detail:+ ($detail)}"
}

check_fail() {
  local name="$1"
  local detail="${2:-}"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  printf 'FAIL %s%s\n' "$name" "${detail:+ ($detail)}" >&2
}

echo "════ Phase 6 Teardown and Cold-Start Pre-Flight Verification ════"

# 1. Docker daemon check
DOCKER_VER="unavailable"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "unknown")"
  check_pass "Docker daemon socket accessible" "version: $DOCKER_VER"
else
  check_fail "Docker daemon socket accessible" "unable to communicate with /var/run/docker.sock"
fi

# 2. Kind binary check
KIND_VER="unavailable"
if command -v kind >/dev/null 2>&1; then
  KIND_VER="$(kind version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")"
  check_pass "Kind CLI available" "version: $KIND_VER"
else
  check_fail "Kind CLI available" "kind executable not found in PATH"
fi

# 3. cgroup v2 hierarchy
CGROUP_VER="1"
if check_cgroup_v2_status; then
  CGROUP_VER="2"
  check_pass "cgroup v2 hierarchy active" "version: 2"
else
  check_fail "cgroup v2 hierarchy active" "host operating under cgroup v1 or cgroups unavailable"
fi

# 4. Cryptographic signing keys
KEYS_DIR="$(keys_dir_abs "$REPO_ROOT")"
if [ -r "$KEYS_DIR/cosign.key" ] && [ -r "$KEYS_DIR/cosign.pub" ] && [ -r "$KEYS_DIR/witness.pem" ]; then
  check_pass "Cryptographic signing keys intact" "dir: $KEYS_DIR"
else
  check_fail "Cryptographic signing keys intact" "missing or unreadable keys in $KEYS_DIR"
fi

# 5. Disk space check (require >= 5GB free)
AVAIL_KB=0
if command -v df >/dev/null 2>&1; then
  AVAIL_KB="$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")"
  if [ "$AVAIL_KB" -gt 5242880 ]; then
    check_pass "Disk space adequate" "$((AVAIL_KB / 1024 / 1024)) GB available"
  else
    check_fail "Disk space adequate" "less than 5 GB available ($((AVAIL_KB / 1024)) MB)"
  fi
fi

# 6. Phase 5 forensic evidence bundle
EAP_TAR="$REPO_ROOT/.evidence/eap-kusari-containment.tar.gz"
EAP_SIG="$REPO_ROOT/.evidence/audit-signature.sha256"
if [ -f "$EAP_TAR" ] && [ -f "$EAP_SIG" ]; then
  check_pass "Phase 5 forensic evidence bundle preserved" "$(basename "$EAP_TAR")"
else
  check_fail "Phase 5 forensic evidence bundle preserved" "bundle or signature missing in .evidence/"
fi

# 7. Zot cache status
ZOT_DIR="$REPO_ROOT/.cache/zot"
check_pass "Zot OCI registry cache inspected" "$(check_zot_cache_status "$REPO_ROOT")"

# 8. Manifest catalog
CATALOG="$REPO_ROOT/test/fixtures/cold-start-manifests.tsv"
if [ -f "$CATALOG" ]; then
  CATALOG_COUNT="$(grep -c -v '^component' "$CATALOG" || echo "0")"
  check_pass "Cold-start manifest catalog ready" "$CATALOG_COUNT components declared"
else
  check_fail "Cold-start manifest catalog ready" "catalog missing at $CATALOG"
fi

VERDICT="PASS"
[ "$FAILED_CHECKS" -gt 0 ] && VERDICT="FAIL"

mkdir -p "$(dirname "$OUT_FILE")"
mkdir -p "$REPO_ROOT/ci-evidence"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat <<EOF >"$OUT_FILE"
{
  "timestamp": "$TIMESTAMP",
  "git_commit": "$GIT_SHA",
  "verdict": "$VERDICT",
  "dry_run": $([ "$DRY_RUN" = "1" ] && echo "true" || echo "false"),
  "total_checks": $TOTAL_CHECKS,
  "failed_checks": $FAILED_CHECKS,
  "tools": {
    "docker": "$DOCKER_VER",
    "kind": "$KIND_VER",
    "cgroup_version": "$CGROUP_VER",
    "signing_keys_dir": "$KEYS_DIR"
  },
  "evidence": {
    "bundle_present": $([ -f "$EAP_TAR" ] && echo "true" || echo "false"),
    "signature_present": $([ -f "$EAP_SIG" ] && echo "true" || echo "false")
  }
}
EOF

# Duplicate to ci-evidence as well for permanent audit retention
cp "$OUT_FILE" "$REPO_ROOT/ci-evidence/phase6-preflight-readiness.json"

echo "─────────────────────────────────────────────────────────────"
echo "VERDICT: $VERDICT ($((TOTAL_CHECKS - FAILED_CHECKS))/$TOTAL_CHECKS passed)"
echo "Artifact: $OUT_FILE"

if [ "$VERDICT" = "PASS" ]; then
  exit 0
else
  exit 1
fi
