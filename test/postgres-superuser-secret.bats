#!/usr/bin/env bats
# @id     postgres-superuser-secret
# @target scripts/postgres-superuser-secret.sh
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   The inf-signalloom Postgres superuser password is minted once into
#         inf-signalloom/postgresql-superuser, never replaced, never on argv.
#         The same password is written to fe-signalloom/
#         discovery-portal-database-credentials, and a running server gets it
#         by ALTER ROLE on stdin. No manifest carries the password.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/postgres-superuser-secret.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  : >"${STATE}/argv"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
ns=""; prev=""
for a in "$@"; do [ "$prev" = "-n" ] && ns="$a"; prev="$a"; done
case " $* " in
  *" cluster-info "*) exit 0 ;;
  *" apply -f - "*)
    doc="$(cat)"
    name="$(awk '$1=="name:" {print $2; exit}' <<<"$doc")"
    dns="$(awk '$1=="namespace:" {print $2; exit}' <<<"$doc")"
    printf '%s\n' "$doc" >"${FAKE_STATE}/secret.${dns}.${name}" ;;
  *" get secret "*)
    name="$(awk '{for(i=1;i<=NF;i++) if($i=="secret") {print $(i+1); exit}}' <<<"$*")"
    f="${FAKE_STATE}/secret.${ns}.${name}"
    [ -f "$f" ] || exit 1
    awk '$1=="password:" {print $2; exit}' "$f" | tr -d '\n' ;;
  *" get deployment postgresql "*)
    [ "${FAKE_PG_READY:-1}" = "1" ] && printf '1' || printf '0' ;;
  *" exec "*) cat >>"${FAKE_STATE}/psql-stdin" ;;
esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

secret_field() { awk -v k="$2:" '$1==k {print $2; exit}' "${STATE}/secret.$1" | base64 -d; }

@test "postgres-superuser-secret: --context is required, exit 2, nothing applied" {
  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  ! grep -q ' apply ' "${STATE}/argv"
}

@test "postgres-superuser-secret: fresh run mints a 32-hex password into inf-signalloom" {
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [[ "$(secret_field inf-signalloom.postgresql-superuser password)" =~ ^[0-9a-f]{32}$ ]]
  [ "$(secret_field inf-signalloom.postgresql-superuser username)" = "signalloom" ]
}

@test "postgres-superuser-secret: the portal credentials Secret carries the same password in its DSN" {
  "${SCRIPT}" --context kind-test
  pw="$(secret_field inf-signalloom.postgresql-superuser password)"
  [ "$(secret_field fe-signalloom.discovery-portal-database-credentials POSTGRES_PASSWORD)" = "${pw}" ]
  [ "$(secret_field fe-signalloom.discovery-portal-database-credentials POSTGRES_USER)" = "signalloom" ]
  [ "$(secret_field fe-signalloom.discovery-portal-database-credentials DATABASE_URL)" = \
    "postgresql://signalloom:${pw}@postgresql.inf-signalloom.svc.cluster.local:5432/signalloom" ]
}

@test "postgres-superuser-secret: re-run keeps the password" {
  "${SCRIPT}" --context kind-test
  before="$(secret_field inf-signalloom.postgresql-superuser password)"
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [[ "${output}" == *kept* ]]
  [ "$(secret_field inf-signalloom.postgresql-superuser password)" = "${before}" ]
}

@test "postgres-superuser-secret: a running server gets ALTER ROLE on stdin, never on argv" {
  "${SCRIPT}" --context kind-test
  pw="$(secret_field inf-signalloom.postgresql-superuser password)"
  grep -q "ALTER ROLE signalloom PASSWORD '${pw}'" "${STATE}/psql-stdin"
  ! grep -q "${pw}" "${STATE}/argv"
}

@test "postgres-superuser-secret: no running server means no exec, the first start reads the Secret" {
  FAKE_PG_READY=0 run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [ ! -f "${STATE}/psql-stdin" ]
  [[ "${output}" == *"first start"* ]]
}

@test "postgres-superuser-secret: no manifest carries the superuser password any more" {
  run rg -n 'POSTGRES_PASSWORD, value:|signalloom:signalloom@|POSTGRES_PASSWORD: signalloom' \
    "${REPO_ROOT}/d2-signalloom/infra" "${REPO_ROOT}/d2-signalloom/apps"
  [ "${status}" -eq 1 ]
}

@test "postgres-superuser-secret: the Postgres Deployment reads the password from the Secret" {
  run yq -e 'select(.kind=="Deployment" and .metadata.name=="postgresql") | .spec.template.spec.containers[0].env[] | select(.name=="POSTGRES_PASSWORD") | .valueFrom.secretKeyRef.name == "postgresql-superuser"' \
    "${REPO_ROOT}/d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}
