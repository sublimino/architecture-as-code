# SLER-P3-PRE — Mesh Policy, Admission Controller, and Severance Seams

## Status & Preflight Verdict
- **Card**: `SLER-P3-PRE`
- **Role**: Pre-flight verification for Phase 3 (Mesh isolation & dynamic admission enforcement)
- **Verdict**: **PASS — Phase 3 cleared to proceed with confirmed seams and zero blockers.**
- **Integration Ref**: `integration/sler-v0.1.0` (base commit `51a53183b4bd4a31b9fa9e64a5b78bc58b0a4bcd`)

---

## 1. Mesh Technology & Policy Inventory

### 1.1 Deployed CNI & Mesh Ingress State
Empirical cluster inspection and repository audit establish the exact network topology:

1. **CNI Layer — Cilium**:
   - Cilium is actively deployed in the cluster (`kube-system` namespace: `cilium-envoy-fn45t`, `cilium-h9hz8`, `cilium-operator-68cb64fdbb-dspv7`).
   - Cilium CRDs are installed and active on the cluster:
     - `ciliumnetworkpolicies.cilium.io`
     - `ciliumclusterwidenetworkpolicies.cilium.io`
     - `ciliumendpoints.cilium.io`
     - `ciliumidentities.cilium.io`
     - `ciliumnodes.cilium.io`
2. **Ingress Layer — Envoy Gateway**:
   - Envoy Gateway (`gateway.envoyproxy.io`) manages north-south cluster ingress (`ingress` namespace: `envoy-gateway-5b674968c-5bkgm`, `envoy-ingress-cluster-6b24dc08-6fc8574f6f-kmkm7`).
   - Manifest definitions live in `d2-infra/components/ingress/controllers/base/envoy-gateway.yaml`.
3. **Istio Service Mesh — NOT DEPLOYED**:
   - Zero Istio CRDs, zero Istio pods, and zero Istio configurations exist in the cluster or in the repository.
4. **Mesh Isolation Manifests — Greenfield**:
   - Audit command `grep -rln 'kind: CiliumNetworkPolicy\|kind: AuthorizationPolicy' d2-signalloom/` returns **0 matches**.
   - Standard Kubernetes `NetworkPolicy` manifests exist in `d2-signalloom/apps/*/base/networkpolicy.yaml` (L3/L4 ingress/egress rules), but dynamic L7 or eBPF-driven mesh isolation policies (`CiliumNetworkPolicy` or Istio `AuthorizationPolicy`) are 100% greenfield.

### 1.2 Implication for P3-1 (Mesh Isolation)
- P3-1 must target **Cilium** (`CiliumNetworkPolicy` / eBPF) or standard Kubernetes `NetworkPolicy` + eBPF conntrack severance, rather than assuming Istio.
- Istio `AuthorizationPolicy` references in proposal prose must be understood as an architectural alternative; in this target runtime, Cilium is the ground truth.

---

## 2. Node-Capability-Guard Admission Webhook Inventory

### 2.1 Complete Manifest Absence
An exhaustive inventory of `d2-signalloom/apps/node-capability-guard/` reveals exactly four files:
- `d2-signalloom/apps/node-capability-guard/go.mod`
- `d2-signalloom/apps/node-capability-guard/cmd/main.go`
- `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go`
- `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler_test.go`

**Missing Deployment Surface:**
- **Zero Dockerfiles**: No `Dockerfile` exists for building a container image.
- **Zero Kubernetes Workload Manifests**: No `Deployment`, `Service`, `ServiceAccount`, or `RBAC` manifests exist under `base/` or anywhere in `d2-signalloom/`.
- **Zero Admission Registration**: No `ValidatingWebhookConfiguration` or `MutatingWebhookConfiguration` exists registering `node-capability-guard` with the Kubernetes API server.
- **Zero GitOps Integration**: No ResourceSets or Flux Kustomizations under `d2-osramp-fleet/` reference `node-capability-guard`.

### 2.2 Decision Logic & Semantic Deficiencies (`pkg/webhook/handler.go`)
Inspection of `pkg/webhook/handler.go:58-113` shows:
```go
// Minimal Pod definition for inspection
type Pod struct {
	Metadata Metadata `json:"metadata"`
	Spec     PodSpec  `json:"spec"`
}

type Metadata struct {
	Name        string            `json:"name"`
	Namespace   string            `json:"namespace"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
}

type PodSpec struct {
	NodeSelector map[string]string `json:"nodeSelector"`
	NodeName     string            `json:"nodeName"`
}
```

**Decision Logic Analysis (`handler.go:77-113`)**:
1. `handler.go:83-89`: Evaluates `pod.Metadata.Labels` for `isAgent`:
   - `signalloom.ai/agent == "true"`
   - `signalloom.ai/role == "agent"`
   - `app.kubernetes.io/component == "agent"`
2. `handler.go:99-106`: For agent pods, checks only `pod.Spec.NodeSelector`:
   - `pod.Spec.NodeSelector["node.signalloom.ai/cgroup-v2"] == "true"`
   - `pod.Spec.NodeSelector["node.signalloom.ai/landlock"] == "true"`
3. **Zero SPIFFE ID Check**: `handler.go` has zero references to SPIFFE IDs (`spiffe://...`).
4. **Zero Contained-Identity Store / Denylist**: `handler.go` has no state store, cache, ConfigMap watcher, or API link to query whether an agent is in a contained or revoked state.
5. **Zero `ServiceAccountName` Field**: `PodSpec` (`handler.go:71-74`) omits `ServiceAccountName`, preventing SPIFFE ID derivation from the pod specification.
6. **Zero Readmission Block Capability**: As written, `node-capability-guard` only validates node capabilities for agent scheduling; it cannot express "block agent X from readmission".

### 2.3 Implication for P3-2 (Admission Webhook Block)
P3-2 must:
1. Build the complete deployment bundle (`Dockerfile`, `base/deployment.yaml`, `base/service.yaml`, `base/validatingwebhookconfiguration.yaml`, TLS certificate generation or cert-manager integration).
2. Extend `PodSpec` to parse `ServiceAccountName`.
3. Implement a contained-identity matching store/predicate (e.g. evaluating `signalloom.ai/agent-name`, SPIFFE ID derived from `spiffe://<trust-domain>/ns/<namespace>/sa/<serviceAccountName>`, and `signalloom.ai/state == "stunned"`).

---

## 3. Contained Agent Identity Contract at Readmission

### 3.1 Static vs Dynamic Identity at Admission Time
In Kubernetes admission control (`AdmissionReview` on Pod `CREATE` / `UPDATE`), a pod has not yet started and cannot present a runtime X.509 SVID or JWT token. Instead, the admission controller inspects the pod manifest:

| Identity Dimension | Source in `AdmissionRequest.Object` | Canonical Format / Convention |
| :--- | :--- | :--- |
| **SPIFFE ServiceAccount** | `pod.Spec.ServiceAccountName` + `pod.Metadata.Namespace` | `spiffe://signalloom.demo/ns/<namespace>/sa/<sa-name>` (`d2-signalloom/apps/fleet-manager/k8sclient.go:351`) |
| **Agent Name** | `pod.Metadata.Labels["signalloom.ai/agent-name"]` | `<agent-id>` without `agent-` prefix (`d2-signalloom/apps/fleet-manager/enforcement.go:88`) |
| **Agent Pod Flag** | `pod.Metadata.Labels["signalloom.ai/agent"]` | `"true"` (`d2-signalloom/apps/fleet-manager/enforcement.go:86`) |
| **State Label** | `pod.Metadata.Labels["signalloom.ai/state"]` | `"stunned"`, `"active"`, `"idle"` (`d2-signalloom/apps/fleet-manager/enforcement.go:82`) |
| **Containment Mode** | `pod.Metadata.Labels["signalloom.io/containment-mode"]` | `"frozen"`, `"isolated"`, `"quarantined"` (`d2-signalloom/apps/fleet-manager/enforcement.go:93`) |

### 3.2 CEL Admission Policy Interlock
The CEL ValidatingAdmissionPolicy in `d2-agent-trust/policies/agent-identity-state-protection.yaml:24-66` protects pods already carrying `signalloom.ai/state: stunned` from having that label removed by unprivileged identities:
- Only `system:serviceaccount:fe-signalloom:swarm-governor` or cluster admin may mutate `signalloom.ai/state` away from `stunned`.
- P3-2's validating webhook provides the complementary defense: denying the **creation/reconstitution** of any new Pod claiming an identity that is currently contained.

---

## 4. Netfilter Conntrack & TCP Severance Primitive

### 4.1 Audit of `stun-sentinel/pkg/tc/conntrack.go`
Inspection of `d2-signalloom/apps/stun-sentinel/pkg/tc/conntrack.go:380-435` confirms:

```go
// FlushIP deletes every conntrack entry involving the target IP and returns the
// number deleted.
//
// Never issues a table-wide flush: entries that do not involve the target are
// left strictly untouched (asserted by ISC-91 / ISC-95).
func FlushIP(target net.IP) (int, error) {
	if target == nil || target.To4() == nil {
		return 0, fmt.Errorf("conntrack: FlushIP requires an IPv4 address, got %v", target)
	}
	c, err := dialNetfilter()
	if err != nil {
		return 0, err
	}
	defer c.Close() // fd closed on every path, including the error paths below
	return flushIPOn(c, target)
}
```

### 4.2 Key Invariants & Capabilities Confirmed
1. **IPv4-Only & Fail-Closed**:
   - `conntrack.go:394-396` explicitly requires `target.To4() != nil`. If given `nil` or an IPv6 address, it fails closed with `conntrack: FlushIP requires an IPv4 address, got <target>`.
2. **Selective Deletion**:
   - `flushIPOn` (`conntrack.go:407-440`) dumps conntrack entries via netlink, filters matching tuples in userspace via `tupleMatchesIP`, and issues individual `CTA_TUPLE_ORIG` / `CTA_TUPLE_REPLY` delete messages.
   - It strictly avoids table-wide flushing (`conntrack.go:391-392`), leaving unrelated pod connections unaffected.
3. **Maturity & Reusability**:
   - This primitive is mature, well-tested (`conntrack_test.go`), and handles netlink socket lifecycles cleanly.
   - P3-1 should extend and call `FlushIP` directly for immediate TCP connection severance upon containment, rather than creating a duplicate netlink implementation.

---

## 5. Verification Tooling & Boundary Proof Readiness (`netassert`)

### 5.1 Tool Availability
- `command -v netassert` returns `/home/andy/bin/netassert` (exit code 0).
- `netassert -v` is operational.
- The binary is a ControlPlane-authored utility designed specifically for verifying Kubernetes NetworkPolicy isolation between pods, deployments, and external endpoints.

### 5.2 Target Wiring in `d2-signalloom/Makefile`
- Target `test-netassert` exists at `d2-signalloom/Makefile:193-203`.
- Gated on `command -v netassert` with fallback instructions.
- References `d2-signalloom/test/netassert-signalloom.yaml`.
- P3-1 boundary proofs and P3-GOV acceptance suites can rely directly on `netassert` for cryptographic/empirical proof of network isolation.

---

## 6. Citation Matrix

| Topic / Seam | Source File | Lines | Summary |
| :--- | :--- | :--- | :--- |
| **Cilium / Mesh Policies** | `d2-signalloom/` | (all) | 0 `CiliumNetworkPolicy` or `AuthorizationPolicy` manifests. |
| **Cilium CNI Pods** | Cluster (`kube-system`) | N/A | `cilium-envoy`, `cilium`, `cilium-operator` active. |
| **Envoy Gateway Ingress** | `d2-infra/components/ingress/controllers/base/envoy-gateway.yaml` | 1-45 | Envoy Gateway controller managing ingress gateway. |
| **Webhook Handler Logic** | `d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go` | 77-113 | `ValidatePod` checks only `cgroup-v2` and `landlock` nodeSelector labels. |
| **Missing Deployment** | `d2-signalloom/apps/node-capability-guard/` | (dir) | Exactly 4 files; 0 manifests, 0 Dockerfiles. |
| **Conntrack FlushIP** | `d2-signalloom/apps/stun-sentinel/pkg/tc/conntrack.go` | 393-396 | IPv4-only, fails closed, selective netlink tuple deletion. |
| **Agent State Labels** | `d2-signalloom/apps/fleet-manager/enforcement.go` | 80-94 | `signalloom.ai/state`, `signalloom.ai/agent`, `signalloom.ai/agent-name`. |
| **SPIFFE ID Pattern** | `d2-signalloom/apps/fleet-manager/k8sclient.go` | 351, 548 | `spiffe://signalloom.demo/ns/<ns>/sa/<agentID>`. |
| **CEL State Protection** | `d2-agent-trust/policies/agent-identity-state-protection.yaml` | 24-66 | Protects mutation away from `stunned` state. |
| **Netassert Target** | `d2-signalloom/Makefile` | 193-203 | `test-netassert` rule checking NetworkPolicy boundaries. |

---

## 7. Directives for Phase 3 Execution

1. **For SLER-P3-1 (Mesh Isolation)**:
   - Target Cilium eBPF / `CiliumNetworkPolicy` or standard `NetworkPolicy` coupled with `conntrack.FlushIP` for active connection severing.
   - Do not attempt Istio-specific CRDs since Istio is not present.
   - Ensure `FlushIP` receives resolved IPv4 addresses from Pod status.
2. **For SLER-P3-2 (Admission Webhook Block)**:
   - Create complete deployment assets for `node-capability-guard` (Dockerfile, Deployment, Service, ValidatingWebhookConfiguration).
   - Update `PodSpec` in `handler.go` to include `ServiceAccountName`.
   - Implement readmission block logic checking derived SPIFFE ID and agent-name labels against contained status.
3. **For SLER-P3-GOV (Governor)**:
   - Verify boundary enforcement with `netassert`.
   - Ensure admission tests assert rejection on pod recreation attempts for contained agents.
