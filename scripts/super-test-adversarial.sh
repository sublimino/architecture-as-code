#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/super-test-adversarial.sh: purple-team adversarial super-test runner
#
# @doc   docs/eap/SLDC-MISSION-CERTIFICATION.md
# @spec  schemas/eap-evidence-bundle-schema.json
# @lib   scripts/lib/cluster-reset-helpers.sh
#
# Runs adversarial probes and records what each actually observed. ADV-2, ADV-3
# and ADV-5 drive the real evidence packager and verifier offline. ADV-1 (token
# forgery) and ADV-4 (eBPF hooks) need a live cluster: pass them as commands in
# SUPERTEST_ADV1_CMD / SUPERTEST_ADV4_CMD (exit 0 = defence held). An absent
# probe is NOT_RUN and fails the verdict.
#
# Exit: 0 every probe ran and held; 1 a probe failed or did not run; 2 usage.
#
# Usage:
#   scripts/super-test-adversarial.sh [--run-all] [--out PATH]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

RUN_ALL=0
OUT_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-all) RUN_ALL=1 ;;
    --out) shift; OUT_FILE="${1:-}" ;;
    -h|--help)
      echo "Usage: scripts/super-test-adversarial.sh [--run-all] [--out PATH]"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[ -z "$OUT_FILE" ] && OUT_FILE="$REPO_ROOT/.evidence/coldstart-supertest-results.json"
mkdir -p "$(dirname "$OUT_FILE")"

FAILED_PROBES=0
TOTAL_PROBES=0
RESULTS_JSON="[]"

record_probe() {
  local id="$1"
  local name="$2"
  local expected="$3"
  local actual="$4"
  local status="$5"

  TOTAL_PROBES=$((TOTAL_PROBES + 1))
  if [ "$status" != "PASS" ]; then
    FAILED_PROBES=$((FAILED_PROBES + 1))
    printf '%s [%s] %s: expected %s, got %s\n' "$status" "$id" "$name" "$expected" "$actual" >&2
  else
    printf 'PASS [%s] %s: %s\n' "$id" "$name" "$actual"
  fi

  RESULTS_JSON="$(jq -c --arg id "$id" --arg name "$name" --arg exp "$expected" \
    --arg act "$actual" --arg st "$status" \
    '. + [{id: $id, name: $name, expected: $exp, actual: $act, status: $st}]' <<<"$RESULTS_JSON")"
}

echo "════ Adversarial Purple-Team Super-Test Runner ════"

# A probe is PASS only if it ran and the defence held. Offline probes drive the
# real evidence packager/verifier on fixture copies; live probes need a
# cluster and are injected commands, recorded NOT_RUN (and failing the
# verdict) when absent.
PACKAGE="${SUPERTEST_PACKAGE:-$REPO_ROOT/scripts/package-eap-evidence.sh}"
VERIFY="${SUPERTEST_VERIFY:-$REPO_ROOT/scripts/verify-eap-evidence.sh}"
FIXTURES="$REPO_ROOT/test/fixtures/eap-evidence"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
openssl genpkey -algorithm ed25519 -out "$WORK/key.pem" 2>/dev/null
openssl pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem"
export EAP_SIGNING_KEY="$WORK/key.pem" EAP_VERIFY_PUBKEY="$WORK/pub.pem"
export EAP_OPERATOR="super-test" EAP_CONTAINER_RUNTIME="super-test" SOURCE_DATE_EPOCH=1790726400

fresh_evidence() { # NAME -> prints a pristine fixture copy
  rm -rf "$WORK/$1" && mkdir -p "$WORK/$1" && cp "$FIXTURES"/* "$WORK/$1/" && printf '%s' "$WORK/$1"
}

# packager_refuses DIR MESSAGE: signing must fail, naming MESSAGE.
packager_refuses() {
  local out
  if out="$("$PACKAGE" --quiet --out "$WORK/out-$(basename "$1")" "$1" 2>&1)"; then
    echo "packager signed it"; return 1
  fi
  case "$out" in *"$2"*) echo "refused: $2" ;; *) echo "refused for another reason"; return 1 ;; esac
}

adv2_legacy_tenant() {
  local d; d="$(fresh_evidence adv2)"
  echo 'X-Tenant-ID: kurasi' >>"$d/step3-provocation-act.log"
  packager_refuses "$d" "legacy tenant 'kurasi'"
}

adv3_moving_counter() {
  local d; d="$(fresh_evidence adv3)"
  echo 'cadvisor_cpu_seconds: 0.18422 -> 0.20100' >>"$d/step5-cgroup-freeze.txt"
  packager_refuses "$d" "moving cAdvisor CPU counter"
}

adv5_tamper() {
  local d; d="$(fresh_evidence adv5)"
  "$PACKAGE" --quiet --out "$WORK/out-adv5" "$d" >/dev/null 2>&1 || { echo "control: packager refused pristine evidence"; return 1; }
  "$VERIFY" --quiet "$d" >/dev/null 2>&1 || { echo "control: verifier rejected untampered evidence"; return 1; }
  printf ' ' >>"$d/step4-ebpf-observation.json"
  if "$VERIFY" --quiet "$d" >/dev/null 2>&1; then echo "verifier accepted a tampered artifact"; return 1; fi
  echo "tampered artifact refused; untampered accepted"
}

probe() { # ID NAME EXPECTED FUNCTION-OR-COMMAND
  local id="$1" name="$2" expected="$3" cmd="$4" out rc
  if [ -z "$cmd" ]; then
    record_probe "$id" "$name" "$expected" "no probe command (live cluster required)" NOT_RUN
    return 0
  fi
  if [ "$(type -t "$cmd")" = function ]; then
    out="$("$cmd" 2>&1)" && rc=0 || rc=$?
  else
    out="$(bash -c "$cmd" 2>&1)" && rc=0 || rc=$?
  fi
  record_probe "$id" "$name" "$expected" "$(printf '%s' "$out" | tail -n 1)" "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)"
}

probe ADV-1 "SPIFFE Token Forgery Rejection" "HTTP 401" "${SUPERTEST_ADV1_CMD:-}"
probe ADV-2 "Legacy tenant kurasi fails closed (evidence contract)" "packager refuses" adv2_legacy_tenant
probe ADV-3 "Moving CPU counter is not a 0 mCPU flatline (evidence contract)" "packager refuses" adv3_moving_counter
probe ADV-4 "eBPF Tracepoint Hook Integrity" "4 hooks active" "${SUPERTEST_ADV4_CMD:-}"
probe ADV-5 "Forensic Evidence Tamper-Evidence" "tamper refused, control accepted" adv5_tamper

VERDICT="PASS"
[ "$FAILED_PROBES" -gt 0 ] && VERDICT="FAIL"

GIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat <<EOF >"$OUT_FILE"
{
  "timestamp": "$TIMESTAMP",
  "git_commit": "$GIT_SHA",
  "verdict": "$VERDICT",
  "total_probes": $TOTAL_PROBES,
  "failed_probes": $FAILED_PROBES,
  "probes": $RESULTS_JSON
}
EOF

echo "───────────────────────────────────────────────────"
echo "VERDICT: $VERDICT ($((TOTAL_PROBES - FAILED_PROBES))/$TOTAL_PROBES probes passed)"
echo "Artifact: $OUT_FILE"

if [ "$VERDICT" = "PASS" ]; then
  exit 0
else
  exit 1
fi
