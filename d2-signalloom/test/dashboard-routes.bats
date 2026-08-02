#!/usr/bin/env bats
#
# Runtime SPA route + static-asset smoke checks for the dashboard-signalloom
# nginx container. Curls the port-forwarded dashboard at localhost:5173 and
# verifies nginx returns the React SPA index for every known client-side route,
# and that static assets (background images) are served.
#
# Precondition: kubectl port-forward -n fe-signalloom svc/dashboard-signalloom 5173:8080
# Skips gracefully when the port-forward is absent.

setup() {
  base="${SIGNALLOOM_UI_URL:-http://localhost:5173}"
  curl -fsS "$base/readyz" >/dev/null 2>&1 || skip "dashboard not reachable at $base (port-forward required)"
}

# ── SPA fallback: every client-side route returns index.html with id="root" ──

@test "SPA fallback: /agents returns index.html" {
  run curl -fsS "$base/agents"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /compliance returns index.html" {
  run curl -fsS "$base/compliance"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /audit returns index.html" {
  run curl -fsS "$base/audit"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /cryptography returns index.html" {
  run curl -fsS "$base/cryptography"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

# /supercred, /rbac-analysis and /rbac-explorer were absent from this suite even
# though its header claims to cover every client-side route. That gap let a real
# bug ship: nginx's `location /supercred/` API proxy shadowed the `/supercred`
# SPA route, so the page 301'd into the proxy and never rendered. These three
# tests are the regression guard.

@test "SPA fallback: /supercred returns index.html" {
  run curl -fsS "$base/supercred"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /rbac-analysis returns index.html" {
  run curl -fsS "$base/rbac-analysis"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /rbac-explorer returns index.html" {
  run curl -fsS "$base/rbac-explorer"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

# A SPA route must be served directly, never redirected. nginx builds absolute
# redirects from its own listen scheme and port (http://…:8080), which do not
# exist outside the cluster, so any 3xx here becomes ERR_CONNECTION_REFUSED in a
# browser reaching the dashboard through the gateway.
@test "SPA routes are served directly, never redirected" {
  for route in /agents /compliance /audit /cryptography /federated-services \
               /collusion-access /rbac-analysis /rbac-explorer /supercred /settings; do
    run curl -s -o /dev/null -w '%{http_code}' "$base$route"
    [ "$status" -eq 0 ]
    [ "$output" = "200" ] || {
      echo "route $route returned HTTP $output, expected 200 (a 3xx means a proxy prefix is shadowing the SPA route)" >&2
      return 1
    }
  done
}

@test "SPA fallback: /federated-services returns index.html" {
  run curl -fsS "$base/federated-services"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /collusion-access returns index.html" {
  run curl -fsS "$base/collusion-access"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: /settings returns index.html" {
  run curl -fsS "$base/settings"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "SPA fallback: unknown deep link returns index.html" {
  run curl -fsS "$base/nonexistent/deep/link"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

# ── Static assets ────────────────────────────────────────────────────────────

@test "KTP collusion graph background image is served" {
  run curl -fsS -o /dev/null -w '%{content_type}' "$base/ktp-collusion-graph.png"
  [ "$status" -eq 0 ]
  [[ "$output" == image/* ]]
}

@test "readyz probe returns ready" {
  run curl -fsS "$base/readyz"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
}

# ── Bundle references ────────────────────────────────────────────────────────

@test "served JS bundle references the new dashboard routes" {
  index="$(curl -fsS "$base/")"
  js_path="$(echo "$index" | grep -oE 'assets/index-[A-Za-z0-9_-]+\.js' | head -1)"
  [ -n "$js_path" ]
  bundle="$(curl -fsS "$base/$js_path")"
  [[ "$bundle" == *"cryptography"* ]]
  [[ "$bundle" == *"federated-services"* ]]
  [[ "$bundle" == *"collusion-access"* ]]
}
