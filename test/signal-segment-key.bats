#!/usr/bin/env bats
# @id     signal-segment-key
# @target scripts/signal-segment-key.sh
# @doc    docs/signalloom/sldp-downstream-contract.md
# @spec   signal-ingest with SIGNAL_STORE=frostdb needs Secret signal-ingest-segment-pseudonym
#         (SIGNAL_SEGMENT_PSEUDONYM_KEY: 32 bytes hex, SIGNAL_SEGMENT_PSEUDONYM_EPOCH), minted
#         idempotently by the bring-up; the key never reaches argv.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/signal-segment-key.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case "$*" in
  *"cluster-info"*)
    if [ "${FAKE_KUBECTL_FAIL_CLUSTER_INFO:-0}" = "1" ]; then
      echo "Unable to connect to the server" >&2
      exit 1
    fi
    echo "Kubernetes control plane is running" ;;
  *" apply -f -"*)
    cat >"${FAKE_STATE}/applied"
    cp "${FAKE_STATE}/applied" "${FAKE_STATE}/stored" ;;
  *"get secret signal-ingest-segment-pseudonym"*)
    [ -f "${FAKE_STATE}/stored" ] || exit 1
    k="$(sed -n 's/.*{\.data\.\([A-Za-z0-9._-]*\)}.*/\1/p' <<<"$*")"
    awk -v k="  ${k}:" 'index($0,k)==1 {print $2; exit}' "${FAKE_STATE}/stored" | tr -d '\n' ;;
esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

value() { awk -v k="  $1:" 'index($0,k)==1 {print $2; exit}' "${STATE}/applied"; }

@test "signal-segment-key: --context is required, exit 2, nothing applied" {
  run "${SCRIPT}"
  [ "$status" -eq 2 ]
  [ ! -f "${STATE}/applied" ]
}

@test "signal-segment-key: fresh run creates the Secret with a 32-byte hex key and epoch 1" {
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"created"* ]]
  grep -q 'name: signal-ingest-segment-pseudonym' "${STATE}/applied"
  grep -q 'namespace: fe-signalloom' "${STATE}/applied"
  key="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [ "${#key}" -eq 64 ]
  [[ "${key}" =~ ^[0-9a-f]{64}$ ]]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "1" ]
}

@test "signal-segment-key: re-run keeps the key (zero apply calls)" {
  "${SCRIPT}" --context kind-test >/dev/null
  first="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)"
  : >"${STATE}/argv"
  run "${SCRIPT}" --context kind-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept"* ]]
  ! grep -q ' apply -f -' "${STATE}/argv"
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)" = "${first}" ]
}

@test "signal-segment-key: --rotate writes a new key and bumps the epoch" {
  "${SCRIPT}" --context kind-test >/dev/null
  first="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)"
  run "${SCRIPT}" --context kind-test --rotate
  [ "$status" -eq 0 ]
  [[ "$output" == *"rotated"* ]]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_KEY)" != "${first}" ]
  [ "$(value SIGNAL_SEGMENT_PSEUDONYM_EPOCH | base64 -d)" = "2" ]
}

@test "signal-segment-key: the key never appears in argv, stdout or stderr" {
  run --separate-stderr "${SCRIPT}" --context kind-test
  key="$(value SIGNAL_SEGMENT_PSEUDONYM_KEY | base64 -d)"
  [ -n "${key}" ]
  ! grep -qF "${key}" "${STATE}/argv"
  [[ "$output" != *"${key}"* ]]
  [[ "$stderr" != *"${key}"* ]]
}

@test "signal-segment-key: unreachable cluster is exit 1 with nothing applied" {
  FAKE_KUBECTL_FAIL_CLUSTER_INFO=1 run "${SCRIPT}" --context kind-test
  [ "$status" -eq 1 ]
  [ ! -f "${STATE}/applied" ]
}

@test "signal-segment-key: the Deployment reads both values from the Secret this script mints" {
  ds="${REPO_ROOT}/d2-signalloom/apps/signal-ingest/base/deployment.yaml"
  grep -q 'name: SIGNAL_SEGMENT_PSEUDONYM_KEY' "$ds"
  grep -q 'name: SIGNAL_SEGMENT_PSEUDONYM_EPOCH' "$ds"
  [ "$(grep -c 'name: signal-ingest-segment-pseudonym' "$ds")" -eq 2 ]
  ! grep -A4 'name: SIGNAL_SEGMENT_PSEUDONYM_KEY' "$ds" | grep -q 'optional: true'
  grep -q 'signal-segment-key CONTEXT' "${REPO_ROOT}/Makefile"
}
