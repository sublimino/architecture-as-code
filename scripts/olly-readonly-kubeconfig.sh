#!/usr/bin/env bash
# Create a read-only ServiceAccount and write a kubeconfig that authenticates as
# it, so the Estate 95 terminal is genuinely scoped to read-only access even
# though it runs kubectl. The SA is bound to the built-in `view` ClusterRole
# (which excludes secrets) plus a supplemental read of the Flux/GitOps CRDs the
# demo surfaces. Idempotent; best-effort (exits non-zero quietly if the cluster
# is down, so `make console` still starts with the default context).
#
# Prints the absolute kubeconfig path on stdout on success (nothing on failure);
# diagnostics go to stderr.
set -euo pipefail

SA=estate95-readonly
NS=kube-system
OUT="${1:-.estate95/readonly.kubeconfig}"

log() { echo "$@" >&2; }

kubectl cluster-info >/dev/null 2>&1 || { log "cluster unreachable; skipping read-only kubeconfig"; exit 1; }

log "creating read-only ServiceAccount ${NS}/${SA}"
kubectl -n "${NS}" create serviceaccount "${SA}" --dry-run=client -o yaml | kubectl apply -f - >&2

# Built-in `view` (read-most, no secrets) ...
kubectl create clusterrolebinding "${SA}-view" \
  --clusterrole=view --serviceaccount="${NS}:${SA}" \
  --dry-run=client -o yaml | kubectl apply -f - >&2

# ... plus read-only on the GitOps CRDs the Cluster State + terminal show.
kubectl apply -f - >&2 <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ${SA}-gitops-read
rules:
  - apiGroups:
      - source.toolkit.fluxcd.io
      - kustomize.toolkit.fluxcd.io
      - helm.toolkit.fluxcd.io
      - notification.toolkit.fluxcd.io
      - fluxcd.controlplane.io
    resources: ["*"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${SA}-gitops-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ${SA}-gitops-read
subjects:
  - kind: ServiceAccount
    name: ${SA}
    namespace: ${NS}
EOF

log "minting a 24h token"
TOKEN=$(kubectl -n "${NS}" create token "${SA}" --duration=24h)
SERVER=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')
CADATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

mkdir -p "$(dirname "${OUT}")"
cat > "${OUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: estate95
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CADATA}
contexts:
  - name: estate95-readonly
    context:
      cluster: estate95
      user: estate95-readonly
current-context: estate95-readonly
users:
  - name: estate95-readonly
    user:
      token: ${TOKEN}
EOF

ABS="$(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")"
log "wrote read-only kubeconfig to ${ABS} (SA ${NS}/${SA}: view + gitops-read, no secrets)"
echo "${ABS}"
