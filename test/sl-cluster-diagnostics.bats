#!/usr/bin/env bats
#
# sl-cluster-diagnostics.bats — Contract and regression tests for sl-cluster-diagnostics
#

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DIAG_BIN="$REPO_ROOT/.agents/skills/sl-cluster-diagnostics/Tools/cluster-diagnostics.sh"
  TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/cluster-diag-test.XXXXXX")"
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "cluster-diagnostics.sh is executable and runs --help" {
  [ -x "$DIAG_BIN" ]
  run "$DIAG_BIN" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Usage: cluster-diagnostics.sh" ]]
  [[ "$output" =~ "--snapshot" ]]
  [[ "$output" =~ "--force-kubectl" ]]
}

@test "cluster-diagnostics.sh rejects unknown options with exit code 2" {
  run "$DIAG_BIN" --invalid-flag
  [ "$status" -eq 2 ]
  [[ "$output" =~ "ERROR: unknown option" ]]
}

@test "cluster-diagnostics.sh produces valid JSON output" {
  if ! kubectl cluster-info --request-timeout=2s >/dev/null 2>&1; then
    skip "Kubernetes cluster is not running"
  fi

  run "$DIAG_BIN" --json --since 1m -n kube-system
  [ "$status" -eq 0 ]

  # Validate JSON structure using python
  echo "$output" > "$TEST_TMP/out.json"
  run python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert "engine" in d
assert "total_pods" in d
assert isinstance(d["total_pods"], int)
assert "unhealthy_pods" in d
assert "signatures" in d
assert isinstance(d["signatures"], list)
print("VALID_JSON")
' "$TEST_TMP/out.json"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "VALID_JSON" ]]
}

@test "cluster-diagnostics.sh functions under --force-kubectl fallback" {
  if ! kubectl cluster-info --request-timeout=2s >/dev/null 2>&1; then
    skip "Kubernetes cluster is not running"
  fi

  run "$DIAG_BIN" --force-kubectl --json --since 1m -n kube-system
  [ "$status" -eq 0 ]

  echo "$output" > "$TEST_TMP/out_kubectl.json"
  run python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
assert d["engine"] == "kubectl"
assert d["total_pods"] > 0
print("KUBECTL_FALLBACK_OK")
' "$TEST_TMP/out_kubectl.json"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "KUBECTL_FALLBACK_OK" ]]
}

@test "cluster-diagnostics.sh snapshot runs cleanly on a namespace" {
  if ! kubectl cluster-info --request-timeout=2s >/dev/null 2>&1; then
    skip "Kubernetes cluster is not running"
  fi

  run "$DIAG_BIN" --snapshot --since 1m -n kube-system
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Workload Lifecycle Summary" ]]
  [[ "$output" =~ "Recent Warning Events" ]]
  [[ "$output" =~ "Extracted Error Log Chunks" ]]
  [[ "$output" =~ "Automated Pattern & Signature Analysis" ]]
}
