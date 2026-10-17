#!/usr/bin/env bats
# @id     openbao-secrets
# @target scripts/openbao-secrets.sh
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   OpenBao's two start-up secrets are minted once and never replaced:
#         the static seal key (inf-bao/openbao-seal-key, 32 raw bytes) and the
#         storage credential (inf-bao/openbao-storage). The Postgres role and
#         database `openbao` are created idempotently with SQL on stdin. No
#         secret value reaches argv.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/openbao-secrets.sh"
  STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "${STATE}" "${BATS_TEST_TMPDIR}/bin"
  : >"${STATE}/argv"
  cat >"${BATS_TEST_TMPDIR}/bin/kubectl" <<'EOS'
#!/usr/bin/env bash
echo "$*" >>"${FAKE_STATE}/argv"
ns=""; prev=""
for a in "$@"; do [ "$prev" = "-n" ] && ns="$a"; prev="$a"; done
field=""
case " $* " in *"{.data.key}"*) field=key ;; *"{.data.password}"*) field=password ;; esac
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
    awk -v k="${field}:" '$1==k {print $2; exit}' "$f" | tr -d '\n' ;;
  *" rollout status "*) [ "${FAKE_PG_READY:-1}" = "1" ] ;;
  *" exec "*) cat >>"${FAKE_STATE}/psql-stdin" ;;
esac
EOS
  chmod +x "${BATS_TEST_TMPDIR}/bin/kubectl"
  export SLDC_KUBECTL="${BATS_TEST_TMPDIR}/bin/kubectl" FAKE_STATE="${STATE}" KUBECONFIG=/dev/null
}

field() { awk -v k="$2:" '$1==k {print $2; exit}' "${STATE}/secret.$1" | base64 -d; }

@test "openbao-secrets: --context is required, exit 2, nothing applied" {
  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  ! grep -q ' apply ' "${STATE}/argv"
}

@test "openbao-secrets: the seal key is 32 raw bytes in inf-bao/openbao-seal-key" {
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [ "$(field inf-bao.openbao-seal-key key | wc -c | tr -d ' ')" = "32" ]
}

@test "openbao-secrets: re-run keeps both the seal key and the storage password" {
  "${SCRIPT}" --context kind-test
  key_before="$(field inf-bao.openbao-seal-key key | od -An -tx1 | tr -d ' \n')"
  pw_before="$(field inf-bao.openbao-storage password)"
  run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"seal key kept"* ]]
  [[ "${output}" == *"storage password kept"* ]]
  [ "$(field inf-bao.openbao-seal-key key | od -An -tx1 | tr -d ' \n')" = "${key_before}" ]
  [ "$(field inf-bao.openbao-storage password)" = "${pw_before}" ]
}

@test "openbao-secrets: the storage Secret holds the connection URL for role openbao" {
  "${SCRIPT}" --context kind-test
  pw="$(field inf-bao.openbao-storage password)"
  [[ "${pw}" =~ ^[0-9a-f]{32}$ ]]
  [ "$(field inf-bao.openbao-storage connection_url)" = \
    "postgres://openbao:${pw}@postgresql.inf-signalloom.svc.cluster.local:5432/openbao?sslmode=disable" ]
}

@test "openbao-secrets: role and database are created idempotently on stdin, never on argv" {
  "${SCRIPT}" --context kind-test
  pw="$(field inf-bao.openbao-storage password)"
  grep -q "WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'openbao')" "${STATE}/psql-stdin"
  grep -q "ALTER ROLE openbao WITH LOGIN PASSWORD '${pw}'" "${STATE}/psql-stdin"
  grep -q "WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'openbao')" "${STATE}/psql-stdin"
  ! grep -q "${pw}" "${STATE}/argv"
}

@test "openbao-secrets: Postgres not ready fails loudly, OpenBao cannot start without its database" {
  FAKE_PG_READY=0 run "${SCRIPT}" --context kind-test
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"postgresql"* ]]
}

# ── network path: OpenBao pod -> inf-signalloom Postgres :5432 only ──────────

@test "openbao-storage network: inf-bao lets only the OpenBao pod out to Postgres 5432" {
  f="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/networkpolicy.yaml"
  run yq ea -e '[select(.metadata.name=="allow-openbao-storage-egress")] | .[0] | [(.spec.podSelector.matchLabels."app.kubernetes.io/name"=="openbao"), (.spec.policyTypes|length==1), (.spec.policyTypes[0]=="Egress"), (.spec.egress|length==1), (.spec.egress[0].to[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"=="inf-signalloom"), (.spec.egress[0].to[0].podSelector.matchLabels."app.kubernetes.io/name"=="postgresql"), (.spec.egress[0].to|length==1), (.spec.egress[0].ports|length==1), (.spec.egress[0].ports[0].port==5432), (.spec.egress[0].ports[0].protocol=="TCP")] | all' "$f"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "openbao-storage network: inf-signalloom admits only the OpenBao pod from inf-bao on 5432" {
  f="${REPO_ROOT}/d2-signalloom/infra/inf-signalloom/configs/base/networkpolicy.yaml"
  run yq ea -e '[select(.metadata.name=="allow-openbao-storage-ingress")] | .[0] | [(.spec.podSelector.matchLabels."app.kubernetes.io/name"=="postgresql"), (.spec.policyTypes|length==1), (.spec.policyTypes[0]=="Ingress"), (.spec.ingress|length==1), (.spec.ingress[0].from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name"=="inf-bao"), (.spec.ingress[0].from[0].podSelector.matchLabels."app.kubernetes.io/name"=="openbao"), (.spec.ingress[0].from|length==1), (.spec.ingress[0].ports|length==1), (.spec.ingress[0].ports[0].port==5432), (.spec.ingress[0].ports[0].protocol=="TCP")] | all' "$f"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "openbao-storage network: NetAssert pins the allowed path and a same-destination deny" {
  run "${REPO_ROOT}/d2-signalloom/test/check-netassert-config-drift.sh"
  [ "${status}" -eq 0 ]
  grep -q 'openbao-to-postgresql-allowed' "${REPO_ROOT}/d2-signalloom/test/netassert-signalloom.yaml"
  grep -q 'spire-server-to-postgresql-denied' "${REPO_ROOT}/d2-signalloom/test/netassert-signalloom.yaml"
}
