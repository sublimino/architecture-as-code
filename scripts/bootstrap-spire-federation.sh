#!/usr/bin/env bash
# @id scripts/bootstrap-spire-federation.sh
# @doc d2-agent-trust/spire-federation-config.yaml
# @tests test/spire-federation-openbao-jwt.bats
# @lib d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml (ConfigMap openbao-jwt-role-config)
# @lib d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml
#
# SLDC-P2-2: federate SPIRE between the workload domain (osramp.local on
# kind-osramp) and the hub domain (signalloom.hub on kind-signalloom-hub), then
# teach the hub's OpenBao and signal-ingest to trust osramp.local JWT-SVIDs
# through the *federated* bundle.
#
# Usage: bootstrap-spire-federation.sh [STEP...]
#   render WHICH       print the federation manifest rendered for workload|hub
#   apply              render + kubectl apply on both clusters, wait for servers
#   seed               exchange trust bundles once (bundle set, both directions)
#   federate           poll "federation refresh" both ways until both succeed
#   entries            idempotent node-alias + workload registration entries
#   jwks               print the hub's federated osramp.local jwt-svid JWKS
#   openbao            idempotent transit key, jwt-osramp mount, policy, role
#   role-configmap     publish openbao-jwt-role-config into the hub app namespace
#   signal-ingest      apply jwt-auth-config + sync JWKS ConfigMap + patch Deployment
#   all                apply seed federate entries openbao role-configmap signal-ingest (default)
#
# Re-running any step is safe: bundles are overwritten, entries are created
# only when absent, OpenBao writes are upserts, and kubectl uses apply.
#
# Injectable boundaries (env): KUBECTL_BIN, BAO_BIN, WORKLOAD_CONTEXT,
# HUB_CONTEXT, WORKLOAD_TD, HUB_TD, WORKLOAD_BUNDLE_URL, HUB_BUNDLE_URL,
# WORKLOAD_CLUSTER, HUB_CLUSTER, BUNDLE_NODEPORT, SPIRE_NS, HUB_APP_NS,
# SPIRE_WORKLOAD_CMD / SPIRE_HUB_CMD (full command prefix that runs
# spire-server CLI on each side), BAO_AUTH_PATH, BACKOFF_MAX_ATTEMPTS,
# BACKOFF_CAP_SECONDS, REPO_ROOT. BAO_ADDR / BAO_TOKEN are read from the
# environment by the bao CLI and are never placed on argv.
#
# Exit codes: 0 ok, 1 usage/config error, 2 step failed after retries,
# 3 hard blocker (OpenBao sealed) - stop and report, do not improvise.
set -eo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
BAO_BIN="${BAO_BIN:-bao}"
WORKLOAD_CONTEXT="${WORKLOAD_CONTEXT:-kind-osramp}"
HUB_CONTEXT="${HUB_CONTEXT:-kind-signalloom-hub}"
WORKLOAD_TD="${WORKLOAD_TD:-osramp.local}"
HUB_TD="${HUB_TD:-signalloom.hub}"
BUNDLE_NODEPORT="${BUNDLE_NODEPORT:-31843}"
WORKLOAD_BUNDLE_URL="${WORKLOAD_BUNDLE_URL:-https://172.19.0.10:${BUNDLE_NODEPORT}}"
HUB_BUNDLE_URL="${HUB_BUNDLE_URL:-https://172.19.0.20:${BUNDLE_NODEPORT}}"
WORKLOAD_CLUSTER="${WORKLOAD_CLUSTER:-osramp}"
HUB_CLUSTER="${HUB_CLUSTER:-signalloom-hub}"
SPIRE_NS="${SPIRE_NS:-spire-system}"
HUB_APP_NS="${HUB_APP_NS:-inf-signalloom}"
BACKOFF_MAX_ATTEMPTS="${BACKOFF_MAX_ATTEMPTS:-8}"
BACKOFF_CAP_SECONDS="${BACKOFF_CAP_SECONDS:-30}"

FEDERATION_MANIFEST="$REPO_ROOT/d2-agent-trust/spire-federation-config.yaml"
ROLE_MANIFEST="$REPO_ROOT/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
INGEST_MANIFEST="$REPO_ROOT/d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml"

log() { printf '[spire-federation] %s\n' "$*" >&2; }
die() { log "ERROR: $2"; exit "$1"; }

# The spire-server CLI runs inside each server pod. Word-splitting the
# override is intentional: it is a command prefix, e.g. "docker exec -i lab".
spire_workload() {
  if [[ -n "${SPIRE_WORKLOAD_CMD:-}" ]]; then $SPIRE_WORKLOAD_CMD "$@"; else
    "$KUBECTL_BIN" --context "$WORKLOAD_CONTEXT" -n "$SPIRE_NS" exec -i spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; fi
}
spire_hub() {
  if [[ -n "${SPIRE_HUB_CMD:-}" ]]; then $SPIRE_HUB_CMD "$@"; else
    "$KUBECTL_BIN" --context "$HUB_CONTEXT" -n "$SPIRE_NS" exec -i spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; fi
}
bao() { $BAO_BIN "$@"; }

# retry_backoff DESCRIPTION CMD...: exponential backoff 1,2,4.. capped at
# BACKOFF_CAP_SECONDS, BACKOFF_MAX_ATTEMPTS tries, then exit 2.
retry_backoff() {
  local what="$1"; shift
  local attempt=1 delay=1
  while true; do
    if "$@"; then return 0; fi
    if (( attempt >= BACKOFF_MAX_ATTEMPTS )); then
      die 2 "$what: still failing after $attempt attempts"
    fi
    log "$what: attempt $attempt failed, retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2)); (( delay > BACKOFF_CAP_SECONDS )) && delay=$BACKOFF_CAP_SECONDS
  done
}

# --- render / apply ---------------------------------------------------------
render() {
  local which="$1" td peer url cluster
  case "$which" in
    workload) td=$WORKLOAD_TD peer=$HUB_TD url=$HUB_BUNDLE_URL cluster=$WORKLOAD_CLUSTER ;;
    hub)      td=$HUB_TD peer=$WORKLOAD_TD url=$WORKLOAD_BUNDLE_URL cluster=$HUB_CLUSTER ;;
    *) die 1 "render: expected workload|hub, got '$which'" ;;
  esac
  SPIRE_TRUST_DOMAIN=$td SPIRE_PEER_TRUST_DOMAIN=$peer SPIRE_PEER_BUNDLE_ENDPOINT_URL=$url \
    SPIRE_CLUSTER_NAME=$cluster SPIRE_BUNDLE_NODEPORT=$BUNDLE_NODEPORT \
    envsubst '${SPIRE_TRUST_DOMAIN} ${SPIRE_PEER_TRUST_DOMAIN} ${SPIRE_PEER_BUNDLE_ENDPOINT_URL} ${SPIRE_CLUSTER_NAME} ${SPIRE_BUNDLE_NODEPORT}' \
    <"$FEDERATION_MANIFEST"
}

server_healthy() { "$@" healthcheck >/dev/null 2>&1; }

step_apply() {
  render workload | "$KUBECTL_BIN" --context "$WORKLOAD_CONTEXT" apply -f -
  render hub | "$KUBECTL_BIN" --context "$HUB_CONTEXT" apply -f -
  retry_backoff "workload spire-server healthy" server_healthy spire_workload
  retry_backoff "hub spire-server healthy" server_healthy spire_hub
}

# --- federation ---------------------------------------------------------------
# Seeding is the only out-of-band trust step: https_spiffe needs the peer's
# root to authenticate its bundle endpoint the first time.
step_seed() {
  local wb hb
  wb=$(spire_workload bundle show -format spiffe) || die 2 "cannot read $WORKLOAD_TD bundle"
  hb=$(spire_hub bundle show -format spiffe) || die 2 "cannot read $HUB_TD bundle"
  printf '%s' "$wb" | spire_hub bundle set -format spiffe -id "spiffe://$WORKLOAD_TD" >/dev/null
  printf '%s' "$hb" | spire_workload bundle set -format spiffe -id "spiffe://$HUB_TD" >/dev/null
  log "seeded $WORKLOAD_TD <-> $HUB_TD"
}

# A refresh only succeeds if the peer's bundle endpoint answered over
# https_spiffe, so a pass here proves live federation, not just the seed.
federation_refreshed() { "$1" federation refresh -id "spiffe://$2" >/dev/null 2>&1; }

step_federate() {
  retry_backoff "hub fetches $WORKLOAD_TD bundle" federation_refreshed spire_hub "$WORKLOAD_TD"
  retry_backoff "workload fetches $HUB_TD bundle" federation_refreshed spire_workload "$HUB_TD"
  log "federation active in both directions"
}

# --- registration entries -----------------------------------------------------
ensure_entry() {
  local id="$1"; shift
  if spire_workload entry show -spiffeID "$id" 2>/dev/null | grep -q 'Entry ID'; then
    log "entry exists: $id"; return 0
  fi
  spire_workload entry create -spiffeID "$id" "$@" >/dev/null
  log "entry created: $id"
}

step_entries() {
  local node="spiffe://$WORKLOAD_TD/spire/node/$WORKLOAD_CLUSTER" fed="spiffe://$HUB_TD"
  if ! spire_workload entry show -spiffeID "$node" 2>/dev/null | grep -q 'Entry ID'; then
    spire_workload entry create -node -spiffeID "$node" -selector "k8s_psat:cluster:$WORKLOAD_CLUSTER" >/dev/null
  fi
  # PF-2: the live DaemonSet is stun-sentinel, not signalloom-stun-sentinel.
  ensure_entry "spiffe://$WORKLOAD_TD/ns/fe-signalloom-agents/sa/stun-sentinel" -parentID "$node" -federatesWith "$fed" \
    -selector k8s:ns:fe-signalloom-agents -selector k8s:sa:stun-sentinel
  ensure_entry "spiffe://$WORKLOAD_TD/ns/fe-signalloom-agents/sa/kusari-agent" -parentID "$node" -federatesWith "$fed" \
    -selector k8s:ns:fe-signalloom-agents -selector k8s:sa:kusari-agent
  ensure_entry "spiffe://$WORKLOAD_TD/ns/agent-trust/sa/agent-cardvault-worker-1" -parentID "$node" -federatesWith "$fed" \
    -selector k8s:ns:agent-trust -selector k8s:sa:agent-cardvault-worker-1
  # Identity for the agent pod itself so `spire-agent api fetch jwt` run
  # inside deploy/spire-agent (the card's acceptance probe) returns an SVID.
  # It is bound nowhere: signal-ingest and OpenBao both refuse it.
  ensure_entry "spiffe://$WORKLOAD_TD/ns/$SPIRE_NS/sa/spire-agent" -parentID "$node" \
    -selector "k8s:ns:$SPIRE_NS" -selector k8s:sa:spire-agent
}

# --- federated JWKS -------------------------------------------------------------
# jwt-svid keys of osramp.local as the hub sees them through federation.
federated_jwks() {
  spire_hub bundle list -id "spiffe://$WORKLOAD_TD" -format spiffe \
    | jq -ce '{keys: [.keys[] | select(.use == "jwt-svid") | {kty, kid, crv, x, y, use}]} | select(.keys | length > 0)'
}
step_jwks() { federated_jwks || die 2 "hub holds no jwt-svid keys for $WORKLOAD_TD - federation not established"; }

# P-256 JWK -> SPKI PEM (SPIRE's ec-p256 jwt_key_type). Anything else fails
# closed rather than silently configuring OpenBao with no keys.
b64url_to_hex() { local s="$1"; while (( ${#s} % 4 )); do s+="="; done; printf '%s' "$s" | basenc --base64url -d | basenc --base16 -w0; }
jwk_to_pem() {
  local jwk="$1" kty crv x y der
  kty=$(jq -r .kty <<<"$jwk"); crv=$(jq -r .crv <<<"$jwk")
  [[ "$kty" == EC && "$crv" == P-256 ]] || die 1 "unsupported JWT key $kty/$crv (expected EC P-256)"
  x=$(b64url_to_hex "$(jq -r .x <<<"$jwk")"); y=$(b64url_to_hex "$(jq -r .y <<<"$jwk")")
  (( ${#x} == 64 && ${#y} == 64 )) || die 1 "malformed P-256 coordinates in $(jq -r .kid <<<"$jwk")"
  der="3059301306072A8648CE3D020106082A8648CE3D03010703420004${x}${y}"
  printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' \
    "$(printf '%s' "$der" | basenc --base16 -d | basenc --base64 -w 64)"
}

# --- OpenBao ------------------------------------------------------------------------
role_cm() { yq -e "select(.kind == \"ConfigMap\" and .metadata.name == \"openbao-jwt-role-config\") | .data.\"$1\"" "$ROLE_MANIFEST"; }

# bao status: 0 unsealed, 2 sealed, anything else unreachable/initialising.
openbao_ready() {
  local rc=0; bao status >/dev/null 2>&1 || rc=$?
  if (( rc == 2 )); then return 2; fi
  return "$rc"
}
wait_openbao() {
  local attempt=1 delay=1 rc
  while true; do
    rc=0; openbao_ready || rc=$?
    (( rc == 0 )) && return 0
    if (( attempt >= BACKOFF_MAX_ATTEMPTS )); then
      (( rc == 2 )) && die 3 "OpenBao is sealed - hard blocker (persistent seal), not retrying further"
      die 2 "OpenBao unreachable after $attempt attempts"
    fi
    log "OpenBao not ready (rc=$rc), retrying in ${delay}s"
    sleep "$delay"; attempt=$((attempt + 1))
    delay=$((delay * 2)); (( delay > BACKOFF_CAP_SECONDS )) && delay=$BACKOFF_CAP_SECONDS
  done
}

step_openbao() {
  : "${BAO_ADDR:?BAO_ADDR must be set for the openbao step}"
  local mount role key jwks pems
  mount="${BAO_AUTH_PATH:-$(role_cm auth-mount)}"; role=$(role_cm role-name); key=$(role_cm transit-key)
  wait_openbao
  jwks=$(step_jwks)
  pems=$(jq -c '.keys[]' <<<"$jwks" | while read -r k; do jwk_to_pem "$k"; done | jq -Rs 'split("-----END PUBLIC KEY-----\n") | map(select(length > 0) + "-----END PUBLIC KEY-----\n")')

  bao secrets list -format=json | jq -e 'has("transit/")' >/dev/null || bao secrets enable transit >/dev/null
  bao read "transit/keys/$key" >/dev/null 2>&1 || bao write -f "transit/keys/$key" type=ecdsa-p256 >/dev/null
  bao auth list -format=json | jq -e --arg m "$mount/" 'has($m)' >/dev/null || bao auth enable -path="$mount" jwt >/dev/null
  jq -n --argjson pems "$pems" '{jwt_validation_pubkeys: $pems}' | bao write "auth/$mount/config" - >/dev/null
  role_cm agent-cardvault-policy.hcl | bao policy write agent-cardvault-policy - >/dev/null
  role_cm role.json | bao write "auth/$mount/role/$role" - >/dev/null
  log "OpenBao: auth/$mount/role/$role trusts $(jq '.keys | length' <<<"$jwks") federated $WORKLOAD_TD key(s)"
}

# --- hub namespace objects ------------------------------------------------------------
kubectl_hub() { "$KUBECTL_BIN" --context "$HUB_CONTEXT" "$@"; }

step_role_configmap() {
  yq -e 'select(.kind == "ConfigMap" and .metadata.name == "openbao-jwt-role-config")' "$ROLE_MANIFEST" \
    | kubectl_hub -n "$HUB_APP_NS" apply -f -
}

step_signal_ingest() {
  local jwks
  jwks=$(step_jwks)
  kubectl_hub -n "$HUB_APP_NS" apply -f "$INGEST_MANIFEST"
  kubectl_hub -n "$HUB_APP_NS" create configmap signal-ingest-jwks --from-file=jwks.json=/dev/stdin \
    --dry-run=client -o yaml <<<"$jwks" | kubectl_hub -n "$HUB_APP_NS" apply -f -
  if kubectl_hub -n "$HUB_APP_NS" get deploy/signal-ingest >/dev/null 2>&1; then
    kubectl_hub -n "$HUB_APP_NS" patch deploy/signal-ingest --type strategic -p "$(cat <<'PATCH'
{"spec":{"template":{"spec":{
  "volumes":[{"name":"signal-auth-jwks","configMap":{"name":"signal-ingest-jwks"}}],
  "containers":[{"name":"signal-ingest",
    "envFrom":[{"configMapRef":{"name":"signal-ingest-jwt-auth"}}],
    "volumeMounts":[{"name":"signal-auth-jwks","mountPath":"/etc/signal-ingest/auth","readOnly":true}]}]}}}}
PATCH
)"
  else
    log "deploy/signal-ingest not present in $HUB_APP_NS; config applied, Deployment patch skipped"
  fi
}

main() {
  local steps=("$@")
  (( ${#steps[@]} )) || steps=(all)
  for s in "${steps[@]}"; do
    case "$s" in
      render) render "${2:?render needs workload|hub}"; return ;;
      apply) step_apply ;;
      seed) step_seed ;;
      federate) step_federate ;;
      entries) step_entries ;;
      jwks) step_jwks ;;
      openbao) step_openbao ;;
      role-configmap) step_role_configmap ;;
      signal-ingest) step_signal_ingest ;;
      all) step_apply; step_seed; step_federate; step_entries; step_openbao; step_role_configmap; step_signal_ingest ;;
      -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; return ;;
      *) die 1 "unknown step '$s'" ;;
    esac
  done
}

# Sourced by test/spire-federation-openbao-jwt.bats for unit tests.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
