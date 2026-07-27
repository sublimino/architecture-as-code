#!/usr/bin/env bats

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  image="signalloom-dashboard-test:${BATS_TEST_NUMBER:-0}"
  container="signalloom-dashboard-test-${BATS_TEST_NUMBER:-0}"
}

teardown() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
}

@test "Dashboard container serves assets, SPA fallback, and readiness" {
  run docker build -t "$image" "$root/d2-signalloom/apps/dashboard-signalloom"
  [ "$status" -eq 0 ]

  run docker run --detach --name "$container" -p 127.0.0.1::8080 "$image"
  [ "$status" -eq 0 ]
  port="$(docker port "$container" 8080/tcp | cut -d: -f2)"

  for _ in $(seq 1 20); do
    curl -fsS "http://127.0.0.1:${port}/readyz" >/dev/null && break
    sleep 0.25
  done

  run curl -fsS "http://127.0.0.1:${port}/readyz"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]
  run curl -fsS "http://127.0.0.1:${port}/assets/placeholder.txt"
  [ "$status" -eq 0 ]
  [ "$output" = "dashboard-asset" ]
  run curl -fsS "http://127.0.0.1:${port}/agents/123"
  [ "$status" -eq 0 ]
  [[ "$output" == *'<div id="root"></div>'* ]]
}
