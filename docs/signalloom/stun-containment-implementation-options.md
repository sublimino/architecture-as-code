# Stun Containment: Implementation Options Memo

**Date:** 2026-08-04
**Author:** Architect Agent (Serena Blackwood archetype)
**Status:** Draft for Andy's review

---

## Recommendation

**Option B (cgroup freeze DaemonSet + shell-script veth eBPF) is the right starting point.** It proves both primitives on the existing kind cluster in days, not weeks. The cgroup freeze is verified present today (the research file confirmed `cgroup.freeze` exists at the exact container path). The veth eBPF TC drop is a ~40-line C program and a Go loader. Together they cover tier 0 (immediate network kill) and mode 1 (freeze-first containment) — the two things credential revocation cannot touch.

Option A is cheaper and proves one primitive. Option C is the real architecture. Option D is the stretch goal that justifies ControlPlane's positioning.

---

## Option A — Shell-Script Proof of Concept (cgroup freeze only)

### What it is

A bash script that, given a pod name, discovers the container's cgroup path on the kind node, writes `1` to `cgroup.freeze`, and optionally patches the liveness probe's `failureThreshold` to prevent kubelet restart. No eBPF, no DaemonSet, no compiled code. Pure `docker exec kind-control-plane` from the host.

### Architecture

Nothing deployed. A shell script runs from the developer's workstation, `docker exec`-ing into the kind node. It reads `/sys/fs/cgroup` to find the container's cgroup scope, writes the freeze, and uses `kubectl` to patch the pod's probe. The existing `supercred-demo.sh` pattern — imperative script driving the demo — is extended rather than replaced.

### Key technical decisions

- **Cgroup discovery:** `crictl inspect <container-id>` returns `cgroupsPath`; on kind/containerd this is `kubelet.slice/kubelet-kubepods.slice/.../cri-containerd-<cid>.scope`. The research file already verified this path.
- **Probe suspension:** Two options, both tested with `kubectl patch`:
  1. Set `failureThreshold: 2147483647` (max int32) — probe keeps running, never trips. Pod spec changes, Flux sees a diff.
  2. Freeze the container *and* its pause container's cgroup — probes still fail, but the kubelet can't restart into a useful state. Riskier, needs testing.
- **No eBPF at all.** Network kill is not addressed. A frozen container's sockets stay open and the kernel keeps ACKing until the receive window closes, but no new application-layer activity occurs. For a demo, this is arguably sufficient — the agent is stopped.

### What it proves

- Mode 1 (freeze-first containment) works on kind today
- Frozen pod is byte-identical in `kubectl get pod -o yaml` (minus any probe patch)
- Flux cannot revert execution state
- KPI: "Agent stops acting within 1 second of stun signal"

### What it doesn't solve

- No network-level kill (tier 0 veth eBPF) — sockets remain open
- No programmatic trigger (requires manual `docker exec`)
- Probe suspension is a visible Kubernetes spec change
- Not demonstrable as a production pattern — it's a shell script

### Effort estimate

**S (Small)** — 1-2 days. Bash scripting, kubectl, crictl. No compiled code, no new deployments.

### Risk

- Probe handling is the main unknown. The research file flagged this explicitly as "unverified and the first thing to test". A liveness probe failure restarts the container into a fresh, unfrozen instance — the stun is silently undone.
- `docker exec` into the kind node is not a pattern that generalises. Fine for proving the primitive, misleading if presented as architecture.

---

## Option B — Go DaemonSet: cgroup freeze + veth eBPF TC drop (RECOMMENDED)

### What it is

A single Go binary deployed as a privileged DaemonSet on each node. It watches for the `signalloom.ai/state=stunned` label (the same label the existing demo uses) and, on transition, executes a two-step containment sequence: (1) freeze the container's cgroup, (2) attach a TC eBPF program to the host-side veth that drops all packets. The freeze stops the agent before it can observe the network kill. The eBPF drop severs connectivity even for kernel-level ACKs.

### Architecture

```
[Sentinel DaemonSet]          (hostPID, privileged, one per node)
  |
  +-- K8s informer: watch pods with signalloom.ai/state label
  |
  +-- On label -> "stunned":
  |     1. Resolve container cgroup path via CRI (crictl inspect)
  |     2. Write 1 to cgroup.freeze
  |     3. Discover host-side veth: read /sys/class/net/vethXXX/iflink,
  |        match against container netns ifindex
  |     4. Load + attach TC eBPF program (cilium/ebpf library)
  |     5. Patch pod probe failureThreshold (or remove via strategic merge patch)
  |
  +-- On label -> "idle" (unstun):
        1. Detach TC program
        2. Write 0 to cgroup.freeze
        3. Restore probe
```

### Key technical decisions

- **Language:** Go. The `cilium/ebpf` library is the standard for loading eBPF from Go, is well-maintained, and ControlPlane already has Go expertise. The eBPF program itself is ~40 lines of C compiled with `bpf2go`.
- **eBPF program:** A TC classifier attached to the host-side veth. Returns `TC_ACT_SHOT` for all packets. Attached at `clsact` qdisc on both ingress and egress. Dies with the veth (which dies with the pod), so no cleanup race.
- **Veth discovery:** On the kind node, enumerate `/sys/class/net/veth*`, read each `iflink`, compare against the `ifindex` inside the container's netns (from `crictl inspect` or `nsenter`). This is the standard mechanism — Cilium, Calico, and kindnet all do it.
- **BTF/CO-RE:** The kind node runs kernel 7.1.3 with `/sys/kernel/btf/vmlinux` present (standard on Debian 13 kernels). CO-RE eBPF works without shipping kernel headers. The `cilium/ebpf` loader handles BTF relocation automatically.
- **Probe handling:** Strategic merge patch to set `livenessProbe: null` on the container spec. This is a visible Kubernetes change, but it's the only reliable approach. Document the trade-off: Flux will see the diff, but the cgroup freeze is invisible.

### What it proves

- Tier 0 (host-side veth eBPF, immediate network kill) — the primitive the research file said was not present in the data path
- Mode 1 (cgroup freeze, freeze-first) — agent cannot observe its own containment
- Both operate on execution/kernel state, orthogonal to Flux
- KPIs: "Sub-second network severance", "Agent frozen before network kill lands", "Invisible to `kubectl get pod`" (minus probe patch)

### What it doesn't solve

- The probe patch is a Kubernetes spec change — Flux can revert it. The cgroup freeze and eBPF drop persist regardless, but the probe will fire and restart the container if Flux reverts the patch. This is the fundamental tension: probe management requires either (a) Flux `spec.ignore` for the probe field, or (b) accepting that a restarted container is re-stunned by the DaemonSet (since the label persists).
- No CRD, no admission webhook, no forensic mode. This is the enforcement primitive, not the orchestration layer.
- No Tetragon integration — syscall-level observability is not included.

### Effort estimate

**M (Medium)** — 3-5 days. Requires: Go, `cilium/ebpf`, basic eBPF C, Kubernetes informer pattern, CRI/crictl. One engineer who has written eBPF before, or two who haven't but know Go and Kubernetes well.

### Risk

- **eBPF verifier rejection.** The TC program is trivial (unconditional drop), so verifier issues are unlikely. But any eBPF development carries verifier risk — budget a day for debugging if unfamiliar.
- **Privileged DaemonSet blast radius.** A bug or compromise in the DaemonSet can freeze or network-kill any container on the node. Mitigate with tight RBAC, a signed image, and label-based scope (only act on pods in specific namespaces).
- **Kind-specific vs production.** The DaemonSet pattern generalises to production, but veth naming, cgroup hierarchy paths, and CRI socket locations differ across distributions. The kind demo is honest about what it proves; it does not prove EKS/GKE/AKS compatibility without additional work.
- **Re-stun loop.** If the label persists but the container restarts (probe failure before patch lands), the DaemonSet re-freezes it. This is actually the desired behaviour — document it as a feature, not a bug.

---

## Option C — Tetragon as eBPF Runtime + Sentinel Controller

### What it is

Deploy Cilium Tetragon as the eBPF runtime (it already runs as a DaemonSet with the eBPF lifecycle managed) and build a lightweight "Sentinel" controller that watches the stun label and applies TracingPolicy CRs. Tetragon handles the eBPF loading, veth attachment, and lifecycle. The controller handles the orchestration: freeze, block, observe, unstun. This is the architecture the existing spec describes, but scoped to the kind cluster with no KubeArmor and no Falco.

### Architecture

```
[Tetragon DaemonSet]         (CNCF project, Helm-installed)
  |
  +-- TracingPolicy CRDs applied per-pod on stun
  |     - Override sys_sendto/sys_connect -> EACCES (network block)
  |     - Override security_file_permission -> EACCES (token block)
  |
[Sentinel Controller]        (custom Go controller, Deployment)
  |
  +-- Watches pods with signalloom.ai/state label
  +-- On "stunned":
  |     1. cgroup freeze (direct, same as Option B)
  |     2. Apply TracingPolicy targeting the pod
  |     3. Patch probe
  |     4. Emit K8s Event + update dashboard status
  +-- On "idle":
        1. Delete TracingPolicy
        2. Unfreeze
        3. Restore probe
```

### Key technical decisions

- **Tetragon over raw eBPF.** Tetragon manages the eBPF program lifecycle, handles kernel version differences, and provides gRPC event streaming for free. The TracingPolicy CRD is a declarative surface for what would otherwise be imperative eBPF attachment. Trade-off: heavier footprint (~200MB RSS per node), but it's a CNCF project with production credibility.
- **No custom eBPF C code.** Tetragon's LSM hooks (`Override` action on `sys_connect`, `security_file_permission`) replace the custom TC drop program. The network block is at the syscall layer, not the packet layer — subtly different. Syscall-level means the agent gets `EACCES` on `connect()` rather than silent packet loss. For a demo, this is arguably better (the agent sees an error, not a timeout).
- **Tetragon on kind.** Tetragon's Helm chart works on kind. BTF is present (kernel 7.1.3). The main constraint is that Tetragon replaces nothing — it's additive to kindnet, not a CNI swap. `disableDefaultCNI` is not needed.
- **cgroup freeze is still direct.** Tetragon does not expose a cgroup freeze primitive. The Sentinel controller writes to `/sys/fs/cgroup` directly, same as Option B. Tetragon handles the network/syscall enforcement; cgroup freeze handles the execution halt.

### What it proves

- The full Sentinel architecture from the spec (OBSERVE + STUN, no FORENSIC)
- Syscall-level enforcement (not just network)
- Tetragon as a viable eBPF runtime for Signal Loom (validates the spec's technology choice)
- KPIs: all of Option B plus "Credential reads blocked at kernel level", "Syscall-level audit trail via Tetragon events"

### What it doesn't solve

- FORENSIC mode (honeypot redirect, fake proxy) — intentionally deferred
- Cloud provider equivalents (AWS/GCP/Azure IAM integration)
- L7 policy (HTTP method/path rules require Cilium CNI, not just Tetragon)
- The probe problem remains identical to Option B

### Effort estimate

**L (Large)** — 1-2 weeks. Requires: Go (controller-runtime), Tetragon Helm deployment + TracingPolicy authoring, CRI integration for cgroup paths, dashboard integration for enforcement status. One senior engineer with Kubernetes controller experience + familiarity with Tetragon.

### Risk

- **Tetragon on kind stability.** Tetragon is production-grade on real clusters but kind's container-in-container model means `/sys/kernel/btf/vmlinux` is the host's BTF, not the kind node's. Usually fine (same kernel), but edge cases exist.
- **TracingPolicy scope.** Tetragon TracingPolicies are cluster-scoped or namespace-scoped, not pod-scoped. Targeting a single pod requires label selectors in the policy, which Tetragon supports but which adds authoring complexity.
- **Operational complexity.** Tetragon + Sentinel + existing stack (Flux, OpenBao, SPIRE, Dex) is a lot of moving parts on a single-node kind cluster. Resource pressure is real.
- **Lock-in concern.** Choosing Tetragon as the runtime is a commitment. If the eventual production story is Cilium CNI (for L7 + deny rules), Tetragon is complementary. If the production story is a different CNI, Tetragon still works (it's CNI-agnostic).

---

## Option D — Inspektor Gadget as eBPF Toolkit

### What it is

Use Inspektor Gadget (CNCF Sandbox, maintained by Microsoft/Kinvolk) as the eBPF runtime instead of custom eBPF or Tetragon. Gadget provides a `run` command that can load arbitrary eBPF programs ("gadgets") from OCI registries, plus built-in gadgets for network tracing, DNS snooping, and process monitoring. The Sentinel controller calls `kubectl gadget` (or the Gadget CR API) to deploy a custom "stun gadget" that attaches TC drop programs to target veth pairs.

### Architecture

```
[Inspektor Gadget DaemonSet]  (CNCF Sandbox, Helm-installed)
  |
  +-- Built-in gadgets: trace_network, trace_dns, snapshot_process
  +-- Custom gadget: "stun" (OCI image, TC drop program)
  |
[Sentinel Controller]         (same as Option C)
  |
  +-- On "stunned":
  |     1. cgroup freeze (direct)
  |     2. kubectl gadget run ghcr.io/controlplane/stun-gadget --podname <pod>
  |     3. Patch probe
  +-- On "idle":
        1. Stop gadget
        2. Unfreeze, restore probe
```

### Key technical decisions

- **Gadget vs Tetragon.** Gadget is a toolkit, not an enforcement engine. It loads and manages eBPF programs but does not have Tetragon's LSM Override capability. You still need the TC drop eBPF program (written in C, packaged as an OCI gadget image). The advantage: Gadget handles veth discovery, program attachment, and lifecycle management. You write the eBPF, Gadget loads it.
- **OCI packaging.** Gadgets are OCI images. The stun gadget (TC drop program) is built with `ig image build`, pushed to a registry, and deployed via `kubectl gadget run`. This is a clean packaging model that aligns with ControlPlane's supply chain story (sign it with Sigstore, attest with Witness).
- **Built-in observability.** Gadget's `trace_network`, `trace_dns`, and `snapshot_process` give immediate forensic observability without writing any eBPF. This is useful demo material even before FORENSIC mode is built.
- **No syscall enforcement.** Gadget cannot block syscalls (no LSM hook support). The stun is network-only (TC drop) plus cgroup freeze. Credential reads are not blocked at the kernel level — the agent is frozen so it can't read them, but if it were unfrozen without the network kill, it could.

### What it proves

- eBPF-as-OCI-artifact (aligns with supply chain security narrative)
- Gadget as a potential ControlPlane-recommended toolkit for runtime enforcement
- Built-in network/process observability on the kind cluster
- KPIs: same as Option B (veth drop + cgroup freeze), plus "Enforcement artifact is a signed OCI image"

### What it doesn't solve

- No syscall-level enforcement (no LSM Override)
- Gadget is less mature than Tetragon for enforcement use cases
- The "gadget" abstraction adds indirection — debugging requires understanding both the gadget framework and the eBPF program
- Same probe problem as all options

### Effort estimate

**M-L (Medium to Large)** — 5-8 days. Requires: eBPF C (the TC drop program), OCI image building for gadgets, Inspektor Gadget Helm deployment, Go controller. The eBPF authoring is the same as Option B; the packaging and loading differ.

### Risk

- **Gadget maturity for enforcement.** Gadget is designed for observability and debugging, not enforcement. Using it to load a TC drop program works but pushes the tool outside its intended use case. The Gadget team may not optimise for this path.
- **Smaller community.** Tetragon has broader adoption for security enforcement. Choosing Gadget is a contrarian bet. Fine for a demo; risky as a production commitment.
- **OCI registry dependency.** The gadget image must be pullable from the kind node. Kind clusters use a local registry or pre-loaded images. Not hard, but one more thing to configure.

---

## Comparison Matrix

| | **A: Shell Script** | **B: Go DaemonSet** | **C: Tetragon** | **D: Gadget** |
|---|---|---|---|---|
| cgroup freeze | Yes | Yes | Yes | Yes |
| veth eBPF drop | No | Yes | No (syscall block) | Yes |
| Syscall enforcement | No | No | Yes | No |
| Observability | None | None | Tetragon events | Built-in gadgets |
| Probe handling | Manual | Automated | Automated | Automated |
| Deployment | None | DaemonSet | DaemonSet + Deployment | DaemonSet + Deployment |
| Effort | S (1-2d) | M (3-5d) | L (1-2w) | M-L (5-8d) |
| Production path | None | Direct | Direct | Indirect |
| Supply chain story | None | Weak | Moderate | Strong (OCI) |
| Demo impact | Low | High | Highest | High |

## Suggested Sequencing

1. **This week:** Option A — shell script proving cgroup freeze + probe handling. 1-2 days. Answer the unverified question from the research file (does a frozen container's liveness probe restart it?).
2. **Next sprint:** Option B — Go DaemonSet with both primitives. 3-5 days. This is the demo artifact.
3. **Post-demo:** Option C — Tetragon integration. This becomes the spec's Phase 1-2 implementation.
4. **If supply chain narrative is primary:** Option D instead of B, to demo enforcement-as-OCI-artifact.

Options A and B are sequential (A validates the primitive, B productionises it). C and D are alternatives to each other for the eBPF runtime layer — pick based on whether syscall enforcement (Tetragon) or supply chain packaging (Gadget) is the stronger demo message.
