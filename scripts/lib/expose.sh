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

# Namespaces holding a flux-runtime-info copy that feeds a ${PUBLIC_ORIGIN}.
ORIGIN_CONSUMER_NAMESPACES=(inf-signalloom fe-signalloom)

# What teardown reverts to. Must match the :=default in dex.yaml and in the
# fe-signalloom deployment, or teardown lands somewhere neither expects.
LOCAL_ORIGIN_DEFAULT="${LOCAL_ORIGIN_DEFAULT:-https://dashboard.osramp.acme.local:30754}"

# The Kustomizations that consume PUBLIC_ORIGIN. Defined here so expose.sh is
# self-contained; public-tunnel.sh sets the same list for its own use.
FLUX_TARGETS=("${FLUX_TARGETS[@]:-inf-signalloom/infra-configs fe-signalloom/apps}")

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
# This replaces patching the Dex secret and the API deployment directly and
# then suspending Flux to stop it reverting them. PUBLIC_ORIGIN is a
# substitution input, so writing it here and reconciling makes Flux APPLY the
# public origin rather than undo it. Nothing needs suspending, and the value
# survives every future reconcile.
publish_origin() {
  local origin="$1" ns

  # Written to flux-system AND to each tenant copy, deliberately.
  #
  # The tenant copies carry `fluxcd.controlplane.io/copyFrom:
  # flux-system/flux-runtime-info`, but that copy does NOT reliably propagate an
  # update: measured on 2026-08-03, changing the key in flux-system (and even
  # forcing a ResourceSet reconcile) left both tenant copies on the previous
  # value, so Dex and the API kept serving a stale origin. Writing flux-system
  # alone looks correct and silently does nothing.
  #
  # flux-system is still written because it is the durable source a future
  # re-copy or a rebuilt namespace will read; the tenant writes are what take
  # effect now.
  kubectl patch configmap flux-runtime-info -n flux-system \
    --type=merge -p "{\"data\":{\"PUBLIC_ORIGIN\":\"${origin}\"}}" >/dev/null
  for ns in "${ORIGIN_CONSUMER_NAMESPACES[@]}"; do
    kubectl patch configmap flux-runtime-info -n "$ns" \
      --type=merge -p "{\"data\":{\"PUBLIC_ORIGIN\":\"${origin}\"}}" >/dev/null 2>&1 || true
  done
  echo "    PUBLIC_ORIGIN=${origin}"

  reconcile_origin_consumers
}

# Teardown SETS the local default rather than removing the key.
#
# Removing it does not unpublish: the tenant copies keep the last value, so the
# demo stays published on a dead origin while the cluster looks reset. An
# explicit value always propagates; an absent one does not.
unpublish_origin() {
  publish_origin "${LOCAL_ORIGIN_DEFAULT}"
}

# Reconciling the Kustomization alone is not enough -- it re-applies whatever
# its source already had. The OCIRepository must be refreshed first or the new
# substitution never reaches the manifest.
reconcile_origin_consumers() {
  local target ns name src
  for target in "${FLUX_TARGETS[@]}"; do
    ns="${target%%/*}"; name="${target##*/}"
    src="$(kubectl get kustomization "$name" -n "$ns" -o jsonpath='{.spec.sourceRef.name}' 2>/dev/null || true)"
    [[ -n "$src" ]] && flux reconcile source oci "$src" -n "$ns" >/dev/null 2>&1 || true
    flux reconcile kustomization "$name" -n "$ns" >/dev/null 2>&1 || true
  done
  echo "    reconciled ${FLUX_TARGETS[*]}"
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
