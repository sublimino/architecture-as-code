# SLER-P4-PRE: Cgroup v2 Freezer Prerequisite & Sentinel Capability Diff

<!-- kanban-contract: preflight-proof digest=sha256:sler-p4-pre-cgroup-freezer-diff -->

## 1. Executive Summary

This preflight analysis prepares Phase 4 (Runtime Containment & Memory Forensics) for **SLER-P4-1** (Unify stun-sentinel implementations into cgroup-v2 freeze engine), **SLER-P4-2** (Forensic memory snapshotting), and **SLER-P4-3** (Governance-gated resume with mandatory credential rotation).

The repository currently contains two disparate sentinel implementations:
1. **`d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go`** (745 lines): The mature, standalone HTTP daemon implementation with exported interfaces, constant-time credential validation, geometric backoff polling, process census (`ListProcs`), emptiness gates against vacuous success, ancestor freeze detection, candidate path matrix discovery, and live write-probing health checks.
2. **`d2-signalloom/apps/signalloom-stun-sentinel/freezer.go`** (111 lines): A minimal, unexported Kubernetes informer-loop helper with zero credential validation, fixed 5-poll loop with zero sleep that silences errors, naive string matching, and no process census.

This document records:
- A function-by-function and symbol-by-symbol capability diff.
- Live deployment status in `kind-osramp` vs manifest inventory.
- Host cgroup-v2 capability verification on the target node pool.
- Load-bearing host permission requirements (`hostPID`, `privileged`, `hostPath` rw) and their rationales.
- Resume token mechanism reconciliation from static `STUN_RESUME_TOKEN` to P1-3's Ed25519 governance token.

---

## 2. Function-by-Function Capability Diff

### 2.1 Symbol & Function Inventory

| Symbol / Function | `stun-sentinel/pkg/cgroup/freezer.go` | `signalloom-stun-sentinel/freezer.go` | Capability Analysis & Reconciliation |
| :--- | :--- | :--- | :--- |
| **Package Declaration** | `package cgroup` | `package main` | `stun-sentinel` provides a reusable library package; `signalloom-stun-sentinel` embeds logic directly in `main`. P4-1 unifies on `package cgroup`. |
| **`Freezer` / `cgroupFreezer`** | `type Freezer struct` (exported)<br>- `root string`<br>- `deadline time.Duration`<br>- `freezeValidator CredentialValidator`<br>- `resumeValidator CredentialValidator` | `type cgroupFreezer struct` (unexported)<br>- `cgroupRoot string`<br>- `dryRun bool` | `Freezer` encapsulates governance credentials and deadline budgets; `cgroupFreezer` only tracks root and dry-run flag. |
| **`FreezeResult`** | `type FreezeResult struct` (exported)<br>Carries `PodUID`, `CgroupPath`, `Frozen`, `Populated`, `LatencyMS`, `Polls`, `PIDs`, `Deadline`. | *None* (functions return bare `error`). | `FreezeResult` is load-bearing for attestation (P5-1) and denial latency metrics (P5-2). |
| **`CredentialValidator`** | `type CredentialValidator func(string) bool` | *None* | `stun-sentinel` enforces governance authorization before touching cgroups. |
| **`DenyAllCredentials`** | `func DenyAllCredentials(string) bool { return false }` | *None* | Safe fail-closed default ensuring unconfigured daemons reject all freeze/resume requests. |
| **`WithDeadline`, `WithFreezeValidator`, `WithResumeValidator`** | Functional options (`Option`) for constructor. | *None* | Allows dependency injection and testing. |
| **`New`** | `func New(root string, opts ...Option) *Freezer` | Ad-hoc struct initialization in `main.go`. | Centralized constructor applying defaults (`/sys/fs/cgroup`, 50ms deadline, fail-closed auth). |
| **`normaliseUID`** | `func normaliseUID(podUID string) (dashed, underscored string, err error)` | Inline `strings.ReplaceAll(podUID, "-", "_")` | `normaliseUID` checks for path traversal (`..`, `/`, `\`) and empty strings (`ErrInvalidPodUID`). |
| **`kubepodsRoots`** | `func kubepodsRoots() []struct { rel string, base string }` | *None* (hardcodes `kubepods.slice`) | Matrix of 4 parent slice hierarchies (`kubelet.slice/kubelet-kubepods.slice`, `kubepods.slice`, `kubepods`, `kubelet/kubepods`). Essential for Kind clusters. |
| **`candidatePaths`** | `func (f *Freezer) candidatePaths(dashed, underscored string) []string` | *None* | Generates ordered candidate path matrix for QoS tiers (`guaranteed`, `burstable`, `besteffort`) across all 4 driver roots without filesystem walking. |
| **`isFreezableCgroup`** | `func isFreezableCgroup(dir string) bool` | Inline `os.Stat(cgroup.freeze)` | Validates presence of `cgroup.freeze` as a regular file. |
| **`ResolvePodCgroup` / `resolvePodCgroup`** | `func (f *Freezer) ResolvePodCgroup(podUID string) (string, error)` (exported, fast-path candidate matrix + bounded walk) | `func (f *cgroupFreezer) resolvePodCgroup(podUID string) (string, error)` (unexported, full `WalkDir`) | `stun-sentinel` resolves in sub-millisecond stat calls; `signalloom-stun-sentinel` walks the entire hierarchy. |
| **`walkForPod`** | `func (f *Freezer) walkForPod(dashed, underscored string) (string, error)` | Inline callback in `filepath.WalkDir` | Depth-bounded (max 6 levels) fallback search for non-standard layouts. |
| **`podCgroupNameMatches`** | Handled by candidate matrix and `walkForPod` string checks. | `func podCgroupNameMatches(name, podUID string) bool` | Helper matching 8 possible string suffixes/prefixes against directory names. |
| **`parseEventsKey`, `parseFrozenState`, `parsePopulatedState`** | Field-exact key/value parser (`parseEventsKey`) | Naive `strings.Contains(data, "frozen 1")` | Field-exact parsing prevents false positive substring matches (e.g., `unfrozen 1`). |
| **`readCgroupState`** | `func readCgroupState(cgroupPath string) (cgroupState, error)` | Inline `os.ReadFile` | Parses `frozen` and `populated` fields together. |
| **`ownFreezeSetting`** | `func ownFreezeSetting(cgroupPath string) (string, error)` | *None* | Reads `cgroup.freeze` directly to distinguish local freeze from ancestor freeze (`ErrAncestorFrozen`). |
| **`classifyWriteErr`** | `func classifyWriteErr(err error, cgroupPath string) error` | *None* (returns bare err) | Maps write errors to typed errors (`ErrCgroupNotFound`, `ErrPermission`). |
| **`writeControl`** | `func writeControl(cgroupPath, value string) error` | `os.WriteFile(freezeFile, []byte("1"), 0644)` | `writeControl` uses `os.OpenFile(..., os.O_WRONLY, 0)` without `O_CREATE` to ensure `ENOENT` on missing files rather than creating stray files. |
| **`awaitState`** | `func awaitState(cgroupPath string, want bool, deadline time.Duration, start time.Time) (...)` | Fixed 5-iteration loop with zero sleep | Geometric backoff (25µs to 1ms) up to deadline; detects pod deletion mid-poll (`eventsFile disappeared`). |
| **`Freeze` / `freeze`** | `func (f *Freezer) Freeze(cgroupPath, credential string) (*FreezeResult, error)` (exported) | `func (f *cgroupFreezer) freeze(cgroupPath string) error` (unexported) | `stun-sentinel` enforces governance credentials, verifies state settlement via `awaitState`, takes post-freeze process census, and enforces **emptiness gate**. `signalloom-stun-sentinel` has no auth, no deadline, no census, and **swallows un-settled freeze errors** (returns `nil`). |
| **`FreezePod`** | `func (f *Freezer) FreezePod(podUID, credential string) (*FreezeResult, error)` (exported) | *None* (caller resolves cgroup first) | Convenience orchestrator combining resolution and freeze. |
| **`Unfreeze` / `unfreeze`** | `func (f *Freezer) Unfreeze(cgroupPath, credential string) (*FreezeResult, error)` (exported) | `func (f *cgroupFreezer) unfreeze(cgroupPath string) error` (unexported) | `stun-sentinel` validates resume credential, checks for `ErrAncestorFrozen`, and records resumed PIDs. `signalloom-stun-sentinel` has zero auth and swallows errors. |
| **`UnfreezePod`** | `func (f *Freezer) UnfreezePod(podUID, credential string) (*FreezeResult, error)` (exported) | *None* (caller resolves cgroup first) | Convenience orchestrator combining resolution and unfreeze. |
| **`ListProcs`** | `func ListProcs(cgroupPath string) ([]int, error)` (exported) | *None* in freezer.go (partial single-PID helper in `network.go`) | Recursively scans all child `cgroup.procs` across container subtrees, deduplicates, and sorts PIDs. |
| **`HealthCheck`** | `func (f *Freezer) HealthCheck() error` (exported) | *None* in freezer.go (`health.go` does shallow driver check) | Performs live `mkdir`/`rmdir` on `/sys/fs/cgroup/stun-sentinel-healthprobe` to prove write access. |
| **`msOf`** | `func msOf(d time.Duration) float64` | *None* | Float64 millisecond conversion helper for JSON telemetry. |

---

### 2.2 Critical Capability Gaps in `signalloom-stun-sentinel`

1. **False-Positive Freeze Trap (Silent Pass)**:
   In `signalloom-stun-sentinel/freezer.go:32-38`, if `frozen 1` is not observed after 5 instantaneous reads, the function exits the loop and returns `nil`. An un-frozen container is reported as successfully contained.
2. **Vacuous Containment (Empty Cgroup)**:
   In cgroup v2, an empty directory reports `frozen 1` immediately. `stun-sentinel` detects this via `!state.populated && len(res.PIDs) == 0` and returns `ErrCgroupEmpty`. `signalloom-stun-sentinel` treats an empty or vanished cgroup as instant success.
3. **No Credential / Governance Gate**:
   `signalloom-stun-sentinel` has zero token validation on freeze or thaw. Any caller that sets a label or triggers a reconcile can stun or unstun pods arbitrarily.
4. **No Process Census (`ListProcs`)**:
   `signalloom-stun-sentinel` has no multi-container process tree census. This blocks Phase 4's forensic memory snapshotting (`gcore` attachment on all target PIDs).
5. **No Ancestor Freeze Diagnostic**:
   If an ancestor cgroup (e.g. `kubepods.slice`) is frozen, writing `0` to the pod's `cgroup.freeze` cannot thaw it. `stun-sentinel` diagnoses this via `ownFreezeSetting` and returns `ErrAncestorFrozen`.

---

## 3. DaemonSet Manifest & Deployment Audit

### 3.1 Comparison of Manifest Definitions

```
+--------------------------------------------------------------------------------------------------+
| Manifest A: d2-signalloom/deploy/stun-sentinel-daemonset.yaml                                    |
+--------------------------------------------------------------------------------------------------+
| Namespace: signalloom-system (pod-security.kubernetes.io/enforce: privileged)                     |
| Image:     ghcr.io/controlplaneio-in-toto/stun-sentinel:v0.1.0                                    |
| Model:     HTTP REST Daemon (:8080) with endpoints /stun, /resume, /healthz, /readyz             |
| Network:   Pod Network (ClusterIP: None headless service) + NetworkPolicy                        |
| Privs:     privileged: true, hostPID: true, hostPath /sys/fs/cgroup (rw)                         |
| Auth:      STUN_FREEZE_TOKEN and STUN_RESUME_TOKEN mounted from Secret stun-sentinel-governance  |
+--------------------------------------------------------------------------------------------------+

+--------------------------------------------------------------------------------------------------+
| Manifest B: d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml              |
+--------------------------------------------------------------------------------------------------+
| Namespace: fe-signalloom-agents                                                                  |
| Image:     stun-sentinel:latest (built from apps/signalloom-stun-sentinel)                        |
| Model:     Kubernetes Informer / Controller watching Pod label signalloom.ai/state=stunned       |
| Network:   hostNetwork: true, port :8081 (/healthz)                                              |
| Privs:     privileged: false, capabilities: [SYS_ADMIN, NET_ADMIN], hostPID: true, /host-cgroup  |
| Auth:      None (reconciles on K8s API event)                                                    |
+--------------------------------------------------------------------------------------------------+
```

### 3.2 Live Cluster Verification (`kind-osramp`)

Live cluster inspection on 2026-09-15 confirmed:
- **Active DaemonSet**: `stun-sentinel` in namespace `fe-signalloom-agents` (Generation 4, 1/1 Ready).
  - Managed by Flux Kustomization `agent-signalloom-stun-sentinel` (`d2-osramp-fleet/tenants/base/agent-swarm.yaml:560`).
  - Running image: `stun-sentinel:latest`.
- **Manifest A (`signalloom-system`)**: **NOT deployed in cluster**. Namespace `signalloom-system` does not exist. `d2-signalloom/deploy/stun-sentinel-daemonset.yaml` is used as a standalone deploy bundle and driven directly in unit/bats test harnesses (`scripts/test-cgroup-freezer.sh`).
- **Dual-Deployment Race**: There is **no active dual-write race** in the current live cluster because only Manifest B is managed by Flux. However, P4-1 must ensure that when the unified daemon is deployed, it satisfies both direct API dispatch (for sub-second orchestrator containment) and the agent-swarm fleet contract.

---

## 4. Host Cgroup-v2 Capability Verification

### 4.1 Node Environment & Kernel Probes

Probed on target Kind cluster node `osramp-control-plane`:
- **OS / Runtime**: Debian GNU/Linux 13 (trixie), Linux kernel `7.1.3+deb13-amd64`, containerd `2.3.1`.
- **Cgroup Filesystem**: `stat -f /sys/fs/cgroup` reports `cgroup2fs` (Magic ID `57c51bcfc13bf2f5`).
- **Hierarchy Structure**:
  ```
  /sys/fs/cgroup/
  └── kubelet.slice/
      └── kubelet-kubepods.slice/
          ├── kubelet-kubepods-burstable.slice/
          └── kubelet-kubepods-besteffort.slice/
  ```
  This layout confirms that the kubelet runs inside a dedicated slice on Kind, matching the top candidate in `stun-sentinel`'s `kubepodsRoots()` matrix: `{rel: "kubelet.slice/kubelet-kubepods.slice", base: "kubelet-kubepods"}`.

### 4.2 Live Write & Freezer Verification

Executed active write probe on `osramp-control-plane`:
```bash
docker exec osramp-control-plane sh -c \
  "mkdir /sys/fs/cgroup/stun-sentinel-healthprobe && \
   test -f /sys/fs/cgroup/stun-sentinel-healthprobe/cgroup.freeze && \
   rmdir /sys/fs/cgroup/stun-sentinel-healthprobe"
```
- **Probe Result**: **PASS**. The kernel automatically instantiated `cgroup.freeze`, `cgroup.events`, and `cgroup.procs` inside the probe directory upon `mkdir`. Directory removed cleanly via `rmdir`.
- **Controller Note**: As documented in `cgroup/freezer.go:9-15`, cgroup v2 freezer is a **core interface** present on all non-root cgroups. It does not appear as a separate entry in `cgroup.controllers` or `cgroup.subtree_control`.

---

## 5. Host Permission Requirements & Rationales (P4-1 Invariants)

Per manifest headers in `d2-signalloom/deploy/stun-sentinel-daemonset.yaml:9-20`, the following three permissions are strictly load-bearing and must NOT be restricted or removed during P4-1 unification:

### 5.1 `hostPID: true`
- **Why it is necessary**: The sentinel performs process census (`ListProcs`) to report which host PIDs were frozen. Inside a container PID namespace, target container processes are invisible or mapped to un-routable localized PIDs (e.g. PID 1).
- **Forensics Impact (P4-2)**: `gcore`, `ptrace`, and `/proc/<pid>/mem` snapshotting require host-level PIDs to attach to frozen container processes.
- **Header Statement**: *"Without the host PID namespace those PIDs would be meaningless to any operator or forensic tool outside this pod."*

### 5.2 `privileged: true` (or `CAP_SYS_ADMIN` in initial user namespace)
- **Why it is necessary**: Writing to another container's cgroup control files (`cgroup.freeze`) across distinct slice boundaries is denied by Linux DAC/MAC to unprivileged processes, regardless of hostPath file permissions.
- **Namespace Requirement**: Namespace `signalloom-system` or `fe-signalloom-agents` must carry Pod Security Admission labels `pod-security.kubernetes.io/enforce: privileged`.

### 5.3 `hostPath: /sys/fs/cgroup` (Read-Write Mount)
- **Why it is necessary**: Freezing is a direct write (`"1"`) to the kernel control file. A read-only mount passes all existence, stat, and read checks, and fails only when emergency containment is triggered.
- **Health Verification**: `/healthz` must continue to execute `Freezer.HealthCheck()` (transient `mkdir`/`rmdir`) to prove hostPath writability at startup and during liveness checks.

---

## 6. Resume Credential & Token Mechanism Reconciliation

### 6.1 Current Static Secret (`STUN_RESUME_TOKEN`)
In `apps/stun-sentinel/cmd/stun-sentinel/main.go:56` and `main.go:264`:
- Loaded from environment variable `STUN_RESUME_TOKEN` (mounted from Secret `stun-sentinel-governance`).
- Validated via `constantTimeTokenValidator`.
- Represents a static shared secret per node daemon.

### 6.2 Target Governance Attributable Token (P4-3 Integration)
In Phase 4, **SLER-P4-3** replaces the static shared secret with the versioned, attributable governance resume token frozen in P1-3 (`d2-signalloom/apps/fleet-manager/resume_token.go`):

```go
type GovernanceResumeToken struct {
    TokenID           string    `json:"token_id"`
    ContainedIdentity string    `json:"contained_identity"`
    Reason            string    `json:"reason"`
    AuthorizedBy      string    `json:"authorized_by"`
    IssuedAt          time.Time `json:"issued_at"`
    ExpiresAt         time.Time `json:"expires_at"`
    Signature         []byte    `json:"signature"`
}
```

- **Verification Protocol**: Sentinel verifies the cryptographic signature (Ed25519) against the governance public key and checks that `ContainedIdentity` matches the target pod.
- **Mandatory Credential Rotation**: Unstunning an agent triggers an automated, synchronous lease and SVID re-issuance before execution resumes.

---

## 7. Plan for SLER-P4-1 Unification

When SLER-P4-1 unifies the sentinels:
1. **Adopt `d2-signalloom/apps/stun-sentinel/pkg/cgroup`** as the sole canonical freezer engine.
2. **Integrate both Dispatch Models**:
   - Primary: HTTP REST API on `:8080` (`/stun`, `/resume`, `/healthz`, `/metrics`) for immediate sub-second orchestration by Fleet Manager.
   - Secondary / Informer: Optional background controller watching Pod label `signalloom.ai/state=stunned` for asynchronous GitOps-driven fallback containment.
3. **Consolidate Network Isolation**:
   - Retire fork/exec `tc` CLI calls from `signalloom-stun-sentinel/network.go`.
   - Use `d2-signalloom/apps/stun-sentinel/pkg/tc` (eBPF `tc_drop.bpf.o` + netlink conntrack flush).
4. **Preserve Load-Bearing Permissions**: Keep `hostPID: true`, `privileged: true`, and read-write `/sys/fs/cgroup`.

---

## 8. Verification Checks Summary

- [x] `docs/signalloom/sler-p4-pre-freezer-diff.md` created with full function-by-function diff.
- [x] Host cgroup-v2 capability verified on `osramp-control-plane` (`cgroup2fs` with writable `cgroup.freeze`).
- [x] Live DaemonSet status confirmed in `kind-osramp` (`agent-signalloom-stun-sentinel` in `fe-signalloom-agents`).
- [x] Load-bearing permissions (`hostPID`, `privileged`, `hostPath` rw) inventoried with rationales.
- [x] Unit test suites for both `apps/stun-sentinel` and `apps/signalloom-stun-sentinel` passing cleanly.
- [x] Build artifact `tc_drop.bpf.o` generated and placed into `apps/stun-sentinel/pkg/tc/`, enabling clean `go test ./...` in `apps/fleet-manager`.
