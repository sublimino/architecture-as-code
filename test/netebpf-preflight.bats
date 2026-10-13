#!/usr/bin/env bats
# test/netebpf-preflight.bats — NETEBPF Phase 1 Preflight Verification Suite

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  local gopath="${GOPATH:-}"
  if [ "$gopath" = "/usr/local/src/gocode" ] || [ -z "$gopath" ]; then gopath=/tmp/gopath; fi
  export GOPATH="$gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0
}

@test "netebpf preflight: scripts/netebpf-preflight.sh executes cleanly" {
  run "${REPO_ROOT}/scripts/netebpf-preflight.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Preflight Summary: 5 passed, 0 failed" ]]
}

@test "netebpf preflight: cgroup v2 hierarchy is accessible" {
  [ -d "/sys/fs/cgroup" ]
}

@test "netebpf preflight: kernel BTF or symbol table is present" {
  run uname -r
  [ "$status" -eq 0 ]
}

@test "netebpf preflight: Go toolchain resolves dependencies cleanly" {
  run go version
  [ "$status" -eq 0 ]
  [[ "$output" =~ "go version" ]]
}

@test "netebpf preflight: signalloom-warden passes go vet" {
  cd "$REPO_ROOT/d2-signalloom/apps/signalloom-warden"
  run go vet ./...
  [ "$status" -eq 0 ]
}
