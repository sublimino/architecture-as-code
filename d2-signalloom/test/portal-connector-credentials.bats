#!/usr/bin/env bats
# @id     portal-connector-credentials
# @target d2-signalloom/apps/fe-signalloom/base/deployment.yaml
# @doc    docs/signalloom/security-architecture-todos.md
# @spec   SA-TODO-003 phase 2: the portal reads and writes connector credentials
#         in OpenBao KV v2 as role signalloom-fe-signalloom, through a bao agent
#         sidecar. The policy grants exactly the tenant connector paths, the
#         Deployment carries a token FILE path and never a token.

setup() {
  ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BOOT="${ROOT}/d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml"
  DEP="${ROOT}/d2-signalloom/apps/fe-signalloom/base/deployment.yaml"
  MIRROR="${ROOT}/d2-signalloom/infra/inf-bao/controllers/base/spire-openbao-config.yaml"
}

policy() { yq ea '[select(.kind=="Job")] | .[0] | .spec.template.spec.containers[0].command[2]' "$BOOT" \
  | awk "/<<'POLICY'/{f=1;next} /^POLICY/{f=0} f"; }

@test "policy grants create/read/update on tenant connector data and delete on its metadata" {
  run policy
  [[ "$output" == *'path "kv/data/signalloom/tenants/+/connectors/+" { capabilities = ["create", "read", "update"] }'* ]]
  [[ "$output" == *'path "kv/metadata/signalloom/tenants/+/connectors/+" { capabilities = ["delete"] }'* ]]
}

@test "policy grants nothing broader than one connector per tenant" {
  run policy
  [[ "$output" != *'signalloom/tenants/*'* ]]
  [[ "$output" != *'kv/data/*'* ]]
  [[ "$output" != *'"list"'* ]]
  [ "$(printf '%s\n' "$output" | rg -c '^\s*path ')" = "3" ]
}

@test "the policy mirror ConfigMap says the same as the setup Job" {
  mirror="$(yq ea '[select(.metadata.name=="openbao-spire-policy")] | .[0] | .data."signalloom-fe-signalloom.hcl"' "$MIRROR")"
  [ "$(printf '%s\n' "$mirror" | sed 's/^ *//' | sort)" = "$(policy | sed 's/^ *//' | rg '^path ' | sort)" ]
}

@test "the role is JSON on stdin with audience openbao and 5-minute batch tokens" {
  run yq ea '[select(.kind=="Job")] | .[0] | .spec.template.spec.containers[0].command[2]' "$BOOT"
  [[ "$output" == *"bao write auth/jwt/role/signalloom-fe-signalloom - <<'ROLE'"* ]]
  [[ "$output" == *'"bound_audiences": "openbao"'* ]]
  [[ "$output" == *'"bound_subject": "spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom"'* ]]
  [[ "$output" == *'"token_type": "batch"'* ]]
  [[ "$output" == *'"token_ttl": "5m"'* ]]
}

@test "the portal reads a token file from its bao agent sidecar and never holds a token" {
  q='[select(.kind=="Deployment")] | .[0] | .spec.template.spec'
  [ "$(yq ea "$q | .containers[] | select(.name==\"discovery-portal\") | .env[] | select(.name==\"BAO_TOKEN_FILE\") | .value" "$DEP")" = "/var/run/secrets/openbao/token" ]
  [ "$(yq ea "$q | .containers[] | select(.name==\"discovery-portal\") | .env[] | select(.name==\"BAO_TOKEN\") | .name" "$DEP")" = "" ]
  [ "$(yq ea "$q | .containers[] | select(.name==\"discovery-portal\") | .volumeMounts[] | select(.name==\"openbao-token\") | .readOnly" "$DEP")" = "true" ]
  [ "$(yq ea "$q | .containers[] | select(.name==\"openbao-agent\") | .command | join(\" \")" "$DEP")" = "bao agent -config=/etc/openbao/agent.hcl" ]
  [ "$(yq ea "$q | .containers[] | select(.name==\"jwt-svid\") | .name" "$DEP")" = "jwt-svid" ]
  [ "$(yq ea "$q | .volumes[] | select(.name==\"openbao-token\") | .emptyDir.medium" "$DEP")" = "Memory" ]
}
