#!/usr/bin/env bash
# expose.sh — Decide HOW to publish the demo, based on where the cluster runs.
#
# The cluster is not always in the same place. On a laptop it is a kind cluster
# with no routable address, so it needs a tunnel. On a GCP CI VM it is a kind
# cluster on a host that already has an external IP, so a tunnel is pointless
# indirection and a second dependency to break. On a managed cluster a
# LoadBalancer is the native answer.
#
# Everything downstream (Dex issuer, API issuer, dashboard redirect URI) keys
# off ONE value: the public origin. This file's whole job is to work out what
# that origin should be and how to make it reachable.
#
# Sourced by public-tunnel.sh; every function here is side-effect free except
# the two named *_up / *_down.

# LOCAL_ORIGIN_DEFAULT was this file's name for the baseline and callers may
# still export it, so it seeds dex-origin.sh's own knob BEFORE the source rather
# than being reconciled with it afterwards. Getting this order wrong would make
# an exported LOCAL_ORIGIN_DEFAULT silently ineffective on teardown — teardown
# would land on the built-in baseline while the caller believed it had moved it.
DEX_ORIGIN_BASELINE="${DEX_ORIGIN_BASELINE:-${LOCAL_ORIGIN_DEFAULT:-}}"

# The origin mechanism itself. Publishing an origin, holding it against a
# competing access method, and restoring the baseline all live in dex-origin.sh
# so that ngrok (here), the IAP tunnel, Tailscale and Tailscale Funnel share ONE
# implementation — Dex has one issuer, so they cannot each have their own.
# shellcheck source=scripts/lib/dex-origin.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dex-origin.sh"

# Which access method this file publishes on behalf of. Overridable so a caller
# that reuses expose.sh for a different transport takes its own lease rather
# than masquerading as the tunnel.
EXPOSE_ORIGIN_METHOD="${EXPOSE_ORIGIN_METHOD:-ngrok}"

# ORIGIN_CONSUMER_NAMESPACES used to live here and has been removed rather than
# kept for compatibility: nothing outside this file ever read it, and leaving it
# beside DEX_ORIGIN_TENANT_NAMESPACES would give one setting two knobs, only one
# of which does anything.

# Retained as this file's published name for the baseline. Now derived from
# dex-origin.sh so the two can never disagree about where teardown lands.
LOCAL_ORIGIN_DEFAULT="${DEX_ORIGIN_BASELINE}"

# ── Strategy detection ───────────────────────────────────────────────
#
# Explicit beats inferred: PUBLIC_STRATEGY forces a choice, so a VM run can
# demand `nodeport` even if the detection heuristics would have said otherwise.
detect_strategy() {
  if [[ -n "${PUBLIC_STRATEGY:-}" ]]; then
    echo "$PUBLIC_STRATEGY"; return
  fi

  # A cloud VM with an external address can serve directly. Checked before
  # kind, because a kind cluster ON a cloud VM should still use the VM's IP --
  # that is exactly the CI case, and tunnelling out of a machine that is
  # already reachable buys nothing but another moving part.
  if gcp_external_ip >/dev/null 2>&1; then
    echo "nodeport"; return
  fi

  # A managed cluster can allocate a real LoadBalancer.
  local ctx
  ctx="$(kubectl config current-context 2>/dev/null || echo '')"
  if [[ "$ctx" != kind-* ]] && [[ -n "$ctx" ]]; then
    echo "loadbalancer"; return
  fi

  # Local kind on a laptop: no routable address, so tunnel out.
  echo "tunnel"
}

# The VM's own external IP, straight from the GCP metadata server. Deliberately
# not `gcloud compute instances describe`: this must work from ON the instance
# without credentials, and the metadata server is authoritative about the
# machine it is running on. Short timeout so a non-GCP host fails fast rather
# than hanging every invocation.
gcp_external_ip() {
  local ip
  ip="$(curl -s --max-time 2 \
    -H 'Metadata-Flavor: Google' \
    'http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' \
    2>/dev/null || true)"
  [[ -n "$ip" ]] || return 1
  echo "$ip"
}

# ── Origin ───────────────────────────────────────────────────────────
#
# The single value everything else derives from. Whatever a browser will type.
#
# NOTE, for anyone about to wire `nodeport` or `loadbalancer` up: neither has a
# caller anywhere in this repo today, and both emit `http://<routable-ip>:<port>`
# — which dex_origin_validate now REFUSES, because Dex would issue its tokens
# over cleartext to a host anyone can route to. That refusal is deliberate and
# is asserted in test/terraform-dex-origin.bats. Reaching a browser over those
# strategies needs TLS in front of them first; it is not a validator to relax.
origin_for_strategy() {
  local strategy="$1" port="${2:-}"
  case "$strategy" in
    tunnel)       cat "$NGROK_URL_FILE" 2>/dev/null ;;
    nodeport)     echo "http://$(gcp_external_ip):${port}" ;;
    loadbalancer) echo "http://$(loadbalancer_address):${port}" ;;
    *)            return 1 ;;
  esac
}

loadbalancer_address() {
  kubectl get svc "$DASHBOARD_SERVICE" -n "$DASHBOARD_NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

# ── Publishing the origin to the cluster ─────────────────────────────
#
# PUBLIC_ORIGIN is a Flux substitution input, so writing it and reconciling
# makes Flux APPLY the public origin rather than undo it — which is why nothing
# has to be suspended and the value survives every future reconcile. That
# machinery now lives in dex-origin.sh; what remains here is this file's
# published surface over it.
#
# Thin wrapper over dex_origin_apply, kept because callers already say
# `publish_origin "$url"` and the origin mechanism should not have needed them
# to learn a new spelling.
#
# The behavioural change this brings, and it is the point of the whole exercise:
# publishing now FAILS if another access method already holds the issuer, rather
# than overwriting it. Two publishers racing over one issuer is not a state
# anything can recover from at runtime — the loser's users get a login that
# fails, with a healthy-looking tunnel in front of it.
publish_origin() {
  local origin="$1"
  dex_origin_apply "$EXPOSE_ORIGIN_METHOD" "$origin"
}

# Teardown SETS the local default rather than removing the key, and releases the
# lease so the next access method can take it.
#
# Removing the key does not unpublish: the tenant copies keep the last value, so
# the demo stays published on a dead origin while the cluster looks reset. An
# explicit value always propagates; an absent one does not.
unpublish_origin() {
  dex_origin_restore
}

# Retained under its original name because it is part of this file's surface;
# the implementation moved to dex-origin.sh so every access method reconciles
# and restarts Dex the same way.
reconcile_origin_consumers() {
  _dex_origin_reconcile
  _dex_origin_restart_dex
}

# ── NodePort exposure (cloud VM) ─────────────────────────────────────
#
# No tunnel, no port-forward, no supervisor: the dashboard Service is published
# on a NodePort and reached at the VM's own external IP. Fewer moving parts
# than the laptop path precisely because the machine is already reachable.
nodeport_up() {
  local port="${PUBLIC_NODE_PORT:-31080}"
  kubectl patch svc "$DASHBOARD_SERVICE" -n "$DASHBOARD_NAMESPACE" --type=merge \
    -p "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":${DASHBOARD_PORT},\"targetPort\":${DASHBOARD_PORT},\"nodePort\":${port},\"protocol\":\"TCP\",\"name\":\"http\"}]}}" >/dev/null
  echo "    ${DASHBOARD_SERVICE} published on nodePort ${port}"
  echo "$port"
}

nodeport_down() {
  kubectl patch svc "$DASHBOARD_SERVICE" -n "$DASHBOARD_NAMESPACE" --type=merge \
    -p '{"spec":{"type":"ClusterIP"}}' >/dev/null 2>&1 || true
}

# The firewall rule that makes the NodePort actually reachable. Scoped to the
# one port and, by default, to the caller's own address -- a demo link is not a
# reason to open a port to the whole internet.
nodeport_firewall_hint() {
  local port="$1"
  cat <<EOF
    The NodePort still needs an ingress rule. Least-privilege version:

      MY_IP=\$(curl -s https://ifconfig.me)
      gcloud compute firewall-rules create signalloom-demo-${port} \\
        --allow=tcp:${port} --source-ranges="\${MY_IP}/32" \\
        --target-tags=signalloom-ci --description='SignalLoom demo, single source IP'

    Remove it when the demo is over:

      gcloud compute firewall-rules delete signalloom-demo-${port} --quiet
EOF
}
