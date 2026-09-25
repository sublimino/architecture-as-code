#!/usr/bin/env bash
# ==============================================================================
# scripts/eap/svid-fetch-proof.sh
# Proves in-pod SVID fetch via SPIFFE CSI driver under PSS restricted.
# Asserts trust domain is signalloom.demo and verifies PSS admission rejection
# of privileged pods as a positive control.
# ==============================================================================
set -euo pipefail

HASH="${1:-a0314bec}"
CUSTOMER="${2:-kusari}"
NS="eap-${HASH}"
TRUST_DOMAIN="${SIGNAL_LOOM_TRUST_DOMAIN:-signalloom.demo}"
EXPECTED_SPIFFE_ID="spiffe://${TRUST_DOMAIN}/ns/${NS}/sa/tenant-app"

echo "=== EAP Workload Identity & SPIFFE CSI Fetch Proof ==="
echo "Target Namespace:    ${NS}"
echo "Expected Trust Domain: ${TRUST_DOMAIN}"
echo "Expected SPIFFE ID:  ${EXPECTED_SPIFFE_ID}"

# ── 1. Create or verify tenant namespace with PSS restricted labels ──────────
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    app.kubernetes.io/managed-by: signalloom-eap
    signalloom.io/eap-hash: "${HASH}"
    signalloom.io/customer: "${CUSTOMER}"
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tenant-app
  namespace: ${NS}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: eap-default-deny-and-isolation
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: fe-signalloom
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: inf-bao
      ports:
        - protocol: TCP
          port: 8200
        - protocol: TCP
          port: 8081
EOF

# ── 2. PSS Admission Controls: Server dry-run proofs ────────────────────────
echo "--> Testing PSS restricted admission with CSI volume..."
cat <<EOF | kubectl -n "${NS}" apply --dry-run=server -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: dryrun-csi-pod
  namespace: ${NS}
spec:
  serviceAccountName: tenant-app
  restartPolicy: Never
  containers:
    - name: test
      image: ghcr.io/spiffe/spire-agent:1.11.1
      command: ["/bin/sleep", "1"]
      volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: "RuntimeDefault"
  volumes:
    - name: spiffe-workload-api
      csi:
        driver: csi.spiffe.io
        readOnly: true
EOF
echo "PSS Admission PASS: Tenant pod with CSI ephemeral volume admitted under restricted."

echo "--> Testing PSS restricted rejection on privileged pod (positive control)..."
priv_output="$(cat <<EOF | kubectl -n "${NS}" apply --dry-run=server -f - 2>&1 || true
apiVersion: v1
kind: Pod
metadata:
  name: dryrun-privileged-pod
  namespace: ${NS}
spec:
  serviceAccountName: tenant-app
  restartPolicy: Never
  containers:
    - name: test
      image: ghcr.io/spiffe/spire-agent:1.11.1
      securityContext:
        privileged: true
EOF
)"

if grep -q "violates PodSecurity" <<< "${priv_output}"; then
  echo "PSS Enforcement PASS: Privileged pod correctly rejected by restricted admission controller."
else
  echo "ERROR: Privileged pod was not rejected by restricted admission controller." >&2
  echo "${priv_output}" >&2
  exit 1
fi

# ── 3. Register SPIRE Entry on Server ─────────────────────────────────────────
echo "--> Registering SPIRE entry for ${EXPECTED_SPIFFE_ID}..."
kubectl -n inf-bao exec deploy/spire-server -c spire-server -- \
  /opt/spire/bin/spire-server entry create \
  -spiffeID "${EXPECTED_SPIFFE_ID}" \
  -parentID "spiffe://${TRUST_DOMAIN}/agent/kind" \
  -selector "k8s:ns:${NS}" \
  -selector "k8s:sa:tenant-app" \
  -x509SVIDTTL 3600 2>&1 | grep -E 'Entry ID|already exists' || true

# ── 4. Deploy Running Tenant Pod with CSI volume ──────────────────────────────
echo "--> Launching tenant-app pod with SPIFFE CSI volume..."
kubectl -n "${NS}" delete pod tenant-app --ignore-not-found --now >/dev/null 2>&1 || true

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tenant-app
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: tenant-app
    app.kubernetes.io/managed-by: signalloom-eap
    signalloom.io/eap-hash: "${HASH}"
spec:
  serviceAccountName: tenant-app
  restartPolicy: Never
  containers:
    - name: tenant-app
      image: ghcr.io/spiffe/spire-agent:1.11.1
      command: ["/opt/spire/bin/spire-agent", "api", "fetch", "x509", "-socketPath", "/spiffe-workload-api/spire-agent.sock"]
      env:
        - name: SPIFFE_ENDPOINT_SOCKET
          value: "unix:///spiffe-workload-api/spire-agent.sock"
      volumeMounts:
        - name: spiffe-workload-api
          mountPath: /spiffe-workload-api
          readOnly: true
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        runAsNonRoot: true
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]
        seccompProfile:
          type: "RuntimeDefault"
  volumes:
    - name: spiffe-workload-api
      csi:
        driver: csi.spiffe.io
        readOnly: true
EOF

echo "--> Waiting for tenant-app SVID fetch completion..."
kubectl -n "${NS}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/tenant-app --timeout=30s

# ── 5. Fetch X.509 SVID logs from the pod ─────────────────────────────────────
echo "--> Reading SVID fetch output from pod logs..."
FETCH_OUTPUT="$(kubectl -n "${NS}" logs pod/tenant-app)"

echo "Fetch Output:"
echo "${FETCH_OUTPUT}"

FETCHED_ID="$(echo "${FETCH_OUTPUT}" | grep -E 'SPIFFE ID:' | awk '{print $NF}' | head -n 1)"
echo "Fetched SPIFFE ID: ${FETCHED_ID}"

if [ "${FETCHED_ID}" = "${EXPECTED_SPIFFE_ID}" ]; then
  echo "PROOF PASSED: In-pod SVID SPIFFE ID '${FETCHED_ID}' matches expected '${EXPECTED_SPIFFE_ID}'"
else
  echo "PROOF FAILED: Got '${FETCHED_ID}', expected '${EXPECTED_SPIFFE_ID}'" >&2
  exit 1
fi
