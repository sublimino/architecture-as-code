#!/usr/bin/env bash
# @id      openbao-agent-generic-role-lab
# @target  d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml,
#          d2-signalloom/infra/agent-swarm/openbao-agent-sidecar.yaml, scripts/swarm-seed-secrets.sh
# @tests   d2-signalloom/test/openbao-agent-secret-authz.bats (the static half)
#
# Behavioural proof, offline, of the agent-swarm secret path end to end: a
# throwaway dev OpenBao in a local container (the cluster's server image),
# configured by the role Job's own script run the way the Job runs it
# (`sh`, inside that image), seeded by scripts/swarm-seed-secrets.sh, then a
# real `bao agent` (the sidecars' image) running a sidecar's agent.hcl
# against a JWT file. JWTs are signed by a lab key made here; nothing
# touches a cluster. Needs docker and the two images; exits non-zero on any
# failed expectation.
#
#   d2-signalloom/test/openbao-agent-generic-role-lab.sh
#   SERVER_IMG=... AGENT_IMG=... KEEP=1 d2-signalloom/test/openbao-agent-generic-role-lab.sh
set -o pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER_IMG="${SERVER_IMG:-quay.io/openbao/openbao:2.1.1}"
AGENT_IMG="${AGENT_IMG:-openbao/openbao:2.1.0}"
ROLE_YAML="$REPO/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"
SIDECAR_YAML="$REPO/d2-signalloom/infra/agent-swarm/openbao-agent-sidecar.yaml"
PREFIX="spiffe://signalloom.demo/ns/fe-signalloom-agents/sa"
D=(docker)

L="$(mktemp -d "${TMPDIR:-/tmp}/bao-role-lab.XXXXXX")" || exit 2
chmod 755 "$L"
PORT=$(( 20000 + RANDOM % 20000 ))
NAME="bao-role-lab-${PORT}"
export BAO_ADDR="http://127.0.0.1:${PORT}" BAO_TOKEN="lab-root" VAULT_ADDR= VAULT_TOKEN=
cleanup() {
  "${D[@]}" rm -f "$NAME" "${NAME}-agent" >/dev/null 2>&1
  [ -n "${KEEP:-}" ] && echo "lab dir kept: $L" || rm -rf "$L"
}
trap cleanup EXIT

fails=0
pass() { printf 'ok   %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
expect() { local what="$1"; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

# bao CLI inside the server container, so the lab needs no host binary.
# BAO_TOKEN goes by name (-e VAR), so its value never lands in docker's argv.
bao() { "${D[@]}" exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN "$NAME" bao "$@"; }

"${D[@]}" run -d --rm --name "$NAME" -p "127.0.0.1:${PORT}:8200" "$SERVER_IMG" \
  server -dev -dev-root-token-id=lab-root -dev-listen-address=0.0.0.0:8200 >/dev/null || exit 2
for _ in $(seq 1 300); do bao status >/dev/null 2>&1 && break; sleep 0.1; done
bao status >/dev/null 2>&1 || { echo "dev server never came up"; exit 2; }
echo "server $SERVER_IMG on $PORT, agent $AGENT_IMG"

# The cluster's auth/jwt mount trusts SPIRE's JWKS; here a lab RSA key.
openssl genrsa -out "$L/k.pem" 2048 2>/dev/null
openssl rsa -in "$L/k.pem" -pubout -out "$L/pub.pem" 2>/dev/null
bao auth enable jwt >/dev/null
bao write auth/jwt/config jwt_validation_pubkeys="$(cat "$L/pub.pem")" >/dev/null

b64u() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
mkjwt() { # sub aud > file (0600)
  local now h p
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64u)
  p=$(printf '{"sub":"%s","aud":["%s"],"iat":%s,"nbf":%s,"exp":%s}' "$1" "$2" "$now" "$now" $((now + 600)) | b64u)
  ( umask 077; printf '%s.%s.%s' "$h" "$p" "$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$L/k.pem" | b64u)" >"$3" )
}
login() { # jwt-file -> token on stdout (empty on refusal); the JWT goes on stdin
  BAO_TOKEN= bao write -field=token auth/jwt/login role=signalloom-agent-generic jwt=- <"$1" 2>/dev/null
}
readable() { # token kv-v2-api-path
  BAO_TOKEN="$1" bao read -field=data "$2" >/dev/null 2>&1
}
unreadable() { ! readable "$@"; }

for sa in zulip-chat-agent swarm-governor rogue-sa; do mkjwt "$PREFIX/$sa" openbao-supercredential "$L/jwt-$sa"; done
mkjwt "$PREFIX/zulip-chat-agent" fleet-manager "$L/jwt-wrong-aud"

# A login BEFORE the role Job's entities exist auto-creates an unnamed entity
# for that SVID; the Job must fold it into the named one. (The role must
# exist for the login, so write a bare role first, as an older Job did.)
yq '.data["agent-generic-role.sh"] | select(. != null)' "$ROLE_YAML" >"$L/role.sh"
bao policy write signalloom-agent-templated - <<<'path "secret/nothing" { capabilities = ["deny"] }' >/dev/null
bao write auth/jwt/role/signalloom-agent-generic - >/dev/null <<EOF
{"role_type":"jwt","bound_audiences":"openbao-supercredential","user_claim":"sub","bound_claims_type":"glob","bound_claims":{"sub":"${PREFIX}/*"},"token_policies":"signalloom-agent-templated"}
EOF
early="$(login "$L/jwt-swarm-governor")"
expect "pre-Job login by swarm-governor succeeds (creates an unnamed entity)" test -n "$early"

echo "--- role Job script, twice (idempotent), as the Job runs it: sh inside the server image"
for run in 1 2; do
  "${D[@]}" exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN "$NAME" sh <"$L/role.sh" >"$L/role-$run.log" 2>&1
  rc=$?
  expect "role script run $run exits 0" test "$rc" -eq 0
done
expect "role script names all six entities" test "$(rg -c -e '^entity ' "$L/role-2.log" || echo 0)" -eq 6

echo "--- seeder"
mkdir -p "$L/bin"
cat >"$L/bin/bao" <<EOF
#!/usr/bin/env bash
exec ${D[*]} exec -i -e BAO_ADDR=http://127.0.0.1:8200 -e BAO_TOKEN $NAME bao "\$@"
EOF
chmod +x "$L/bin/bao"
PATH="$L/bin:$PATH" bash "$REPO/scripts/swarm-seed-secrets.sh" >"$L/seed.log" 2>&1
expect "seeder writes every secret (no '✗')" test "$(rg -c -e '✗' "$L/seed.log" || echo 0)" -eq 0
expect "secrets are keyed by service account, no spiffe: segment" \
  test "$(bao kv list -format=json secret/agents 2>/dev/null | tr -d ' \n')" = '["cpai-engineer/","prod-deploy-gate/","prompt-commit-summarizer/","swarm-governor/","triage-ci-worker/","zulip-chat-agent/"]'

echo "--- authn and authz"
zt="$(login "$L/jwt-zulip-chat-agent")"
expect "zulip-chat-agent SVID logs in" test -n "$zt"
expect "wrong-audience SVID is refused" test -z "$(login "$L/jwt-wrong-aud")"
expect "zulip-chat-agent reads its own secret" readable "$zt" secret/data/agents/zulip-chat-agent/zulip/api-key
expect "zulip-chat-agent cannot read swarm-governor's" unreadable "$zt" secret/data/agents/swarm-governor/anthropic/api-key
gt="$(login "$L/jwt-swarm-governor")"
expect "swarm-governor (logged in before the Job ran) reads its own after the merge" readable "$gt" secret/data/agents/swarm-governor/anthropic/api-key
rt="$(login "$L/jwt-rogue-sa")"
expect "an unregistered SA in the namespace logs in (the glob admits it)" test -n "$rt"
for p in zulip-chat-agent/zulip/api-key swarm-governor/anthropic/api-key; do
  expect "...but reads nothing: $p" unreadable "$rt" "secret/data/agents/$p"
done

echo "--- bao agent ($AGENT_IMG) with the repo's zulip-chat-agent agent.hcl"
mkdir -p "$L/secrets" "$L/home" && chmod 777 "$L/secrets" "$L/home"
yq 'select(.metadata.name == "zulip-chat-agent-openbao-config") | .data["agent.hcl"]' "$SIDECAR_YAML" \
  | sed -e "s#http://openbao.inf-bao.svc.cluster.local:8200#http://127.0.0.1:8200#" \
        -e "s#/var/run/secrets/spiffe/jwt#$L/jwt-zulip-chat-agent#" \
        -e "s#/home/openbao/.bao-token#$L/home/.bao-token#" -e "s#/vault/secrets/#$L/secrets/#" >"$L/agent.hcl"
"${D[@]}" run -d --name "${NAME}-agent" --network "container:${NAME}" --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e SPIFFE_ID="$PREFIX/zulip-chat-agent" -v "$L:$L" --entrypoint bao "$AGENT_IMG" \
  agent -config="$L/agent.hcl" >/dev/null
for _ in $(seq 1 150); do
  [ -s "$L/secrets/ZULIP_API_KEY" ] && break
  [ "$("${D[@]}" inspect -f '{{.State.Running}}' "${NAME}-agent" 2>/dev/null)" = true ] || break
  sleep 0.2
done
sleep 1
"${D[@]}" logs "${NAME}-agent" >"$L/agent.log" 2>&1
expect "agent still running" test "$("${D[@]}" inspect -f '{{.State.Running}}' "${NAME}-agent")" = true
expect "agent logged 'authentication successful'" rg -q -e 'authentication successful' "$L/agent.log"
expect "agent logged no template error" bash -c '! rg -q -e "template server error|runtime error" "$1"' _ "$L/agent.log"
expect "/vault/secrets/ZULIP_API_KEY rendered the seeded value" \
  test "$(cat "$L/secrets/ZULIP_API_KEY" 2>/dev/null | tr -d '\n')" = "demo-zulip-api-key-not-real-000000000000"
expect "JWT file still present after the agent read it (remove_jwt_after_reading=false)" test -s "$L/jwt-zulip-chat-agent"
expect "agent log carries no JWT and no token" \
  bash -c '! rg -q -F -e "$(cut -d. -f2 "$1")" -e "$(cat "$2" 2>/dev/null || echo NO-SINK)" "$3"' _ "$L/jwt-zulip-chat-agent" "$L/home/.bao-token" "$L/agent.log"

echo
[ "$fails" -eq 0 ] && echo "LAB PASS" || echo "LAB FAIL: $fails"
exit $(( fails > 0 ))
