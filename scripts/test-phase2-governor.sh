#!/usr/bin/env bash
# @id scripts/test-phase2-governor.sh
# @doc docs/eap/SLDC-P2-GOVERNOR-REPORT.md
# @tests test/phase2-governor-verification.bats
# @lib scripts/lib/dual-cluster.sh, scripts/bootstrap-spire-federation.sh,
#      scripts/lib/p2gov-forge-jwt.ts, test/fixtures/phase2-governor/*.yaml
#
# SLDC-P2-GOV: Phase 2 governance runner. Certifies the cross-cluster trust
# fabric between kind-osramp (spiffe://osramp.local) and kind-signalloom-hub
# (spiffe://signalloom.hub) on the live dual-Kind topology.
#
# Usage: scripts/test-phase2-governor.sh [--keep-fixtures] [--skip-bringup]
#        scripts/test-phase2-governor.sh --crkc     (legacy CRKC Phase 2 suite)
#
# Gates (each recorded in the certification JSON):
#   G1  merge        P2-1/P2-2 commits are ancestors of HEAD, a --no-ff
#                    --no-commit re-merge is a no-op, no conflict markers
#   G2  bringup      dual-cluster-up.sh + bootstrap-spire-federation.sh,
#                    federation refresh both directions (5 tries, 2s backoff)
#   G3  tls          TLS 1.3 only on 172.19.0.20:31443, AEAD cipher, TLS 1.2
#                    refused
#   G4  mtls         pod on kind-osramp verifies the hub's signalloom.hub
#                    X.509-SVID through the federated bundle and presents its
#                    own osramp.local SVID; the hub verifies it (SUCCESS)
#   G5  ingest       JWT-SVID (aud signal-ingest) POST /api/v1/observations
#                    across the bridge -> 201; 10 consecutive exchanges, 0
#                    trust errors
#   G6  negative     anonymous -> 401 on a route proven to exist; malformed
#                    signature, rogue.local token, wrong audience -> 401/403;
#                    rogue.local client certificate refused at TLS
#   G7  openbao      glob subject agent-cardvault-worker-1 -> 200 + token;
#                    unauthorized-agent -> 400; expired SVID -> 400
#   G8  mutation     bound_claims_type removed -> same token 400, restored ->
#                    200; wrong trust bundle -> server verification fails
#
# Evidence: ci-evidence/phase2-governance-certification.json,
#           ci-evidence/phase2-token-exchange-audit.txt (tokens redacted to
#           header+claims; signatures and OpenBao client tokens never written).
# Exit: 0 all gates pass, 1 a gate failed, 2 usage, 3 hard blocker (persistent
#       federation/mTLS failure or anonymous access succeeded).
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

KEEP_FIXTURES=0
BRINGUP=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --crkc) shift; exec "$SCRIPT_DIR/test-crkc-phase2-governor.sh" "$@" ;;
    --keep-fixtures) KEEP_FIXTURES=1 ;;
    --skip-bringup) BRINGUP=0 ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# shellcheck source=scripts/lib/dual-cluster.sh
source "$SCRIPT_DIR/lib/dual-cluster.sh"

BOOTSTRAP="$SCRIPT_DIR/bootstrap-spire-federation.sh"
FIXTURE_DIR="$REPO_ROOT/test/fixtures/phase2-governor"
ROLE_MANIFEST="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
EVIDENCE_DIR="${P2GOV_EVIDENCE_DIR:-$REPO_ROOT/ci-evidence}"
CERT_JSON="$EVIDENCE_DIR/phase2-governance-certification.json"
AUDIT_TXT="$EVIDENCE_DIR/phase2-token-exchange-audit.txt"

P2_1_SHA="${P2_1_SHA:-3598eab5df94a9f93e4cc7b85e1410d2b7fad2a0}"
P2_2_SHA="${P2_2_SHA:-16ed92d1f80ee07947df9562788a21cef461cf39}"
FRONT_HOST="${FRONT_HOST:-$SLDC_HUB_IP}"
FRONT_PORT="${FRONT_PORT:-31443}"
FRONT_SNI="${FRONT_SNI:-sl-eap-4b53ab6b.ts.net}"
BAO_ADDR="${BAO_ADDR:-http://$SLDC_HUB_IP:30820}"
BAO_MOUNT=jwt-osramp
BAO_ROLE=agent-cardvault
HUB_NS=sldc-p2-gov
SOCK=/run/spire/sockets/agent.sock
EXPIRY_TTL=10
SI_IMAGE="${SI_IMAGE:-signal-ingest:sldc-p2-gov-$(git -C "$REPO_ROOT" rev-parse --short=8 HEAD)}"
export BAO_ADDR
# OpenBao CLI runs inside the fixture pod (see scripts/lib/p2gov-bao.sh)
BAO_BIN="${BAO_BIN:-$SCRIPT_DIR/lib/p2gov-bao.sh}"
export BAO_BIN P2GOV_HUB_NS=sldc-p2-gov HUB_CONTEXT="${SLDC_HUB_CTX:-kind-signalloom-hub}"

# probe name -> namespace/serviceaccount on kind-osramp
declare -A PROBE_NS=([kusari]=fe-signalloom-agents [cardvault]=agent-trust [unauth]=agent-trust [expiry]=agent-trust)
declare -A PROBE_SA=([kusari]=kusari-agent [cardvault]=agent-cardvault-worker-1 [unauth]=unauthorized-agent [expiry]=agent-cardvault-worker-expiry)

log() { printf '[p2-gov] %s\n' "$*" >&2; }
mkdir -p "$EVIDENCE_DIR"
: >"$AUDIT_TXT"
audit() { printf '%s\n' "$*" >>"$AUDIT_TXT"; }

GATES_JSON='[]'
FAILED=0
BLOCKER=0
# gate ID NAME STATUS DETAIL
gate() {
  GATES_JSON=$(jq -c --arg id "$1" --arg n "$2" --arg s "$3" --arg d "$4" \
    '. + [{id:$id, name:$n, status:$s, detail:$d}]' <<<"$GATES_JSON")
  audit "GATE $1 $2: $3 - $4"
  log "GATE $1 $2: $3 - $4"
  [ "$3" = pass ] || FAILED=1
}

# --- cleanup ------------------------------------------------------------------
PROBES_UP=()
# https()/bao_login() run inside $(...), so side results travel via files
P2GOV_TMP=$(mktemp -d)
CERT_WRITTEN=0
cleanup() {
  local rc=$?
  rm -rf "$P2GOV_TMP"
  if [ "$CERT_WRITTEN" = 0 ] && [ -n "${STARTED:-}" ]; then
    # aborted mid-run: never leave an earlier run's certificate standing
    gate ABORT runner fail "runner exited rc=$rc before all gates ran"
    write_cert fail
  fi
  if [ "$KEEP_FIXTURES" = 1 ]; then log "keeping fixtures (--keep-fixtures)"; return "$rc"; fi
  log "cleanup: deleting probe pods, fixture entries and hub fixture namespace"
  for p in "${PROBES_UP[@]}"; do
    kosr -n "${PROBE_NS[$p]}" delete pod "p2gov-$p" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  for sa in unauthorized-agent agent-cardvault-worker-expiry; do
    delete_entry workload "spiffe://osramp.local/ns/agent-trust/sa/$sa" || true
  done
  delete_entry hub "spiffe://signalloom.hub/ns/$HUB_NS/sa/sldc-p2-gov-front" || true
  if [ "$(kosr get ns agent-trust -o jsonpath='{.metadata.labels.signalloom\.io/fixture}' 2>/dev/null)" = true ]; then
    kosr delete ns agent-trust --wait=false >/dev/null 2>&1 || true
  fi
  khub delete ns "$HUB_NS" --wait=false >/dev/null 2>&1 || true
  return "$rc"
}
trap cleanup EXIT

spire_cli() { # workload|hub ARGS...
  local ctx=$SLDC_OSRAMP_CTX; [ "$1" = hub ] && ctx=$SLDC_HUB_CTX; shift
  "$KUBECTL_BIN" --context "$ctx" -n spire-system exec -i spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"
}
entry_id() { spire_cli "$1" entry show -spiffeID "$2" 2>/dev/null | awk '/^Entry ID/ {print $4; exit}'; }
delete_entry() { local id; id=$(entry_id "$1" "$2"); [ -z "$id" ] || spire_cli "$1" entry delete -entryID "$id" >/dev/null; }
ensure_entry() { # side spiffeID args...
  local side=$1 id=$2; shift 2
  [ -n "$(entry_id "$side" "$id")" ] || spire_cli "$side" entry create -spiffeID "$id" "$@" >/dev/null
}

# --- G1 merge ----------------------------------------------------------------------
g1_merge() {
  local out rc=0 markers dirty
  for s in "$P2_1_SHA" "$P2_2_SHA"; do
    git -C "$REPO_ROOT" merge-base --is-ancestor "$s" HEAD || { gate G1 merge fail "$s is not an ancestor of HEAD"; return; }
  done
  out=$(git -C "$REPO_ROOT" merge --no-commit --no-ff "$P2_1_SHA" "$P2_2_SHA" 2>&1) || rc=$?
  git -C "$REPO_ROOT" merge --abort >/dev/null 2>&1 || true
  markers=$(git -C "$REPO_ROOT" grep -lE '^(<<<<<<<|>>>>>>>) ' -- ':!*.md' 2>/dev/null | head -5 || true)
  dirty=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no | wc -l)
  audit "merge: HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD) re-merge rc=$rc output='$out'"
  if [ "$rc" -eq 0 ] && [[ "$out" == *"Already up to date"* ]] && [ -z "$markers" ]; then
    gate G1 merge pass "P2-1 ${P2_1_SHA:0:8} and P2-2 ${P2_2_SHA:0:8} are ancestors of HEAD; --no-ff --no-commit re-merge is a no-op; 0 conflict markers; $dirty tracked files modified at gate time"
  else
    gate G1 merge fail "re-merge rc=$rc out='$out' markers='$markers'"
  fi
}

# --- G2 bringup ---------------------------------------------------------------------
federation_ok() { # side peerTD
  local i
  for i in 1 2 3 4 5; do
    if spire_cli "$1" federation refresh -id "spiffe://$2" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}
g2_bringup() {
  if [ "$BRINGUP" = 1 ]; then
    "$SCRIPT_DIR/dual-cluster-up.sh" >>"$AUDIT_TXT" 2>&1 || { gate G2 bringup fail "dual-cluster-up.sh failed"; return; }
    "$BOOTSTRAP" apply seed federate entries >>"$AUDIT_TXT" 2>&1 || true
  fi
  local notrun
  notrun=$( { kosr get pods -n kube-system --no-headers; khub get pods -n kube-system --no-headers; } \
    | awk '$3!="Running" && $3!="Completed"' | wc -l)
  if federation_ok hub osramp.local && federation_ok workload signalloom.hub; then
    gate G2 bringup pass "both clusters Ready, $notrun non-running kube-system pods, federation refresh ok hub<-osramp.local and osramp<-signalloom.hub"
  else
    gate G2 bringup fail "federation refresh failed after 5 attempts with 2s backoff"
    BLOCKER=1
  fi
}

# --- fixtures -------------------------------------------------------------------------
wait_rollout() { "$KUBECTL_BIN" --context "$1" -n "$2" rollout status "deploy/$3" --timeout=180s >/dev/null; }

fixtures_up() {
  local node_hub="spiffe://signalloom.hub/k8s-cluster/$SLDC_HUB_CLUSTER"
  local node_osr="spiffe://osramp.local/k8s-cluster/$SLDC_OSRAMP_CLUSTER"
  # leftovers from an interrupted run: a Terminating namespace or old probe
  # pods would swallow this run's objects, so let them finish going first
  for p in kusari cardvault unauth expiry; do
    kosr -n "${PROBE_NS[$p]}" delete pod "p2gov-$p" --ignore-not-found --wait=true --timeout=120s >/dev/null 2>&1 || true
  done
  if [ "$(kosr get ns agent-trust -o jsonpath='{.status.phase}' 2>/dev/null)" = Terminating ]; then
    kosr wait --for=delete ns/agent-trust --timeout=180s >/dev/null
  fi
  # workload identities under test
  if ! kosr get ns agent-trust >/dev/null 2>&1; then
    kosr create ns agent-trust >/dev/null
    kosr label ns agent-trust signalloom.io/fixture=true signalloom.io/card=SLDC-P2-GOV >/dev/null
  fi
  for p in cardvault unauth expiry; do
    kosr -n agent-trust create sa "${PROBE_SA[$p]}" --dry-run=client -o yaml | kosr apply -f - >/dev/null
  done
  ensure_entry workload "spiffe://osramp.local/ns/agent-trust/sa/unauthorized-agent" -parentID "$node_osr" \
    -federatesWith spiffe://signalloom.hub -selector k8s:ns:agent-trust -selector k8s:sa:unauthorized-agent
  ensure_entry workload "spiffe://osramp.local/ns/agent-trust/sa/agent-cardvault-worker-expiry" -parentID "$node_osr" \
    -federatesWith spiffe://signalloom.hub -jwtSVIDTTL "$EXPIRY_TTL" \
    -selector k8s:ns:agent-trust -selector k8s:sa:agent-cardvault-worker-expiry
  # hub-side identity for the TLS front
  [ -n "$(entry_id hub "$node_hub")" ] || spire_cli hub entry create -node -spiffeID "$node_hub" \
    -selector "k8s_psat:cluster:$SLDC_HUB_CLUSTER" >/dev/null
  ensure_entry hub "spiffe://signalloom.hub/ns/$HUB_NS/sa/sldc-p2-gov-front" -parentID "$node_hub" \
    -federatesWith spiffe://osramp.local -dns "$FRONT_SNI" -selector "k8s:ns:$HUB_NS" -selector k8s:sa:sldc-p2-gov-front

  # hub fixture: always fresh (generated secrets must match what the pods
  # booted with); secrets are generated here and piped, never on argv
  khub delete ns "$HUB_NS" --ignore-not-found --wait=true --timeout=120s >/dev/null
  khub create ns "$HUB_NS" --dry-run=client -o yaml | khub apply -f - >/dev/null
  openssl rand -hex 24 | tr -d '\n' | khub -n "$HUB_NS" create secret generic sldc-p2-gov-bao --from-file=token=/dev/stdin \
    --dry-run=client -o yaml | khub apply -f - >/dev/null
  { printf 'encryption-key='; openssl rand -hex 16; printf 'pseudonym-key='; openssl rand -hex 16; } \
    | khub -n "$HUB_NS" create secret generic sldc-p2-gov-identity --from-env-file=/dev/stdin \
      --dry-run=client -o yaml | khub apply -f - >/dev/null
  local pgpw; pgpw=$(openssl rand -hex 16)
  { printf 'password=%s\n' "$pgpw"; printf 'dsn=postgres://audit:%s@audit-db:5432/audit?sslmode=disable\n' "$pgpw"; } \
    | khub -n "$HUB_NS" create secret generic sldc-p2-gov-audit --from-env-file=/dev/stdin \
      --dry-run=client -o yaml | khub apply -f - >/dev/null
  # the shipped signal-ingest config, then the fixture that mounts it
  HUB_APP_NS=$HUB_NS "$BOOTSTRAP" signal-ingest >>"$AUDIT_TXT" 2>&1
  SI_IMAGE=$SI_IMAGE envsubst '${SI_IMAGE}' <"$FIXTURE_DIR/hub-fixture.yaml" | khub apply -f - >/dev/null
  wait_rollout "$SLDC_HUB_CTX" "$HUB_NS" openbao
  wait_rollout "$SLDC_HUB_CTX" "$HUB_NS" audit-db
  wait_rollout "$SLDC_HUB_CTX" "$HUB_NS" signal-ingest
  wait_rollout "$SLDC_HUB_CTX" "$HUB_NS" sl-eap-front
  "$BOOTSTRAP" openbao >>"$AUDIT_TXT" 2>&1

  for p in kusari cardvault unauth expiry; do
    PROBE_NAME="p2gov-$p" PROBE_NS=${PROBE_NS[$p]} PROBE_SA=${PROBE_SA[$p]} \
      envsubst '${PROBE_NAME} ${PROBE_NS} ${PROBE_SA}' <"$FIXTURE_DIR/workload-probe.yaml" | kosr apply -f - >/dev/null
    PROBES_UP+=("$p")
  done
  for p in kusari cardvault unauth expiry; do
    kosr -n "${PROBE_NS[$p]}" wait --for=condition=Ready "pod/p2gov-$p" --timeout=180s >/dev/null
  done
}

# --- probe helpers ----------------------------------------------------------------------
pexec() { local p=$1 c=$2; shift 2; kosr -n "${PROBE_NS[$p]}" exec -i "p2gov-$p" -c "$c" -- "$@"; }

# mint_jwt PROBE AUD -> JWT-SVID on stdout (retries while the agent syncs)
mint_jwt() {
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$(pexec "$1" agent /opt/spire/bin/spire-agent api fetch jwt -audience "$2" -socketPath "$SOCK" -output json 2>/dev/null \
      | jq -r '.[0].svids[0].svid // empty' 2>/dev/null) || true
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 2
  done
  return 1
}
fetch_x509() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pexec "$1" agent /opt/spire/bin/spire-agent api fetch x509 -socketPath "$SOCK" -write /svid >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}
# claims view for the audit log: header + payload only, never the signature
claims() { jq -Rc 'split(".") | {header: (.[0] | @base64d | fromjson), claims: (.[1] | gsub("-";"+") | gsub("_";"/") | . + ("=" * ((4 - length % 4) % 4)) | @base64d | fromjson)}' <<<"$1"; }

# https PROBE METHOD PATH [TOKEN] [BODY] [CERTMODE] -> "STATUS|CLIENT_VERIFY|TLS"; raw response in $P2GOV_TMP/last_response
# Request (bearer + body) is written to the tool container's stdin, never argv.
# CERTMODE: svid (default) | none | rogue
https() {
  local p=$1 m=$2 path=$3 tok=${4:-} body=${5:-} mode=${6:-svid} req certargs
  req="$m $path HTTP/1.1\r\nHost: $FRONT_SNI\r\nConnection: close\r\n"
  [ -n "$tok" ] && req+="Authorization: Bearer $tok\r\n"
  if [ -n "$body" ]; then req+="Content-Type: application/json\r\nContent-Length: ${#body}\r\n\r\n$body"; else req+="\r\n"; fi
  case "$mode" in
    svid) certargs="-cert /svid/svid.0.pem -key /svid/svid.0.key" ;;
    rogue) certargs="-cert /svid/rogue-leaf.pem -key /svid/rogue-leaf.key" ;;
    none) certargs="" ;;
  esac
  # Transport failures (no response, 502/503/504 from the front's upstream)
  # are retried up to 5 times, 2s apart, per the card's retry contract.
  # An auth decision (any other status) is returned as-is, never retried.
  local LAST_RESPONSE status attempt
  for attempt in 1 2 3 4 5; do
    LAST_RESPONSE=$(printf '%b' "$req" | pexec "$p" tool sh -c \
      "openssl s_client -quiet -connect $FRONT_HOST:$FRONT_PORT -servername $FRONT_SNI \
         -CAfile /svid/federated_bundle.0.0.pem -verify_return_error -verify_hostname $FRONT_SNI $certargs 2>/dev/null" || true)
    status=$(printf '%s' "$LAST_RESPONSE" | awk 'NR==1 {print $2}')
    case "${status:-none}" in
      none|502|503|504) audit "transport retry $attempt/5: $m $path via $p -> ${status:-none}"; sleep 2 ;;
      *) break ;;
    esac
  done
  local cv tls
  cv=$(printf '%s' "$LAST_RESPONSE" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-sldc-client-verify" {print $2}')
  tls=$(printf '%s' "$LAST_RESPONSE" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-sldc-tls" {print $2}')
  printf '%s' "$LAST_RESPONSE" >"$P2GOV_TMP/last_response"
  printf '%s|%s|%s' "${status:-none}" "${cv:-none}" "${tls:-none}"
}
obs_body() {
  printf '[{"id":"p2gov-%s","timestamp":"%s","layer":"identity_authorization","fidelity":"definitive","source":"sldc-p2-gov","confidence":1,"raw_evidence_ref":"sldc-p2-gov","description":"SLDC-P2-GOV cross-cluster telemetry probe"}]' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

# bao_login TOKEN -> HTTP status; OpenBao body kept in $P2GOV_TMP with the
# client token and accessor redacted (file bao_body); bao_token_len records that one came back
bao_login() {
  local raw code
  raw=$(jq -Rc --arg role "$BAO_ROLE" '{role: $role, jwt: .}' <<<"$1" \
    | curl -s -o /dev/stdout -w '\n%{http_code}' -X POST --data-binary @- "$BAO_ADDR/v1/auth/$BAO_MOUNT/login")
  code=$(tail -n1 <<<"$raw"); raw=$(sed '$d' <<<"$raw")
  jq -r '.auth.client_token // "" | length' <<<"$raw" >"$P2GOV_TMP/bao_token_len" 2>/dev/null || echo 0 >"$P2GOV_TMP/bao_token_len"
  jq -c 'if .auth then .auth.client_token = "REDACTED" | .auth.accessor = "REDACTED" else . end' <<<"$raw" \
    >"$P2GOV_TMP/bao_body" 2>/dev/null || printf '%s' "$raw" >"$P2GOV_TMP/bao_body"
  printf '%s' "$code"
}

# --- G3 TLS -----------------------------------------------------------------------------
g3_tls() {
  local out13 out12 proto cipher group
  out13=$(openssl s_client -connect "$FRONT_HOST:$FRONT_PORT" -servername "$FRONT_SNI" -brief </dev/null 2>&1 || true)
  out12=$(openssl s_client -connect "$FRONT_HOST:$FRONT_PORT" -servername "$FRONT_SNI" -tls1_2 -brief </dev/null 2>&1 || true)
  audit "--- openssl s_client (default) ---"; audit "$out13"
  audit "--- openssl s_client -tls1_2 ---"; audit "$out12"
  proto=$(awk -F': ' '/^Protocol version/ {print $2}' <<<"$out13")
  cipher=$(awk -F': ' '/^Ciphersuite/ {print $2}' <<<"$out13")
  group=$(awk -F': ' '/^(Negotiated TLS1.3 group|Server Temp Key|Peer Temp Key)/ {print $2; exit}' <<<"$out13")
  if [ "$proto" = TLSv1.3 ] && [[ "$cipher" =~ ^TLS_(AES_(128|256)_GCM_SHA(256|384)|CHACHA20_POLY1305_SHA256)$ ]] \
     && ! grep -q '^Protocol version: TLSv1.2' <<<"$out12"; then
    gate G3 tls pass "protocol=$proto cipher=$cipher group=${group:-unknown}; TLS 1.2 handshake refused"
  else
    gate G3 tls fail "protocol='$proto' cipher='$cipher'; tls1_2 output: $(head -c 200 <<<"$out12")"
  fi
}

# --- G4 mTLS ------------------------------------------------------------------------------
g4_mtls() {
  local out ok=0 i r
  fetch_x509 kusari || { gate G4 mtls fail "no X.509-SVID for kusari probe"; BLOCKER=1; return; }
  # up to 5 handshakes, 2s apart: a fresh pod's first cross-bridge connect
  # can time out while the path warms; persistent failure is the blocker
  local attempt
  for attempt in 1 2 3 4 5; do
    out=$(pexec kusari tool sh -c "openssl s_client -connect $FRONT_HOST:$FRONT_PORT -servername $FRONT_SNI \
        -CAfile /svid/federated_bundle.0.0.pem -verify_return_error -verify_hostname $FRONT_SNI \
        -cert /svid/svid.0.pem -key /svid/svid.0.key -brief </dev/null 2>&1; \
        openssl x509 -in /svid/svid.0.pem -noout -ext subjectAltName 2>/dev/null" || true)
    audit "--- mTLS from kind-osramp p2gov-kusari (attempt $attempt) ---"; audit "$out"
    grep -q 'Verification: OK' <<<"$out" && break
    sleep 2
  done
  for i in 1 2 3 4 5; do
    r=$(https kusari GET /healthz)
    if [ "$(cut -d'|' -f2 <<<"$r")" = SUCCESS ]; then ok=1; break; fi
    sleep 2
  done
  audit "mtls /healthz: $r"
  if grep -q 'Verification: OK' <<<"$out" && grep -q 'spiffe://signalloom.hub' <<<"$(khub -n "$HUB_NS" exec deploy/sl-eap-front -c nginx -- cat /svid/svid.0.pem | openssl x509 -noout -ext subjectAltName)" && [ "$ok" = 1 ]; then
    gate G4 mtls pass "handshake attempt $attempt/5: osramp pod verified hub SVID (spiffe://signalloom.hub/ns/$HUB_NS/sa/sldc-p2-gov-front, DNS $FRONT_SNI) via federated bundle; hub verified client SVID spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent: client_verify=SUCCESS ($(cut -d'|' -f3 <<<"$r"))"
  else
    gate G4 mtls fail "server verification or client verification failed (last: $r)"
    BLOCKER=1
  fi
}

# --- G5 authenticated ingest -----------------------------------------------------------------
g5_ingest() {
  local tok r n ok=0 fails=0 i
  tok=$(mint_jwt kusari signal-ingest) || { gate G5 ingest fail "could not mint JWT-SVID"; return; }
  audit "JWT-SVID kusari: $(claims "$tok")"
  r=$(https kusari POST /api/v1/observations "$tok" "$(obs_body first)")
  audit "authenticated POST /api/v1/observations: $r body=$(tr -d '\r' <"$P2GOV_TMP/last_response" | awk 'NF' | tail -n1)"
  AUTH_STATUS=${r%%|*}
  for i in $(seq 1 10); do
    tok=$(mint_jwt kusari signal-ingest) || { fails=$((fails + 1)); continue; }
    n=$(https kusari POST /api/v1/observations "$tok" "$(obs_body "loop-$i")")
    audit "exchange $i: $n"
    if [ "${n%%|*}" = 201 ] && [ "$(cut -d'|' -f2 <<<"$n")" = SUCCESS ]; then ok=$((ok + 1)); else fails=$((fails + 1)); fi
  done
  # the store now holds what we sent: read access is a different permission,
  # so prove it from the service's own log line instead of widening the binding
  local ingested
  ingested=$(khub -n "$HUB_NS" logs deploy/signal-ingest --tail=200 2>/dev/null | grep -c 'observations ingested' || true)
  if [ "$AUTH_STATUS" = 201 ] && [ "$ok" = 10 ] && [ "$fails" = 0 ]; then
    gate G5 ingest pass "POST /api/v1/observations with osramp.local JWT-SVID across the bridge -> 201; 10/10 consecutive exchanges 201 with client_verify=SUCCESS, 0 trust errors; signal-ingest logged $ingested ingest events"
  else
    gate G5 ingest fail "first=$AUTH_STATUS ok=$ok fails=$fails"
  fi
}

# --- G6 negative auth --------------------------------------------------------------------------
g6_negative() {
  local tok anon anon_post bad rogue wrongaud nobind readperm tampered rogue_x509 host_anon
  tok=$(mint_jwt kusari signal-ingest)
  host_anon=$(curl -k -s -o /dev/null -w '%{http_code}' "https://$FRONT_HOST:$FRONT_PORT/api/v1/observations" -H "Host: $FRONT_SNI")
  anon=$(https kusari GET /api/v1/observations "" "" none)
  anon_post=$(https kusari POST /api/v1/observations "" "$(obs_body anon)" none)
  # route-existence control: the same GET with a valid token is 403 (lacks
  # observations:read), not 404, so a 401 above is an auth decision
  readperm=$(https kusari GET /api/v1/observations "$tok")
  tampered="${tok:0:${#tok}-6}$(printf '%s' "${tok: -6}" | tr 'A-Za-z' 'N-ZA-Mn-za-m')"
  bad=$(https kusari POST /api/v1/observations "$tampered" "$(obs_body tampered)")
  rogue=$(https kusari POST /api/v1/observations "$(bun "$SCRIPT_DIR/lib/p2gov-forge-jwt.ts" spiffe://rogue.local/ns/fe-signalloom-agents/sa/kusari-agent signal-ingest)" "$(obs_body rogue)")
  local forged_osr
  forged_osr=$(https kusari POST /api/v1/observations "$(bun "$SCRIPT_DIR/lib/p2gov-forge-jwt.ts" spiffe://osramp.local/ns/fe-signalloom-agents/sa/kusari-agent signal-ingest)" "$(obs_body forged)")
  wrongaud=$(https kusari POST /api/v1/observations "$(mint_jwt kusari openbao)" "$(obs_body aud)")
  fetch_x509 unauth
  nobind=$(https unauth POST /api/v1/observations "$(mint_jwt unauth signal-ingest)" "$(obs_body nobind)")
  # rogue.local client certificate presented at TLS
  pexec kusari tool sh -c 'cd /svid && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
      -subj /CN=rogue-ca -keyout rogue-ca.key -out rogue-ca.pem >/dev/null 2>&1 && \
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=rogue -keyout rogue-leaf.key -out rogue.csr >/dev/null 2>&1 && \
    printf "subjectAltName=URI:spiffe://rogue.local/ns/fe-signalloom-agents/sa/kusari-agent\n" > rogue.ext && \
    openssl x509 -req -in rogue.csr -CA rogue-ca.pem -CAkey rogue-ca.key -CAcreateserial -days 1 -extfile rogue.ext -out rogue-leaf.pem >/dev/null 2>&1'
  rogue_x509=$(https kusari POST /api/v1/observations "$tok" "$(obs_body roguecert)" rogue)
  audit "negative: host anonymous GET=$host_anon pod anonymous GET=$anon anonymous POST=$anon_post valid-token GET (no read perm)=$readperm"
  audit "negative: tampered signature=$bad rogue.local JWT=$rogue forged osramp.local JWT=$forged_osr wrong audience=$wrongaud unbound subject=$nobind rogue.local client cert=$rogue_x509"
  audit "rogue.local JWT claims: $(claims "$(bun "$SCRIPT_DIR/lib/p2gov-forge-jwt.ts" spiffe://rogue.local/ns/fe-signalloom-agents/sa/kusari-agent signal-ingest)")"
  local rej='^(401|403)$' s
  local all_ok=1
  [ "$host_anon" = 401 ] || all_ok=0
  [ "${anon%%|*}" = 401 ] || all_ok=0
  [ "${anon_post%%|*}" = 401 ] || all_ok=0
  [ "${readperm%%|*}" = 403 ] || all_ok=0
  for s in "$bad" "$rogue" "$forged_osr" "$wrongaud" "$nobind"; do [[ "${s%%|*}" =~ $rej ]] || all_ok=0; done
  [ "${rogue_x509%%|*}" = 400 ] || all_ok=0
  if [ "$host_anon" != 401 ] && [[ "$host_anon" =~ ^2 ]]; then BLOCKER=1; fi
  if [[ "${anon%%|*}" =~ ^2 ]] || [[ "${anon_post%%|*}" =~ ^2 ]]; then BLOCKER=1; fi
  local restarts
  restarts=$(khub -n "$HUB_NS" get pods -l app=signal-ingest -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{"\n"}{end}' | awk '{s+=$1} END {print s+0}')
  audit "signal-ingest restarts after negative probes: $restarts"
  [ "$restarts" = 0 ] || { all_ok=0; audit "$(khub -n "$HUB_NS" logs deploy/signal-ingest --previous --tail=40 2>&1)"; }
  if [ "$all_ok" = 1 ]; then
    gate G6 negative pass "signal-ingest restarts=0; anonymous 401 (host GET, pod GET, pod POST); route proven live by valid-token GET=403; tampered sig ${bad%%|*}, rogue.local JWT ${rogue%%|*}, forged osramp.local JWT ${forged_osr%%|*}, wrong aud ${wrongaud%%|*}, unbound subject ${nobind%%|*}; rogue.local client cert refused at TLS ${rogue_x509%%|*}"
  else
    gate G6 negative fail "restarts=$restarts host_anon=$host_anon anon=$anon anon_post=$anon_post readperm=$readperm bad=$bad rogue=$rogue forged=$forged_osr wrongaud=$wrongaud nobind=$nobind rogue_x509=$rogue_x509"
  fi
}

# --- G7 OpenBao glob -----------------------------------------------------------------------------
g7_openbao() {
  local tok_ok tok_no tok_exp c_ok c_no c_exp
  tok_ok=$(mint_jwt cardvault openbao)
  tok_no=$(mint_jwt unauth openbao)
  tok_exp=$(mint_jwt expiry openbao)
  audit "JWT-SVID cardvault: $(claims "$tok_ok")"
  audit "JWT-SVID unauthorized-agent: $(claims "$tok_no")"
  audit "JWT-SVID expiry (ttl ${EXPIRY_TTL}s): $(claims "$tok_exp")"
  c_ok=$(bao_login "$tok_ok"); audit "openbao login agent-cardvault-worker-1: $c_ok $(cat "$P2GOV_TMP/bao_body")"
  local has_token; has_token=$(cat "$P2GOV_TMP/bao_token_len")
  local policies; policies=$(jq -rc '.auth.policies // empty' <<<"$(cat "$P2GOV_TMP/bao_body")")
  c_no=$(bao_login "$tok_no"); audit "openbao login unauthorized-agent: $c_no $(cat "$P2GOV_TMP/bao_body")"
  sleep $((EXPIRY_TTL + 7))
  c_exp=$(bao_login "$tok_exp"); audit "openbao login expired SVID: $c_exp $(cat "$P2GOV_TMP/bao_body")"
  if [ "$c_ok" = 200 ] && [ "${has_token:-0}" -gt 0 ] && [ "$c_no" = 400 ] && [ "$c_exp" = 400 ]; then
    gate G7 openbao pass "glob subject agent-cardvault-worker-1 -> 200 with client token, policies=$policies; unauthorized-agent -> 400; expired SVID (ttl ${EXPIRY_TTL}s + 5s leeway) -> 400"
  else
    gate G7 openbao fail "ok=$c_ok token_len=$has_token unauthorized=$c_no expired=$c_exp"
  fi
}

# --- G8 mutation -----------------------------------------------------------------------------------
g8_mutation() {
  local tok c_mut c_restored mutated tb
  tok=$(mint_jwt cardvault openbao)
  mutated=$(yq -e 'select(.kind == "ConfigMap" and .metadata.name == "openbao-jwt-role-config") | .data."role.json"' "$ROLE_MANIFEST" \
    | jq -c 'del(.bound_claims_type)')
  audit "mutation: role.json from $ROLE_MANIFEST with bound_claims_type removed: $mutated"
  printf '%s' "$mutated" | $BAO_BIN write "auth/$BAO_MOUNT/role/$BAO_ROLE" - >/dev/null
  c_mut=$(bao_login "$tok"); audit "mutated login: $c_mut $(cat "$P2GOV_TMP/bao_body")"
  "$BOOTSTRAP" openbao >>"$AUDIT_TXT" 2>&1
  c_restored=$(bao_login "$tok"); audit "restored login: $c_restored $(jq -c 'del(.auth.policies)' <<<"$(cat "$P2GOV_TMP/bao_body")" 2>/dev/null | head -c 300)"
  # trust bundle mutation: verify the hub with the osramp.local bundle instead
  # of the federated signalloom.hub bundle; the handshake must fail closed
  tb=$(pexec kusari tool sh -c "openssl s_client -connect $FRONT_HOST:$FRONT_PORT -servername $FRONT_SNI \
      -CAfile /svid/bundle.0.pem -verify_return_error -brief </dev/null 2>&1" || true)
  audit "--- trust-bundle mutation (osramp.local bundle used to verify hub) ---"; audit "$tb"
  if [ "$c_mut" = 400 ] && [ "$c_restored" = 200 ] && ! grep -q 'Verification: OK' <<<"$tb" && grep -qiE 'verify error|unable to get local issuer' <<<"$tb"; then
    gate G8 mutation pass "bound_claims_type removed -> 400, restored -> 200 (glob is load-bearing); wrong trust bundle -> TLS verify error, handshake aborted"
  else
    gate G8 mutation fail "mutated=$c_mut restored=$c_restored bundle-mutation='$(head -c 200 <<<"$tb")'"
  fi
}

# --- main ------------------------------------------------------------------------------------------
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
audit "SLDC-P2-GOV token exchange audit - started $STARTED - HEAD $(git -C "$REPO_ROOT" rev-parse HEAD)"
audit "Tokens are recorded as decoded header+claims only; signatures and OpenBao client tokens are never written."
g1_merge
g2_bringup
if [ "$BLOCKER" = 0 ]; then
  fixtures_up
  g3_tls
  g4_mtls
  g5_ingest
  g6_negative
  g7_openbao
  g8_mutation
fi

write_cert() {
jq -n --arg status "$1" --arg started "$STARTED" --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg head "$(git -C "$REPO_ROOT" rev-parse HEAD)" --arg p21 "$P2_1_SHA" --arg p22 "$P2_2_SHA" \
  --arg si "$SI_IMAGE" --argjson blocker "$BLOCKER" --argjson gates "$GATES_JSON" '{
    schema: "sldc.phase2-governance-certification/v1",
    card: "SLDC-P2-GOV", status: $status, hard_blocker: ($blocker == 1),
    proceed_to_phase3: ($status == "pass"), human_signoff_required: true,
    started: $started, finished: $finished,
    integration_head: $head, merged: {"SLDC-P2-1": $p21, "SLDC-P2-2": $p22},
    topology: {workload: {context: "kind-osramp", ip: "172.19.0.10", trust_domain: "osramp.local"},
               hub: {context: "kind-signalloom-hub", ip: "172.19.0.20", trust_domain: "signalloom.hub"}},
    fixture: {hub_namespace: "sldc-p2-gov", signal_ingest_image: $si, torn_down: true},
    gates: $gates }' >"$CERT_JSON"
  if [ "$KEEP_FIXTURES" = 1 ]; then jq '.fixture.torn_down = false' "$CERT_JSON" >"$CERT_JSON.tmp" && mv "$CERT_JSON.tmp" "$CERT_JSON"; fi
  CERT_WRITTEN=1
}

STATUS=pass; [ "$FAILED" = 0 ] || STATUS=fail
write_cert "$STATUS"
log "certification: $STATUS ($CERT_JSON)"
[ "$BLOCKER" = 0 ] || exit 3
[ "$STATUS" = pass ]
