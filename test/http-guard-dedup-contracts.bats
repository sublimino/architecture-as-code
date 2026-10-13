#!/usr/bin/env bats
# test/http-guard-dedup-contracts.bats
# End-to-end offline contract suite verifying the consolidated RFC 9110 HTTP
# method gate, OPTIONS parity, HEAD body suppression, and body-draining helpers
# across Go, Python, and TypeScript services, plus worktree hygiene and proposal
# consolidation invariants.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  local gopath="${GOPATH:-}"
  if [ "$gopath" = "/usr/local/src/gocode" ] || [ -z "$gopath" ]; then
    gopath=/tmp/gopath
  fi
  export GOPATH="$gopath"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="*"
  export CGO_ENABLED=0
  export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/bin:$PATH"
  mkdir -p "$GOPATH" "$GOCACHE" "$GOMODCACHE"
}

@test "all 8 refactored Go services provide shared httputil.go and httputil_test.go" {
  for app in fleet-manager hosted-daytona-coder cardvault prompt-commit-summarizer triage-ci-worker workspace-connector cpai-engineer prod-deploy-gate; do
    [ -f "$ROOT/d2-signalloom/apps/$app/httputil.go" ]
    [ -f "$ROOT/d2-signalloom/apps/$app/httputil_test.go" ]
    grep -q "drainAndCloseBody" "$ROOT/d2-signalloom/apps/$app/httputil.go"
  done
}

@test "all 4 TypeScript acceptance harnesses import shared http-gate.ts and pass contract tests" {
  [ -f "$ROOT/test/acceptance/harness/http-gate.ts" ]
  for srv in server.ts cockpit-telemetry-server.ts coding-agents-server.ts user-admin-flags-server.ts; do
    grep -q "http-gate" "$ROOT/test/acceptance/harness/$srv"
  done
  run bun test "$ROOT/test/unit/acceptance-harnesses-head-contracts.test.ts"
  [ "$status" -eq 0 ]
}

@test "Python HTTP services normalize Allow headers and pass contract suites" {
  grep -q "normalize_allow" "$ROOT/d2-agent-trust/a2a/service.py"
  grep -q "_normalize_allow" "$ROOT/d2-signalloom/apps/fake-integration-proxy/server.py"
  grep -q "_normalize_allow" "$ROOT/d2-signalloom/apps/netassert-controller/server.py"

  run pytest -q "$ROOT/d2-agent-trust/test"
  [ "$status" -eq 0 ]

  PYTHONPATH="$ROOT/d2-signalloom/apps/fake-integration-proxy" run pytest -q "$ROOT/d2-signalloom/apps/fake-integration-proxy/test"
  [ "$status" -eq 0 ]

  PYTHONPATH="$ROOT/d2-signalloom/apps/netassert-controller" run pytest -q "$ROOT/d2-signalloom/apps/netassert-controller/test"
  [ "$status" -eq 0 ]
}

@test "canonical 2026-Q4 RFC 9110 HTTP hardening proposal exists and is indexed in docs/README.md" {
  local canonical="$ROOT/docs/Proposal — Platform-Wide RFC 9110 HTTP Method Gate, HEAD, OPTIONS, and Body Lifecycle Hardening (2026-Q4).md"
  [ -f "$canonical" ]
  grep -q "Platform-Wide RFC 9110 HTTP Method Gate, HEAD, OPTIONS, and Body Lifecycle Hardening" "$ROOT/docs/README.md"
  run "$ROOT/scripts/docs-lint.sh" "$canonical" "$ROOT/docs/README.md"
  [ "$status" -eq 0 ]
}

@test "in-repo worktree hygiene guard passes on current repository state" {
  run "$ROOT/scripts/check-worktree-hygiene.sh"
  [ "$status" -eq 0 ]
}
