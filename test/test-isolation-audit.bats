#!/usr/bin/env bats
# @id     test-isolation-audit
# @target scripts/test-isolation-audit.sh
# @doc    docs/signalloom/runbooks/parallel-tests.md

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  export REPO_ROOT
  AUDIT="${REPO_ROOT}/scripts/test-isolation-audit.sh"
  export AUDIT
  export KUBECONFIG=/dev/null
}

@test "audit: the committed tree passes with the committed allowlist" {
  run bash "$AUDIT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-isolation-audit: OK"* ]]
}

@test "audit: an empty allowlist makes the tree fail, so the gate is load-bearing" {
  : >"${BATS_TEST_TMPDIR}/empty.txt"
  TEST_ISOLATION_ALLOWLIST="${BATS_TEST_TMPDIR}/empty.txt" run bash "$AUDIT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FINDING"* ]]
}

@test "audit: --json reports a scanned count and a findings array" {
  run bash "$AUDIT" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.findings | length == 0'
  echo "$output" | jq -e '.scanned > 100'
  echo "$output" | jq -e '.allowlisted > 0'
}

@test "audit: an allowlist entry with no reason is rejected, not silently honoured" {
  echo 'test/foo.bats:PORT:8080' >"${BATS_TEST_TMPDIR}/noreason.txt"
  TEST_ISOLATION_ALLOWLIST="${BATS_TEST_TMPDIR}/noreason.txt" run bash "$AUDIT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"no reason"* ]]
}

@test "audit: --list-allowlisted prints every entry with its reason" {
  run bash "$AUDIT" --list-allowlisted
  [ "$status" -eq 0 ]
  # every printed line carries a reason
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [[ "$line" == *"#"* ]]
  done <<<"$output"
}

# --- detector behaviour, proved on fixtures rather than on the live tree ------
# These run the detector against a throwaway Makefile+file pair so the
# assertions do not move whenever a real test file is edited.

mkfixture() { # <relative path> <content>
  mkdir -p "${BATS_TEST_TMPDIR}/repo/scripts" "${BATS_TEST_TMPDIR}/repo/$(dirname "$1")"
  printf '%s\n' "$2" >"${BATS_TEST_TMPDIR}/repo/$1"
  cp "$AUDIT" "${BATS_TEST_TMPDIR}/repo/scripts/"
  cp "${REPO_ROOT}/Makefile" "${BATS_TEST_TMPDIR}/repo/Makefile.orig" 2>/dev/null || true
  {
    echo "SLDC_OFFLINE_BATS = $1"
    echo "SLDC_GO_DIRS ="
  } >"${BATS_TEST_TMPDIR}/repo/Makefile"
  : >"${BATS_TEST_TMPDIR}/repo/allow.txt"
}

runfixture() {
  cd "${BATS_TEST_TMPDIR}/repo" || return 1
  TEST_ISOLATION_ALLOWLIST=allow.txt bash scripts/test-isolation-audit.sh --json
}

@test "audit detector: a hardcoded 127.0.0.1 port is a PORT finding" {
  mkfixture test/x.bats 'curl http://127.0.0.1:34788/healthz'
  run runfixture
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '[.findings[] | select(.kind=="PORT" and .literal=="34788")] | length == 1'
}

@test "audit detector: port 0 is the fix, not a finding" {
  mkfixture test/x.bats 'python3 -c "s.bind((\"127.0.0.1\", 0))"'
  run runfixture
  [ "$status" -eq 0 ]
}

@test "audit detector: a fixed /tmp path is a TMP finding" {
  mkfixture test/x.bats 'echo hi >/tmp/bats-bigbody.json'
  run runfixture
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '[.findings[] | select(.kind=="TMP" and .literal=="/tmp/bats-bigbody.json")] | length == 1'
}

@test "audit detector: a /tmp path made unique by \$\$ or %d is not a finding" {
  mkfixture test/x.bats 'sock="/tmp/bao-test-bats-$$.sock"; other="/tmp/test-baoaudit-%d.sock"'
  run runfixture
  [ "$status" -eq 0 ]
}

@test "audit detector: \$BATS_TEST_TMPDIR is not a finding" {
  mkfixture test/x.bats 'echo hi >"${BATS_TEST_TMPDIR}/body.json"'
  run runfixture
  [ "$status" -eq 0 ]
}

@test "audit detector: an allowlisted finding stops being a finding" {
  mkfixture test/x.bats 'curl http://127.0.0.1:34788/healthz'
  echo 'test/x.bats:PORT:34788  # fixture' >"${BATS_TEST_TMPDIR}/repo/allow.txt"
  run runfixture
  [ "$status" -eq 0 ]
}

@test "audit detector: an allowlist entry for a DIFFERENT literal does not mask the finding" {
  mkfixture test/x.bats 'curl http://127.0.0.1:34788/healthz'
  echo 'test/x.bats:PORT:34777  # wrong literal' >"${BATS_TEST_TMPDIR}/repo/allow.txt"
  run runfixture
  [ "$status" -eq 1 ]
  echo "$output" | jq -e '[.findings[] | select(.literal=="34788")] | length == 1'
}
