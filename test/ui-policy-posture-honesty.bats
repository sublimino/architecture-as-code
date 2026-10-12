#!/usr/bin/env bats
# Policy Posture & Risk window: money must come from the backend or not be shown.
#
# The window used to bare-catch every /api/compliance/* failure and render a
# hardcoded demo dataset (ALE £48,200 / VaR95 £192,800 and 20 per-control ALEs).
# No such route is served, so the fabricated figures were on 100% of requests.
# It also rendered VaR95 x 1.15 under the caption "TVaR + risk load", which is a
# different computation from the documented TVaR x 1.15.
#
# These tests render the window headlessly via test/helpers/estate95-window-harness.mjs.

setup() {
  root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  harness="$root/test/helpers/estate95-window-harness.mjs"
  window="$root/ui/windows/policy-posture.js"
  [ -f "$harness" ] || skip "harness missing"
  [ -f "$window" ] || skip "window missing"
  command -v node >/dev/null || skip "node not installed"
}

render() { # render <scenario-json-file>
  node "$harness" "$window" "$1"
}

write_unserved_scenario() {
  cat >"$BATS_TEST_TMPDIR/unserved.json" <<'JSON'
{ "getDefault": { "status": 404, "error": "no route /api/compliance/* is served" } }
JSON
}

write_live_scenario() { # live summary + checks, VaR95 totals 200000
  cat >"$BATS_TEST_TMPDIR/live.json" <<'JSON'
{
  "get": {
    "/api/compliance/summary": { "ok": {
      "totalControls": 40, "totalPassed": 33, "totalAle": 11111, "totalVar95": 200000,
      "frameworks": [
        { "id": "eu-ai-act", "name": "EU AI Act", "version": "v9.9", "controls": 40, "passed": 33, "ale": 11111, "var95": 200000 }
      ]
    } },
    "/api/compliance/checks": { "ok": [
      { "name": "Live control from the backend", "framework": "EU AI Act", "status": "fail", "ale": 7777 }
    ] }
  }
}
JSON
}

write_live_with_carried_scenario() {
  cat >"$BATS_TEST_TMPDIR/carried.json" <<'JSON'
{
  "get": {
    "/api/compliance/summary": { "ok": {
      "totalControls": 40, "totalPassed": 33, "totalAle": 11111, "totalVar95": 200000,
      "carried": 362501, "carriedBasis": "TVaR95 x 1.15 risk load",
      "frameworks": []
    } },
    "/api/compliance/checks": { "ok": [] }
  }
}
JSON
}

@test "policy-posture: refuses when no /api/compliance route is served" {
  write_unserved_scenario
  run render "$BATS_TEST_TMPDIR/unserved.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qiE "not served|unavailable|could not load"
}

@test "policy-posture: serves no fabricated money when the route is not served" {
  write_unserved_scenario
  run render "$BATS_TEST_TMPDIR/unserved.json"
  [ "$status" -eq 0 ]
  for fabricated in "48,200" "192,800" "35,100" "140,400" "12,400" "49,600" "8,900" "35,600" "481,160"; do
    if echo "$output" | grep -qF "$fabricated"; then
      echo "fabricated figure $fabricated rendered with no backend" >&2
      return 1
    fi
  done
}

@test "policy-posture: serves no fabricated control rows when the route is not served" {
  write_unserved_scenario
  run render "$BATS_TEST_TMPDIR/unserved.json"
  [ "$status" -eq 0 ]
  for row in "Bias testing on protected attrs" "AU-6 Audit review" "SBOM provided to downstream" "NIST 800-53" "DORA"; do
    if echo "$output" | grep -qF "$row"; then
      echo "fabricated control row '$row' rendered with no backend" >&2
      return 1
    fi
  done
}

@test "policy-posture: renders backend figures when the route IS served" {
  write_live_scenario
  run render "$BATS_TEST_TMPDIR/live.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "11,111"
  echo "$output" | grep -qF "200,000"
  echo "$output" | grep -qF "Live control from the backend"
}

@test "policy-posture: carried is never derived client-side from VaR95" {
  write_live_scenario
  run render "$BATS_TEST_TMPDIR/live.json"
  [ "$status" -eq 0 ]
  # 200000 * 1.15 = 230000. No TVaR is computed anywhere, so this must not appear.
  if echo "$output" | grep -qF "230,000"; then
    echo "carried was derived as VaR95 x 1.15 client-side" >&2
    return 1
  fi
  echo "$output" | grep -qiE "carried.*(unavailable|no tvar)|(unavailable|no tvar).*carried"
}

@test "policy-posture: carried is shown only with a backend value and its basis" {
  write_live_with_carried_scenario
  run render "$BATS_TEST_TMPDIR/carried.json"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "362,501"
  echo "$output" | grep -qiF "TVaR95 x 1.15 risk load"
}

@test "policy-posture: module source carries no hardcoded money and no 1.15 factor" {
  run grep -nE '1\.15|48200|192800|35100|140400|12400|49600|8900|35600|DEMO_FRAMEWORKS|DEMO_CHECKS' "$window"
  [ "$status" -ne 0 ] || {
    echo "$output" >&2
    return 1
  }
}
