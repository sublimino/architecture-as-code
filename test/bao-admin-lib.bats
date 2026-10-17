#!/usr/bin/env bats
# @id     bao-admin-lib
# @target scripts/lib/bao-admin.sh
# @doc    d2-signalloom/infra/inf-bao/controllers/base/openbao-admin.yaml
# @spec   Host scripts administer OpenBao as inf-bao-admin by kubectl exec into
#         deploy/openbao-admin (container bao). No token is passed on argv.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LOG}"
case "$*" in *"cat /var/run/secrets/openbao/token"*) printf 's.ADMIN15M\n' ;; esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" FAKE_LOG="${BATS_TEST_TMPDIR}/log"
  : >"${FAKE_LOG}"
  # shellcheck source=scripts/lib/bao-admin.sh
  source "${REPO_ROOT}/scripts/lib/bao-admin.sh"
}

@test "bao_admin runs one bao command in the admin pod" {
  bao_admin kv get kv/x
  [ "$(cat "${FAKE_LOG}")" = "-n inf-bao exec deployment/openbao-admin -c bao -- bao-admin kv get kv/x" ]
}

@test "bao_admin honours BAO_NAMESPACE and BAO_ADMIN_KUBECTL_ARGS" {
  BAO_NAMESPACE=other BAO_ADMIN_KUBECTL_ARGS="--context kind-x" bao_admin status
  [ "$(cat "${FAKE_LOG}")" = "--context kind-x -n other exec deployment/openbao-admin -c bao -- bao-admin status" ]
}

@test "bao_admin_stdin attaches stdin for bao write PATH -" {
  echo '{}' | bao_admin_stdin write auth/jwt/role/x -
  [ "$(cat "${FAKE_LOG}")" = "-n inf-bao exec -i deployment/openbao-admin -c bao -- bao-admin write auth/jwt/role/x -" ]
}

@test "bao_admin_sh runs a script with the admin token set in the pod" {
  bao_admin_sh 'bao kv put kv/x a=b'
  [ "$(cat "${FAKE_LOG}")" = "-n inf-bao exec deployment/openbao-admin -c bao -- with-bao-admin sh -ec bao kv put kv/x a=b" ]
}

@test "bao_admin_token copies the current short-lived token out" {
  run bao_admin_token
  [ "$status" -eq 0 ]
  [ "$output" = "s.ADMIN15M" ]
}

@test "the library never names a static token" {
  run rg -n 'root-token|BAO_TOKEN=' "${REPO_ROOT}/scripts/lib/bao-admin.sh"
  [ "$status" -eq 1 ]
}
