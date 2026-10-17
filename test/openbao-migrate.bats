#!/usr/bin/env bats
# @id     openbao-migrate
# @target scripts/openbao-migrate.sh
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   SA-TODO-003 cutover: export every KV v2 value, ACL policy, JWT-type
#         auth mount (config and roles) from the retiring dev OpenBao; import
#         it into the persistent server as inf-bao-admin; verify key by key on
#         sha256 of canonical JSON. Logs carry hashes, never values. Import is
#         idempotent. Root and inf-bao-admin material is never exported or
#         overwritten.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/openbao-migrate.sh"
  W="${BATS_TEST_TMPDIR}"
  cat >"$W/src.json" <<'JSON'
{"mounts": {"kv/": {"type": "kv", "options": {"version": "2"}},
            "secret/": {"type": "kv", "options": {"version": "2"}},
            "sys/": {"type": "system"}, "identity/": {"type": "identity"},
            "cubbyhole/": {"type": "cubbyhole"}},
 "auth": {"jwt/": {"type": "jwt"}, "jwt-payments/": {"type": "jwt"}, "token/": {"type": "token"}},
 "paths": {
  "kv/data/signalloom/fe-signalloom": {"value": "SECRET-FE-VALUE"},
  "kv/data/signalloom/cardvault-agent": {"username": "cardvault-svc", "password": "SECRET-CARD-PW"},
  "secret/data/agents/cpai-engineer/anthropic/api-key": {"value": "SECRET-SK-ANT"},
  "sys/policies/acl/root": {"policy": ""},
  "sys/policies/acl/default": {"policy": "path \"sys/capabilities-self\" {}"},
  "sys/policies/acl/inf-bao-admin": {"policy": "path \"*\" {}"},
  "sys/policies/acl/signalloom-fe-signalloom": {"policy": "path \"kv/data/signalloom/fe-signalloom\" { capabilities = [\"read\"] }"},
  "sys/policies/acl/signalloom-agent-kagent-k8s-reader": {"policy": "path \"secret/data/agents/k8s-reader/*\" { capabilities = [\"read\"] }"},
  "auth/jwt/config": {"jwks_url": "http://spire-oidc.inf-bao.svc.cluster.local:8008/keys"},
  "auth/jwt/role/signalloom-fe-signalloom": {"role_type": "jwt", "bound_subject": "spiffe://x/fe", "token_ttl": 300},
  "auth/jwt/role/inf-bao-admin": {"role_type": "jwt", "bound_subject": "spiffe://x/admin"},
  "auth/jwt-payments/config": {"jwks_url": "http://spire-oidc.inf-bao.svc.cluster.local:8008/keys"},
  "auth/jwt-payments/role/fleet-txn-pipeline": {"role_type": "jwt", "bound_subject": "spiffe://x/txn"}
 }}
JSON
  cat >"$W/dst.json" <<'JSON'
{"mounts": {"kv/": {"type": "kv", "options": {"version": "2"}},
            "secret/": {"type": "kv", "options": {"version": "2"}},
            "sys/": {"type": "system"}},
 "auth": {"jwt/": {"type": "jwt"}, "token/": {"type": "token"}},
 "paths": {
  "sys/policies/acl/inf-bao-admin": {"policy": "path \"*\" { capabilities = [\"read\"] } # DST-OWNED"},
  "auth/jwt/role/inf-bao-admin": {"role_type": "jwt", "bound_subject": "spiffe://x/admin-DST"},
  "auth/jwt/config": {"jwks_url": "http://spire-oidc.inf-bao.svc.cluster.local:8008/keys"}
 }}
JSON
  for side in src dst; do
    printf '#!/bin/sh\nFAKE_BAO_STORE="%s/%s.json" exec python3 "%s/test/fixtures/fake-bao-store.py" "$@"\n' \
      "$W" "$side" "$REPO_ROOT" >"$W/bao-$side"
    chmod +x "$W/bao-$side"
  done
  export OPENBAO_MIGRATE_SRC_BAO="$W/bao-src" OPENBAO_MIGRATE_DST_BAO="$W/bao-dst"
  EXPORT="$W/export/openbao-export.json"
  mkdir -p "$W/export"
}

dst() { python3 -c "import json,sys; print(json.dumps(json.load(open('$W/dst.json'))$1))"; }

@test "migrate: a subcommand and --file are required" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  run "$SCRIPT" export
  [ "$status" -eq 2 ]
}

@test "export: writes a 0600 file with every KV value, policy, mount and role, and no root or admin material" {
  run "$SCRIPT" export --file "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$EXPORT")" = "600" ]
  [ "$(jq '.kv | length' "$EXPORT")" = "3" ]
  [ "$(jq -r '[.policies[].name] | sort | join(",")' "$EXPORT")" = "default,signalloom-agent-kagent-k8s-reader,signalloom-fe-signalloom" ]
  [ "$(jq -r '[.jwt_roles[] | .mount + .name] | sort | join(",")' "$EXPORT")" = "jwt-payments/fleet-txn-pipeline,jwt/signalloom-fe-signalloom" ]
  [ "$(jq -r '[.auth_mounts[].path] | sort | join(",")' "$EXPORT")" = "jwt-payments/,jwt/" ]
  [ "$(jq -r '[.kv_mounts[].path] | sort | join(",")' "$EXPORT")" = "kv/,secret/" ]
  [[ "$output" == *"exported kv=3 policies=3 auth_mounts=2 jwt_roles=2"* ]]
}

@test "export: logs carry sha256 hashes, never a secret value" {
  run "$SCRIPT" export --file "$EXPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kv kv/signalloom/fe-signalloom sha256="* ]]
  [[ "$output" != *SECRET-* ]]
}

@test "export: an unreachable source fails and writes no file" {
  FAKE_BAO_DOWN=1 run "$SCRIPT" export --file "$EXPORT"
  [ "$status" -ne 0 ]
  [ ! -e "$EXPORT" ]
}

@test "import then verify: every key matches, counts reported, values never logged" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  run "$SCRIPT" import --file "$EXPORT"
  [ "$status" -eq 0 ]
  [[ "$output" != *SECRET-* ]]
  run "$SCRIPT" verify --file "$EXPORT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"verified matched=10 mismatched=0 missing=0"* ]]
  [[ "$output" != *SECRET-* ]]
  [ "$(dst "['paths']['kv/data/signalloom/cardvault-agent']['password']")" = '"SECRET-CARD-PW"' ]
}

@test "import: creates missing KV and JWT auth mounts" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  "$SCRIPT" import --file "$EXPORT" >/dev/null
  [ "$(dst "['auth']['jwt-payments/']['type']")" = '"jwt"' ]
}

@test "import: never overwrites root or inf-bao-admin material" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  "$SCRIPT" import --file "$EXPORT" >/dev/null
  [[ "$(dst "['paths']['sys/policies/acl/inf-bao-admin']['policy']")" == *DST-OWNED* ]]
  [ "$(dst "['paths']['auth/jwt/role/inf-bao-admin']['bound_subject']")" = '"spiffe://x/admin-DST"' ]
  run rg -c 'sys/policies/acl/root' "$W/dst.json.writes"
  [ "$status" -eq 1 ]
}

@test "import: a second run writes nothing (idempotent)" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  "$SCRIPT" import --file "$EXPORT" >/dev/null
  before="$(wc -l <"$W/dst.json.writes")"
  run "$SCRIPT" import --file "$EXPORT"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$W/dst.json.writes")" = "$before" ]
  [[ "$output" == *"imported written=0 unchanged=10"* ]]
}

@test "verify: a changed value fails with the path and both hashes, never the value" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  "$SCRIPT" import --file "$EXPORT" >/dev/null
  python3 - "$W/dst.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["paths"]["kv/data/signalloom/fe-signalloom"] = {"value": "SECRET-TAMPERED"}
json.dump(s, open(p, "w"))
PY
  run "$SCRIPT" verify --file "$EXPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISMATCH kv kv/signalloom/fe-signalloom want="*" got="* ]]
  [[ "$output" == *"mismatched=1"* ]]
  [[ "$output" != *SECRET-* ]]
}

@test "verify: a key absent from the target is reported missing" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  run "$SCRIPT" verify --file "$EXPORT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING kv kv/signalloom/fe-signalloom"* ]]
}

@test "verify: a role field newer servers add does not count as a mismatch" {
  "$SCRIPT" export --file "$EXPORT" >/dev/null
  "$SCRIPT" import --file "$EXPORT" >/dev/null
  python3 - "$W/dst.json" <<'PY'
import json, sys
p = sys.argv[1]; s = json.load(open(p))
s["paths"]["auth/jwt/role/signalloom-fe-signalloom"]["new_field_in_2_7"] = True
json.dump(s, open(p, "w"))
PY
  run "$SCRIPT" verify --file "$EXPORT"
  [ "$status" -eq 0 ]
}
