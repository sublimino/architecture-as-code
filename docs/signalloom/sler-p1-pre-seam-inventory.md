# SLER-P1-PRE: Unresolved Enforcement Seams & Attack Surface Inventory

**Document Version:** 1.0.0  
**Phase:** Phase 1 Preflight (`SLER-P1-PRE`)  
**Shortcode:** `SLER`  
**Target Repository:** `osramp-demo` (`/home/andy/src/cp/osramp-demo`)  
**Target Branch:** `integration/sler-v0.1.0`  
**Date:** 2026-09-15  

---

## 1. Executive Summary & Seam Matrix

This inventory establishes the baseline enforcement seams, attack surface vulnerabilities, type signature gaps, and deployment disparities across the Signal Loom codebase prior to the commencement of Phase 1 Enforcer contract implementation.

### Primary Seams at a Glance

| # | Seam / Surface | Location | Current Posture | Architectural Risk / Gap | Phase Owner |
|---|---|---|---|---|---|
| **1** | **Fleet Manager HTTP Auth** | `d2-signalloom/apps/fleet-manager/main.go:256-262` | 7 / 7 routes unauthenticated | Any network-adjacent pod can trigger cluster-wide agent stun or recovery. | `P1-1`, `P1-3` |
| **2** | **Stun Sentinel HTTP & Engine Auth Asymmetry** | `d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go:249-255`<br>`pkg/cgroup/freezer.go:507,575` | Outer Bearer middleware present, but `Freezer.Freeze()` takes no credential parameter. | Signature-level gap: `Freezer.Freeze` cannot validate credentials at the engine layer; only `Unfreeze` does. | `P1-4` |
| **3** | **Sentinel DaemonSet & HostNetwork Seam** | `d2-signalloom/deploy/stun-sentinel-daemonset.yaml:103,136`<br>`d2-signalloom/infra/agent-swarm/networkpolicy.yaml:12-13` | `hostPID: true`, `privileged: true`, `signalloom-system` privileged namespace, 0 NetworkPolicies. | Standard K8s `NetworkPolicy` cannot filter traffic to `hostNetwork` pods. | `P1-4` |
| **4** | **Dual Sentinel Divergence** | `d2-signalloom/apps/stun-sentinel/`<br>`d2-signalloom/apps/signalloom-stun-sentinel/` | Two disparate implementations with differing discovery, polling, tc, and zero shared types. | `signalloom-stun-sentinel` lacks credential checks, emptiness gates, and process census. | `P4-1` |
| **5** | **Node Capability Guard Greenfield Manifests** | `d2-signalloom/apps/node-capability-guard/` | Go source only (`main.go`, `handler.go`). 0 manifests, 0 Dockerfiles. | Webhook has no deployment artifacts or `ValidatingWebhookConfiguration`. | `P3-2` |
| **6** | **Cascade False-Success Fabrication** | `d2-signalloom/apps/fleet-manager/cascade.go:88-109` | Errors in `GetPodState`, `RevokeCredentials`, `SetPodState` are swallowed; returns HTTP 200 `StateStunned`. | Orchestrator claims containment succeeded when underlying actions failed or ran against `noopFleetClient`. | `P1-5` |
| **7** | **Greenfield Mesh Policies** | `d2-signalloom/` (whole directory) | 0 `CiliumNetworkPolicy` or `AuthorizationPolicy` manifests exist. | In-flight TCP mesh isolation must be built greenfield. | `P3-1` |

---

## 2. HTTP Route & Authentication Matrix

### 2.1 Fleet Manager (`d2-signalloom/apps/fleet-manager/main.go`)

`fleet-manager` acts as the central orchestration plane. In [`main.go:256-262`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L256-L262), 7 HTTP endpoints are registered directly on a standard Go `http.ServeMux` with **zero** authentication, authorization, or token-validation middleware:

| Route | HTTP Method | Handler Function | Line Citation | Current Auth Posture | Impact / Blast Radius |
|---|---|---|---|---|---|
| `/health` | `GET` | `s.handleHealth` | [`main.go:256`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L256), [`:69-72`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L69-L72) | **Open / Unauthenticated** | Returns `{"status":"ok"}`. Safe for liveness probes. |
| `/api/v1/fleet/topology` | `GET` | `s.handleTopology` | [`main.go:257`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L257), [`:74-100`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L74-L100) | **Open / Unauthenticated** | Exposes entire fleet graph, dependency edges, risk scores, and cascade history. |
| `/api/v1/fleet/deploy` | `POST` | `s.handleDeploy` | [`main.go:258`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L258), [`:154-177`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L154-L177) | **Open / Unauthenticated** | Triggers topology reload and state reset. |
| `/api/v1/fleet/stun/{agentId}` | `POST` | `s.handleStun` | [`main.go:259`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L259), [`:102-128`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L102-L128) | **Open / Unauthenticated** | **CRITICAL:** Any caller can trigger cascading stun on any target agent and its downstream DAG dependencies. |
| `/api/v1/fleet/scan` | `POST` | `s.handleScan` | [`main.go:260`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L260), [`:179-204`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L179-L204) | **Open / Unauthenticated** | Triggers fleet compliance scan. |
| `/api/v1/fleet/recover` | `POST` | `s.handleRecover` | [`main.go:261`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L261), [`:130-152`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L130-L152) | **Open / Unauthenticated** | **CRITICAL:** Any caller can unstun/recover all stunned agents in topological order. |
| `/api/v1/fleet/reset` | `POST` | `s.handleReset` | [`main.go:262`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L262), [`:154-177`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L154-L177) | **Open / Unauthenticated** | Resets fleet topology and cascade state. |

### 2.2 Stun Sentinel (`d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go`)

`stun-sentinel` is a node-level daemon that performs in-kernel process freezing via cgroup v2 and network packet dropping via eBPF TC filters. In [`main.go:249-255`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L249-L255):

| Route | HTTP Method | Handler Function | Line Citation | Auth Posture | Inner Engine Auth |
|---|---|---|---|---|---|
| `/healthz` | `GET` | `s.handleHealth` | [`main.go:249`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L249), [`:196-212`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L196-L212) | **Open** | N/A (probes cgroup hierarchy writability via test mkdir). |
| `/readyz` | `GET` | `s.handleHealth` | [`main.go:250`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L250), [`:196-212`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L196-L212) | **Open** | N/A (readiness check). |
| `/stun` | `POST` | `s.handleStun` (via `requireBearer`) | [`main.go:254`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L254), [`:227-242`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L227-L242), [`:106-146`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L106-L146) | **Bearer Token Gated (HTTP layer only)** | **NONE:** `cgroup.Freezer.Freeze()` takes NO credential parameter. |
| `/resume` | `POST` | `s.handleResume` (via `requireBearer`) | [`main.go:255`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L255), [`:227-242`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L227-L242), [`:148-189`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L148-L189) | **Bearer Token Gated (HTTP layer)** | **ENFORCED:** `cgroup.Freezer.Unfreeze(cgroupPath, credential)` verifies validator. |

---

## 3. Structural Type Signature Gap: `Freezer.Freeze` vs `Freezer.Unfreeze`

Inspection of [`d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go) confirms an asymmetric type design between freeze and unfreeze:

### 3.1 Type Definitions and Method Signatures

1. **Validator Type & Default:**
   ```go
   // pkg/cgroup/freezer.go:118-122
   type CredentialValidator func(credential string) bool

   func DenyAllCredentials(string) bool { return false }
   ```
2. **Freezer Struct & Option:**
   ```go
   // pkg/cgroup/freezer.go:156-160
   type Freezer struct {
       root      string
       deadline  time.Duration
       validator CredentialValidator
   }

   // pkg/cgroup/freezer.go:175-181
   func WithCredentialValidator(v CredentialValidator) Option {
       return func(f *Freezer) {
           if v != nil {
               f.validator = v
           }
       }
   }
   ```
3. **Freeze Methods (NO credential parameter):**
   ```go
   // pkg/cgroup/freezer.go:507
   func (f *Freezer) Freeze(cgroupPath string) (*FreezeResult, error)

   // pkg/cgroup/freezer.go:557
   func (f *Freezer) FreezePod(podUID string) (*FreezeResult, error)
   ```
4. **Unfreeze Methods (CREDENTIAL parameter mandatory):**
   ```go
   // pkg/cgroup/freezer.go:575-580
   func (f *Freezer) Unfreeze(cgroupPath, credential string) (*FreezeResult, error) {
       res := &FreezeResult{CgroupPath: cgroupPath, Frozen: true, Deadline: f.deadline}

       if f.validator == nil || !f.validator(credential) {
           return res, fmt.Errorf("%w: %s", ErrUnauthorized, cgroupPath)
       }
       ...
   }

   // pkg/cgroup/freezer.go:624
   func (f *Freezer) UnfreezePod(podUID, credential string) (*FreezeResult, error)
   ```

### 3.2 Key Finding for P1-4 & P1-3

- `cgroup.WithCredentialValidator` is wired to the `Freezer` at construction in [`cmd/stun-sentinel/main.go:271`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L271), but inside `pkg/cgroup/freezer.go` `f.validator` is queried **exclusively** within `Unfreeze` ([`:578`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L578)).
- `Freeze` and `FreezePod` have no `credential` parameter.
- **Architectural Consequence:** The missing engine-level credential gate on `Freeze` is a **structural type signature gap**, not an omitted function call. Hardening the freeze path requires updating the `Freeze` / `FreezePod` function signatures and caller contracts across the Go codebase.

---

## 4. Sentinel DaemonSet Security Posture & HostNetwork Seam

### 4.1 DaemonSet Manifest Audit ([`d2-signalloom/deploy/stun-sentinel-daemonset.yaml`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml))

| Manifest Element | Configuration in Manifest | Line Citation | Security / Operational Implication |
|---|---|---|---|
| **Namespace Labels** | `pod-security.kubernetes.io/enforce: privileged`<br>`pod-security.kubernetes.io/audit: privileged`<br>`pod-security.kubernetes.io/warn: privileged` | [`:34-36`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L34-L36) | Namespace explicitly bypasses all Kubernetes Pod Security Standards. |
| **Process Namespace** | `hostPID: true` | [`:103`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L103) | Pod sees every PID on the host to report frozen PIDs in `ListProcs`. |
| **Security Context** | `privileged: true`<br>`runAsUser: 0`<br>`readOnlyRootFilesystem: true`<br>`allowPrivilegeEscalation: true` | [`:136-140`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L136-L140) | Has unrestricted root capabilities on the host kernel and devices. |
| **Volume Mounts** | `hostPath: /sys/fs/cgroup`<br>`readOnly: false` | [`:144-147`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L144-L147), [`:175-178`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L175-L178) | Can write `cgroup.freeze` on any cgroup directory on the node. |
| **Service Definition** | `clusterIP: None`, port `8080` | [`:182-199`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/deploy/stun-sentinel-daemonset.yaml#L182-L199) | Headless service for direct node-local pod addressing. |
| **NetworkPolicy** | **None present in `signalloom-system`** | N/A | **Exposed to cluster network.** |

### 4.2 The HostNetwork / NetworkPolicy Boundary

In [`d2-signalloom/infra/agent-swarm/networkpolicy.yaml:12-13`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/infra/agent-swarm/networkpolicy.yaml#L12-L13), the policy header states:
```yaml
#   - The stun sentinel needs hostNetwork (handled via DaemonSet spec,
#     not NetworkPolicy — it runs on the node network)
```

**Crucial Threat Analysis for P1-4 & P3-1:**
1. Standard Kubernetes `NetworkPolicy` resources (implemented by standard CNI plugins) attach to pod veth interfaces and evaluate traffic entering/exiting pod network namespaces.
2. When a pod runs on `hostNetwork` or listens directly on the host interface, standard `NetworkPolicy` rules **cannot** intercept or filter its incoming traffic.
3. Therefore, adding a standard `NetworkPolicy` manifest alone does NOT close the network exposure of a host-network daemon. Protection requires:
   - **Application-Layer Mutual Auth / Bearer Tokens** (enforced in Go HTTP handlers).
   - **Cilium Host Policies (`CiliumClusterwideNetworkPolicy`)** or eBPF host firewalls if network filtering at L3/L4 is mandated.

---

## 5. Dual Sentinel Implementations: Detailed Behavioral Diff for P4-1

The repository currently contains two independent sentinel implementations:
- **Sentinel A:** `d2-signalloom/apps/stun-sentinel` (Stand-alone HTTP daemon + eBPF TC)
- **Sentinel B:** `d2-signalloom/apps/signalloom-stun-sentinel` (Kubernetes Controller / Informer loop)

### Comprehensive Behavioral Comparison

| Capability / Aspect | Sentinel A (`apps/stun-sentinel`) | Sentinel B (`apps/signalloom-stun-sentinel`) | Reconciliation Required for P4-1 |
|---|---|---|---|
| **Control Model** | HTTP REST daemon listening on `:8080` ([`cmd/main.go:245-257`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go#L245-L257)). Controlled by explicit API calls. | K8s Informer / Controller loop ([`main.go:48-95`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/main.go#L48-L95)) watching Pod label changes (`signalloom.ai/state=stunned`). | P4-1 should unify control plane to support both direct API dispatch (for sub-second orchestrator containment) and informer fallback. |
| **Go Toolchain** | `go 1.24` ([`go.mod:3`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/go.mod#L3)) | `go 1.22.0` ([`go.mod:3`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/go.mod#L3)) | Align to uniform Go 1.24 toolchain. |
| **Cgroup v2 Discovery** | Scans 4 layout hierarchies: `kubelet.slice/kubelet-kubepods.slice`, `kubepods.slice`, `kubepods`, `kubelet/kubepods` across 3 QoS tiers ([`pkg/cgroup/freezer.go:232-260`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L232-L260)). | Hardcodes single directory `/sys/fs/cgroup/kubepods.slice/` with basic string matching ([`freezer.go:65-80`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/freezer.go#L65-L80)). | Adopt Sentinel A's robust `kubepodsRoots()` matrix. |
| **Freeze Verification & Polling** | `awaitState()` with geometric backoff (25µs to 1ms) up to deadline ([`pkg/cgroup/freezer.go:469-495`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L469-L495)). | Fixed 5-iteration loop with unbuffered sleep-less polling ([`freezer.go:28-33`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/freezer.go#L28-L33)). | Adopt Sentinel A's `awaitState()` with deadline tracking. |
| **Emptiness & Vacuous-Success Gate** | Asserts `populated != 0` and `len(PIDs) > 0` post-freeze ([`pkg/cgroup/freezer.go:542-551`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L542-L551)). Returns `ErrCgroupEmpty`. | **None.** Vacuously reports success on empty/vanished cgroups. | Adopt Sentinel A's `ErrCgroupEmpty` gate. |
| **Process Census** | Post-freeze `ListProcs()` reads `cgroup.procs` to capture full child process tree ([`pkg/cgroup/freezer.go:537-540`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L537-L540)). | **None.** Does not read `cgroup.procs` or return process PIDs. | Adopt Sentinel A's process census for forensic snapshotting (P4-2). |
| **Credential Validation** | `CredentialValidator` and `WithCredentialValidator` on Unfreeze ([`pkg/cgroup/freezer.go:118,175`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go#L118-L175)). | **None.** Zero authentication or credential parameter on unfreeze. | Enforce unified governance token validation across both freeze and resume. |
| **Network Isolation Layer** | In-kernel eBPF TC drop filter program (`tc_drop.bpf.c`) + netlink conntrack table flush ([`pkg/tc/`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/stun-sentinel/pkg/tc/)). | External `tc` CLI fork (`os/exec`) + netns switching via `setns` ([`network.go:42-120`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/signalloom-stun-sentinel/network.go#L42-L120)). | Unify on eBPF TC loader to eliminate `fork/exec` overhead and external binary dependencies. |
| **Dry Run Mode** | Supported via temporary mock cgroup hierarchy roots in unit tests. | Explicit `dryRun` boolean flag in `cgroupFreezer` and `tcDropFilter`. | Adopt structured dry-run simulation mode into unified enforcer. |
| **Telemetry & Audit** | `pkg/telemetry/emitter.go` + rich `FreezeResult` struct with latencies, polls, and PIDs. | `audit.go` with `AuditLogger` emitting `stunEvent` JSON logs to stdout. | Merge structured event schema into Phase 5 witness attestation pipeline. |

---

## 6. Manifest & Deployment Posture Contrast

A strict audit of manifests across all three components reveals contrasting maturity levels:

```
d2-signalloom/
├── apps/
│   ├── fleet-manager/base/            # [MATURE] 6 manifests + kustomization
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── fleet-config.yaml
│   │   ├── kustomization.yaml
│   │   ├── networkpolicy.yaml
│   │   ├── rbac.yaml
│   │   └── service.yaml
│   │
│   ├── node-capability-guard/         # [EMPTY / GREENFIELD] 0 manifests
│   │   ├── cmd/main.go
│   │   ├── go.mod
│   │   └── pkg/webhook/handler.go
│   │
│   └── stun-sentinel/                 # [PARTIAL] 1 deploy DaemonSet, 0 NetworkPolicy
│       └── (deploy manifest in d2-signalloom/deploy/stun-sentinel-daemonset.yaml)
```

### Manifest Contrast Summary

| Component | Manifests on Disk | Deployment Type | NetworkPolicy | RBAC / ServiceAccount | Notes / Task Required |
|---|---|---|---|---|---|
| **`node-capability-guard`** | **0** (No `base/`, no Dockerfile, no Deployment, no Service, no Webhook config) | None | None | None | **100% Greenfield for P3-2.** Must create Dockerfile, Deployment, Service, TLS certs, and `ValidatingWebhookConfiguration`. |
| **`fleet-manager`** | **6** (`configmap.yaml`, `deployment.yaml`, `fleet-config.yaml`, `networkpolicy.yaml`, `rbac.yaml`, `service.yaml`) | Deployment (`fe-signalloom` namespace) | Ingress on port 8082 from dashboard / proxy | ClusterRole + ServiceAccount | Well-defined base; needs API authentication and real Enforcer wiring (P1-1). |
| **`stun-sentinel`** | **1** (`d2-signalloom/deploy/stun-sentinel-daemonset.yaml`) | DaemonSet (`signalloom-system` namespace) | **None** | ClusterRole (read pods) + SA | Privileged DaemonSet; requires bearer authentication token and node-level policy considerations (P1-4). |

---

## 7. FleetClient Interface & Orchestrator Error Masking

### 7.1 Interface Definition ([`d2-signalloom/apps/fleet-manager/cascade.go:36-48`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/cascade.go#L36-L48))

```go
type FleetClient interface {
    // GetPodState reads the current state label from the agent's pod.
    GetPodState(ctx context.Context, namespace, agentID string) (string, error)

    // SetPodState updates the state label on the agent's pod.
    SetPodState(ctx context.Context, namespace, agentID, state string) error

    // RevokeCredentials revokes the agent's OpenBao credentials.
    RevokeCredentials(ctx context.Context, agentID string) error

    // RestoreCredentials re-credentials the agent via SPIRE -> OpenBao -> KV.
    RestoreCredentials(ctx context.Context, agentID string) error
}
```

### 7.2 The `noopFleetClient` Trap ([`main.go:214-222`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L214-L222), [`:250`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/main.go#L250))

In `main.go`, `client` is instantiated unconditionally as:
```go
client := FleetClient(&noopFleetClient{})
```
Where every method returns `nil` (or `StateRunning`). There is zero Kubernetes in-cluster client configuration, zero OpenBao HTTP client, and zero SPIRE integration.

### 7.3 False-Success Masking in Orchestrator ([`cascade.go:88-109`](file:///home/andy/src/.worktrees/5cadd/osramp-demo/d2-signalloom/apps/fleet-manager/cascade.go#L88-L109))

During a cascade stun:
1. **Line 88-92:** `GetPodState` error is caught, logged as a warning, and masked:
   ```go
   currentState, err := o.client.GetPodState(ctx, agent.Namespace, id)
   if err != nil {
       slog.Warn("failed to read pod state", "agent", id, "error", err)
       currentState = StateRunning // assume running if we can't read
   }
   ```
2. **Line 95-97:** `RevokeCredentials` error is caught, logged as a warning, and ignored:
   ```go
   if err := o.client.RevokeCredentials(ctx, id); err != nil {
       slog.Warn("failed to revoke credentials", "agent", id, "error", err)
   }
   ```
3. **Line 100-102:** `SetPodState` error is caught, logged as a warning, and ignored:
   ```go
   if err := o.client.SetPodState(ctx, agent.Namespace, id, StateStunned); err != nil {
       slog.Warn("failed to set pod state", "agent", id, "error", err)
   }
   ```
4. **Line 104-109:** A success event `ToState: StateStunned` is unconditionally appended to the result, and the HTTP handler returns `200 OK` with `CascadeResult`!

**Mandate for P1-1 & P1-5:**
- P1-1 must replace `noopFleetClient` with a real `Enforcer` / cluster client implementing the 4 `FleetClient` operations.
- P1-5 must eliminate the error masking in `cascade.go`, propagating per-plane error states and failing closed when containment actions fail.

---

## 8. Mesh & Service Mesh Isolation Seams

A search across `d2-signalloom/` for service mesh policies:
```bash
grep -rn 'kind: CiliumNetworkPolicy\|kind: AuthorizationPolicy' d2-signalloom/
```
Result: **Zero occurrences.**

### Implications for P3-1 (Dynamic Mesh Isolation)
1. There are no existing `CiliumNetworkPolicy` or Istio `AuthorizationPolicy` manifests in `d2-signalloom/` to extend or patch.
2. P3-1 is a **greenfield implementation** that must introduce the dynamic mesh isolation controller/templates to cut in-flight TCP connections within the guaranteed <2s deadline.

---

## 9. Downstream Phase Handoff & Implementation Requirements

| Task ID | Component | Prerequisite Seam Documented | Direct Action Required from this Preflight |
|---|---|---|---|
| **P1-1** | `fleet-manager` | Seam 6 (`noopFleetClient` fallback) | Implement real `FleetClient` connecting to K8s API + OpenBao + Sentinel. Eliminate noop silent fallback. |
| **P1-2** | `fleet-manager` | Seams 1 & 6 (Dispatch models) | Define typed multi-plane containment dispatch schemas (`ContainmentResult`, per-plane errors). |
| **P1-3** | Core contracts | Seam 3 & 4 (Wire contracts) | Freeze versioned wire schemas and governance resume token format. |
| **P1-4** | `stun-sentinel` | Seams 2 & 3 (`Freeze` signature & NetworkPolicy) | Update `Freezer.Freeze(cgroupPath, credential)` signature; harden bearer token validation and daemon deployment. |
| **P1-5** | `fleet-manager` | Seam 6 (False-success cascade) | Refactor `CascadeOrchestrator` to record partial/failed plane executions instead of fabricating 200 OK. |
| **P2-PRE/1/2**| OpenBao / SPIRE | Seam 6 (`RevokeCredentials`) | Implement active lease revocation and SPIRE entry eviction. |
| **P3-PRE/1/2**| Mesh / Admission | Seams 5 & 7 (Greenfield webhook & mesh) | Author `node-capability-guard` manifests and dynamic `CiliumNetworkPolicy` / `AuthorizationPolicy`. |
| **P4-PRE/1/2/3**| Sentinel | Seams 2 & 4 (Dual sentinel unification) | Unify `stun-sentinel` and `signalloom-stun-sentinel` into single cgroup-v2 freeze engine with process census. |
| **P5-PRE/1/2**| Witness Ledger | Seam 6 (Attested evidence) | Bind all per-plane results into cryptographically attested forensic records. |

---

## 10. Audit Verification Commands

The assertions in this document were verified with the following commands on worktree `integration/sler-v0.1.0`:

```bash
# 1. Route handlers in fleet-manager and stun-sentinel
grep -n 'HandleFunc' d2-signalloom/apps/fleet-manager/main.go d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go

# 2. Credential validator wiring
grep -n 'WithCredentialValidator' d2-signalloom/apps/stun-sentinel/cmd/stun-sentinel/main.go

# 3. Method signatures in freezer.go
grep -n 'func (f \*Freezer) \(Freeze\|Unfreeze\)' d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go

# 4. Manifest inventory for node-capability-guard
find d2-signalloom/apps/node-capability-guard -type f

# 5. Service mesh policy search across d2-signalloom
grep -rn 'kind: CiliumNetworkPolicy\|kind: AuthorizationPolicy' d2-signalloom/
```
