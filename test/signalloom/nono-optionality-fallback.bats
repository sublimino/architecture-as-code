#!/usr/bin/env bats
# test/signalloom/nono-optionality-fallback.bats — Verification of dynamic Nono capability detection and graceful fallback (SP-5).
#
# Covers Mission SLON (Signal Loom First User and Agent Onboarding — Phase 2-2):
# 1. Probe script existence and executable permissions.
# 2. Dynamic probe capability detection under normal host execution (--dry-run).
# 3. Graceful fallback on simulated absent Nono substrate (NONO_FORCE_FALLBACK=1).
# 4. Unconfined workload execution during fallback without crashing.
# 5. Backend signed audit session ingest and hash-chain verification.
# 6. Rejection of corrupted/tampered hash chains with HTTP 400.
# 7. Rejection of invalid cryptographic signatures with HTTP 400.
# 8. Standalone session verify probe endpoint functionality.
# 9. In-cluster pod health and telemetry verification in fe-signalloom-agents.

setup_file() {
  export PATH="/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export PROBE_SCRIPT="$REPO_ROOT/d2-signalloom/apps/fe-signalloom-agents/probe-nono-capability.sh"

  for cmd in jq python3 sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "Prerequisite tool '$cmd' missing" >&2
      return 1
    }
  done
}

@test "1. Dynamic Nono capability probe script exists and is executable" {
  [ -f "$PROBE_SCRIPT" ]
  [ -x "$PROBE_SCRIPT" ]
}

@test "2. Probe script executes with --dry-run and returns valid structured JSON telemetry" {
  run bash "$PROBE_SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  probe_json="$output"
  [ "$(echo "$probe_json" | jq -r .event)" = "nono_probe" ]
}

@test "3. Probe script detects Nono binary and Landlock capability when present" {
  if command -v nono >/dev/null 2>&1; then
    run bash "$PROBE_SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    probe_json="$output"
    [ "$(echo "$probe_json" | jq -r .nono_capability_available)" = "true" ]
    [ "$(echo "$probe_json" | jq -r .status)" = "detected" ]
    [ "$(echo "$probe_json" | jq -r .sandboxing)" = "landlock" ]
  else
    skip "Nono binary not installed on host test environment"
  fi
}

@test "4. Probe script gracefully falls back when Nono is simulated as missing" {
  run env NONO_FORCE_FALLBACK=1 bash "$PROBE_SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  probe_json="$output"
  [ "$(echo "$probe_json" | jq -r .nono_capability_available)" = "false" ]
  [ "$(echo "$probe_json" | jq -r .status)" = "fallback" ]
  [ "$(echo "$probe_json" | jq -r .fallback)" = "unconfined" ]
}

@test "5. Fallback path executes workload unconfined without crashing" {
  run env NONO_FORCE_FALLBACK=1 bash "$PROBE_SCRIPT" echo "WORKLOAD_UNCONFINED_EXEC_SUCCESS"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "WORKLOAD_UNCONFINED_EXEC_SUCCESS" ]]
}

@test "6. Backend audit session ingest accepts and verifies valid hash-chained session" {
  run python3 -m pytest -p no:libtmux "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py" -k "test_ingest_valid_signed_audit_session" -q
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
}

@test "7. Backend audit session ingest rejects broken or tampered hash chains with HTTP 400" {
  run python3 -m pytest -p no:libtmux "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py" -k "test_ingest_rejects_broken_hash_chain or test_ingest_rejects_mismatched_root_hash" -q
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
}

@test "8. Backend audit session ingest rejects invalid or forged signatures with HTTP 400" {
  run python3 -m pytest -p no:libtmux "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py" -k "test_ingest_rejects_invalid_signature" -q
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
}

@test "9. Standalone session verify probe endpoint validates session without persistence" {
  run python3 -m pytest -p no:libtmux "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py" -k "test_verify_probe_endpoint" -q
  [ "$status" -eq 0 ]
  [[ "$output" =~ "passed" ]]
}

@test "10. In-cluster demo agent pods in fe-signalloom-agents are healthy with zero crashloops" {
  if ! kubectl get nodes >/dev/null 2>&1; then
    skip "Kubernetes cluster not accessible"
  fi

  run kubectl -n fe-signalloom-agents get pods -l signalloom.ai/agent=true -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.phase}{" (restarts="}{.status.containerStatuses[0].restartCount}{")\n"}{end}'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent-nono-evidenced" ]]
  [[ "$output" =~ "Running" ]]
  # Assert restart count is 0
  [[ "$output" =~ "restarts=0" ]]
}
