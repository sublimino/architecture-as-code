# SLAAT-P2-4: Agent Sandbox Confinement & Landlock LSM Policy Fixes

Remediates the Phase 1 findings owned by this card: `SLAAT-P1-4`'s F1 (eBPF
telemetry has no detection independent of a sensitive-path match) and F2
(cgroup-tree discovery can stall under host contention), and hardens the
Landlock filesystem policy per this card's Approach.

## 1. Landlock filesystem hardening

`nono/profiles/worktree-agent.json` `filesystem.deny` gained:

| Path | Why |
| :--- | :--- |
| `/proc/sys/` | named explicitly by this card's Approach |
| `/sys/fs/cgroup/` | named explicitly; also the host cgroup hierarchy the sentinel itself needs exclusive write access to |
| `/root/` | "root execution paths" |
| `~/.kube/` | broadened from the existing `~/.kube/config` (kept, for backward compatibility with the SLAAT-P1-4 structural test) to the whole directory — a kubeconfig can also live as `~/.kube/cache/*` or a context-specific file |

Verified live against the real kernel via `scripts/test-agent-sandbox-escape.sh`
(16/16 probes pass, unchanged from SLAAT-P1-4's baseline — the new deny
entries are additive, not a behavior change for any existing probe) and
`scripts/test-worktree-confinement.sh` (21/21 probes pass). Both harnesses
are read-only against the profile; no probe in either targets the four new
entries specifically, because they test the SP-1 worktree-confinement
contract (a different control surface), not sandbox-generic Landlock
coverage. The new entries are verified structurally in
`test/sandbox-confinement-hardening.bats`.

## 2. Cgroup discovery deadline (SLAAT-P1-4/F2)

**Root cause.** `Freezer.ResolvePodCgroup`'s fast-path candidate list misses
in some pod layouts, falling back to `walkForPod`, a `filepath.WalkDir` over
the whole cgroup-v2 hierarchy bounded only by *depth*
(`maxDiscoveryDepth = 6`), never by *wall-clock time*. On a shared,
contended kind node every directory in that walk costs a real
stat/open/read syscall that now queues behind other I/O, so the walk could
run long enough to blow past a caller's own timeout — observed as an
intermittent HTTP 504 (2 of 5 stress runs) even though the actual
`Freeze()` write+poll, once the path was found, always completed inside its
50ms deadline.

**Fix** (`d2-signalloom/apps/stun-sentinel/pkg/cgroup/freezer.go`):
- `maxDiscoveryBudget` (2s) bounds the walk's wall-clock time independently
  of its depth.
- A new sentinel error, `ErrDiscoveryDeadline`, is returned distinctly from
  `ErrCgroupNotFound` when the budget is exceeded — the previous code
  silently collapsed "timed out" into "not found", which hid the finding
  and gives the caller the wrong operational response (give up vs. retry).
- `cmd/stun-sentinel/main.go`'s `statusFor` maps `ErrDiscoveryDeadline` to
  `503 Service Unavailable` (retryable), and `/stun`/`/resume` are wrapped
  in a 5s `http.TimeoutHandler` as defense-in-depth against a genuinely
  wedged syscall (not merely a slow search).

Proven by six new unit tests in `pkg/cgroup/freezer_test.go` (deadline
trips and is distinct from not-found, in both `ResolvePodCgroup` and
`FreezePod`) and one new case in `cmd/stun-sentinel/main_test.go`'s
`statusFor` table.

## 3. Evasive-burst detection (SLAAT-P1-4/F1 / SLAAT-P2-PRE's SENTINEL-F1)

**Root cause.** `pkg/correlator.SentinelProbeManager.handleRecord` drops any
syscall event that does not match `IsSensitivePath` *before* pod lookup,
normalization, or freeze. A rapid process-spawn burst (200 execve calls)
touches no sensitive path, so every single event in it was discarded —
live-reproduced by `SLAAT-P2-PRE` as `SENTINEL-F1`.

**Fix** (`pkg/correlator/ebpf_correlator.go`, `types.go`):
- A `burstTracker` counts EXECVE events per cgroup within a sliding window
  (`DefaultEvasiveBurstThreshold=20` events / `DefaultEvasiveBurstWindow=1s`,
  overridable via `WithEvasiveBurstThreshold`). Reaching the threshold
  reports and, for a governed agent pod, freezes — independently of, and
  checked before, the sensitive-path filter.
- Reaching threshold resets the window, so a sustained attacker is
  re-flagged every window rather than alerting once and going silent.
- **Separately discovered while instrumenting this**: `dispatchWorker`
  discarded `dispatchObservation`'s error outright
  (`_ = m.dispatchObservation(obs)`), so a detection's only trace was the
  signal-ingest HTTP POST — if that POST failed, there was zero evidence
  anywhere `kubectl logs` could show. Every observation (sensitive-path or
  burst) is now logged to stdout as a structured `ebpf_detection` /
  `ebpf_detection_dispatch_failed` JSON line *before* the POST is attempted.

Proven by ten new unit tests across `pipeline_test.go` (burst trips exactly
at threshold, no false positive below it, re-trips after a window reset,
refuses freeze outside policy — mirroring the existing sensitive-path
test shapes) and `ebpf_correlator_test.go` (stdout logging survives a
simulated signal-ingest outage).

## 4. Live verification and the deployment finding

Both fixes above are **proven at the Go unit-test level**
(`test/sandbox-confinement-hardening.bats`, tests 4–6), which is
deterministic and hermetic.

**Live verification of the burst detector was attempted and is
incomplete**, and that is itself the most load-bearing finding of this
card:

1. Rebuilt `signalloom-stun-sentinel` from this branch's current source
   (image tags `v0.2.1-slaat-p2-4`, then `v0.2.2-slaat-p2-4` after adding
   the stdout alarm logging) and rolled the `fe-signalloom-agents/stun-sentinel`
   DaemonSet to each in turn.
2. `scripts/probe-sentinel-evasion.sh`'s burst probe still showed **zero**
   detection after the real rebuild+redeploy. Root-caused by directly
   testing the ALREADY-SHIPPED sensitive-path detector against the live
   pod (`cat /etc/passwd` from the probe pod, a path on
   `DefaultSensitivePrefixes`): **zero `ebpf_detection` lines were emitted
   for that either**, even though the daemon logged `ebpf_probe_attached`
   with all four tracepoints at startup.
3. This means the correlator's ring-buffer consumption is not delivering
   events end-to-end in this environment when built from this branch's
   current source — a **pre-existing wiring/behavior gap that predates
   this card** (this card did not touch `signalloom-stun-sentinel/main.go`,
   the file that wires the loader and the informer).
4. The **previously-running image** (`v0.2.0`, tagged `import-2026-10-01`)
   *did* have a working pipeline: its logs show a periodic
   `ebpf_correlator_stats` event (`records_read` in the billions, `matched`
   counts in the hundreds) that **does not exist anywhere in this branch's
   Go source** (`grep -r records_read --include='*.go'` returns zero
   matches repo-wide). That image was evidently built from different,
   more-advanced source not yet merged into
   `integration/slaat-whole-system-adversarial`.
5. **Decision**: rolled the shared DaemonSet back to `v0.2.0` rather than
   leave a correlator that delivers zero events — including for the
   already-shipped sensitive-path detector — on the cluster every other
   SLAAT card also depends on. Regressing a working control to add an
   unverifiable one is not an acceptable trade.

`test/landlock-adversarial-escape.bats`'s two burst-detection assertions
gate on the deployed image tag (`require_burst_fix_deployed`) and **skip**,
loudly, with this explanation, rather than silently passing against an
image that cannot carry the fix or hard-failing in a way that reads as a
regression in this card's own (unit-proven) code.

**Recommended follow-up**: reconcile `signalloom-stun-sentinel/main.go`'s
eBPF/correlator wiring against whatever source actually produced the
working `v0.2.0` image (likely a sibling SLDC-family branch), find the
delta, and only then redeploy this card's burst-detector fix live.

## 5. Cgroup v2 resource governance (already-shipped, re-verified live)

`d2-signalloom/apps/fleet-agents/base/agent-*.yaml` and
`d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml`
already carry `runAsNonRoot`, non-root UID, `readOnlyRootFilesystem: true`,
`allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]` (sentinel adds
back only `SYS_PTRACE`/`BPF`/`NET_ADMIN`/`SYS_ADMIN`, each commented with
why), and `resources.limits` — this card found nothing to add here.

New script `scripts/verify-cgroup-enforcement.sh` proves these limits are
*enforced by the kernel*, not merely declared: `memory.max`/`cpu.max` on a
live fleet pod's real cgroup match its Pod spec exactly, and a 100m-quota
throwaway pod this script owns demonstrably gets CPU-throttled
(`cpu.stat.nr_throttled` advances) under a real stress burst. 5/5 probes
pass; `test/sandbox-confinement-hardening.bats` re-asserts three of them.

Kubelet-level `pids.max` (a cluster/node config knob, not a Pod-spec field)
was deliberately left untouched: changing it is a node-level kubelet
config change, which this card's Out of Scope list names directly
("Modifying host operating system kernel configurations").

## Evidence index

- `ci-evidence/slaat-p2-4-landlock-escape-battery.json` — 16/16,
  `scripts/test-agent-sandbox-escape.sh`.
- `ci-evidence/slaat-p2-4-worktree-confinement.json` — 21/21,
  `scripts/test-worktree-confinement.sh`.
- `ci-evidence/slaat-p2-4-cgroup-enforcement.json` — 5/5,
  `scripts/verify-cgroup-enforcement.sh`.
- `ci-evidence/slaat-p2-4-sentinel-evasion-post-fix-source-level.json` —
  the live probe run against the (subsequently rolled back) `v0.2.2-slaat-p2-4`
  image; see §4 for why its burst-detection fields read `FAIL`.
- `test/sandbox-confinement-hardening.bats` — 11/11 (new suite).
- `test/landlock-adversarial-escape.bats` — 15/15 (2 honest skips, §4).
- `test/landlock-containment-probes.bats` — 13/13 (unchanged).
- `test/worktree-landlock-confinement.bats` — 36/36 (unchanged).
- `d2-signalloom/apps/stun-sentinel/pkg/{cgroup,correlator}` — all unit
  tests green, including 16 new tests this card adds.
