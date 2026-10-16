#!/usr/bin/env bats
# @id     connector-credential-key
# @target scripts/connector-credential-key.sh
# @doc    d2-signalloom/apps/fe-signalloom/src/connector_credentials.py
# @spec   fe-signalloom seals connector credentials with a 32-byte key from Secret
#         fe-signalloom/fe-signalloom-connector-credential-key (data key `key`, hex),
#         minted idempotently, never replaced, never on argv; the Deployment mounts it.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/connector-credential-key.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  touch "${STATE}/argv"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
case " $* " in
  *" cluster-info "*) [ "${FAKE_KUBECTL_FAIL_CLUSTER_INFO:-0}" = "1" ] && exit 1; exit 0 ;;
  *" apply "*) cat >"${FAKE_STATE}/secret" ;;
  *" get secret "*)
    [ -f "${FAKE_STATE}/secret" ] || exit 1
    awk '$1=="key:" {print $2; exit}' "${FAKE_STATE}/secret" | tr -d '\n' ;;
esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

applies() {
  if [ ! -f "${STATE}/argv" ]; then
    echo "0"
    return
  fi
  grep -c ' apply -f -' "${STATE}/argv" || true
}
stored_key_hex() { awk '$1=="key:" {print $2; exit}' "${STATE}/secret" | base64 -d; }

@test "connector-credential-key: --context is required, exit 2, nothing applied" {
  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  [ "$(applies)" = "0" ]
}

@test "connector-credential-key: fresh run creates the Secret in fe-signalloom with 32 hex-encoded bytes" {
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  grep -q 'name: fe-signalloom-connector-credential-key' "${STATE}/secret"
  grep -q 'namespace: fe-signalloom$' "${STATE}/secret"
  [[ "$(stored_key_hex)" =~ ^[0-9a-f]{64}$ ]]
}

@test "connector-credential-key: re-run keeps the key and applies nothing" {
  "${SCRIPT}" --context kind-test
  before="$(stored_key_hex)"
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [[ "${output}" == *kept* ]]
  [ "$(applies)" = "1" ]
  [ "$(stored_key_hex)" = "${before}" ]
}

@test "connector-credential-key: there is no rotate option" {
  run "${SCRIPT}" --context kind-test --rotate
  [ "${status}" -eq 2 ]
  [ "$(applies)" = "0" ]
}

@test "connector-credential-key: the key never appears in argv or output" {
  run "${SCRIPT}" --context kind-test
  key="$(stored_key_hex)"
  ! grep -q "${key}" "${STATE}/argv"
  [[ "${output}" != *"${key}"* ]]
}

@test "connector-credential-key: unreachable cluster is exit 1 with nothing applied" {
  FAKE_KUBECTL_FAIL_CLUSTER_INFO=1 run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 1 ]
  [ "$(applies)" = "0" ]
}

@test "connector-credential-key: the fe-signalloom Deployment mounts this Secret at the path CONNECTOR_CREDENTIAL_KEY_FILE names" {
  dep="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  grep -q 'secretName: fe-signalloom-connector-credential-key' "${dep}"
  grep -A1 'name: CONNECTOR_CREDENTIAL_KEY_FILE' "${dep}" | grep -q 'value: /etc/fe-signalloom/connector-credential-key/key'
  grep -q 'mountPath: /etc/fe-signalloom/connector-credential-key' "${dep}"
  grep -q 'connector-credential-key CONTEXT' "${REPO_ROOT}/Makefile"
}
