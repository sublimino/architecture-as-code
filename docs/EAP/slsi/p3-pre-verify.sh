#!/usr/bin/env bash
# docs/EAP/slsi/p3-pre-verify.sh — Verification script for SLSI Phase 3 Preflight
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"

CONTRACT_JSON="docs/EAP/slsi/p3-pre-contract.json"
PROPOSAL="docs/Proposal — SLSI Signal Loom Design Partner Appliance Self-Initialisation Pipeline (2026-Q4).md"

usage() {
  echo "Usage: $0 [--strict | --citations | --all]"
  exit 1
}

run_strict() {
  echo "=== Running SLSI P3-PRE Strict Reproducibility Audit ==="
  [[ -f "$CONTRACT_JSON" ]] || { echo "FAIL: $CONTRACT_JSON not found"; exit 1; }

  local total failed=0 passed=0
  total=$(jq '.capabilities | length' "$CONTRACT_JSON")

  for i in $(seq 0 $((total - 1))); do
    local cap verdict proof
    cap=$(jq -r ".capabilities[$i].capability" "$CONTRACT_JSON")
    verdict=$(jq -r ".capabilities[$i].verdict" "$CONTRACT_JSON")
    proof=$(jq -r ".capabilities[$i].proof" "$CONTRACT_JSON")

    printf "  [%s] %s ... " "$verdict" "$cap"
    if eval "$proof" >/dev/null 2>&1; then
      echo "OK"
      passed=$((passed + 1))
    else
      echo "FAIL (proof exited non-zero)"
      failed=$((failed + 1))
    fi
  done

  echo "Strict verification complete: $passed passed, $failed failed (total $total)."
  [[ $failed -eq 0 ]] || exit 1
}

run_citations() {
  echo "=== Running SLSI P3-PRE Citation Resolution Audit ==="
  [[ -f "$CONTRACT_JSON" ]] || { echo "FAIL: $CONTRACT_JSON not found"; exit 1; }

  local failed=0 passed=0

  # Check all citations in requiredSource fields that contain file:line patterns
  while IFS= read -r citation; do
    [[ -z "$citation" ]] && continue
    local file line
    file="${citation%%:*}"
    line="${citation##*:}"

    if [[ ! -f "$file" ]]; then
      echo "FAIL: Citation file does not exist: $file (from $citation)"
      failed=$((failed + 1))
      continue
    fi

    local max_lines
    max_lines=$(wc -l < "$file")
    if (( line < 1 || line > max_lines )); then
      echo "FAIL: Line $line out of range (1..$max_lines) in $file"
      failed=$((failed + 1))
    else
      passed=$((passed + 1))
    fi
  done < <(jq -r '.capabilities[].requiredSource | scan("[a-zA-Z0-9_./-]+:[0-9]+")' "$CONTRACT_JSON" | sort -u)

  echo "Citation verification complete: $passed citations verified, $failed failed."
  [[ $failed -eq 0 ]] || exit 1
}

main() {
  local mode="all"
  if [[ $# -gt 0 ]]; then
    case "$1" in
      --strict) mode="strict" ;;
      --citations) mode="citations" ;;
      --all) mode="all" ;;
      *) usage ;;
    esac
  fi

  case "$mode" in
    strict) run_strict ;;
    citations) run_citations ;;
    all)
      run_strict
      run_citations
      ;;
  esac
}

main "$@"
