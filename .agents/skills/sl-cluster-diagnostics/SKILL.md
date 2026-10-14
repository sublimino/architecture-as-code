---
name: sl-cluster-diagnostics
description: "Scheduled-run and on-demand cluster diagnostic sentinel and log triager for #partner-signal-loom. Continuously analyzes Kubernetes cluster health, detects pod crash loops, image pull backoffs, stuck finalizers, and warning events. Captures and aggregates multi-namespace logs using stern or portable kubectl logs fallback with noise filtering and signature matching. USE WHEN cluster errors, pod crash, image pull backoff, debug cluster, stern logs, cluster logs, inspect cluster, sl-cluster-diagnostics, /sl-cluster-diagnostics, or on schedule '*/15 * * * *'."
---

# sl-cluster-diagnostics

Scheduled and on-demand cluster diagnostics, pod lifecycle triage, and log inspection sentinel for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `*/15 * * * *` (Every 15 minutes, or immediately upon test failure, container crash, or alert notification).
- **Trigger**: Cron notification, `/sl-cluster-diagnostics`, `/cluster-debug`, or manual prompts "debug cluster", "inspect cluster logs", "check cluster errors".
- **Checkpoint**: Push right. Diagnose unhealthy pods, capture recent warning events, and aggregate multi-pod logs across target namespaces (`fe-signalloom`, `inf-signalloom`, `cert-manager`, `kube-system`, etc.). Automatically match known error signatures (e.g. ACME challenge finalizer deadlocks, OIDC redirect loops, eBPF correlator holds, unseeded Vault secrets). Emit a concise 4-bullet diagnostic brief.
- **Brief**: Emit a 4-bullet status: (1) Total vs unhealthy pods, (2) Recent warning events, (3) Extracted log error summary, and (4) Actionable signature remediation.

---

## Mandate & Non-Negotiable Invariants

1. **Self-Contained & Zero Tmux Dependency**:
   - The diagnostic skill runs entirely within the repository and terminal tools.
   - It replaces the interactive `ktmux` multi-pane layout (`watch-kpo`, `watch-kev`, `stern`, `watch-klog`) with self-contained, scriptable commands that work reliably in CI, background tasks, AI agent sandboxes (`nono`), and headless environments without requiring tmux or X11.

2. **Stern Engine with Native Kubectl Fallback**:
   - Auto-detects `stern` for fast, colored, multi-pod streaming and log chunk extraction with regex exclusions.
   - Gracefully and transparently falls back to native `kubectl logs` bounded concurrency when `stern` is not installed or when running in restricted containers (`--force-kubectl`).

3. **Noise Suppression Invariant**:
   - Routinely filters out leader election heartbeats (`panics.go:76|leaderelection.go:247`), harmless linearized raft trace logs from `etcd`, and repetitive HTTP 200 health probe requests (`kube-probe/1.36`, `GET /readyz 200`, `GET /health 200`) so actionable errors stand out immediately.

4. **Automated Signature Remediation**:
   - Directly maps observed error patterns to verified runbook remediations:
     - `cert-manager` challenge cleanup errors -> `make clean-test-artifacts`
     - OIDC redirect loops (`/dex/auth` 302 storms) -> SPA single-flight lock validation
     - eBPF warden correlator holds (`thaw_refused_correlator_hold`) -> security sensor containment inspection
     - OpenBao secret 404s -> `scripts/swarm-seed-secrets.sh`
     - `ImagePullBackOff` -> `CLUSTER_NAME=osramp ./scripts/kind-load-verified.sh <image>`

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Diagnostics.md`](Workflows/Diagnostics.md)
- **Signature Catalog**: [`References/ErrorSignatures.md`](References/ErrorSignatures.md)
- **Executable Diagnostics Tool**: [`Tools/cluster-diagnostics.sh`](Tools/cluster-diagnostics.sh)

---

## Execution Modes & Sequence

```bash
# 1. Comprehensive Snapshot (Default)
.agents/skills/sl-cluster-diagnostics/Tools/cluster-diagnostics.sh --snapshot

# 2. Targeted Namespace Error Scan (e.g. fe-signalloom, last 10 minutes)
.agents/skills/sl-cluster-diagnostics/Tools/cluster-diagnostics.sh -e -n fe-signalloom --since 10m

# 3. Machine-Readable JSON for Automated Verification
.agents/skills/sl-cluster-diagnostics/Tools/cluster-diagnostics.sh --json --since 5m

# 4. Continuous Live Tail (Replaces tmux pane 10.4)
.agents/skills/sl-cluster-diagnostics/Tools/cluster-diagnostics.sh --stream
```

### Standard Execution Steps:

1. **Verify Kubernetes Cluster Connectivity**:
   - Runs `kubectl cluster-info` and probes API server responsiveness.
2. **Scan Workload Lifecycles**:
   - Identifies non-running pods (`CrashLoopBackOff`, `ImagePullBackOff`, `Pending`, `Terminating`) and high restart counts.
3. **Capture API Warning Events**:
   - Pulls recent `Warning` events sorted by timestamp.
4. **Aggregate & Extract Error Logs**:
   - Extracts log chunks using `stern` or parallel `kubectl logs` fallback.
5. **Evaluate Anti-Pattern Signatures**:
   - Analyzes logs against cataloged failure modes and outputs concrete next steps.
