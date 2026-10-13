#!/usr/bin/env bats
# ==============================================================================
# test/clean-test-artifacts.bats — Dedicated Test Artifact Cleanup Job Tests
# ==============================================================================

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/clean-test-artifacts.sh"
  TEST_KC="/tmp/osramp-test-tenant-bats-$$.kubeconfig"
  TEST_DIR="/tmp/slsi-test-bats-$$"
}

teardown() {
  rm -f "${TEST_KC:-}" "/tmp/osramp-test-tenant-bats-"*".kubeconfig" "/tmp/osramp-test-tenant-nohyphen-"*".kubeconfig"
  if [[ -n "${TEST_DIR:-}" && -d "${TEST_DIR}" ]]; then
    rm -rf "${TEST_DIR}"
  fi
  rm -rf "/tmp/slsi-test-bats-"*
}

@test "clean-test-artifacts.sh is executable and wired to make clean-test-artifacts" {
  [ -x "$SCRIPT" ]
  grep -q "^clean-test-artifacts:" "${REPO_ROOT}/Makefile"
}

@test "clean-test-artifacts.sh --help prints usage and exits 0" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: clean-test-artifacts.sh [options]"* ]]
  [[ "$output" == *"--dry-run"* ]]
  [[ "$output" == *"--check"* ]]
}

@test "clean-test-artifacts.sh rejects unknown options with exit code 2" {
  run "$SCRIPT" --bogus-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERROR: unknown option: --bogus-flag"* ]]
}

@test "clean-test-artifacts.sh --check detects leaked host kubeconfig without deleting it, and clean mode removes it" {
  local leaked_kc="/tmp/osramp-test-tenant-bats-$$.kubeconfig"
  touch "$leaked_kc"

  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Host temp kubeconfig: ${leaked_kc}"* ]]
  [ -e "$leaked_kc" ]

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed ${leaked_kc}"* ]]
  [ ! -e "$leaked_kc" ]
}

@test "clean-test-artifacts.sh detects and cleans orphaned /tmp/slsi-test-* directories and --dry-run does not delete them" {
  local leaked_dir="/tmp/slsi-test-bats-$$"
  mkdir -p "${leaked_dir}/out"
  echo "test-output" > "${leaked_dir}/out/result.json"

  run "$SCRIPT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Host temp test artifact: ${leaked_dir}"* ]]
  [ -f "${leaked_dir}/out/result.json" ]

  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Host temp test artifact: ${leaked_dir}"* ]]
  [ -f "${leaked_dir}/out/result.json" ]

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed ${leaked_dir}"* ]]
  [ ! -e "$leaked_dir" ]
}

@test "clean-test-artifacts.sh --check detects unhyphenated test-tenant kubeconfig" {
  local leaked_nohyphen="/tmp/osramp-test-tenant-nohyphen-$$.kubeconfig"
  touch "$leaked_nohyphen"

  run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Host temp kubeconfig: ${leaked_nohyphen}"* ]]
  [ -e "$leaked_nohyphen" ]

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed ${leaked_nohyphen}"* ]]
  [ ! -e "$leaked_nohyphen" ]
}
