#!/usr/bin/env bats
#
# Guards scripts/ci/user-surface-gate.sh — the post-deploy user-surface gate.
#
# ═══ What this suite is, and what it deliberately is not ════════════════════
#
# The gate exists because 29/29 PASS coexisted with two dead demos. So a suite
# that "tests the gate" carries an obvious hazard: if it were the only thing
# that ever ran, we would have rebuilt the original defect one level up — a
# green suite over a gate nobody points at the real estate.
#
# The split is therefore explicit and is the whole design:
#
#   THIS SUITE (offline, stubbed, both lanes)
#       proves the gate can TELL THE VERDICTS APART: that it goes green when
#       the surface works, red for each distinct way it can break, and that it
#       enumerates from the registry rather than a list. It proves the
#       instrument is calibrated.
#
#   THE LIVE STAGE (demo lane, real tailnet origin, post-deploy)
#       proves the PRODUCT works. Only that run is evidence about a demo.
#
# Nothing here may ever be cited as evidence that a demo works. Test 1 is the
# one that keeps this suite honest in the other direction: a gate that cannot
# pass is a gate that gets switched off, and a stuck-red instrument teaches the
# same lesson as a stuck-green one.
#
# The first draft of the gate WAS stuck red — jfield printed Python's `True`,
# which compares unequal to JSON `true`, so a fully working demo would have
# been reported BROKEN forever. Test 1 is what would have caught it.

GATE="${BATS_TEST_DIRNAME}/../scripts/ci/user-surface-gate.sh"
REGISTRY_TOOL="${BATS_TEST_DIRNAME}/../scripts/ci/demo-surface-registry.py"
STUB="${BATS_TEST_DIRNAME}/fixtures/user-surface-gate/stub-surface-server.py"

setup() {
  PORT=$(( 34000 + (RANDOM % 4000) ))
  BASE="http://127.0.0.1:${PORT}"
  STUB_PID=""
}

teardown() {
  [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null
  return 0
}

# Write a registry source with the given demo types, and start the stub with
# the given scenario. The registry is a REAL DEMO_CONFIGS shape so the
# extractor under test is genuinely parsing, not being handed a fixture list.
start_stub() {
  local scenario="$1"; shift
  printf '%s' "$scenario" > "$BATS_TEST_TMPDIR/scenario.json"
  python3 "$STUB" "$PORT" "$BATS_TEST_TMPDIR/scenario.json" &
  STUB_PID=$!
  local i=0
  while [ "$i" -lt 60 ]; do
    curl -s -o /dev/null --max-time 1 -X POST "${BASE}/dex/token" && return 0
    i=$(( i + 1 )); sleep 0.1
  done
  echo "stub server never came up on ${PORT}" >&2
  return 1
}

# $1..$n : demo types to declare in the generated registry.
#
# Writes BOTH halves of the contract: the server registry, and one SPA module
# per demo declaring the prefix that demo is called at. Both are needed because
# the gate now probes the CLIENT prefix — the two are not the same string, and
# assuming they were is what made this gate's first live run report SuperCred
# broken at a path no client uses.
write_registry() {
  {
    echo 'from types import MappingProxyType'
    echo 'DEMO_CONFIGS = MappingProxyType('
    echo '    {'
    for d in "$@"; do
      printf '        "%s": DemoConfig(\n' "$d"
      printf '            demo_type="%s",\n' "$d"
      printf '            label="%s",\n' "$d"
      printf '            default_script="scripts/%s-demo.sh",\n' "$d"
      printf '        ),\n'
    done
    echo '    }'
    echo ')'
  } > "$BATS_TEST_TMPDIR/demo_runner.py"

  mkdir -p "$BATS_TEST_TMPDIR/spa"
  for d in "$@"; do
    {
      printf '// all calls for this demo go to /api/demo/%s\n' "$d"
      printf "export const DEMO_API = '/api/demo/%s'\n" "$d"
    } > "$BATS_TEST_TMPDIR/spa/${d}Demo.ts"
  done
  echo "$BATS_TEST_TMPDIR/demo_runner.py"
}

# Drop a demo's SPA module, leaving the server half declaring a demo no client
# can reach.
orphan_client() {
  rm -f "$BATS_TEST_TMPDIR/spa/${1}Demo.ts"
}

run_gate() {
  local reg="$1"; shift
  REGISTRY_SOURCE="$reg" REGISTRY_TOOL="$REGISTRY_TOOL" \
    SPA_API_DIR="$BATS_TEST_TMPDIR/spa" \
    run "$GATE" --base-url "$BASE" "$@"
}

# ─── 1. The gate can pass. ──────────────────────────────────────────────────
@test "gate goes GREEN when every surface is healthy" {
  local reg; reg="$(write_registry supercred signalfusion)"
  start_stub '{"supercred":{"status":"healthy"},"signalfusion":{"status":"healthy"}}'
  run_gate "$reg"
  [ "$status" -eq 0 ]
  [[ "$output" == *"READY"* ]]
  [[ "$output" != *"BROKEN USER SURFACE"* ]]
}

# The regression test for the stuck-red defect described in the header: assert
# on the PARSED value, so a repr change cannot pass this by coincidence.
@test "a working surface reports script_available as JSON true, not Python True" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"healthy"}}'
  run_gate "$reg"
  [ "$status" -eq 0 ]
  [[ "$output" != *"script_available=True"* ]]
  [[ "$output" == *"script_available=true"* ]]
}

# ─── 2. Each way of being broken is a DISTINCT verdict. ─────────────────────
@test "200 with script_available=false is BROKEN, not a pass" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"incapable"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BROKEN"* ]]
  [[ "$output" == *"supercred"* ]]
  [[ "$output" == *"reports itself INCAPABLE"* ]]
}

@test "a 404 route is NOT_DEPLOYED, distinct from BROKEN" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NOT_DEPLOYED"* ]]
  [[ "$output" == *"NOT DEPLOYED"* ]]
}

@test "a 403 with a valid token is UNAUTHORIZED, distinct from NOT_DEPLOYED" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"forbidden"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"UNAUTHORIZED"* ]]
  [[ "$output" != *"NOT_DEPLOYED"* ]]
}

@test "a 503 on status is BROKEN and surfaces the server's error code" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"error503"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BROKEN"* ]]
  [[ "$output" == *"demo_root_unresolved"* ]]
}

@test "a capable runner advertising zero steps is BROKEN" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"nosteps"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no acts"* ]]
}

# ─── 3. Completion, not HTTP 200. ───────────────────────────────────────────
@test "--execute drives a run to terminal succeeded and passes" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"healthy"}}'
  run_gate "$reg" --execute
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal state: succeeded"* ]]
  [[ "$output" == *"ran step"* ]]
}

@test "--execute reports RAN_FAILED when a run starts and then fails" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"runfails"}}'
  run_gate "$reg" --execute
  [ "$status" -eq 1 ]
  [[ "$output" == *"RAN_FAILED"* ]]
  [[ "$output" == *"STARTED and did not complete"* ]]
}

# A demo that never terminates must fail, not hang the pipeline forever and
# not be quietly counted as passing.
@test "--execute fails a run that never reaches a terminal state" {
  local reg; reg="$(write_registry supercred)"
  start_stub '{"supercred":{"status":"runhangs"}}'
  USER_SURFACE_RUN_TIMEOUT=6 run_gate "$reg" --execute
  [ "$status" -eq 1 ]
  [[ "$output" == *"RAN_TIMEOUT"* ]]
}

# ─── 4. Enumeration is DERIVED — a new demo cannot be silently uncovered. ───
#
# This is the test that addresses the repeated root cause. A third demo is
# added to the registry ONLY. Nothing in the gate mentions it and no scenario
# serves it. If the gate carried a hand-written list it would probe two
# surfaces, find them healthy and exit 0. It must instead discover the third
# and fail on it.
@test "a demo added to the registry alone is probed and FAILS the gate" {
  local reg; reg="$(write_registry supercred signalfusion newdemo)"
  start_stub '{"supercred":{"status":"healthy"},"signalfusion":{"status":"healthy"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Enumerated 3 demo surface(s)"* ]]
  [[ "$output" == *"newdemo"* ]]
  [[ "$output" == *"NOT_DEPLOYED"* ]]
}

@test "the registry extractor reads the real shipped demo_runner registry" {
  run python3 "$REGISTRY_TOOL" \
    "${BATS_TEST_DIRNAME}/../d2-signalloom/apps/fe-signalloom/src/demo_runner.py"
  [ "$status" -eq 0 ]
  [[ "$output" == *"supercred"* ]]
  [[ "$output" == *"signalfusion"* ]]
}

# ─── 4b. The CLIENT half of the contract. ───────────────────────────────────
#
# Regression test for a false verdict this gate produced against the live lane.
# It probed the SERVER prefix for every demo, so SuperCred was reported BROKEN
# at /api/demo/supercred — a path no client calls, which routes to
# fe-signalloom, which has no demo scripts BY DESIGN. The demo was fine at the
# path a human actually uses.
#
# The two prefixes are genuinely different per demo and must be read from the
# SPA, never assumed. Asserting the exact strings is the point: a change that
# silently unified them would restore the false verdict.
@test "the real SPA prefixes are read per-demo and are NOT the server prefix" {
  run python3 "$REGISTRY_TOOL" \
    "${BATS_TEST_DIRNAME}/../d2-signalloom/apps/fe-signalloom/src/demo_runner.py" \
    "${BATS_TEST_DIRNAME}/../d2-signalloom/apps/dashboard-signalloom/src/api"
  [ "$status" -eq 0 ]
  [[ "$output" == *"supercred"*$'\t'"/demo-api"* ]]
  [[ "$output" == *"signalfusion"*$'\t'"/api/demo/signalfusion"* ]]
}

# Regression: the client↔demo linkage must not depend on a COMMENT.
#
# The first version matched a SPA module to a demo by finding the literal
# `/api/demo/<type>` in its text — a string that, in the real modules, lives
# only in doc comments describing the nginx rewrite. Measured against the
# in-flight signalfusion fix written two ways, identical WORKING code resolved
# to `/demo-api/signalfusion` with the comment and to NOTHING without it. The
# second would have reported a correctly-fixed demo as NO_CLIENT_PATH.
#
# So this fixture mentions the server path NOWHERE. Only the filename carries
# the demo token, which is what no prose edit can remove.
@test "client prefix resolves with no server path anywhere in the module" {
  local reg; reg="$(write_registry signalfusion)"
  cat > "$BATS_TEST_TMPDIR/spa/signalFusionDemo.ts" <<'EOF'
/** All signal-fusion calls go through this prefix. */
const SF_DEMO_API = '/demo-api/signalfusion'
EOF
  rm -f "$BATS_TEST_TMPDIR/spa/signalfusionDemo.ts"
  run python3 "$REGISTRY_TOOL" "$reg" "$BATS_TEST_TMPDIR/spa"
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\t'"/demo-api/signalfusion" ]]
  [[ "$output" != *"/api/demo/signalfusion" ]]
}

# A demo the server serves and no client calls is unreachable from the UI.
# Each half's own tests are green about its own side; only comparing them sees
# it, which is exactly the blind spot that produced this whole slice.
@test "a demo with no client module is NO_CLIENT_PATH, not silently skipped" {
  local reg; reg="$(write_registry supercred signalfusion)"
  orphan_client signalfusion
  start_stub '{"supercred":{"status":"healthy"},"signalfusion":{"status":"healthy"}}'
  run_gate "$reg"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NO_CLIENT_PATH"* ]]
  [[ "$output" == *"NO client module calls it"* ]]
}

# ─── 5. The gate refuses to run rather than passing vacuously. ──────────────
@test "an unparseable registry is a hard stop, never an empty green run" {
  echo 'DEMO_CONFIGS = some_function_call()' > "$BATS_TEST_TMPDIR/bad.py"
  start_stub '{}'
  run_gate "$BATS_TEST_TMPDIR/bad.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"GATE CANNOT RUN"* ]]
}

@test "a registry with zero demos is a hard stop, not a pass over an empty set" {
  printf 'DEMO_CONFIGS = {}\n' > "$BATS_TEST_TMPDIR/empty.py"
  start_stub '{}'
  run_gate "$BATS_TEST_TMPDIR/empty.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"zero demos"* ]]
}

# Distinguishing this from a product outage is the difference between an
# operator trusting the gate and learning to ignore it.
@test "an unmintable token is CANNOT-RUN (exit 2), not every-demo-broken" {
  local reg; reg="$(write_registry supercred signalfusion)"
  start_stub '{"_dex":"down","supercred":{"status":"healthy"}}'
  run_gate "$reg"
  [ "$status" -eq 2 ]
  [[ "$output" == *"could not mint a Dex token"* ]]
  [[ "$output" != *"BROKEN USER SURFACE"* ]]
}

@test "no base URL is a hard stop with no localhost default" {
  local reg; reg="$(write_registry supercred)"
  REGISTRY_SOURCE="$reg" run "$GATE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no base URL"* ]]
}

# ─── 6. The live stage points at the real origin, not a port-forward. ───────
#
# The gate is only as good as where it is aimed. The pipeline stage must pass a
# tailnet origin; a 127.0.0.1 or localhost base URL there would reproduce the
# exact blind spot the gate was built to remove.
@test "the demo-pipeline stage aims the gate at a tailnet origin" {
  local pipeline="${BATS_TEST_DIRNAME}/../scripts/gcp-tf/demo-pipeline.sh"
  run grep -n 'user-surface-gate.sh' "$pipeline"
  [ "$status" -eq 0 ]
  local line
  line="$(grep -A3 'user-surface-gate.sh' "$pipeline")"
  [[ "$line" != *"127.0.0.1"* ]]
  [[ "$line" != *"localhost"* ]]
}
