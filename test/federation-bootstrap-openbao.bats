#!/usr/bin/env bats
# @id test/federation-bootstrap-openbao.bats
# @target scripts/bootstrap-spire-federation.sh (steps jwks, openbao, signal-ingest)
# @spec d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml
#
# SLDC-P2-2: what the bootstrap actually writes into OpenBao and the
# signal-ingest JWKS ConfigMap, driven offline by fake spire-server, bao and
# kubectl binaries that record argv and stdin. Only jwt-svid keys may become
# trust anchors; anything the script cannot convert must stop it before the
# first write; the root token must never reach argv.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/bootstrap-spire-federation.sh"
ROLE_FILE="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"

# P-256 key -> "<x_b64url> <y_b64url>" and its openssl SPKI PEM in $1.pem
p256() {
  openssl ecparam -name prime256v1 -genkey -noout -out "$1.key" 2>/dev/null
  openssl ec -in "$1.key" -pubout -out "$1.pem" 2>/dev/null
  local pt
  pt=$(openssl ec -in "$1.key" -pubout -outform DER 2>/dev/null | tail -c 64 | basenc --base16 -w0)
  printf '%s %s\n' "$(printf '%s' "${pt:0:64}" | basenc --base16 -d | basenc --base64url -w0 | tr -d '=')" \
    "$(printf '%s' "${pt:64:64}" | basenc --base16 -d | basenc --base64url -w0 | tr -d '=')"
}

setup() {
  F="$BATS_TEST_TMPDIR"; export F CALLS="$BATS_TEST_TMPDIR/calls"; : >"$CALLS"
  read -r JX JY < <(p256 "$F/jwt")
  read -r XX XY < <(p256 "$F/x509")
  jq -n --arg jx "$JX" --arg jy "$JY" --arg xx "$XX" --arg xy "$XY" '{keys: [
    {use: "x509-svid", kty: "EC", crv: "P-256", x: $xx, y: $xy, x5c: ["AA=="]},
    {use: "jwt-svid", kty: "EC", kid: "jwt-a", crv: "P-256", x: $jx, y: $jy}], spiffe_sequence: 3}' >"$F/bundle.json"
  cat >"$F/spire" <<'EOF'
#!/usr/bin/env bash
echo "spire $*" >>"$CALLS"
[ "$1 $2" = "bundle list" ] && cat "$F/bundle.json"
EOF
  cat >"$F/bao" <<'EOF'
#!/usr/bin/env bash
echo "bao $*" >>"$CALLS"
case "$*" in
  status) exit 0 ;;
  "secrets list -format=json"|"auth list -format=json") echo '{}' ;;
  "read transit/keys/"*) exit 1 ;;
  "write auth/"*"/config -") cat >"$F/bao-config.json" ;;
  "write auth/"*"/role/"*" -") cat >"$F/bao-role.json" ;;
  "policy write "*" -") cat >"$F/bao-policy.hcl" ;;
esac
exit 0
EOF
  cat >"$F/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
case "$*" in
  *"create configmap signal-ingest-jwks"*) printf 'data:\n  jwks.json: %s\n' "$(cat)" ;;
  *"apply -f -"*) cat >>"$F/applied" ;;
  *"get deploy/signal-ingest"*) exit 1 ;;
esac
exit 0
EOF
  chmod +x "$F/spire" "$F/bao" "$F/kubectl"
  export SPIRE_HUB_CMD="$F/spire" SPIRE_WORKLOAD_CMD="$F/spire" BAO_BIN="$F/bao" KUBECTL_BIN="$F/kubectl" \
    BAO_ADDR=http://127.0.0.1:1 BAO_TOKEN=s.root-token-must-not-leak BACKOFF_MAX_ATTEMPTS=1
}

no_bao_writes() { if grep -Eq '^bao (write|policy|auth enable|secrets enable)' "$CALLS"; then grep '^bao' "$CALLS" >&2; return 1; fi; }

@test "jwks: only jwt-svid keys are exported, x509 authorities are dropped" {
  run "$SCRIPT" jwks
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.keys[] | [.kid, .use]]' <<<"$output")" = '[["jwt-a","jwt-svid"]]' ]
}

@test "jwks: a bundle with no jwt-svid key exits 2 and names the trust domain" {
  jq '.keys |= map(select(.use != "jwt-svid"))' "$F/bundle.json" >"$F/b" && mv "$F/b" "$F/bundle.json"
  run "$SCRIPT" jwks
  [ "$status" -eq 2 ]
  [[ "$output" == *"hub holds no jwt-svid keys for osramp.local"* ]]
}

@test "jwks: an unreachable hub SPIRE server exits 2, not an empty key set" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$F/spire"
  run "$SCRIPT" jwks
  [ "$status" -eq 2 ]
}

@test "openbao: trusts exactly the jwt-svid key as openssl's PEM and writes the shipped role" {
  run "$SCRIPT" openbao
  [ "$status" -eq 0 ]
  [ "$(jq -r '.jwt_validation_pubkeys | length' "$F/bao-config.json")" -eq 1 ]
  [ "$(jq -r '.jwt_validation_pubkeys[0]' "$F/bao-config.json")" = "$(cat "$F/jwt.pem")" ]
  [ "$(jq -S . "$F/bao-role.json")" = "$(yq -e 'select(.metadata.name == "openbao-jwt-role-config") | .data."role.json"' "$ROLE_FILE" | jq -S .)" ]
  grep -qx 'bao write auth/jwt-osramp/role/agent-cardvault -' "$CALLS"
}

@test "openbao: the root token never appears on any argv" {
  run "$SCRIPT" openbao
  [ "$status" -eq 0 ]
  if grep -q 'root-token-must-not-leak' "$CALLS"; then return 1; fi
}

@test "openbao: a non-P-256 jwt-svid key exits 1 before any OpenBao write" {
  jq '.keys += [{use: "jwt-svid", kty: "EC", kid: "p384", crv: "P-384", x: "AA", y: "AA"}]' "$F/bundle.json" >"$F/b" && mv "$F/b" "$F/bundle.json"
  run "$SCRIPT" openbao
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsupported JWT key EC/P-384"* ]]
  no_bao_writes
}

@test "openbao: truncated P-256 coordinates exit 1 before any OpenBao write" {
  jq '.keys |= map(if .use == "jwt-svid" then .x = .x[0:20] else . end)' "$F/bundle.json" >"$F/b" && mv "$F/b" "$F/bundle.json"
  run "$SCRIPT" openbao
  [ "$status" -eq 1 ]
  [[ "$output" == *"malformed P-256 coordinates in jwt-a"* ]]
  no_bao_writes
}

@test "openbao: no jwt-svid key exits 2 before any OpenBao write" {
  jq '.keys |= map(select(.use != "jwt-svid"))' "$F/bundle.json" >"$F/b" && mv "$F/b" "$F/bundle.json"
  run "$SCRIPT" openbao
  [ "$status" -eq 2 ]
  no_bao_writes
}

@test "openbao: a sealed OpenBao exits 3 before any write" {
  sed -i 's/^  status) exit 0 ;;/  status) exit 2 ;;/' "$F/bao"
  run "$SCRIPT" openbao
  [ "$status" -eq 3 ]
  no_bao_writes
}

@test "openbao: BAO_ADDR unset exits non-zero before contacting OpenBao" {
  BAO_ADDR= run "$SCRIPT" openbao
  [ "$status" -ne 0 ]
  [[ "$output" == *"BAO_ADDR must be set"* ]]
  if grep -q '^bao' "$CALLS"; then return 1; fi
}

@test "signal-ingest: the JWKS ConfigMap carries only jwt-svid keys" {
  run "$SCRIPT" signal-ingest
  [ "$status" -eq 0 ]
  jwks=$(yq -r '.data."jwks.json"' "$F/applied" | rg -v '^(---|null)$' | tail -1)
  [ "$(jq -c '[.keys[].kid]' <<<"$jwks")" = '["jwt-a"]' ]
}

@test "signal-ingest: no jwt-svid key exits 2 and applies nothing" {
  jq '.keys |= map(select(.use != "jwt-svid"))' "$F/bundle.json" >"$F/b" && mv "$F/b" "$F/bundle.json"
  run "$SCRIPT" signal-ingest
  [ "$status" -eq 2 ]
  if grep -q 'apply' "$CALLS"; then return 1; fi
}
