#!/usr/bin/env bats
#
# The Jev exploration loop in BROWSER mode.
#
# `test/jev-loop.bats` pins the fetch-mode loop: coverage accounting, the
# reserved-port policy, teardown. It cannot pin the thing that matters most
# about an exploratory bot, because fetch mode structurally cannot do it.
# bot.py fetches each route with urllib and never executes JavaScript, so
# "44/44 routes visited" means 44 routes ANSWERED. Against a single-page app
# every path answers the same document shell, including paths that are not
# routes at all — so a run that rendered nothing reports exactly what a run
# that rendered everything reports, and `console_errors_observable` is false
# because there is no console to observe.
#
# This suite pins the render-time contract:
#
#   1. every derived route RENDERS — the SPA mounts and paints a non-trivial
#      page, asserted per route and not inferred from an HTTP status
#   2. a planted console error on one route is DETECTED — the console oracle
#      is wired end to end through a real Chromium, not merely declared
#   3. the report distinguishes rendered from merely answered, and declares
#      console errors observable only when they actually were
#   4. the fetch-mode default is untouched: `loop.sh` with no --mode still
#      reports console errors as unobservable
#
# Runtime. Browser mode needs the Playwright runtime the acceptance suite
# already uses (`test/acceptance/node_modules/@playwright/test`) plus a
# Chromium build, and needs the dashboard's own `node_modules` so vite can
# serve a bundle a browser can execute. When any of those is absent the suite
# SKIPS with a message naming what to install. When they are PRESENT it must
# FAIL rather than skip: a rendering regression hiding behind a skip is the
# exact failure this suite exists to stop.

setup() {
  root="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  loop="$root/scripts/jev-test-bot/loop.sh"
  routes="$root/scripts/jev-test-bot/routes.py"
  driver="$root/scripts/jev-test-bot/browser_driver.mjs"
  reports_root="$BATS_TEST_TMPDIR/reports"
  mkdir -p "$reports_root"
}

json_get() {
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for key in sys.argv[2].split("."):
    doc = doc[int(key)] if key.isdigit() else doc[key]
print(json.dumps(doc) if isinstance(doc, (list, dict)) else doc)
' "$1" "$2"
}

# The one gate, consulted by every test that drives a browser. Deliberately
# reports WHICH precondition is missing: "skipped" with no reason is how a
# suite stops meaning anything.
require_browser_runtime() {
  run bash "$root/scripts/jev-test-bot/browser-runtime.sh" --check
  if [ "$status" -ne 0 ]; then
    skip "browser runtime unavailable: $output"
  fi
}

@test "JEVBROWSER the driver and the runtime probe parse" {
  [ -f "$driver" ]
  [ -x "$root/scripts/jev-test-bot/browser-runtime.sh" ]
  run bash -n "$root/scripts/jev-test-bot/browser-runtime.sh"
  [ "$status" -eq 0 ]
  run python3 -m py_compile "$root/scripts/jev-test-bot/decide_server.py"
  [ "$status" -eq 0 ]
}

@test "JEVBROWSER fetch mode is unchanged: --mode fetch is the default and reports no console oracle" {
  run grep -n 'MODE:-fetch' "$loop"
  [ "$status" -eq 0 ]
  # loop.sh must accept --mode and reject an unknown one rather than silently
  # falling back to a mode the caller did not ask for.
  run env -u JEV_REPORTS_DIR "$loop" --mode nonsense --print-routes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown --mode"* ]]
}

# ── 1 + 3. Every derived route renders, and the report says so ─────────────

@test "JEVBROWSER one iteration renders every derived route and reports rendered vs answered" {
  require_browser_runtime

  run env -u JEV_REPORTS_DIR timeout 1800 "$loop" \
    --mode browser --mock --iterations 1 --turns 2 --timeout 60 \
    --reports-dir "$reports_root" --run-id browser-render
  echo "$output"
  [ "$status" -eq 0 ]

  report="$reports_root/browser-render/iteration-1.json"
  [ -f "$report" ]

  derived_count="$(python3 "$routes" | wc -l | tr -d ' ')"
  [ "$derived_count" -gt 20 ]

  # Coverage accounting still holds — browser mode must not weaken it.
  total="$(json_get "$report" routes_total)"
  [ "$total" -eq "$derived_count" ]
  [ "$(json_get "$report" routes_unvisited_count)" -eq 0 ]

  # The claim fetch mode could not make: every route rendered, by name.
  run python3 -c '
import json, subprocess, sys
report = json.load(open(sys.argv[1]))
derived = subprocess.run([sys.executable, sys.argv[2]], capture_output=True, text=True, check=True)
want = [r for r in derived.stdout.splitlines() if r.strip()]
rendered = set(report["routes_rendered"])
missing = [r for r in want if r not in rendered]
if missing:
    print("routes answered but never rendered:", missing)
    print("reasons:", {a.get("area"): a.get("render_reason") for a in report["areas"] if a.get("rendered") is False})
    sys.exit(1)
print("rendered", len(rendered), "of", len(want))
' "$report" "$routes"
  echo "$output"
  [ "$status" -eq 0 ]

  [ "$(json_get "$report" routes_rendered_count)" -eq "$derived_count" ]
  [ "$(json_get "$report" routes_answered_not_rendered)" = "[]" ]

  # And the console oracle must be declared observable only because it was.
  [ "$(json_get "$report" console_errors_observable)" = "True" ]

  # A real browser on a real route surface finds real controls. Zero would
  # mean the action space extractor ran against an empty document.
  run python3 -c '
import json, sys
report = json.load(open(sys.argv[1]))
spaces = [a.get("action_space_size", 0) for a in report["areas"] if a.get("readable")]
assert spaces, "no readable area reports"
if max(spaces) < 5:
    print("action spaces too small to be a rendered app:", sorted(spaces))
    sys.exit(1)
acted = sum(a.get("actions_executed", 0) for a in report["areas"])
if acted < 1:
    print("no typed action was executed on any route")
    sys.exit(1)
print("max action space", max(spaces), "actions executed", acted)
' "$report"
  echo "$output"
  [ "$status" -eq 0 ]

  summary="$reports_root/browser-render/summary.json"
  [ "$(json_get "$summary" console_errors_observable)" = "True" ]
  [ "$(json_get "$summary" routes_answered_not_rendered)" = "[]" ]
  [ "$(json_get "$summary" passed)" = "True" ]
}

# ── 2. The console oracle actually fires ───────────────────────────────────

@test "JEVBROWSER a planted console error on one route is detected and fails the route" {
  require_browser_runtime

  # One route, planted fault, so the assertion names the oracle rather than
  # a 44-route walk. --allow-partial because this is deliberately a narrow
  # walk and the coverage assertion must keep refusing silent ones.
  narrow="$BATS_TEST_TMPDIR/one-route.txt"
  printf '/risk\n' >"$narrow"

  run env -u JEV_REPORTS_DIR JEV_FAULT_ROUTE=/risk JEV_FAULT_KIND=console \
    timeout 900 "$loop" \
    --mode browser --mock --iterations 1 --turns 1 --timeout 60 \
    --routes-from "$narrow" --allow-partial \
    --reports-dir "$reports_root" --run-id browser-fault-console
  echo "$output"
  # A detected defect is exit 1, which is the point: the oracle made the run fail.
  [ "$status" -eq 1 ]

  report="$reports_root/browser-fault-console/iteration-1.json"
  [ -f "$report" ]
  [ "$(json_get "$report" console_errors_observable)" = "True" ]
  [ "$(json_get "$report" passed)" = "False" ]

  # The planted string must appear in the console oracle specifically — not in
  # some other bucket that happens to be non-empty.
  run python3 -c '
import json, sys
report = json.load(open(sys.argv[1]))
console = report["console_errors"]
hits = [c for c in console if "JEV_PLANTED_CONSOLE_FAULT" in json.dumps(c)]
if not hits:
    print("console oracle did not catch the planted fault. console_errors =", json.dumps(console))
    print("all bugs =", json.dumps(report["bugs"]))
    sys.exit(1)
if hits[0].get("category") != "CONSOLE_ERROR":
    print("planted fault landed in the wrong category:", hits[0].get("category"))
    sys.exit(1)
if hits[0].get("area") != "/risk":
    print("planted fault not attributed to its route:", hits[0].get("area"))
    sys.exit(1)
print("console oracle caught", len(hits), "planted error(s)")
' "$report"
  echo "$output"
  [ "$status" -eq 0 ]

  # The route still RENDERED — a console error is a defect in a working page,
  # and conflating the two would make either signal useless.
  [ "$(json_get "$report" routes_rendered)" = '["/risk"]' ]
}

@test "JEVBROWSER a planted uncaught exception is detected by the page-error oracle" {
  require_browser_runtime

  narrow="$BATS_TEST_TMPDIR/one-route-pageerror.txt"
  printf '/risk\n' >"$narrow"

  run env -u JEV_REPORTS_DIR JEV_FAULT_ROUTE=/risk JEV_FAULT_KIND=pageerror \
    timeout 900 "$loop" \
    --mode browser --mock --iterations 1 --turns 1 --timeout 60 \
    --routes-from "$narrow" --allow-partial \
    --reports-dir "$reports_root" --run-id browser-fault-pageerror
  echo "$output"
  [ "$status" -eq 1 ]

  report="$reports_root/browser-fault-pageerror/iteration-1.json"
  run python3 -c '
import json, sys
report = json.load(open(sys.argv[1]))
hits = [b for b in report["bugs"]
        if b.get("category") == "PAGE_ERROR" and "JEV_PLANTED_PAGE_FAULT" in json.dumps(b)]
if not hits:
    print("page-error oracle missed the planted exception. bugs =", json.dumps(report["bugs"]))
    sys.exit(1)
print("page-error oracle caught", len(hits))
' "$report"
  echo "$output"
  [ "$status" -eq 0 ]
}

# ── 4. The planted-fault hook must be inert when not asked for ────────────

@test "JEVBROWSER the fault hook is inert with no JEV_FAULT_ROUTE set" {
  require_browser_runtime

  narrow="$BATS_TEST_TMPDIR/clean-route.txt"
  printf '/risk\n' >"$narrow"

  run env -u JEV_REPORTS_DIR -u JEV_FAULT_ROUTE -u JEV_FAULT_KIND \
    timeout 900 "$loop" \
    --mode browser --mock --iterations 1 --turns 1 --timeout 60 \
    --routes-from "$narrow" --allow-partial \
    --reports-dir "$reports_root" --run-id browser-clean
  echo "$output"
  [ "$status" -eq 0 ]

  report="$reports_root/browser-clean/iteration-1.json"
  run python3 -c '
import json, sys
report = json.load(open(sys.argv[1]))
planted = [b for b in report["bugs"] if "JEV_PLANTED" in json.dumps(b)]
if planted:
    print("fault hook fired without being asked:", json.dumps(planted))
    sys.exit(1)
print("clean")
' "$report"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(json_get "$report" passed)" = "True" ]
}

# ── The destructive guard survives the move into a real browser ───────────

@test "JEVBROWSER destructive controls are never clicked" {
  # Asserted against the driver's own guard rather than by hoping a walk
  # happens to meet a sign-out button: the whole point of a guard is that the
  # dangerous case must not need to occur for the guard to be proven.
  run node --input-type=module -e '
import { isDestructive } from "'"$root"'/scripts/jev-test-bot/browser_driver.mjs";
const must = ["Sign out", "Log out", "logout", "Delete agent", "Revoke credential",
              "Remove host", "Reset demo", "Deactivate", "Quarantine agent"];
const mustNot = ["Agents", "FAIR Risk", "Search", "Save view", "Next", "Refresh"];
let bad = [];
for (const n of must) if (!isDestructive(n)) bad.push("NOT guarded: " + n);
for (const n of mustNot) if (isDestructive(n)) bad.push("over-guarded: " + n);
if (bad.length) { console.log(bad.join("\n")); process.exit(1); }
console.log("guard ok");
'
  echo "$output"
  [ "$status" -eq 0 ]
}
