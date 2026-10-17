#!/usr/bin/env bats
# @id     openbao-persistent-server
# @target d2-signalloom/infra/inf-bao/controllers/base/openbao-spire.yaml
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   SA-TODO-003 phase 1: OpenBao 2.7.1 runs a server config (no -dev) on
#         PostgreSQL storage with a static seal key from a Secret. A one-shot
#         init Job initialises it once, keeps the root token in memory only,
#         creates the SPIFFE-bound inf-bao-admin JWT role, and revokes root.
#         The openbao-admin Deployment is the one place host scripts reach
#         that role from.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BASE="${ROOT}/d2-signalloom/infra/inf-bao/controllers/base"
  SERVER="${BASE}/openbao-spire.yaml"
  INIT="${BASE}/openbao-init.yaml"
  ADMIN="${BASE}/openbao-admin.yaml"
}

doc() { yq ea "[select(.kind==\"$2\" and .metadata.name==\"$3\")] | .[0] | $4" "$1"; }

# ── server ───────────────────────────────────────────────────────────────────

@test "server: image is openbao 2.7.1, one replica, Recreate" {
  [ "$(doc "$SERVER" Deployment openbao '.spec.template.spec.containers[0].image')" = "quay.io/openbao/openbao:2.7.1" ]
  [ "$(doc "$SERVER" Deployment openbao '.spec.replicas')" = "1" ]
  [ "$(doc "$SERVER" Deployment openbao '.spec.strategy.type')" = "Recreate" ]
}

@test "server: runs a config file, never dev mode" {
  args="$(doc "$SERVER" Deployment openbao '.spec.template.spec.containers[0].args | join(" ")')"
  [ "$args" = "server -config=/openbao/config/config.hcl" ]
  run rg -n -- '"-dev"|-dev-|BAO_DEV_ROOT_TOKEN_ID' "$SERVER"
  [ "$status" -eq 1 ]
}

@test "server: config is PostgreSQL storage, static seal from a file, HTTP listener, no HA" {
  cfg="$(doc "$SERVER" ConfigMap openbao-server-config '.data."config.hcl"')"
  [[ "$cfg" == *'storage "postgresql"'* ]]
  [[ "$cfg" == *'ha_enabled = "false"'* ]]
  [[ "$cfg" == *'seal "static"'* ]]
  [[ "$cfg" == *'current_key    = "file:///openbao/seal/key"'* ]]
  [[ "$cfg" == *'tls_disable = true'* ]]
  [[ "$cfg" != *inmem* ]]
  [[ "$cfg" != *connection_url* ]]
}

@test "server: storage URL and seal key come from Secrets, not the manifest" {
  [ "$(doc "$SERVER" Deployment openbao '.spec.template.spec.containers[0].env[] | select(.name=="BAO_PG_CONNECTION_URL") | .valueFrom.secretKeyRef.name')" = "openbao-storage" ]
  [ "$(doc "$SERVER" Deployment openbao '.spec.template.spec.containers[0].env[] | select(.name=="BAO_PG_CONNECTION_URL") | .valueFrom.secretKeyRef.key')" = "connection_url" ]
  [ "$(doc "$SERVER" Deployment openbao '.spec.template.spec.volumes[] | select(.name=="seal-key") | .secret.secretName')" = "openbao-seal-key" ]
}

# ── init Job: manifest ───────────────────────────────────────────────────────

@test "init: Job is in the controllers slice and carries no token" {
  rg -q '^  - openbao-init.yaml$' "${BASE}/kustomization.yaml"
  [ "$(doc "$INIT" Job openbao-init '.spec.template.spec.containers[0].image')" = "quay.io/openbao/openbao:2.7.1" ]
  run rg -n 'name: BAO_TOKEN' "$INIT"
  [ "$status" -eq 1 ]
}

@test "init: admin role is bound to exactly one SPIFFE ID with a 15m token" {
  script="$(doc "$INIT" ConfigMap openbao-init-config '.data."init.sh"')"
  [[ "$script" == *'ADMIN_SUBJECT="spiffe://signalloom.demo/ns/inf-bao/sa/openbao-admin"'* ]]
  [[ "$script" == *'"bound_subject": "spiffe://signalloom.demo/ns/inf-bao/sa/openbao-admin"'* ]]
  [[ "$script" == *'"bound_audiences": "openbao"'* ]]
  [[ "$script" == *'"token_ttl": "15m"'* ]]
  [[ "$script" == *'"token_max_ttl": "15m"'* ]]
}

@test "init: admin policy cannot read raw storage, mint root, rekey, touch audit, or widen itself" {
  hcl="$(doc "$INIT" ConfigMap openbao-init-config '.data."inf-bao-admin.hcl"')"
  for p in 'sys/raw' 'sys/raw/*' 'sys/generate-root*' 'sys/generate-root-token*' 'sys/rekey*' 'sys/audit/*' 'sys/seal'; do
    [[ "$hcl" == *"path \"${p}\" { capabilities = [\"deny\"] }"* ]] || { echo "missing deny: $p"; return 1; }
  done
  [[ "$hcl" == *'path "auth/jwt/role/inf-bao-admin" { capabilities = ["read"] }'* ]]
  [[ "$hcl" == *'path "sys/policies/acl/inf-bao-admin" { capabilities = ["read"] }'* ]]
}

# ── init Job: behaviour against a fake bao ───────────────────────────────────

init_env() {
  WORK="${BATS_TEST_TMPDIR}/init"
  mkdir -p "$WORK/bin" "$WORK/config"
  doc "$INIT" ConfigMap openbao-init-config '.data."init.sh"' >"$WORK/init.sh"
  doc "$INIT" ConfigMap openbao-init-config '.data."inf-bao-admin.hcl"' >"$WORK/config/inf-bao-admin.hcl"
  cat >"$WORK/bin/bao" <<'EOS'
#!/bin/sh
printf '%s|token=%s\n' "$*" "${BAO_TOKEN:-}" >>"$FAKE_LOG"
case "$*" in
  "status -format=json") printf '{\n  "initialized": %s\n}\n' "$FAKE_INIT"; [ "$FAKE_INIT" = true ] && exit 0; exit 2 ;;
  "status") exit 0 ;;
  "operator init "*) printf '{\n  "recovery_keys_b64": [\n    "RECOVERY-KEY-XYZ"\n  ],\n  "root_token": "s.ROOT-TOKEN-XYZ"\n}\n' ;;
esac
case "$*" in *"$FAKE_FAIL_AT"*) [ -n "$FAKE_FAIL_AT" ] && exit 1 ;; esac
exit 0
EOS
  chmod +x "$WORK/bin/bao"
  export PATH="$WORK/bin:$PATH" FAKE_LOG="$WORK/log" BAO_ADDR=http://bao.test:8200 \
         OPENBAO_INIT_CONFIG_DIR="$WORK/config" FAKE_FAIL_AT="${FAKE_FAIL_AT:-}"
  : >"$FAKE_LOG"
}

@test "init behaviour: an initialised server is left alone" {
  FAKE_INIT=true init_env
  FAKE_INIT=true run sh "$WORK/init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already initialised"* ]]
  run rg -c 'operator init' "$FAKE_LOG"
  [ "$status" -eq 1 ]
}

@test "init behaviour: fresh server is initialised, configured, and root is revoked last" {
  FAKE_INIT=false init_env
  FAKE_INIT=false run sh "$WORK/init.sh"
  [ "$status" -eq 0 ]
  calls="$(cut -d'|' -f1 "$FAKE_LOG" | rg -v '^status')"
  expected="operator init -format=json -recovery-shares=1 -recovery-threshold=1
secrets enable -path=kv kv-v2
secrets enable -path=secret kv-v2
auth enable jwt
write auth/jwt/config jwks_url=http://spire-oidc.inf-bao.svc.cluster.local:8008/keys
policy write inf-bao-admin ${WORK}/config/inf-bao-admin.hcl
write auth/jwt/role/inf-bao-admin -
token revoke -self"
  [ "$calls" = "$expected" ]
  # every call after init ran as the root token, in the environment only
  [ "$(rg -v '^status' "$FAKE_LOG" | rg -c 'token=s.ROOT-TOKEN-XYZ$')" = "7" ]
}

@test "init behaviour: the root token and recovery key never reach stdout, stderr or argv" {
  FAKE_INIT=false init_env
  FAKE_INIT=false run sh "$WORK/init.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *ROOT-TOKEN-XYZ* ]]
  [[ "$output" != *RECOVERY-KEY-XYZ* ]]
  run rg -c 'ROOT-TOKEN-XYZ|RECOVERY-KEY-XYZ' <(cut -d'|' -f1 "$FAKE_LOG")
  [ "$status" -eq 1 ]
}

@test "init behaviour: a failure after init still revokes root" {
  FAKE_INIT=false FAKE_FAIL_AT="policy write" init_env
  FAKE_INIT=false run sh "$WORK/init.sh"
  [ "$status" -ne 0 ]
  [ "$(tail -1 "$FAKE_LOG" | cut -d'|' -f1)" = "token revoke -self" ]
}

# ── admin identity ───────────────────────────────────────────────────────────

@test "admin: openbao-admin Deployment logs in as inf-bao-admin through a bao agent" {
  [ "$(doc "$ADMIN" Deployment openbao-admin '.spec.template.spec.serviceAccountName')" = "openbao-admin" ]
  agent="$(doc "$ADMIN" ConfigMap openbao-admin-config '.data."agent.hcl"')"
  [[ "$agent" == *'role                     = "inf-bao-admin"'* ]]
  [[ "$agent" == *'path = "/var/run/secrets/openbao/token"'* ]]
  wrapper="$(doc "$ADMIN" ConfigMap openbao-admin-config '.data."bao-admin"')"
  [[ "$wrapper" == *'BAO_TOKEN="$(cat /var/run/secrets/openbao/token)"'* ]]
  [[ "$wrapper" == *'exec bao "$@"'* ]]
}

@test "admin: SPIRE registers spiffe://signalloom.demo/ns/inf-bao/sa/openbao-admin, and the Job re-runs on change" {
  f="${BASE}/spire-agent-swarm-entries.yaml"
  rg -q '^      inf-bao:openbao-admin$' "$f"
  [ "$(yq ea '[select(.kind=="Job")] | .[0] | .metadata.annotations."kustomize.toolkit.fluxcd.io/force"' "$f")" = "Enabled" ]
  want="$(yq ea '[select(.kind=="ConfigMap")] | .[0] | .data."register-entries.sh"' "$f" | sha256sum | cut -c1-12)"
  [ "$(yq ea '[select(.kind=="Job")] | .[0] | .spec.template.metadata.annotations."signalloom.io/config-hash"' "$f")" = "$want" ]
}

@test "no inf-bao or proof manifest still pins openbao 2.1.1" {
  run rg -n 'openbao/openbao:2\.1\.1' "${ROOT}/d2-signalloom/infra" "${ROOT}/d2-signalloom/apps/fe-signalloom/base"
  [ "$status" -eq 1 ]
}

@test "server: the audit log is declared in config.hcl, never enabled through the API" {
  # OpenBao 2.7 answers 400 to PUT sys/audit/*; an init that calls it dies
  # after operator init and leaves a server with no admin role.
  run rg -c '^    audit "file" "stdout"' "$BATS_TEST_DIRNAME/../infra/inf-bao/controllers/base/openbao-spire.yaml"
  [ "$output" = "1" ]
  run rg -c 'audit enable' "$BATS_TEST_DIRNAME/../infra/inf-bao/controllers/base/openbao-init.yaml"
  [ "$status" -eq 1 ]
}

@test "admin: the jwt-svid writer and the bao agent run as the same uid and gid" {
  # The SVID file is written mode 0600; a writer running as root leaves the
  # uid-100 bao agent with "permission denied" and no token.
  f="$BATS_TEST_DIRNAME/../infra/inf-bao/controllers/base/openbao-admin.yaml"
  uids="$(yq -r 'select(.kind=="Deployment") | .spec.template.spec.containers[] | select(.name=="jwt-svid" or .name=="bao") | "\(.securityContext.runAsUser):\(.securityContext.runAsGroup)"' "$f" | rg -v "^:$" | sort -u)"
  [ "$(printf '%s\n' "$uids" | wc -l)" -eq 1 ]
  [ "$uids" = "100:1000" ]
}
