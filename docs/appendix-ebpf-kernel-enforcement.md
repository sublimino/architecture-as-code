# Appendix: eBPF and Kernel-Level Enforcement for AI Agent Containment

> **Author:** Andy Martin, ControlPlane  
> **Date:** 2026-08-27  
> **Status:** Research appendix for OSRAMP / Signal Loom  
> **Audience:** CTO-level; assumes familiarity with eBPF, cgroups v2, Linux security modules, and Kubernetes internals

---

## 1. Signal Loom's Current Approach: The Stun Sentinel

### 1.1 Architecture

The `signalloom-stun-sentinel` is a DaemonSet deployed to every node in the `fe-signalloom-agents` namespace. It watches for pod label changes via the Kubernetes informer API and executes a two-phase containment sequence when it detects a pod labelled `signalloom.ai/state=stunned`.

**Source:** `d2-signalloom/apps/signalloom-stun-sentinel/` (`main.go`, `freezer.go`, `network.go`)

### 1.2 Containment Sequence

**Phase 1 -- Cgroup Freeze (freezer.go)**

1. Resolves the pod's cgroup path by scanning `{cgroupRoot}/kubepods/{qos-class}/pod-{uid}` across guaranteed, burstable, and besteffort tiers.
2. Handles the UID normalisation trap: Kubernetes uses hyphens in pod UIDs but underscores in cgroup directory names -- both sides are normalised before matching.
3. Writes `1` to `{cgroupPath}/cgroup.freeze`, which is a cgroups v2 kernel interface (available since Linux 5.2) that atomically freezes ALL processes in the cgroup hierarchy. Every thread enters `TASK_FROZEN` state -- no further userspace instructions execute, but memory is preserved.
4. This is not a signal-based mechanism. Unlike `SIGSTOP`, cgroup freeze cannot be intercepted, caught, or ignored by the target process. The freeze is enforced by the kernel scheduler itself.

**Phase 2 -- TC Network Drop (network.go)**

1. Discovers the host-side veth interface by listing network interfaces and matching CNI naming conventions (`veth*`, `cali*`, `lxc*`).
2. Attaches a `clsact` qdisc to the interface (idempotent -- `EEXIST` is tolerated).
3. Adds two TC `matchall` + `action drop` filters: one on ingress, one on egress. This drops ALL packets in both directions at the TC layer, before they reach the kernel network stack.
4. The TC filter operates at the host's network namespace on the veth peer -- the pod cannot see, modify, or remove it.

**Unstun** reverses both: unfreeze the cgroup (write `0`), then delete the `clsact` qdisc (which cascades to all attached filters).

### 1.3 Trigger Mechanism

The sentinel uses a `SharedInformerFactory` scoped to the watch namespace with a label selector `signalloom.ai/agent=true`. On `UpdateFunc`, it compares old and new label values for `signalloom.ai/state`. The informer's resync interval is 30 seconds, but label changes propagate via watch events -- typically within 100-500ms of the API server accepting the patch.

Total containment latency = API watch propagation + cgroup resolve + freeze write + veth discovery + TC attach. The implementation measures and logs `latency_ms` per stun event. Expected total: sub-second on a healthy cluster.

### 1.4 Privilege Requirements

The DaemonSet spec reveals the full privilege surface:

| Requirement | Why |
|---|---|
| `hostPID: true` | Required to access `/proc/{pid}/` for potential netns peer lookup (production path) |
| `hostNetwork: true` | Required to see and manipulate host-side veth interfaces |
| `SYS_ADMIN` capability | Required to write to `/sys/fs/cgroup/.../cgroup.freeze` |
| `NET_ADMIN` capability | Required for `tc qdisc add/del` and `tc filter add` |
| `/sys/fs/cgroup` volume mount (RW) | Direct host cgroup filesystem access |

All other capabilities are dropped. The container runs as non-privileged (`privileged: false`).

### 1.5 Strengths

- **Forensic preservation.** Cgroup freeze keeps all process memory intact -- stack frames, heap, file descriptors, network buffers. A frozen agent can be inspected post-mortem without losing the state that led to the containment trigger.
- **Atomic process control.** Every thread in the pod freezes simultaneously. There is no race window where a multi-threaded agent could detect the freeze starting and exfiltrate data before it completes.
- **Network isolation is host-side.** The TC drop filter operates on the veth peer in the host netns. The pod's own network namespace is irrelevant -- even a root-capable process inside the pod cannot remove the filter.
- **No eBPF program compilation.** The TC `matchall` + `action drop` is a kernel-native cls_matchall classifier with a built-in gact action. No BPF bytecode is loaded, no verifier pass is needed, no BTF dependency.
- **Reversible.** Unstun restores full operation. The agent's in-flight state (open sockets, pending I/O, process trees) resumes where it stopped.

### 1.6 Weaknesses

- **Broad host privileges.** `hostPID` + `hostNetwork` + `SYS_ADMIN` is a significant attack surface if the sentinel itself is compromised. A compromised sentinel DaemonSet could freeze or network-isolate any pod on the node.
- **Coarse veth matching.** The current implementation returns the first veth/cali/lxc interface it finds, not the specific one belonging to the target pod. In production, this requires `nsenter` into the pod's netns to read the peer ifindex from `/sys/class/net/eth0/iflink`, then match it to the host-side interface. The demo shortcut is acknowledged in code comments.
- **Label-watch latency.** The trigger path goes through the Kubernetes API server: client patches the label, API server persists to etcd, watch event propagates to the informer. Under API server load or network partition, this can exceed 1 second. The enforcement is not synchronous with the action that caused the stun decision.
- **No per-syscall granularity.** Freeze is all-or-nothing. You cannot selectively block file writes while allowing reads, or block network egress while allowing DNS. It is a containment mechanism, not a policy enforcement mechanism.
- **No integration with existing eBPF infrastructure.** If the cluster runs Cilium, it already has TC programs attached to every pod veth. The sentinel's `tc qdisc add clsact` will conflict with Cilium's existing clsact qdisc. The `EEXIST` handling covers the qdisc, but adding matchall drop filters to Cilium's ingress/egress chains may produce undefined behaviour.
- **Single-binary, single-purpose.** The sentinel does exactly one thing (freeze+drop on label change). There is no policy language, no graduated response, no integration with admission control or audit systems.

---

## 2. Nirmata Runtime for Kyverno

### 2.1 Overview

Released 16 August 2026, Nirmata Runtime for Kyverno extends the Kyverno policy-as-code ecosystem from admission-time configuration enforcement to runtime kernel-level enforcement. The core thesis: admission control answers "does this spec look right?" but cannot answer "is this workload doing what its spec says it should?" once the pod is running.

**Repository:** [github.com/nirmata/runtime](https://github.com/nirmata/runtime)

### 2.2 eBPF Program Architecture

Nirmata Runtime attaches two categories of eBPF programs:

**BPF-LSM programs** (requires kernel 5.7+ with `CONFIG_BPF_LSM=y`):

| LSM Hook | Behaviour | Effect |
|---|---|---|
| `bprm_check_security` | `exec` | Deny process execution by resolved kernel path. Returns `-EPERM` before the binary loads. |
| `file_open` | `open` | Deny file access by resolved kernel path. Returns `-EPERM` before the file descriptor is created. |

**Cgroup-scoped eBPF programs:**

| Attach Point | Behaviour | Effect |
|---|---|---|
| Cgroup egress (likely `BPF_PROG_TYPE_CGROUP_SKB` or `BPF_PROG_TYPE_CGROUP_SOCK_ADDR`) | `network` | Deny egress by destination. Connection never completes. |
| Cgroup egress (deep packet inspection) | `protocol` | Deny by application-layer protocol on the wire, independent of port. A reverse shell on port 443 pretending to be HTTPS is caught. |
| DNS hook (likely cgroup connect or socket filter) | `dns` | Observe and report DNS resolution. Deliberately does not block -- DNS denial has failure modes worse than the traffic it would stop. |

The critical architectural property: all five behaviours are decided **synchronously with the syscall they gate**. A blocked exec returns `-EPERM` before the process runs. A blocked connection never completes. There is no decision-enforcement gap for a compromised workload to race.

### 2.3 Policy Language

Nirmata Runtime uses the same policy language as Kyverno: **CEL (Common Expression Language)**. Policies are expressed as `RuntimePolicy` custom resources:

```yaml
apiVersion: runtime.nirmata.io/v1alpha1
kind: RuntimePolicy
metadata:
  name: agent-gateway-only
spec:
  mode: enforce          # or "monitor" (default)
  podSelector:
    matchLabels:
      nirmata.io/agent: "true"
  behaviors:
  - network:
      allow:
        values:
        - llm-gateway.ai-platform.svc.cluster.local
        - kube-dns.kube-system.svc.cluster.local
      deny:
        values:
        - "*"
  - protocol:
      allow:
        values:
        - tls
        - dns
      deny:
        values:
        - "*"
  - exec:
      allow:
        values:
        - /usr/bin/python3
        - /app/agent
      deny:
        values:
        - "*"
  - open:
      deny:
        values:
        - /var/run/secrets/**
        - /root/.aws/**
```

Key design decisions:

- **Monitor-first by default.** Every policy ships in monitor mode. A `WouldDeny` counterfactual signal shows what would be blocked before flipping to enforce.
- **CEL expressions** can pull live values from ConfigMaps or HTTP sources on a refresh interval, enabling dynamic policy updates without redeployment.
- **`monitorFilter`** is a per-observation CEL predicate that runs before a finding is written to OpenReports, filtering noise (e.g., `sh`, `grep`) from exec monitoring.
- **OpenReports** integration: findings land as standard Kubernetes objects, not proprietary dashboards.

### 2.4 Comparison with Signal Loom

| Dimension | Signal Loom Stun Sentinel | Nirmata Runtime for Kyverno |
|---|---|---|
| **Purpose** | Emergency containment (freeze in place) | Continuous runtime policy enforcement |
| **Trigger** | Kubernetes label change (reactive) | Synchronous with the syscall (proactive) |
| **Enforcement mechanism** | cgroup.freeze + TC matchall drop | BPF-LSM hooks + cgroup eBPF programs |
| **Granularity** | Binary: frozen or running | Per-syscall: exec, open, network, protocol, DNS |
| **Latency** | 100ms-1s (API watch + userspace) | Synchronous with syscall (~microseconds) |
| **Memory preservation** | Yes -- frozen processes retain full state | No -- blocked operations are denied, process continues |
| **Policy language** | None (label-triggered) | CEL (same as Kyverno admission policies) |
| **Kernel requirements** | Linux 5.2+ (cgroup.freeze) | Linux 5.7+ (BPF-LSM), `CONFIG_BPF_LSM=y` |
| **Privileges** | hostPID, hostNetwork, SYS_ADMIN, NET_ADMIN | Likely CAP_BPF + CAP_SYS_ADMIN for eBPF loading |
| **AI agent scenario** | Agent has gone rogue, preserve evidence | Agent is constrained to declared behaviour envelope |

### 2.5 What Signal Loom Can Learn

1. **Policy-as-code integration.** The stun sentinel has no policy language. Stun decisions are made externally and communicated via labels. Nirmata's RuntimePolicy CRD shows how to express containment rules declaratively, version them in Git, and audit them through the same pipeline as admission policies.

2. **Monitor-before-enforce.** Nirmata's `WouldDeny` counterfactual is a pattern Signal Loom should adopt. Before enforcing a stun policy, run it in monitor mode to surface false positives without disrupting running agents.

3. **Continuous enforcement vs. emergency containment.** These are complementary, not competitive. Nirmata Runtime prevents bad behaviour from happening; Signal Loom's stun sentinel is the circuit breaker when prevention fails. A production system wants both layers.

4. **Protocol-aware network filtering.** The stun sentinel's TC drop is a sledgehammer. Nirmata's protocol-level enforcement (blocking by application protocol, not just port) could inform a more graduated network containment where agents are restricted to specific protocols rather than fully network-isolated.

---

## 3. Competitive Landscape

### 3.1 Tool Comparison Matrix

| Tool | Mechanism | Enforcement Latency | Policy Format | Freeze vs Kill | K8s Integration | Network Isolation | AI-Specific | Production Status |
|---|---|---|---|---|---|---|---|---|
| **Signal Loom Stun Sentinel** | cgroup.freeze + TC matchall drop | 100ms-1s (API watch) | None (label-triggered) | Freeze (preserves memory) | DaemonSet, label watch | TC drop (all traffic) | Yes (designed for agent containment) | Demo/PoC |
| **Nirmata Runtime for Kyverno** | BPF-LSM (bprm_check_security, file_open) + cgroup eBPF | Synchronous (~us) | CEL (RuntimePolicy CRD) | Deny (process continues, operation blocked) | CRD, podSelector, OpenReports | Cgroup egress + protocol DPI | Yes (agent exec/network bounds) | v1alpha1 (Aug 2026) |
| **Cilium Tetragon** | kprobes/tracepoints + BPF-LSM + bpf_override_return + bpf_send_signal | Synchronous (~us) | TracingPolicy CRD (YAML) | Kill (SIGKILL) or Override return | CRD, K8s-aware labels/namespaces | Via Cilium CNI (not Tetragon itself) | No (general-purpose) | CNCF project, production (Isovalent/Cisco) |
| **KubeArmor** | BPF-LSM / AppArmor / SELinux | Synchronous (LSM hook) | KubeArmorPolicy CRD | Block (deny syscall, process continues) | CRD, DaemonSet, label selectors | Process/file/network controls | No (general-purpose) | CNCF Sandbox, production at scale |
| **Falco + Falcosidekick** | eBPF tracepoints/kprobes (detection only) | Detection: ~1s; Response: seconds (webhook) | Falco Rules (YAML) + Falcosidekick actions | Kill (via webhook to K8s operator) | DaemonSet, K8s metadata enrichment | Via response actions (NetworkPolicy creation) | No (general-purpose detection) | CNCF Graduated, wide production adoption |
| **Aqua Tracee** | eBPF tracepoints/kprobes | Detection: sub-second | Rego/Signature-based rules | Detection only (no inline enforcement) | DaemonSet, K8s metadata | No (observability only) | No | Open source (Apache 2.0), Aqua commercial |
| **Seccomp-BPF** | Syscall filter (prctl/seccomp) | Synchronous (syscall entry) | JSON seccomp profiles (OCI spec) | Kill (SCMP_ACT_KILL) or Errno (SCMP_ACT_ERRNO) | Pod securityContext, SeccompProfile CRD | No (syscall only, not network-aware) | No | Kernel-native since 3.5, production everywhere |
| **Google gVisor** | Userspace kernel (Sentry intercepts all syscalls) | Synchronous (every syscall reimplemented) | N/A (isolation by architecture) | Isolation (separate kernel, no direct freeze) | RuntimeClass, GKE Sandbox | Sentry reimplements networking | No (general isolation) | Production (GKE, Cloudflare Workers) |
| **Kata Containers** | Hardware virtualisation (KVM micro-VM per pod) | N/A (isolation boundary, not policy) | N/A (VM isolation) | VM-level: pause/stop VM | RuntimeClass, containerd shim | VM-level network isolation | No (general isolation) | Production (Ant Group, Azure) |
| **Sysbox** | User namespaces + OCI runtime interception | N/A (isolation boundary) | N/A (rootless container) | No freeze capability | RuntimeClass (k3s integration) | Container-level only | No | Open source, Docker-acquired, CE only |

### 3.2 Detailed Tool Analysis

#### Cilium Tetragon

Tetragon is the most technically mature eBPF enforcement engine. Two enforcement mechanisms:

1. **Override Return Value** (`bpf_override_return`): The function never executes; an error value (typically `-EPERM`) is returned to the caller. Limited to functions marked `ALLOW_ERROR_INJECTION` -- primarily syscalls and security check functions. Requires `CONFIG_BPF_KPROBE_OVERRIDE=y`.

2. **SIGKILL** (`bpf_send_signal`): Terminates the process synchronously. However, SIGKILL sent during a `write()` does not guarantee the data was not written -- it guarantees the process is terminated after.

The `NotifyEnforcer` action in TracingPolicy takes `argError` (override return) and `argSig` (signal to send). Both are optional and can be combined.

**Strengths:** Deep kernel integration, Kubernetes-native (understands pods/namespaces/labels), sub-1% performance overhead, CNCF project with Cisco/Isovalent backing, existing Cilium CNI integration.

**Weakness for Signal Loom:** Tetragon kills processes; it does not freeze them. There is no `cgroup.freeze` equivalent in TracingPolicy. For forensic preservation of rogue AI agents, Tetragon's SIGKILL destroys the evidence.

#### KubeArmor

KubeArmor abstracts three LSM backends behind a single policy CRD:

- **AppArmor** (default on most distros, no kernel recompile)
- **BPF-LSM** (kernel 5.7+, `CONFIG_BPF_LSM=y`)
- **SELinux** (RHEL/Fedora ecosystems)

The `KubeArmorPolicy` CRD controls process execution, file access, and network operations per pod/container. Enforcement is inline with the LSM hook -- blocked operations return `-EPERM` before they execute.

**Strengths:** Widest kernel compatibility (AppArmor fallback means it works on any modern kernel), CNCF Sandbox project, MITRE/STIGs/CIS rule mappings, non-privileged DaemonSet.

**Weakness:** No protocol-level network filtering (L3/L4 only), no cgroup freeze capability, no AI-specific features.

#### Falco + Falcosidekick

Falco is **detection only** -- it does not prevent actions. Containment requires Falcosidekick response automation, which routes alerts to external systems (Kubernetes operators, webhooks, Lambda functions) that take action.

Response patterns:
- Create a `NetworkPolicy` isolating the pod from all egress
- Delete the pod
- Patch labels (which could trigger Signal Loom's stun sentinel)

**The latency penalty is real.** Detection (~1s) + webhook delivery + operator reconciliation + API server persistence = multiple seconds before containment. For an AI agent executing tool calls at sub-second intervals, this window is exploitable.

**Strength:** Largest rule library, 70+ output destinations, CNCF Graduated, battle-tested in production.

#### Seccomp-BPF

Kernel-native since Linux 3.5. Filters syscalls at entry, before arguments are processed. Applied via `prctl(PR_SET_SECCOMP)` or the `seccomp()` syscall.

Docker's default seccomp profile blocks ~44 of 300+ syscalls. This is a **compile-time, static filter** -- no dynamic policy updates, no runtime reconfiguration without restarting the container.

For AI agent sandboxing:
- Block `execve`/`execveat` to prevent arbitrary command execution
- Block `socket(AF_INET, ...)` to prevent network connections
- Block `ptrace` to prevent debugging other processes
- Block `mount`/`umount` to prevent filesystem manipulation

**Limitation:** Seccomp operates on syscall numbers and argument values only. It has no concept of file paths, network destinations, process names, or Kubernetes context. It cannot express "allow network to `api.openai.com` but deny to `evil.com`".

#### Google gVisor

gVisor provides isolation through architecture, not policy. The Sentry process reimplements ~200 Linux syscalls in Go. A container running under gVisor never touches the host kernel for most operations.

**Syscall interception:** The default mechanism since 2023 is `systrap` (seccomp-trap), where every container syscall triggers a seccomp notification that the Sentry handles.

**Performance:** 10-30% overhead on I/O-heavy workloads. Every syscall crosses the user/kernel boundary twice (container -> trap -> Sentry -> host syscall). For AI inference workloads that are GPU-bound, this overhead is negligible. For agents doing heavy file I/O or network calls, it is measurable.

**No freeze capability.** gVisor isolates; it does not contain in the forensic sense. You cannot freeze-in-place a gVisor workload while preserving its state for investigation.

#### Kata Containers + eBPF (Ant Group Pattern)

Ant Group's AntCWPP (Cloud Workload Protection Platform) combines Kata's micro-VM isolation with eBPF-based runtime enforcement inside the VM:

- **Kata** provides the hardware isolation boundary (KVM micro-VM per pod, separate kernel)
- **eBPF** provides fine-grained policy enforcement within the VM (process, file, network controls)

This is the strongest isolation posture available: even a complete guest kernel compromise cannot reach the host. eBPF inside the VM provides runtime visibility without weakening the isolation boundary.

**Cost:** Kata pods have higher memory overhead (each gets its own kernel), slower startup (~1-3s vs. ~100ms for containers), and limited GPU passthrough support.

### 3.3 Emerging Projects (2025-2026)

| Project | Description | Status |
|---|---|---|
| **eBPF-PATROL** | Adaptive eBPF-LSM runtime security agent for containerised AI environments. Deny/Allow/Kill enforcement. | Preprint (Nov 2025) |
| **BpfJailer (Meta)** | eBPF-based mandatory access control for AI training/inference. Presented at Linux Plumbers 2025. | Open-source planned 2026 |
| **AgentCgroup** | OS-level cgroup abstraction for AI agents. Presented at AgenticOS 2026 workshop (ASPLOS 2026). | Research |
| **AgentSight** | System-level observability for AI agents using eBPF. | Workshop paper |
| **Sandlock** | Confines AI agent code using unprivileged Linux primitives (namespaces, seccomp-BPF). No root required. | arXiv preprint (2025) |
| **ActPlane** | Programmable OS-level policy enforcement for agent harnesses. | arXiv preprint (Jun 2026) |
| **agent-sandbox** | CNCF project (SIG Apps, KubeCon NA 2025). Declarative CRD for isolated AI-agent workloads. Supports gVisor and Kata backends. | Early CNCF |

---

## 4. Architectural Recommendations

### 4.1 Should Signal Loom Adopt an Existing Tool?

**Recommendation: No single tool replaces the stun sentinel, but the sentinel should integrate with existing infrastructure rather than operating in isolation.**

The stun sentinel solves a specific problem that no other tool addresses: **freeze-in-place with memory preservation for forensic analysis of a rogue AI agent**. Tetragon kills. KubeArmor blocks. Falco detects. Nirmata Runtime denies. None of them freeze.

However, the sentinel should not be the only enforcement layer. The recommended architecture is **defence in depth**:

| Layer | Tool | Purpose |
|---|---|---|
| **L1: Admission** | Kyverno | Validate agent pod specs at deploy time |
| **L2: Runtime prevention** | Nirmata Runtime or Tetragon | Continuously enforce behaviour envelope (exec, file, network) |
| **L3: Runtime detection** | Falco | Detect anomalies that prevention rules do not cover |
| **L4: Emergency containment** | Signal Loom Stun Sentinel | Freeze + network-isolate when L2/L3 trigger a stun decision |

The stun sentinel becomes the **circuit breaker** -- the last-resort mechanism when continuous enforcement has been bypassed or when an agent's behaviour exceeds its declared envelope in a way that warrants preserving state for investigation.

### 4.2 Integrating with Cilium's Existing eBPF Infrastructure

If the cluster runs Cilium as its CNI (which is the case for GKE Autopilot, EKS recommended, AKS built-in), the sentinel's TC filter attachment will conflict with Cilium's existing `clsact` qdisc and eBPF programs on pod veth interfaces.

**Recommended integration approach:**

1. **Use Cilium's identity-based policy engine instead of raw TC filters.** Rather than attaching a custom `matchall drop` filter, create a `CiliumNetworkPolicy` that denies all ingress and egress for the stunned pod. Cilium's eBPF datapath will enforce this within its existing TC programs -- no additional qdisc attachment needed.

    ```yaml
    apiVersion: cilium.io/v2
    kind: CiliumNetworkPolicy
    metadata:
      name: stun-isolate-${POD_NAME}
      namespace: fe-signalloom-agents
    spec:
      endpointSelector:
        matchLabels:
          signalloom.ai/state: stunned
      ingress: []   # deny all
      egress: []    # deny all
    ```

2. **Use Cilium's endpoint API for immediate enforcement.** `CiliumNetworkPolicy` application goes through the API server and the Cilium agent's reconciliation loop. For tighter latency, use `cilium endpoint config <ep-id> --policy-ingress=deny --policy-egress=deny` directly from the sentinel. This bypasses the API server entirely and takes effect within the Cilium agent's BPF map update cycle (~milliseconds).

3. **Leverage Tetragon for the stun trigger.** Instead of watching Kubernetes labels, write a `TracingPolicy` that detects the specific syscall patterns or file access patterns that indicate a rogue agent, and have Tetragon fire a `NotifyEnforcer` that both sends SIGSTOP (not SIGKILL) to the process and notifies the sentinel to apply the cgroup freeze. This reduces the trigger latency from API-watch-speed (~100ms-1s) to syscall-synchronous (~microseconds).

### 4.3 Reducing Privilege Requirements

The current privilege surface can be reduced:

**Drop `hostPID`:**

The current code does not actually use `/proc/{pid}/` for veth resolution -- it lists interfaces by naming convention. If switching to Cilium-based network isolation (recommendation 4.2), the sentinel no longer needs to manipulate host network interfaces at all, eliminating the need for both `hostPID` and `hostNetwork`.

**Drop `hostNetwork`:**

With Cilium policy-based isolation, the sentinel does not need to see host-side interfaces. It only needs Kubernetes API access (to watch labels and optionally create CiliumNetworkPolicies) and cgroup filesystem access (to freeze).

**Reduce to `CAP_DAC_OVERRIDE` instead of `SYS_ADMIN`:**

Writing to `/sys/fs/cgroup/.../cgroup.freeze` requires write access to a file owned by root. `CAP_DAC_OVERRIDE` bypasses file permission checks without granting the full `SYS_ADMIN` surface. However, this depends on the cgroup filesystem mount options -- if mounted with `nosuid`, additional capabilities may be needed.

**Alternatively, use a privileged init container** that sets up the cgroup write access (e.g., bind-mounts the specific pod cgroup paths with appropriate permissions), and run the main sentinel container with minimal capabilities.

**Target privilege surface after refactoring:**

| Requirement | Before | After |
|---|---|---|
| `hostPID` | true | **false** |
| `hostNetwork` | true | **false** |
| `SYS_ADMIN` | yes | **DAC_OVERRIDE or dropped** |
| `NET_ADMIN` | yes | **dropped** (Cilium handles network) |
| cgroup volume | RW host mount | RW host mount (unchanged) |

### 4.4 BPF-LSM Hooks vs. TC Filters

**The case for BPF-LSM:**

BPF-LSM hooks (`security_task_setscheduler`, `security_file_open`, `bprm_check_security`) are **synchronous with the operation they gate**. The decision happens inside the syscall path -- there is no userspace round-trip, no watch event delay, no API server in the loop. If the goal is to prevent an agent from performing a specific action, BPF-LSM is the correct mechanism.

However, BPF-LSM cannot freeze a process. It can deny individual operations or kill the process, but it cannot suspend execution while preserving state. The `cgroup.freeze` interface is unique in this regard.

**The case for keeping TC filters (or their Cilium equivalent):**

Network isolation and process control are orthogonal concerns. Freezing a process via cgroup.freeze does not stop in-flight packets already in the network stack. TC/Cilium-level network isolation is still needed to prevent data exfiltration by packets that were queued before the freeze.

**Recommendation:** Use BPF-LSM (via Tetragon or Nirmata Runtime) for **continuous prevention** and keep cgroup.freeze for **emergency containment**. Replace raw TC filters with Cilium policy enforcement for network isolation.

### 4.5 Future Direction: Policy API + eBPF

The Kubernetes Gateway API and evolving Network Policy v2 proposals are moving toward richer, declarative network policy. The AdminNetworkPolicy and BaselineAdminNetworkPolicy (KEP-2091, GA target 2026) provide cluster-scoped, priority-ordered network policy that could replace ad-hoc TC filter attachment.

A future stun sentinel could:

1. Watch for stun decisions (from Tetragon alerts, Falco events, or direct API signals)
2. Apply cgroup.freeze for process containment
3. Create an `AdminNetworkPolicy` with highest priority that denies all traffic to/from the stunned pod
4. The cluster's CNI (Cilium, Calico, or any ANP-compliant implementation) enforces the network policy through its existing eBPF datapath

This eliminates all host-level privilege requirements except cgroup write access.

---

## 5. Implementation Ideas

### 5.1 Production-Grade Veth Resolution

The current `findHostVeth` is a demo shortcut. Production implementation:

```go
// resolveVethByNetns finds the host-side veth for a pod by reading the 
// interface link index from the pod's network namespace.
func resolveVethByNetns(podPID int) (string, error) {
    // Read the pod's eth0 ifindex from /proc/{pid}/net/
    podIfPath := fmt.Sprintf("/proc/%d/net/if_inet6", podPID)
    // or parse /proc/{pid}/net/dev for the eth0 entry
    
    // Read the peer ifindex from /sys/class/net/eth0/iflink
    // inside the pod's netns (via nsenter or netns fd)
    peerIflink := readFromNetns(podPID, "/sys/class/net/eth0/iflink")
    
    // Match the peer ifindex to a host-side interface
    hostIfaces, _ := net.Interfaces()
    for _, iface := range hostIfaces {
        if iface.Index == peerIflink {
            return iface.Name, nil
        }
    }
    return "", fmt.Errorf("no host interface with index %d", peerIflink)
}
```

This eliminates the naming-convention dependency and works with any CNI.

### 5.2 Cilium-Integrated Network Isolation

Replace the TC filter attachment with Cilium endpoint manipulation:

```go
// isolateViaCilium uses Cilium's local endpoint API to immediately deny
// all traffic to/from the pod, without going through the K8s API server.
func isolateViaCilium(podIP string) error {
    // Find the Cilium endpoint ID for this pod
    out, err := exec.Command("cilium", "endpoint", "list", 
        "-o", "json").Output()
    if err != nil {
        return fmt.Errorf("cilium endpoint list: %w", err)
    }
    
    epID := findEndpointByIP(out, podIP)
    if epID == 0 {
        return fmt.Errorf("no cilium endpoint for IP %s", podIP)
    }
    
    // Set policy to deny-all for this endpoint
    _, err = exec.Command("cilium", "endpoint", "config", 
        strconv.Itoa(epID),
        "--policy-ingress=always",  // always = deny unless explicitly allowed
        "--policy-egress=always",
    ).CombinedOutput()
    return err
}
```

This approach:
- Uses Cilium's existing BPF datapath (no additional TC programs)
- Takes effect in milliseconds (BPF map update, no API server round-trip)
- Is compatible with existing Cilium network policies
- Does not require `NET_ADMIN` or `hostNetwork`

### 5.3 BPF-LSM-Based Graduated Containment

Instead of binary freeze/unfreeze, implement graduated containment via BPF-LSM:

**Level 1 -- Network Restrict:** Deny egress except DNS and the designated LLM gateway.

**Level 2 -- Exec Restrict:** Deny all `execve` calls except the agent's own binary and approved tools.

**Level 3 -- File Restrict:** Deny writes to all paths except the agent's designated workspace.

**Level 4 -- Full Freeze:** Apply cgroup.freeze (existing mechanism).

This can be implemented with Tetragon `TracingPolicy`:

```yaml
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: agent-containment-l2
spec:
  kprobes:
  - call: __x64_sys_execve
    syscall: true
    args:
    - index: 0
      type: string
    selectors:
    - matchNamespaces:
      - namespace: Mnt
        operator: In
        values:
        - "signalloom-agents"   # K8s namespace
      matchArgs:
      - index: 0
        operator: NotIn
        values:
        - /usr/bin/python3
        - /app/agent
        - /usr/bin/node
      matchActions:
      - action: Override
        argError: -1    # EPERM
      - action: Post
        argSig: 19      # SIGSTOP (not SIGKILL -- preserve state)
```

### 5.4 Tetragon-Triggered Stun

Replace the label-watch trigger with Tetragon event-driven stun:

```go
// watchTetragonEvents subscribes to Tetragon's gRPC event stream
// and triggers stun when a containment-worthy event is detected.
func watchTetragonEvents(ctx context.Context, freezer *cgroupFreezer) {
    conn, _ := grpc.Dial("unix:///var/run/cilium/tetragon.sock",
        grpc.WithInsecure())
    client := tetragon.NewFineGuidanceSensorsClient(conn)
    
    stream, _ := client.GetEvents(ctx, &tetragon.GetEventsRequest{
        AllowList: []*tetragon.Filter{
            {EventSet: []tetragon.EventType{
                tetragon.EventType_PROCESS_TRACEPOINT,
            }},
        },
    })
    
    for {
        event, err := stream.Recv()
        if err != nil { break }
        
        // Check if this event matches a stun-worthy pattern
        if shouldStun(event) {
            podUID := extractPodUID(event)
            cgroupPath, _ := freezer.resolvePodCgroup(podUID)
            freezer.freeze(cgroupPath)
            isolateViaCilium(extractPodIP(event))
        }
    }
}
```

This reduces containment latency from API-watch-speed (~100ms-1s) to Tetragon-event-speed (~microseconds from syscall to event delivery).

### 5.5 Declarative Stun Policies with Kyverno

Integrate stun triggers with Kyverno's policy engine:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: auto-stun-on-anomaly
spec:
  rules:
  - name: stun-on-excessive-exec
    match:
      resources:
        kinds:
        - Pod
        namespaces:
        - fe-signalloom-agents
        selector:
          matchLabels:
            signalloom.ai/agent: "true"
    # Triggered by Nirmata Runtime's OpenReport findings
    preconditions:
      all:
      - key: "{{ request.object.metadata.annotations.\"runtime.nirmata.io/violations\" }}"
        operator: GreaterThan
        value: "10"
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            signalloom.ai/state: stunned
```

This creates a feedback loop: Nirmata Runtime detects policy violations -> violations accumulate in annotations -> Kyverno mutating webhook applies the stun label -> sentinel freezes the pod.

---

## 6. Kernel Version Requirements Summary

| Feature | Minimum Kernel | Config Option |
|---|---|---|
| cgroups v2 `cgroup.freeze` | 5.2 | `CONFIG_CGROUPS`, `CONFIG_CGROUP_FREEZER` |
| BPF-LSM | 5.7 | `CONFIG_BPF_LSM=y`, `lsm=bpf` boot param |
| `bpf_override_return` (Tetragon) | 4.16 | `CONFIG_BPF_KPROBE_OVERRIDE=y` |
| `bpf_send_signal` (Tetragon) | 5.3 | (built-in) |
| TC `cls_bpf` | 4.1 | `CONFIG_NET_CLS_BPF` |
| TC `cls_matchall` | 4.7 | `CONFIG_NET_CLS_MATCHALL` |
| `BPF_PROG_TYPE_CGROUP_SKB` | 4.10 | `CONFIG_CGROUP_BPF` |
| `BPF_PROG_TYPE_CGROUP_SOCK_ADDR` | 4.18 | `CONFIG_CGROUP_BPF` |
| Seccomp-BPF | 3.5 | `CONFIG_SECCOMP_FILTER` |
| BTF (required for CO-RE eBPF) | 5.2 | `CONFIG_DEBUG_INFO_BTF` |

All GKE, EKS, and AKS node images ship kernels >= 5.10 with BTF and BPF-LSM support. On-prem clusters running RHEL 8 (kernel 4.18) lack BPF-LSM but support everything else.

---

## References

- [Nirmata Runtime for Kyverno announcement](https://nirmata.com/2026/08/16/introducing-nirmata-runtime-for-kyverno-kernel-level-enforcement-for-ai-workloads/) (August 2026)
- [Nirmata Runtime GitHub](https://github.com/nirmata/runtime)
- [Tetragon enforcement documentation](https://tetragon.io/docs/concepts/enforcement/)
- [Tetragon TracingPolicy selectors](https://github.com/cilium/tetragon/blob/main/docs/content/en/docs/concepts/tracing-policy/selectors.md)
- [KubeArmor GitHub](https://github.com/kubearmor/KubeArmor) (CNCF Sandbox)
- [Falco runtime security](https://falco.org/) (CNCF Graduated)
- [Aqua Tracee](https://github.com/aquasecurity/tracee)
- [gVisor security model](https://gvisor.dev/docs/architecture_guide/security/)
- [Kata Containers + eBPF (Ant Group)](https://katacontainers.io/blog/kata-containers-ant-container-security-with-ebpf-whitepaper/)
- [Tigera: Why eBPF Is Useful for Watching and Sandboxing AI Agents](https://www.tigera.io/blog/why-ebpf-is-useful-for-watching-and-sandboxing-ai-agents/)
- [eBPF-PATROL preprint](https://arxiv.org/pdf/2605.17909) (May 2025)
- [Sandlock: Confining AI Agent Code with Unprivileged Linux Primitives](https://arxiv.org/pdf/2605.26298)
- [ActPlane: Programmable OS-Level Policy Enforcement for Agent Harnesses](https://arxiv.org/pdf/2606.25189)
- [AI Code Sandboxes: A Comparative Security Study](https://arxiv.org/pdf/2606.08433) (June 2026)
- [Cilium eBPF networking and security](https://docs.cilium.io/)
- [Linux kernel cgroups v2 documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html)
