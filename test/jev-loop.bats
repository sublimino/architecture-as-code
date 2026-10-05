#!/usr/bin/env bats
#
# The Jev exploration loop, offline.
#
# This suite exists because every interesting failure mode of an exploratory
# test bot is SILENT. A run that walked one page reports PASS exactly like a
# run that walked forty. A coverage report built from a trimmed route list
# reports 100% of the list it was given. A loop that grabbed port 8080 does not
# fail — it quietly tests, or breaks, whatever a sibling suite had there.
#
# So the three things pinned here are the three that cannot be eyeballed:
#
#   1. a two-iteration run accounts for EVERY derived route as visited or
#      unvisited, with nothing falling between the two lists
#   2. a deliberately trimmed route list FAILS the coverage assertion rather
#      than passing against its own narrower definition of "everything"
#   3. the port chosen is outside every range the other suites reserve
#
# Runs with MOCK=true and no network: the bot falls back to its calibrated
# simulator, and the dashboard is served by spa-server.py from the app's real
# index.html, so no TypeSafe call, no npm install, and no backend are needed.
#
# Each test gets its own run-id and its own reports root under BATS_TEST_TMPDIR,
# so these never collide with a developer's reports/jev/ or with each other.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  loop="$root/scripts/jev-test-bot/loop.sh"
  routes="$root/scripts/jev-test-bot/routes.py"
  reports_root="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_root"
}

# jq is not a dependency of this repo's test environment; python3 is (bot.py is
# python). Reading JSON through python keeps the suite runnable wherever the
# bot itself is.
json_get() {
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    doc = doc[int(key)] if key.isdigit() else doc[key]
print(json.dumps(doc) if isinstance(doc, (list, dict)) else doc)
' "$1" "$2"
}

@test "JEVLOOP the loop and its helpers are executable and parse" {
  [ -x "$loop" ]
  run bash -n "$loop"
  [ "$status" -eq 0 ]
  run python3 -m py_compile \
    "$root/scripts/jev-test-bot/routes.py" \
    "$root/scripts/jev-test-bot/loop_report.py" \
    "$root/scripts/jev-test-bot/spa-server.py" \
    "$root/scripts/jev-test-bot/bot.py"
  [ "$status" -eq 0 ]
}

# ── 1. Two iterations, full coverage accounting ────────────────────────────

@test "JEVLOOP two iterations against the local dashboard account for every route and exit 0" {
  run env -u JEV_REPORTS_DIR timeout 900 "$loop" \
    --mock --iterations 2 --turns 2 --timeout 5 \
    --reports-dir "$reports_root" --run-id two-iterations
  echo "$output"
  [ "$status" -eq 0 ]

  run_dir="$reports_root/two-iterations"
  [ -f "$run_dir/iteration-1.json" ]
  [ -f "$run_dir/iteration-2.json" ]
  [ -f "$run_dir/summary.json" ]

  # The derived surface is the yardstick, not the loop's own copy of it: if
  # routes.txt were silently truncated, comparing the report against routes.txt
  # would still agree with itself.
  derived_count="$(python3 "$routes" | wc -l | tr -d ' ')"
  [ "$derived_count" -gt 20 ]

  for iteration in 1 2; do
    report="$run_dir/iteration-$iteration.json"

    total="$(json_get "$report" routes_total)"
    [ "$total" -eq "$derived_count" ]

    visited_count="$(json_get "$report" routes_visited_count)"
    unvisited_count="$(json_get "$report" routes_unvisited_count)"

    # No route may fall between the two lists. This is the assertion the
    # report's own exit code 4 also guards, checked here from the outside.
    [ "$((visited_count + unvisited_count))" -eq "$total" ]

    # And every individual derived route must appear in one of them by name —
    # equal counts could still be two different sets.
    run python3 -c '
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
derived = subprocess.run([sys.executable, sys.argv[2]], capture_output=True, text=True, check=True)
want = [r for r in derived.stdout.splitlines() if r.strip()]
accounted = set(report["routes_visited"]) | set(report["routes_unvisited"])
missing = [r for r in want if r not in accounted]
if missing:
    print("unaccounted routes:", missing)
    sys.exit(1)
overlap = set(report["routes_visited"]) & set(report["routes_unvisited"])
if overlap:
    print("routes counted as both visited and unvisited:", sorted(overlap))
    sys.exit(1)
print("accounted", len(accounted))
' "$report" "$routes"
    echo "$output"
    [ "$status" -eq 0 ]

    # The coverage keys a reader actually consults must be present and typed.
    run json_get "$report" path_status
    [ "$status" -eq 0 ]
    run json_get "$report" console_errors_observable
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]
  done

  # Offline against the app shell every route answers, so this run should in
  # fact have covered the lot. Asserted separately from the accounting above:
  # the accounting must hold even on a run that covers nothing.
  [ "$(json_get "$run_dir/iteration-1.json" routes_unvisited_count)" -eq 0 ]
  [ "$(json_get "$run_dir/summary.json" iterations)" -eq 2 ]
  [ "$(json_get "$run_dir/summary.json" routes_never_visited)" = "[]" ]
  [ "$(json_get "$run_dir/summary.json" passed)" = "True" ]
}

@test "JEVLOOP the run leaves no scratch behind and no server running" {
  run env -u JEV_REPORTS_DIR timeout 900 "$loop" \
    --mock --iterations 1 --turns 2 --timeout 5 \
    --reports-dir "$reports_root" --run-id teardown
  [ "$status" -eq 0 ]

  run_dir="$reports_root/teardown"
  # Evidence survives...
  [ -f "$run_dir/summary.json" ]
  [ -f "$run_dir/routes.txt" ]
  # ...scratch does not.
  [ ! -d "$run_dir/tmp" ]
  [ ! -d "$run_dir/browser-profile" ]

  # Nothing is still listening on the port the run used. Matching on the port
  # rather than on a command pattern deliberately: a pgrep pattern typed into
  # a bats test also appears in that test's own command line.
  port="$(json_get "$run_dir/iteration-1.json" dashboard.port)"
  run python3 -c '
import socket, sys
with socket.socket() as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", int(sys.argv[1])))
    except OSError as exc:
        print("port still held:", exc)
        sys.exit(1)
print("port free")
' "$port"
  echo "$output"
  [ "$status" -eq 0 ]
}

# The run above covers every route, because offline every path answers 200
# from the app shell. That makes it structurally blind to the unvisited side of
# the partition: with `unvisited` hardcoded to [] the suite stayed green, since
# [] is also the correct answer for that input. So the aggregator is driven
# directly with a route that has no report, which is what a real gap looks like
# — a bot run that crashed, timed out, or was never dispatched for a page.
@test "JEVLOOP a route with no bot report is reported unvisited, not quietly dropped" {
  areas="$BATS_TEST_TMPDIR/gap-areas"
  mkdir -p "$areas"
  routes_file="$BATS_TEST_TMPDIR/gap-routes.txt"
  printf '/agents\n/risk\n/never-explored\n' >"$routes_file"

  # One bot report, covering two of the three routes.
  cat >"$areas/001-agents.json" <<'JSON'
{
  "area_scope": "/agents",
  "turns_executed": 2,
  "duration_seconds": 0.1,
  "visited_paths": ["/agents", "/risk"],
  "path_status": {"/agents": 200, "/risk": 200},
  "defects": [],
  "defects_count": 0,
  "passed": true,
  "mode": "simulated_jev"
}
JSON

  out="$BATS_TEST_TMPDIR/gap-iteration.json"
  run python3 "$root/scripts/jev-test-bot/loop_report.py" iteration \
    --routes "$routes_file" --area-reports "$areas" --out "$out" \
    --run-id gap --iteration 1
  echo "$output"
  [ "$status" -eq 0 ]

  [ "$(json_get "$out" routes_total)" -eq 3 ]
  [ "$(json_get "$out" routes_visited_count)" -eq 2 ]
  [ "$(json_get "$out" routes_unvisited_count)" -eq 1 ]
  [ "$(json_get "$out" routes_unvisited)" = '["/never-explored"]' ]
  # The gap must be named, not merely counted.
  [[ "$(json_get "$out" routes_visited)" == *"/agents"* ]]
  [[ "$(json_get "$out" routes_visited)" != *"/never-explored"* ]]
}

@test "JEVLOOP a defective route surfaces as a bug and the iteration does not pass" {
  areas="$BATS_TEST_TMPDIR/bug-areas"
  mkdir -p "$areas"
  routes_file="$BATS_TEST_TMPDIR/bug-routes.txt"
  printf '/risk\n' >"$routes_file"

  cat >"$areas/001-risk.json" <<'JSON'
{
  "area_scope": "/risk",
  "visited_paths": ["/risk"],
  "path_status": {"/risk": 500},
  "defects": [
    {"category": "HTTP_5XX_SERVER_ERROR", "message": "HTTP 500 server error",
     "url": "http://127.0.0.1:41000/risk", "details": {"status_code": 500}}
  ],
  "defects_count": 1,
  "passed": false,
  "mode": "simulated_jev"
}
JSON

  out="$BATS_TEST_TMPDIR/bug-iteration.json"
  run python3 "$root/scripts/jev-test-bot/loop_report.py" iteration \
    --routes "$routes_file" --area-reports "$areas" --out "$out" --iteration 1
  [ "$status" -eq 0 ]
  [ "$(json_get "$out" bug_count)" -eq 1 ]
  [ "$(json_get "$out" passed)" = "False" ]
  # Classified, so a reader can tell an HTTP failure from an unreachable host.
  [ "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d["http_errors"]), len(d["network_errors"]), len(d["crash_errors"]))' "$out")" = "1 0 0" ]
  # The bug must carry which area found it, or a 40-route run cannot be triaged.
  [[ "$(json_get "$out" bugs.0.area)" = "/risk" ]]
}

@test "JEVLOOP an unreadable bot report fails the iteration rather than vanishing" {
  areas="$BATS_TEST_TMPDIR/broken-areas"
  mkdir -p "$areas"
  routes_file="$BATS_TEST_TMPDIR/broken-routes.txt"
  printf '/agents\n' >"$routes_file"
  printf 'this is not json' >"$areas/001-agents.json"

  out="$BATS_TEST_TMPDIR/broken-iteration.json"
  run python3 "$root/scripts/jev-test-bot/loop_report.py" iteration \
    --routes "$routes_file" --area-reports "$areas" --out "$out" --iteration 1
  [ "$status" -eq 0 ]
  # A bot that died mid-write is a fact about the run, not something to skip.
  [ "$(json_get "$out" passed)" = "False" ]
  [ "$(json_get "$out" routes_unvisited_count)" -eq 1 ]
}

# ── 2. A broken route list must fail, not pass against itself ──────────────

@test "JEVLOOP a trimmed route list fails the coverage assertion with exit 4" {
  trimmed="$BATS_TEST_TMPDIR/trimmed-routes.txt"
  printf '/agents\n/risk\n' >"$trimmed"

  run env -u JEV_REPORTS_DIR timeout 300 "$loop" \
    --mock --turns 1 --timeout 5 --routes-from "$trimmed" \
    --reports-dir "$reports_root" --run-id trimmed
  echo "$output"
  [ "$status" -eq 4 ]
  [[ "$output" == *"does not cover the derived application surface"* ]]
  # The message must name what is missing, or the failure is unactionable.
  [[ "$output" == *"/compliance"* ]]

  # And it must fail BEFORE starting a dashboard — a coverage defect should
  # cost a second, not a server boot.
  [[ "$output" != *"dashboard ready"* ]]
}

@test "JEVLOOP a route list dropping exactly one page still fails" {
  # The two-route case above could pass by accident on a crude length check.
  # Dropping a single route is the realistic regression: someone adds a page
  # and the list is one short.
  full="$BATS_TEST_TMPDIR/one-short.txt"
  python3 "$routes" | head -n -1 >"$full"
  dropped="$(python3 "$routes" | tail -n 1)"
  [ -n "$dropped" ]

  run env -u JEV_REPORTS_DIR timeout 300 "$loop" \
    --mock --turns 1 --timeout 5 --routes-from "$full" \
    --reports-dir "$reports_root" --run-id one-short
  echo "$output"
  [ "$status" -eq 4 ]
  [[ "$output" == *"$dropped"* ]]
}

@test "JEVLOOP a narrower walk is possible only by asking for it explicitly" {
  trimmed="$BATS_TEST_TMPDIR/explicit-partial.txt"
  printf '/agents\n/risk\n' >"$trimmed"

  run env -u JEV_REPORTS_DIR timeout 300 "$loop" \
    --mock --turns 1 --timeout 5 --routes-from "$trimmed" --allow-partial \
    --reports-dir "$reports_root" --run-id explicit-partial
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--allow-partial was given"* ]]
  [ "$(json_get "$reports_root/explicit-partial/iteration-1.json" routes_total)" -eq 2 ]
}

# ── 3. The port must be outside every reserved range ──────────────────────

@test "JEVLOOP the chosen port is outside every reserved range" {
  # Sampled rather than checked once: the port is drawn at random from a
  # window, and a single draw proves almost nothing about the policy.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    run "$loop" --print-port
    [ "$status" -eq 0 ]
    port="$output"
    [[ "$port" =~ ^[0-9]+$ ]]
    [ "$port" -ge 1024 ]
    # 8080-8099 port-forwards, 8200 OpenBao, 5001 registry,
    # 18080-18099 secondary port-forwards, 30754 the dashboard NodePort.
    [ "$port" -ne 8200 ]
    [ "$port" -ne 5001 ]
    [ "$port" -ne 30754 ]
    if [ "$port" -ge 8080 ]; then [ "$port" -gt 8099 ]; fi
    if [ "$port" -ge 18080 ]; then [ "$port" -gt 18099 ]; fi
  done
}

@test "JEVLOOP the reserved-port policy rejects every reserved value it claims to" {
  # Exercises the predicate directly, so the policy is pinned even on a day
  # when the random window happens never to draw near a reserved range.
  for reserved in 80 443 1023 5001 8080 8090 8099 8200 18080 18090 18099 30754; do
    run bash -c 'source "$1" --print-port >/dev/null 2>&1; port_is_reserved "$2"' _ "$loop" "$reserved"
    # port_is_reserved returns 0 for reserved. Sourcing the script runs main,
    # so it is invoked through a subshell that discards that output.
    [ "$status" -eq 0 ] || { echo "port $reserved was NOT treated as reserved"; false; }
  done

  for allowed in 41000 42500 44999; do
    run bash -c 'source "$1" --print-port >/dev/null 2>&1; port_is_reserved "$2"' _ "$loop" "$allowed"
    [ "$status" -eq 1 ] || { echo "port $allowed was wrongly treated as reserved"; false; }
  done
}

@test "JEVLOOP the run reports the port it used and it is in the search window" {
  run env -u JEV_REPORTS_DIR timeout 900 "$loop" \
    --mock --iterations 1 --turns 1 --timeout 5 \
    --reports-dir "$reports_root" --run-id port-report
  [ "$status" -eq 0 ]
  port="$(json_get "$reports_root/port-report/iteration-1.json" dashboard.port)"
  [ "$port" -ge 41000 ]
  [ "$port" -le 44999 ]
  [ "$(json_get "$reports_root/port-report/iteration-1.json" dashboard.started_locally)" = "True" ]
}
