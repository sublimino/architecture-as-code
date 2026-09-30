#!/usr/bin/env bats
# @id test/spire-federation-openbao-jwt.bats
# @target scripts/bootstrap-spire-federation.sh
# @target d2-agent-trust/spire-federation-config.yaml
# @target d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml
# @target d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml
# @doc docs/eap/SLDC-P2-TOPOLOGY-AUDIT.md
#
# SLDC-P2-2: SPIRE federation (osramp.local <-> signalloom.hub) and the
# OpenBao JWT role that admits federated osramp.local JWT-SVIDs by glob.
#
# Tier 1 (always): static contract of the four manifests, and the bootstrap
# script's backoff, seal handling, idempotency and JWK->PEM conversion with
# fake binaries.
#
# Tier 2 (SLDC_P22_LIVE=1): a disposable Docker lab. Two real SPIRE 1.11.1
# servers federate over https_spiffe using the manifest's own federation
# block; a real SPIRE agent mints JWT-SVIDs; a real OpenBao 2.1.1 is configured
# only by the bootstrap script, from the federated bundle. Nothing touches
# kind-osramp or kind-signalloom-hub. SLDC_P22_EVIDENCE_DIR keeps the evidence.
#
#   bats test/spire-federation-openbao-jwt.bats
#   SLDC_P22_LIVE=1 SLDC_P22_EVIDENCE_DIR=ci-evidence/sldc-p2-2 bats test/spire-federation-openbao-jwt.bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
# Absolute, because the Go check cds into the module before writing evidence.
[[ -z "${SLDC_P22_EVIDENCE_DIR:-}" || "$SLDC_P22_EVIDENCE_DIR" = /* ]] || SLDC_P22_EVIDENCE_DIR="$REPO_ROOT/$SLDC_P22_EVIDENCE_DIR"
SCRIPT="$REPO_ROOT/scripts/bootstrap-spire-federation.sh"
ROLE_FILE="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
FED_FILE="$REPO_ROOT/d2-agent-trust/spire-federation-config.yaml"
INGEST_FILE="$REPO_ROOT/d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml"
AUTH_GO="$REPO_ROOT/d2-signalloom/apps/signal-ingest/api/auth.go"
LAB=sldc-p22
CARDVAULT="spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault-worker-1"

role_json() { yq -e 'select(.kind == "ConfigMap" and .metadata.name == "openbao-jwt-role-config") | .data."role.json"' "$ROLE_FILE"; }
role_policy() { yq -e 'select(.metadata.name == "openbao-jwt-role-config") | .data."agent-cardvault-policy.hcl"' "$ROLE_FILE"; }
live() { [[ "${SLDC_P22_LIVE:-}" == 1 ]] || skip "live lab tier: set SLDC_P22_LIVE=1"; }

# ---------------------------------------------------------------- tier 1 ---

@test "role ConfigMap sets bound_claims_type to glob (PF-3)" {
  run bash -c "$(declare -f role_json); ROLE_FILE='$ROLE_FILE' role_json | jq -r .bound_claims_type"
  [ "$status" -eq 0 ]
  [ "$output" = "glob" ]
}

@test "role binds audiences, sub claim, policy and 1h TTL exactly as specified" {
  run bash -c "$(declare -f role_json); ROLE_FILE='$ROLE_FILE' role_json | jq -ce '[.role_type, .bound_audiences, .user_claim, .token_policies, .token_ttl, .token_max_ttl, .token_no_default_policy]'"
  [ "$status" -eq 0 ]
  [ "$output" = '["jwt",["signal-ingest","openbao"],"sub",["agent-cardvault-policy"],"1h","1h",true]' ]
}

@test "role glob is pinned to one namespace and one SA prefix (no ns/* or sa/* wildcard)" {
  run bash -c "$(declare -f role_json); ROLE_FILE='$ROLE_FILE' role_json | jq -r '.bound_claims.sub'"
  [ "$status" -eq 0 ]
  [ "$output" = "spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault*" ]
  [[ "$output" != *"/ns/*"* && "$output" != *"/sa/*"* && "$output" != *"osramp.local/*"* ]]
}

@test "role leeways are 5s, not OpenBao's 60s/150s defaults" {
  run bash -c "$(declare -f role_json); ROLE_FILE='$ROLE_FILE' role_json | jq -c '[.clock_skew_leeway, .expiration_leeway, .not_before_leeway]'"
  [ "$output" = "[5,5,5]" ]
}

@test "policy grants read on its own transit key only and denies escalation paths" {
  run bash -c "$(declare -f role_policy); ROLE_FILE='$ROLE_FILE' role_policy"
  [ "$status" -eq 0 ]
  grep -Fq 'path "transit/keys/agent-cardvault" {' <<<"$output"
  for denied in 'auth/token/create' 'auth/token/create-orphan' 'sys/policy/*' 'sys/policies/*' 'sys/auth/*' 'sys/mounts/*' 'transit/keys/agent-cardvault/rotate' 'transit/export/*'; do
    awk -v p="path \"$denied\" {" 'index($0,p){f=1} f&&/capabilities/{print; exit}' <<<"$output" | grep -Fq '"deny"'
  done
  ! grep -Eq 'sudo|path "\*"|path "transit/\*"' <<<"$output"
}

@test "legacy signalloom.demo role Job is untouched (additive change)" {
  run yq -e 'select(.kind == "Job") | .spec.template.spec.containers[0].command[2]' "$ROLE_FILE"
  grep -Fq '"sub": "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/*cardvault*"' <<<"$output"
  run kubectl kustomize "$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base"
  [ "$status" -eq 0 ]
  grep -q 'name: openbao-jwt-role-config' <<<"$output"
}

@test "federation manifest renders per side with no unrendered variables" {
  run "$SCRIPT" render workload
  [ "$status" -eq 0 ]
  # comments may name the variables; only YAML/HCL content must be rendered
  if grep -v '^[[:space:]]*#' <<<"$output" | grep -q '\${'; then echo "unrendered variable"; return 1; fi
  grep -Fq 'trust_domain = "osramp.local"' <<<"$output"
  grep -Fq 'federates_with "signalloom.hub"' <<<"$output"
  grep -Fq 'bundle_endpoint_url = "https://172.19.0.20:31843"' <<<"$output"
  grep -Fq 'endpoint_spiffe_id = "spiffe://signalloom.hub/spire/server"' <<<"$output"
  run "$SCRIPT" render hub
  grep -Fq 'trust_domain = "signalloom.hub"' <<<"$output"
  grep -Fq 'federates_with "osramp.local"' <<<"$output"
  grep -Fq 'bundle_endpoint_url = "https://172.19.0.10:31843"' <<<"$output"
  n=$(yq -N 'select(.kind != null) | .kind' <<<"$output" | wc -l)
  [ "$n" -ge 15 ]
}

@test "federation block markers exist exactly once (the live lab splices them)" {
  [ "$(grep -c '# BEGIN federation' "$FED_FILE")" -eq 1 ]
  [ "$(grep -c '# END federation' "$FED_FILE")" -eq 1 ]
  ! grep -q 'spire-server.spire.svc.cluster.local:8081/keys' <(grep -v '^#' "$FED_FILE")
}

@test "signal-ingest auth config names real permissions and exact SPIFFE IDs" {
  cfg=$(yq -e 'select(.metadata.name == "signal-ingest-jwt-auth") | .data' "$INGEST_FILE")
  [ "$(yq -r .SIGNAL_AUTH_AUDIENCE <<<"$cfg")" = signal-ingest ]
  [ "$(yq -r .SIGNAL_AUTH_TRUST_DOMAIN <<<"$cfg")" = osramp.local ]
  [ "$(yq -r .SIGNAL_AUTH_JWKS_REFRESH <<<"$cfg")" = 15m ]
  b=$(yq -r .SIGNAL_AUTH_BINDINGS <<<"$cfg")
  [ "$(jq -c 'keys' <<<"$b")" = '["spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent","spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel"]' ]
  [ "$(jq -r '[.[].tenant_id] | unique | join(",")' <<<"$b")" = kusari ]
  for p in $(jq -r '[.[].permissions[]] | unique | .[]' <<<"$b"); do
    grep -Fq "Permission = \"$p\"" "$AUTH_GO"
  done
}

@test "retry_backoff gives up after BACKOFF_MAX_ATTEMPTS with exit 2" {
  run bash -c "source '$SCRIPT'; sleep() { :; }; BACKOFF_MAX_ATTEMPTS=4; n=0; f() { n=\$((n+1)); echo \$n > '$BATS_TEST_TMPDIR/n'; return 1; }; retry_backoff probe f"
  [ "$status" -eq 2 ]
  [ "$(cat "$BATS_TEST_TMPDIR/n")" -eq 4 ]
  grep -q 'retrying in 4s' <<<"$output"
}

@test "wait_openbao retries while initialising and stops on a sealed OpenBao (exit 3)" {
  cat >"$BATS_TEST_TMPDIR/bao" <<EOF
#!/usr/bin/env bash
c=\$(cat "$BATS_TEST_TMPDIR/calls" 2>/dev/null || echo 0); echo \$((c+1)) >"$BATS_TEST_TMPDIR/calls"
(( c < 2 )) && exit 1
exit \${FAKE_FINAL_RC}
EOF
  chmod +x "$BATS_TEST_TMPDIR/bao"
  run bash -c "source '$SCRIPT'; sleep() { :; }; BAO_BIN='$BATS_TEST_TMPDIR/bao'; FAKE_FINAL_RC=0 wait_openbao"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/calls")" -eq 3 ]
  rm -f "$BATS_TEST_TMPDIR/calls"
  run bash -c "source '$SCRIPT'; sleep() { :; }; BAO_BIN='$BATS_TEST_TMPDIR/bao'; BACKOFF_MAX_ATTEMPTS=5; FAKE_FINAL_RC=2 wait_openbao"
  [ "$status" -eq 3 ]
  grep -q 'sealed - hard blocker' <<<"$output"
}

@test "entries step is idempotent: second run creates nothing" {
  cat >"$BATS_TEST_TMPDIR/spire" <<EOF
#!/usr/bin/env bash
db="$BATS_TEST_TMPDIR/entries"; touch "\$db"
id=""; for ((i=1;i<=\$#;i++)); do [[ "\${!i}" == -spiffeID ]] && { j=\$((i+1)); id="\${!j}"; }; done
case "\$1 \$2" in
  "entry show") grep -qxF "\$id" "\$db" && echo "Entry ID : x" ; exit 0 ;;
  "entry create") echo "\$id" >>"\$db"; echo create >>"$BATS_TEST_TMPDIR/creates" ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/spire"
  SPIRE_WORKLOAD_CMD="$BATS_TEST_TMPDIR/spire" run "$SCRIPT" entries
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/creates")" -eq 5 ]
  grep -qxF 'spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel' "$BATS_TEST_TMPDIR/entries"
  if grep -q 'signalloom-stun-sentinel' "$BATS_TEST_TMPDIR/entries"; then return 1; fi
  SPIRE_WORKLOAD_CMD="$BATS_TEST_TMPDIR/spire" run "$SCRIPT" entries
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/creates")" -eq 5 ]
}

@test "jwk_to_pem reproduces openssl's SPKI for a P-256 key and rejects other curves" {
  openssl ecparam -name prime256v1 -genkey -noout -out "$BATS_TEST_TMPDIR/k.pem" 2>/dev/null
  openssl ec -in "$BATS_TEST_TMPDIR/k.pem" -pubout -out "$BATS_TEST_TMPDIR/pub.pem" 2>/dev/null
  pt=$(openssl ec -in "$BATS_TEST_TMPDIR/k.pem" -pubout -outform DER 2>/dev/null | tail -c 64 | basenc --base16 -w0)
  b64u() { printf '%s' "$1" | basenc --base16 -d | basenc --base64url -w0 | tr -d '='; }
  jwk=$(jq -nc --arg x "$(b64u "${pt:0:64}")" --arg y "$(b64u "${pt:64:64}")" '{kty:"EC",crv:"P-256",kid:"t",x:$x,y:$y}')
  run bash -c "source '$SCRIPT'; jwk_to_pem '$jwk'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$BATS_TEST_TMPDIR/pub.pem")" ]
  run bash -c "source '$SCRIPT'; jwk_to_pem '{\"kty\":\"EC\",\"crv\":\"P-384\",\"kid\":\"t\",\"x\":\"AA\",\"y\":\"AA\"}'"
  [ "$status" -eq 1 ]
}

@test "unknown step fails with exit 1" {
  run "$SCRIPT" definitely-not-a-step
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------- tier 2 ---

lab_spire() { docker exec -i "$LAB-spire-$1" /opt/spire/bin/spire-server "${@:2}"; }
lab_jwt() { docker exec -u "$1" "$LAB-spire-agent" /opt/spire/bin/spire-agent api fetch jwt -audience "$2" -socketPath /run/spire/sockets/agent.sock | sed -n 2p | tr -d '\t '; }
lab_bao_url() { echo "http://$(docker port "$LAB-bao" 8200)"; }
# lab_login JWT -> "<http_code> <errors-or-policies>", body kept in $BATS_TEST_TMPDIR/login.json
lab_login() {
  jq -nc --arg j "$1" '{role: "agent-cardvault", jwt: $j}' |
    curl -s -o "$BATS_TEST_TMPDIR/login.json" -w '%{http_code}' -X POST --data @- "$(lab_bao_url)/v1/auth/jwt-osramp/login"
  printf ' %s\n' "$(jq -c '.errors // .auth.policies' "$BATS_TEST_TMPDIR/login.json")"
}
lab_env() {
  export SPIRE_WORKLOAD_CMD="docker exec -i $LAB-spire-osramp /opt/spire/bin/spire-server"
  export SPIRE_HUB_CMD="docker exec -i $LAB-spire-hub /opt/spire/bin/spire-server"
  export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN; BAO_TOKEN=$(cat "$LABDIR/root.token")
  export BAO_BIN="docker exec -i -e BAO_ADDR -e BAO_TOKEN $LAB-bao bao"
}
payload() { cut -d. -f2 <<<"$1" | basenc --base64url -d 2>/dev/null; }

lab_down() {
  docker rm -f "$LAB-spire-osramp" "$LAB-spire-hub" "$LAB-spire-agent" "$LAB-bao" >/dev/null 2>&1 || true
  docker network rm "$LAB-lab" >/dev/null 2>&1 || true
}

server_conf() { # TD PEER PEER_URL - core config + the manifest's federation block
  local fed
  fed=$(awk '/# BEGIN federation/{f=1;next} /# END federation/{f=0} f' "$FED_FILE" | sed 's/^      //' |
    SPIRE_TRUST_DOMAIN=$1 SPIRE_PEER_TRUST_DOMAIN=$2 SPIRE_PEER_BUNDLE_ENDPOINT_URL=$3 \
      envsubst '${SPIRE_TRUST_DOMAIN} ${SPIRE_PEER_TRUST_DOMAIN} ${SPIRE_PEER_BUNDLE_ENDPOINT_URL}')
  cat <<EOF
server {
  bind_address = "0.0.0.0"
  bind_port = "8081"
  trust_domain = "$1"
  data_dir = "/run/spire/data"
  log_level = "INFO"
  ca_key_type = "ec-p256"
  jwt_key_type = "ec-p256"
  default_jwt_svid_ttl = "5m"
$fed
}
plugins {
  DataStore "sql" { plugin_data { database_type = "sqlite3" connection_string = "/run/spire/data/datastore.sqlite3" } }
  KeyManager "memory" { plugin_data {} }
  NodeAttestor "join_token" { plugin_data {} }
}
EOF
}

setup_file() {
  [[ "${SLDC_P22_LIVE:-}" == 1 ]] || return 0
  export LABDIR="$BATS_FILE_TMPDIR/lab"; mkdir -p "$LABDIR"
  lab_down
  server_conf osramp.local signalloom.hub https://spire-hub:8443 >"$LABDIR/osramp.conf"
  server_conf signalloom.hub osramp.local https://spire-osramp:8443 >"$LABDIR/hub.conf"
  docker network create "$LAB-lab" >/dev/null
  for s in osramp hub; do
    docker run -d --name "$LAB-spire-$s" --network "$LAB-lab" --network-alias "spire-$s" \
      -v "$LABDIR/$s.conf:/conf/server.conf:ro" --tmpfs /run/spire/data:uid=1000,gid=1000 \
      ghcr.io/spiffe/spire-server:1.11.1 -config /conf/server.conf >/dev/null
  done
  for s in osramp hub; do
    for _ in $(seq 60); do lab_spire "$s" healthcheck >/dev/null 2>&1 && break; sleep 1; done
  done
  # Negative control before seeding: https_spiffe cannot authenticate the peer.
  lab_spire hub federation refresh -id spiffe://osramp.local >"$LABDIR/preseed.out" 2>&1 && echo 0 >"$LABDIR/preseed.rc" || echo $? >"$LABDIR/preseed.rc"
  # Federate first: an entry with -federatesWith needs the peer bundle to exist.
  SPIRE_WORKLOAD_CMD="docker exec -i $LAB-spire-osramp /opt/spire/bin/spire-server" \
    SPIRE_HUB_CMD="docker exec -i $LAB-spire-hub /opt/spire/bin/spire-server" \
    "$SCRIPT" seed federate >"$LABDIR/bootstrap.log" 2>&1

  lab_spire osramp bundle show >"$LABDIR/osramp-bundle.pem"
  tok=$(lab_spire osramp token generate -spiffeID spiffe://osramp.local/lab/node -ttl 600 | awk '{print $2}')
  cat >"$LABDIR/agent.conf" <<EOF
agent {
  data_dir = "/run/spire/data"
  log_level = "INFO"
  server_address = "spire-osramp"
  server_port = "8081"
  socket_path = "/run/spire/sockets/agent.sock"
  trust_domain = "osramp.local"
  trust_bundle_path = "/conf/bundle.pem"
}
plugins {
  NodeAttestor "join_token" { plugin_data {} }
  KeyManager "memory" { plugin_data {} }
  WorkloadAttestor "unix" { plugin_data {} }
}
EOF
  docker run -d --name "$LAB-spire-agent" --network "$LAB-lab" -v "$LABDIR/agent.conf:/conf/agent.conf:ro" \
    -v "$LABDIR/osramp-bundle.pem:/conf/bundle.pem:ro" --tmpfs /run/spire/data --tmpfs /run/spire/sockets:mode=0755 \
    ghcr.io/spiffe/spire-agent:1.11.1 -config /conf/agent.conf -joinToken "$tok" >/dev/null
  # unix:uid stands in for k8s:ns/sa in the lab; the SPIFFE IDs are the real ones.
  for e in "1001 ns/agent-trust/sa/agent-cardvault-worker-1" "1002 ns/fe-signalloom-agents/sa/kusari-agent" "1003 ns/fe-signalloom-agents/sa/stun-sentinel"; do
    set -- $e
    lab_spire osramp entry create -parentID spiffe://osramp.local/lab/node -spiffeID "spiffe://osramp.local/$2" \
      -selector "unix:uid:$1" -federatesWith spiffe://signalloom.hub >/dev/null
  done

  head -c 16 /dev/urandom | basenc --base16 -w0 >"$LABDIR/root.token"; chmod 600 "$LABDIR/root.token"
  BAO_DEV_ROOT_TOKEN_ID=$(cat "$LABDIR/root.token") docker run -d --name "$LAB-bao" --network "$LAB-lab" \
    -e BAO_DEV_ROOT_TOKEN_ID -p 127.0.0.1::8200 quay.io/openbao/openbao:2.1.1 server -dev >/dev/null

  lab_env
  "$SCRIPT" openbao >>"$LABDIR/bootstrap.log" 2>&1
  for _ in $(seq 60); do [[ -n "$(lab_jwt 1001 openbao 2>/dev/null)" ]] && break; sleep 1; done
}

teardown_file() {
  [[ "${SLDC_P22_LIVE:-}" == 1 ]] || return 0
  if [[ -n "${SLDC_P22_EVIDENCE_DIR:-}" ]]; then
    mkdir -p "$SLDC_P22_EVIDENCE_DIR"; cp "$LABDIR"/{bootstrap.log,preseed.out} "$SLDC_P22_EVIDENCE_DIR/" 2>/dev/null || true
  fi
  lab_down
}

evidence() { [[ -n "${SLDC_P22_EVIDENCE_DIR:-}" ]] && { mkdir -p "$SLDC_P22_EVIDENCE_DIR"; cat >"$SLDC_P22_EVIDENCE_DIR/$1"; } || cat >/dev/null; }

@test "live: federation refresh fails before the bundles are seeded (https_spiffe is real)" {
  live
  [ "$(cat "$LABDIR/preseed.rc")" -ne 0 ]
  grep -q 'local copy of bundle not found' "$LABDIR/preseed.out"
}

@test "live: bootstrap federated both directions and configured OpenBao" {
  live
  grep -q 'federation active in both directions' "$LABDIR/bootstrap.log"
  grep -q 'trusts 1 federated osramp.local key(s)' "$LABDIR/bootstrap.log"
  lab_env
  run "$SCRIPT" jwks
  [ "$status" -eq 0 ]
  [ "$(jq '[.keys[] | select(.use == "jwt-svid")] | length' <<<"$output")" -ge 1 ]
}

@test "live: SPIRE agent mints an osramp.local JWT-SVID for audience signal-ingest" {
  live
  t=$(lab_jwt 1003 signal-ingest)
  p=$(payload "$t")
  jq . <<<"$p" | evidence decoded-jwt-svid-signal-ingest.json
  [ "$(jq -r .sub <<<"$p")" = spiffe://osramp.local/ns/fe-signalloom-agents/sa/stun-sentinel ]
  [ "$(jq -c .aud <<<"$p")" = '["signal-ingest"]' ]
  [ "$(jq -r '.exp - .iat' <<<"$p")" -eq 300 ]
}

@test "live: wildcard subject agent-cardvault-worker-1 logs in with HTTP 200" {
  live
  run lab_login "$(lab_jwt 1001 openbao)"
  [ "$output" = '200 ["agent-cardvault-policy"]' ]
  jq '{http_status: 200, auth: (.auth | {policies, token_policies, lease_duration, renewable, metadata})}' "$BATS_TEST_TMPDIR/login.json" | evidence openbao-login-200.json
  jq -r '.data."role.json"' <(yq -o json 'select(.metadata.name == "openbao-jwt-role-config")' "$ROLE_FILE") | evidence openbao-jwt-role-config.role.json
}

@test "live: MUTATION bound_claims_type=string rejects the same token with HTTP 400" {
  live; lab_env
  role=$(role_json)
  jq '.bound_claims_type = "string"' <<<"$role" | $BAO_BIN write auth/jwt-osramp/role/agent-cardvault - >/dev/null
  run lab_login "$(lab_jwt 1001 openbao)"
  $BAO_BIN write auth/jwt-osramp/role/agent-cardvault - <<<"$role" >/dev/null
  printf '%s\n' "$output" | evidence mutation-string-login.txt
  [[ "$output" == '400 ["error validating claims: claim \"sub\" does not match any associated bound claim values"]' ]]
  run lab_login "$(lab_jwt 1001 openbao)"
  [ "$output" = '200 ["agent-cardvault-policy"]' ]
}

@test "live: audience outside bound_audiences is rejected" {
  live
  run lab_login "$(lab_jwt 1001 other)"
  [[ "$output" == 400* && "$output" == *"invalid audience (aud) claim"* ]]
}

@test "live: an osramp.local SVID outside the glob (kusari-agent) is rejected" {
  live
  run lab_login "$(lab_jwt 1002 openbao)"
  [[ "$output" == 400* && "$output" == *'claim \"sub\" does not match'* ]]
}

@test "live: a hub-domain signer and a tampered payload are both rejected" {
  live
  run lab_login "$(lab_spire hub jwt mint -spiffeID spiffe://signalloom.hub/ns/agent-trust/sa/agent-cardvault-worker-1 -audience openbao 2>/dev/null)"
  [[ "$output" == 400* && "$output" == *"no known key successfully validated"* ]]
  IFS=. read -r h _ s <<<"$(lab_jwt 1002 openbao)"
  forged=$(jq -nc --arg sub "$CARDVAULT" '{aud: ["openbao"], sub: $sub, exp: (now + 300 | floor)}' | basenc --base64url -w0 | tr -d =)
  run lab_login "$h.$forged.$s"
  [[ "$output" == 400* && "$output" == *"no known key successfully validated"* ]]
}

@test "live: an expired SVID is rejected once past the 5s leeway" {
  live
  t=$(lab_spire osramp jwt mint -spiffeID "$CARDVAULT" -audience openbao -ttl 30s 2>/dev/null)
  run lab_login "$t"
  [ "$output" = '200 ["agent-cardvault-policy"]' ]
  sleep $(( $(payload "$t" | jq .exp) - $(date +%s) + 7 ))
  run lab_login "$t"
  [[ "$output" == 400* && "$output" == *"token is expired"* ]]
}

@test "live: the workload token reads its transit key and cannot escalate" {
  live
  run lab_login "$(lab_jwt 1001 openbao)"
  tok=$(jq -r .auth.client_token "$BATS_TEST_TMPDIR/login.json")
  code() { curl -s -o /dev/null -w '%{http_code}' -H @- "$@" <<<"X-Vault-Token: $tok"; }
  b=$(lab_bao_url)
  [ "$(code "$b/v1/transit/keys/agent-cardvault")" = 200 ]
  [ "$(code -X POST "$b/v1/auth/token/create")" = 403 ]
  [ "$(code -X POST "$b/v1/auth/token/create-orphan")" = 403 ]
  [ "$(code -X POST "$b/v1/transit/keys/agent-cardvault/rotate")" = 403 ]
  [ "$(code -X PUT -d '{"policy":"path \"*\" {capabilities=[\"sudo\"]}"}' "$b/v1/sys/policies/acl/escalate")" = 403 ]
  [ "$(code -X POST -d '{"role_type":"jwt"}' "$b/v1/auth/jwt-osramp/role/evil")" = 403 ]
  [ "$(code "$b/v1/auth/token/lookup-self")" = 200 ]
}

@test "live: JWT key rotation on osramp.local reaches the hub through federation" {
  live; lab_env
  before=$("$SCRIPT" jwks | jq '.keys | length')
  lab_spire osramp localauthority jwt prepare >/dev/null
  lab_spire hub federation refresh -id spiffe://osramp.local >/dev/null
  after=$("$SCRIPT" jwks | jq '.keys | length')
  [ "$after" -eq $((before + 1)) ]
  run "$SCRIPT" openbao
  [ "$status" -eq 0 ]
  grep -q "trusts $after federated osramp.local key(s)" <<<"$output"
}

@test "live: signal-ingest verifier accepts a real SVID with the shipped config (Go)" {
  live; lab_env
  command -v go >/dev/null || fail "go toolchain required for the live signal-ingest check"
  cfg=$(yq -o json 'select(.metadata.name == "signal-ingest-jwt-auth") | .data' "$INGEST_FILE")
  export SIGNAL_AUTH_AUDIENCE SIGNAL_AUTH_TRUST_DOMAIN SIGNAL_AUTH_BINDINGS SIGNAL_AUTH_JWKS_REFRESH
  SIGNAL_AUTH_AUDIENCE=$(jq -r .SIGNAL_AUTH_AUDIENCE <<<"$cfg"); SIGNAL_AUTH_TRUST_DOMAIN=$(jq -r .SIGNAL_AUTH_TRUST_DOMAIN <<<"$cfg")
  SIGNAL_AUTH_BINDINGS=$(jq -r .SIGNAL_AUTH_BINDINGS <<<"$cfg"); SIGNAL_AUTH_JWKS_REFRESH=$(jq -r .SIGNAL_AUTH_JWKS_REFRESH <<<"$cfg")
  export SIGNAL_INGEST_LIVE_JWT SIGNAL_INGEST_LIVE_UNBOUND_JWT SIGNAL_INGEST_LIVE_JWKS
  SIGNAL_INGEST_LIVE_JWT=$(lab_jwt 1003 signal-ingest); SIGNAL_INGEST_LIVE_UNBOUND_JWT=$(lab_jwt 1001 signal-ingest)
  SIGNAL_INGEST_LIVE_JWKS=$("$SCRIPT" jwks)
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run env GOPATH="${SLDC_P22_GOPATH:-${GOPATH:-$HOME/go}}" GOMODCACHE="${SLDC_P22_GOPATH:-${GOPATH:-$HOME/go}}/pkg/mod" GOFLAGS=-mod=mod \
    go test ./api/ -run '^TestLiveSPIREJWTSVID$' -count=1 -v
  printf '%s\n' "$output" | evidence signal-ingest-live-verifier.txt
  [ "$status" -eq 0 ]
  grep -q -- '--- PASS: TestLiveSPIREJWTSVID' <<<"$output"
  ! grep -q -- '--- SKIP' <<<"$output"
}
