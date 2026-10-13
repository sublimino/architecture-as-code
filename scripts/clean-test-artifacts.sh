#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# scripts/clean-test-artifacts.sh — Audit and remove leaked test artifacts from
# the live cluster and host /tmp without auto-cleaning cluster state inside test suites.
#
# Why this is a separate job:
#   Tests deploy resources into the Kubernetes cluster (Certificates, Issuers,
#   Secrets, Routes, Pods) that persist beyond test execution so engineers and
#   agents can inspect cluster state. This script is the dedicated cleanup job
#   that audits and reconciles the cluster and host /tmp back to a clean state
#   on demand, in CI, or during scheduled drift reconciliation.
#
# Usage:
#   scripts/clean-test-artifacts.sh [--check | --dry-run] [--quiet]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

MODE="clean"
QUIET=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Audit and clean leaked test artifacts in the Kubernetes cluster and /tmp.

Options:
  --check     Read-only check; exit 1 if any test artifacts or drift are present
  --dry-run   Report what would be cleaned without mutating state (exit 0)
  --quiet     Suppress informational output
  -h, --help  Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE="check"
      shift
      ;;
    --dry-run)
      MODE="dry-run"
      shift
      ;;
    --quiet|-q)
      QUIET=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

log() {
  if [[ "$QUIET" -eq 0 ]]; then
    echo "$@"
  fi
}

ARTIFACTS_FOUND=0
ARTIFACTS_CLEANED=0

record_finding() {
  local desc="$1"
  ARTIFACTS_FOUND=$((ARTIFACTS_FOUND + 1))
  log "  [ARTIFACT] ${desc}"
}

record_cleaned() {
  local desc="$1"
  ARTIFACTS_CLEANED=$((ARTIFACTS_CLEANED + 1))
  log "  [CLEANED]  ${desc}"
}

log "=== Signal Loom Test Artifact Cleanup Job (mode: ${MODE}) ==="

# ------------------------------------------------------------------------------
# 1. Host /tmp test artifacts
# ------------------------------------------------------------------------------
shopt -s nullglob
TMP_KUBECONFIGS=(
  /tmp/osramp-tenant-*.kubeconfig
  /tmp/osramp-test-tenant-*.kubeconfig
  /tmp/osramp-test-tenant*.kubeconfig
  /tmp/osramp-redteam-*.kubeconfig
  /tmp/osramp.kubeconfig
  /tmp/test-osramp.kubeconfig
  /tmp/kind-tenant-*.kubeconfig
  /tmp/kind-test-tenant-*.kubeconfig
  /tmp/kind-test-tenant*.kubeconfig
  /tmp/kind-redteam-*.kubeconfig
  /tmp/tenant-*.kubeconfig
  /tmp/redteam-*.kubeconfig
)
TMP_TEST_ARTIFACTS=(
  /tmp/slsi-test-*
  /tmp/slsi-diag-*
  /tmp/slsi-osd1-*
  /tmp/slsi-pkg-*
  /tmp/slsi-selftest.*
  /tmp/slsi-falsify-utility.*
  /tmp/worktree-hygiene.*
  /tmp/test-tenant
)
TMP_SKILL_LOGS=(
  /tmp/scheduled-skills-*
)
shopt -u nullglob

for f in "${TMP_KUBECONFIGS[@]}"; do
  [[ -e "$f" ]] || continue
  record_finding "Host temp kubeconfig: $f"
  if [[ "$MODE" == "clean" ]]; then
    rm -f "$f"
    record_cleaned "Removed $f"
  fi
done

for p in "${TMP_TEST_ARTIFACTS[@]}"; do
  [[ -e "$p" ]] || continue
  record_finding "Host temp test artifact: $p"
  if [[ "$MODE" == "clean" ]]; then
    rm -rf "$p"
    record_cleaned "Removed $p"
  fi
done

if [[ "$MODE" != "check" ]]; then
  for d in "${TMP_SKILL_LOGS[@]}"; do
    [[ -e "$d" ]] || continue
    record_finding "Host scheduled-skills log dir: $d"
    if [[ "$MODE" == "clean" ]]; then
      rm -rf "$d"
      record_cleaned "Removed $d"
    fi
  done
fi

# ------------------------------------------------------------------------------
# 2. Cluster test artifacts (if cluster is reachable)
# ------------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1 || ! kubectl cluster-info --request-timeout=4s >/dev/null 2>&1; then
  log "CLUSTER_STATUS=OFFLINE (skipping in-cluster artifact cleanup)"
  log "ARTIFACTS_FOUND=${ARTIFACTS_FOUND}"
  log "ARTIFACTS_CLEANED=${ARTIFACTS_CLEANED}"
  if [[ "$MODE" == "check" && "$ARTIFACTS_FOUND" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

log "CLUSTER_STATUS=ONLINE"

repair_cluster_tls_secret() {
  local owner_name cert_ann cert_obj_name cert_uid
  owner_name="$(kubectl get secret cluster-tls -n cert-manager -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
  cert_ann="$(kubectl get secret cluster-tls -n cert-manager -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}' 2>/dev/null || true)"
  if [[ ( -n "$owner_name" && "$owner_name" != "cluster" && "$owner_name" != "cluster-tls" ) || ( -n "$cert_ann" && "$cert_ann" != "cluster" && "$cert_ann" != "cluster-tls" ) ]]; then
    record_finding "Secret/cluster-tls in cert-manager hijacked (owner=${owner_name:-none}, cert-annotation=${cert_ann:-none})"
    if [[ "$MODE" == "clean" ]]; then
      cert_obj_name="cluster"
      cert_uid="$(kubectl get certificate cluster -n cert-manager -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
      if [[ -z "$cert_uid" ]]; then
        cert_obj_name="cluster-tls"
        cert_uid="$(kubectl get certificate cluster-tls -n cert-manager -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
      fi
      if [[ -n "$cert_uid" ]]; then
        kubectl patch secret cluster-tls -n cert-manager --type=merge \
          -p="{\"metadata\":{\"annotations\":{\"cert-manager.io/certificate-name\":\"${cert_obj_name}\"},\"ownerReferences\":[{\"apiVersion\":\"cert-manager.io/v1\",\"blockOwnerDeletion\":true,\"controller\":true,\"kind\":\"Certificate\",\"name\":\"${cert_obj_name}\",\"uid\":\"${cert_uid}\"}]}}" >/dev/null
        record_cleaned "Restored Secret/cluster-tls ownerReference and annotation to Certificate/${cert_obj_name} (${cert_uid})"
      else
        kubectl patch secret cluster-tls -n cert-manager --type=json \
          -p='[{"op":"remove","path":"/metadata/ownerReferences"}]' >/dev/null 2>&1 || true
        record_cleaned "Cleared stale ownerReference from Secret/cluster-tls"
      fi
    fi
  fi
}

# 2a. Leaked test ClusterIssuers (delete first so cert-manager does not recreate acme-dns01-account-key)
mapfile -t LEAKED_ISSUERS < <(
  kubectl get clusterissuers.cert-manager.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^(acme-dns01-issuer|byo-ca-issuer)$' || true
)
if [[ "${#LEAKED_ISSUERS[@]}" -gt 0 ]]; then
  record_finding "${#LEAKED_ISSUERS[@]} leaked test ClusterIssuer(s): ${LEAKED_ISSUERS[*]}"
  if [[ "$MODE" == "clean" ]]; then
    kubectl delete clusterissuers.cert-manager.io "${LEAKED_ISSUERS[@]}" --ignore-not-found >/dev/null 2>&1 || true
    record_cleaned "Deleted leaked ClusterIssuer(s): ${LEAKED_ISSUERS[*]}"
  fi
fi

# 2b. Repair Secret/cluster-tls ownerReference in cert-manager BEFORE deleting
#     test Certificates so Kubernetes GC never deletes Secret/cluster-tls.
if kubectl get ns cert-manager >/dev/null 2>&1; then
  repair_cluster_tls_secret

  # 2c. Leaked test Certificates in cert-manager (delete with --cascade=orphan)
  mapfile -t LEAKED_CERTS < <(
    kubectl get certificates.cert-manager.io -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-)' || true
  )
  if [[ "${#LEAKED_CERTS[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_CERTS[@]} leaked test Certificate(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      kubectl delete certificates.cert-manager.io -n cert-manager "${LEAKED_CERTS[@]}" --cascade=orphan --ignore-not-found >/dev/null 2>&1 || true
      record_cleaned "Deleted ${#LEAKED_CERTS[@]} leaked test Certificate(s) in cert-manager"
      repair_cluster_tls_secret
    fi
  fi

  # 2d. Leaked CertificateRequests and ACME Orders/Challenges in cert-manager
  mapfile -t LEAKED_CRS < <(
    kubectl get certificaterequests.cert-manager.io -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-)' || true
  )
  if [[ "${#LEAKED_CRS[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_CRS[@]} leaked test CertificateRequest(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      kubectl delete certificaterequests.cert-manager.io -n cert-manager "${LEAKED_CRS[@]}" --ignore-not-found >/dev/null 2>&1 || true
      record_cleaned "Deleted ${#LEAKED_CRS[@]} leaked test CertificateRequest(s) in cert-manager"
    fi
  fi

  mapfile -t LEAKED_CHALLENGES < <(
    kubectl get challenges.acme.cert-manager.io -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-)' || true
  )
  if [[ "${#LEAKED_CHALLENGES[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_CHALLENGES[@]} leaked ACME Challenge(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      for ch in "${LEAKED_CHALLENGES[@]}"; do
        kubectl patch challenge.acme.cert-manager.io "$ch" -n cert-manager --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
        kubectl delete challenge.acme.cert-manager.io "$ch" -n cert-manager --ignore-not-found >/dev/null 2>&1 || true
      done
      record_cleaned "Deleted ${#LEAKED_CHALLENGES[@]} leaked ACME Challenge(s) in cert-manager"
    fi
  fi

  mapfile -t LEAKED_ORDERS < <(
    kubectl get orders.acme.cert-manager.io -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-)' || true
  )
  if [[ "${#LEAKED_ORDERS[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_ORDERS[@]} leaked ACME Order(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      for ord in "${LEAKED_ORDERS[@]}"; do
        kubectl patch order.acme.cert-manager.io "$ord" -n cert-manager --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' >/dev/null 2>&1 || true
        kubectl delete order.acme.cert-manager.io "$ord" -n cert-manager --ignore-not-found >/dev/null 2>&1 || true
      done
      record_cleaned "Deleted ${#LEAKED_ORDERS[@]} leaked ACME Order(s) in cert-manager"
    fi
  fi

  # 2e. Leaked test ReferenceGrants in cert-manager
  mapfile -t LEAKED_RGS < <(
    kubectl get referencegrants.gateway.networking.k8s.io -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-|byo-tls-grant$)' || true
  )
  if [[ "${#LEAKED_RGS[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_RGS[@]} leaked test ReferenceGrant(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      kubectl delete referencegrants.gateway.networking.k8s.io -n cert-manager "${LEAKED_RGS[@]}" --ignore-not-found >/dev/null 2>&1 || true
      record_cleaned "Deleted ${#LEAKED_RGS[@]} leaked test ReferenceGrant(s) in cert-manager"
    fi
  fi

  # 2f. Leaked test Secrets in cert-manager
  mapfile -t LEAKED_CM_SECRETS < <(
    kubectl get secrets -n cert-manager -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '^(tenant-|test-tenant-|redteam-|acme-dns01-account-key$|byo-tls$)' || true
  )
  if [[ "${#LEAKED_CM_SECRETS[@]}" -gt 0 ]]; then
    record_finding "${#LEAKED_CM_SECRETS[@]} leaked test Secret(s) in cert-manager"
    if [[ "$MODE" == "clean" ]]; then
      kubectl delete secrets -n cert-manager "${LEAKED_CM_SECRETS[@]}" --ignore-not-found >/dev/null 2>&1 || true
      record_cleaned "Deleted ${#LEAKED_CM_SECRETS[@]} leaked test Secret(s) in cert-manager"
    fi
  fi
fi

# 2g. Leaked test HTTPRoutes across namespaces
mapfile -t LEAKED_ROUTES < <(
  kubectl get httproutes.gateway.networking.k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '/(tenant-|test-tenant-|redteam-)' || true
)
if [[ "${#LEAKED_ROUTES[@]}" -gt 0 ]]; then
  record_finding "${#LEAKED_ROUTES[@]} leaked test HTTPRoute(s)"
  if [[ "$MODE" == "clean" ]]; then
    for ns_name in "${LEAKED_ROUTES[@]}"; do
      [[ -n "$ns_name" ]] || continue
      kubectl delete httproutes.gateway.networking.k8s.io "${ns_name#*/}" -n "${ns_name%%/*}" --ignore-not-found >/dev/null 2>&1 || true
    done
    record_cleaned "Deleted ${#LEAKED_ROUTES[@]} leaked test HTTPRoute(s)"
  fi
fi

# 2h. Flux-system test secrets (slsi-release-pub and cosign-pub drift)
if kubectl get ns flux-system >/dev/null 2>&1; then
  if kubectl get secret slsi-release-pub -n flux-system >/dev/null 2>&1; then
    record_finding "Leaked test Secret flux-system/slsi-release-pub"
    if [[ "$MODE" == "clean" ]]; then
      kubectl delete secret slsi-release-pub -n flux-system --ignore-not-found >/dev/null 2>&1 || true
      record_cleaned "Deleted Secret flux-system/slsi-release-pub"
    fi
  fi

  CANONICAL_COSIGN_PUB="${REPO_ROOT}/.keys/cosign.pub"
  if [[ -f "$CANONICAL_COSIGN_PUB" ]] && kubectl get secret cosign-pub -n flux-system >/dev/null 2>&1; then
    CLUSTER_PUB="$(kubectl get secret cosign-pub -n flux-system -o jsonpath='{.data.cosign\.pub}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    EXTRA_FIELDS="$(kubectl get secret cosign-pub -n flux-system -o jsonpath='{.metadata.labels.signalloom\.ai/tenant-id}{.data.release\.pub}' 2>/dev/null || true)"
    DISK_PUB="$(cat "$CANONICAL_COSIGN_PUB")"
    if [[ "$CLUSTER_PUB" != "$DISK_PUB" || -n "$EXTRA_FIELDS" ]]; then
      record_finding "Secret flux-system/cosign-pub drifted from .keys/cosign.pub (overwritten by test tenant key)"
      if [[ "$MODE" == "clean" ]]; then
        kubectl create secret generic cosign-pub -n flux-system \
          --from-file=cosign.pub="$CANONICAL_COSIGN_PUB" \
          --dry-run=client -o yaml | kubectl replace -f - >/dev/null
        record_cleaned "Restored Secret flux-system/cosign-pub from .keys/cosign.pub"
      fi
    fi
  fi
fi

# 2i. Gateway/cluster and ClientTrafficPolicy in ingress namespace
if kubectl get gateway.gateway.networking.k8s.io cluster -n ingress >/dev/null 2>&1; then
  GW_HOST="$(kubectl get gateway.gateway.networking.k8s.io cluster -n ingress -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null || true)"
  GW_CERT="$(kubectl get gateway.gateway.networking.k8s.io cluster -n ingress -o jsonpath='{.spec.listeners[1].tls.certificateRefs[0].name}' 2>/dev/null || true)"
  GW_TENANT_LBL="$(kubectl get gateway.gateway.networking.k8s.io cluster -n ingress -o jsonpath='{.metadata.labels.signalloom\.ai/tenant}' 2>/dev/null || true)"
  if [[ "$GW_HOST" != "*.osramp.acme.local" || "$GW_CERT" != "cluster-tls" || -n "$GW_TENANT_LBL" ]]; then
    record_finding "Gateway ingress/cluster drifted (hostname=${GW_HOST}, cert=${GW_CERT}, tenant=${GW_TENANT_LBL:-none})"
    if [[ "$MODE" == "clean" ]]; then
      CANONICAL_GW="$(kubectl get resourceset cluster-gateway -n ingress -o json 2>/dev/null | jq -c '.spec.resources[] | select(.kind=="Gateway" and .metadata.name=="cluster")' 2>/dev/null || true)"
      if [[ -n "$CANONICAL_GW" ]]; then
        printf '%s\n' "$CANONICAL_GW" | kubectl apply -f - >/dev/null 2>&1 || true
        kubectl label gateway.gateway.networking.k8s.io cluster -n ingress signalloom.ai/tenant- signalloom.ai/ingress-mode- >/dev/null 2>&1 || true
        record_cleaned "Restored Gateway ingress/cluster from ResourceSet/cluster-gateway"
      elif command -v flux >/dev/null 2>&1; then
        flux reconcile kustomization infra-configs -n ingress --with-source >/dev/null 2>&1 || true
        record_cleaned "Triggered Flux reconciliation to restore Gateway ingress/cluster"
      fi
    fi
  fi
fi

# 2j. Leaked test Namespace 'zot' (real registry is in Namespace 'registry')
if kubectl get ns zot >/dev/null 2>&1; then
  record_finding "Leaked test Namespace 'zot' (from init-tenant.sh stage p2-3)"
  if [[ "$MODE" == "clean" ]]; then
    kubectl delete ns zot --ignore-not-found --wait=true >/dev/null 2>&1 || true
    record_cleaned "Deleted test Namespace 'zot'"
  fi
fi

# 2k. Failed Jobs and terminated Failed (Error) / completed test probe Pods
mapfile -t FAILED_JOBS < <(
  kubectl get jobs -A -o json 2>/dev/null \
    | jq -r '.items[] | select((.status.failed // 0) > 0) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true
)
if [[ "${#FAILED_JOBS[@]}" -gt 0 ]]; then
  record_finding "${#FAILED_JOBS[@]} failed Job(s): ${FAILED_JOBS[*]}"
  if [[ "$MODE" == "clean" ]]; then
    for ns_name in "${FAILED_JOBS[@]}"; do
      [[ -n "$ns_name" ]] || continue
      kubectl delete job "${ns_name#*/}" -n "${ns_name%%/*}" --ignore-not-found >/dev/null 2>&1 || true
    done
    record_cleaned "Deleted ${#FAILED_JOBS[@]} failed Job(s)"
  fi
fi

mapfile -t STALE_PODS < <(
  kubectl get pods -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.status.phase == "Failed" or (.status.phase == "Succeeded" and (.metadata.name | test("^(nono-containment-probe-|test-|probe-)")))) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || true
)
if [[ "${#STALE_PODS[@]}" -gt 0 ]]; then
  record_finding "${#STALE_PODS[@]} terminated Failed/probe Pod(s)"
  if [[ "$MODE" == "clean" ]]; then
    for ns_name in "${STALE_PODS[@]}"; do
      [[ -n "$ns_name" ]] || continue
      kubectl delete pod "${ns_name#*/}" -n "${ns_name%%/*}" --ignore-not-found >/dev/null 2>&1 || true
    done
    record_cleaned "Deleted ${#STALE_PODS[@]} terminated Failed/probe Pod(s)"
  fi
fi

log "ARTIFACTS_FOUND=${ARTIFACTS_FOUND}"
log "ARTIFACTS_CLEANED=${ARTIFACTS_CLEANED}"

if [[ "$MODE" == "check" ]]; then
  if [[ "$ARTIFACTS_FOUND" -gt 0 ]]; then
    log "RESULT: DIRTY (${ARTIFACTS_FOUND} test artifact group(s) present; run 'make clean-test-artifacts' or './scripts/clean-test-artifacts.sh')"
    exit 1
  else
    log "RESULT: CLEAN (0 test artifacts found)"
    exit 0
  fi
fi

log "RESULT: CLEANUP_COMPLETE (found=${ARTIFACTS_FOUND}, cleaned=${ARTIFACTS_CLEANED})"
exit 0
