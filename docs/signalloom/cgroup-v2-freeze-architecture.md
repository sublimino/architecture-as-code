# cgroup-v2 Freeze Architecture — Tier 0 Kernel Execution Halt

> **Card:** CRKC-P1-2 · **Component:** `d2-signalloom/apps/stun-sentinel`
> **Status:** implemented and measured on a live Kind cluster
> **Evidence:** [`evidence/cgroup-freeze-proof.json`](evidence/cgroup-freeze-proof.json) ·
> [`evidence/cgroup-freeze-benchmark.json`](evidence/cgroup-freeze-benchmark.json)

## What this is

When Signal Loom judges an agent compromised, labelling the pod is not enough. A label is
Kubernetes *configuration* state: asynchronous, visible to the workload, revertible by a
reconciler, and entirely powerless over the CPU the agent is using right now. Between detection
and eviction there is a window — seconds, sometimes tens of seconds — in which a compromised
agent can exfiltrate, tamper with the audit trail it is about to appear in, or fork children to
outlive its parent.

Tier 0 closes that window. `stun-sentinel` writes `1` to the pod's cgroup-v2 `cgroup.freeze`
file. The kernel stops scheduling every task in the subtree. Measured on the cluster this
document was written against: **CPU accounting went from 572,317 µs per 500 ms to exactly 0**,
and the transition was confirmed in **0.042 ms**.

This document records how it works, what the design is defending against, and — importantly —
three things the CRKC-P1-2 card asserted that turned out not to be true of this kernel.

## Three corrections to the card's premises

These are recorded here rather than only in the errata, because each one would otherwise be
re-derived (or re-implemented incorrectly) by a later phase.

### 1. The freezer is a core interface, not a controller

The card says the preflight "confirmed `/sys/fs/cgroup/cgroup.controllers` contains `freezer`
and `cpu`". It does not, and it never will on any cgroup-v2 host:

```console
$ cat /sys/fs/cgroup/cgroup.controllers
cpuset cpu io memory hugetlb pids rdma misc
```

In cgroup v1 the freezer was a controller you mounted and enabled. In cgroup v2 it was
deliberately reimplemented as a **core interface** — `cgroup.freeze` and `cgroup.events` are
present on every non-root cgroup with no controller enablement and no `cgroup.subtree_control`
entry. A preflight that greps `cgroup.controllers` for `freezer` will find nothing on a
perfectly capable host and conclude, wrongly, that freezing is unavailable.

The upstream CRKC-P1-PRE errata states this correctly ("unified core freeze primitive"); the
card's compiled summary paraphrased it into a controller claim. `test/cgroup-freeze-stun.bats`
asserts the true behaviour in both directions — the string is absent from `cgroup.controllers`
*and* the control files are present on a non-root cgroup — so the claim cannot quietly return.

### 2. `/sys/fs/cgroup/kubepods.slice` does not exist on this cluster

The card's approach specifies "locating `/sys/fs/cgroup/kubepods.slice` paths for target pod
UIDs". On the Kind cluster the real path is:

```
/sys/fs/cgroup/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-besteffort.slice/
  kubelet-kubepods-besteffort-pod81450922_ec47_4bf5_908f_b7b673152099.slice
```

The root cause is that **a pod's cgroup path is a function of the runtime's cgroup driver and of
the systemd slice the kubelet itself runs in — neither of which is derivable from the pod UID**.
Kind runs kubelet inside its own `kubelet.slice` unit, so kubepods is nested one level deeper
and every slice name is prefixed accordingly. An implementation that hardcodes one layout is
correct on exactly one cluster.

`ResolvePodCgroup` therefore enumerates a candidate matrix rather than constructing a path.

### 3. Frozen tasks report `S`, not `D`

The card's evidence requirement is that "container processes transition to `D` / frozen state",
and its loop instruction says to poll `/proc/<pid>/stat` "until state changes to `D`". That
condition never becomes true on a modern kernel:

```console
$ awk '{print $3}' /proc/4052062/stat
S
$ cat /proc/4052062/wchan
get_signal
```

The cgroup-v1 freezer parked tasks in `TASK_UNINTERRUPTIBLE`, which renders as `D`. The cgroup-v2
freezer uses `TASK_INTERRUPTIBLE` instead, so frozen tasks show as `S` — a deliberate change, so
that freezing a cgroup does not inflate the node's load average or make every frozen task look
hung to monitoring. Polling for `D` would loop until timeout against a *correctly frozen*
container.

`S` on its own proves nothing (most idle processes are `S`). The three signals that actually
discriminate, and which the test suite asserts, are:

| Signal | Where | Meaning |
| :---- | :---- | :---- |
| `frozen 1` | `cgroup.events` | the kernel reports the subtree settled |
| `usage_usec` delta of exactly `0` | `cpu.stat` | no instruction was executed |
| `wchan` = `get_signal` | `/proc/<pid>/wchan` | the task is parked in `__refrigerator()` |

## Why the freezer and not SIGSTOP

| Property | `cgroup.freeze` | `SIGSTOP` / ptrace |
| :---- | :---- | :---- |
| Interceptable by the target | No — enforced by the scheduler | Partly; the stop is observable and racy |
| Covers processes forked during the halt | Yes, atomically across the subtree | No — a fork can outrun the signal loop |
| Requires enumerating PIDs | No | Yes, and the list is stale as you read it |
| Survives the target ignoring it | Yes | `SIGSTOP` cannot be caught, but delivery is per-process |
| Single control point | One file write | N syscalls over a racing PID set |

The decisive property is the second. A compromised agent that detects containment and forks is
defeated by an in-kernel subtree freeze and is *not* reliably defeated by a userspace loop over
`cgroup.procs`, because a child created between the read and the signal is missed. This is why
`cgroup.freeze` is Tier 0 and why userspace stop mechanisms are explicitly out of scope for this
card.

## Design

```
      POST /stun {pod_uid}
              │
              ▼
   ┌──────────────────────┐
   │  ResolvePodCgroup    │  candidate matrix: 4 roots x 3 QoS tiers x 2 drivers
   │                      │  fallback: depth-bounded walk (maxDepth 6)
   └──────────┬───────────┘  selection criterion: cgroup.freeze EXISTS
              │
              ▼
   ┌──────────────────────┐
   │  write "1" to        │  O_WRONLY, never O_CREATE
   │  cgroup.freeze       │  EACCES / ENOENT classified into distinct errors
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │  poll cgroup.events  │  first read immediate, then 25µs → 1ms backoff
   │  until "frozen 1"    │  HARD 50ms deadline → ErrFreezeDeadline
   └──────────┬───────────┘
              │  ← success is defined HERE, not at the write
              ▼
   ┌──────────────────────┐
   │  census cgroup.procs │  recursive, AFTER confirmation (fork-race close)
   └──────────┬───────────┘
              │
              ▼
      StunExecutionHalted → Signal Loom (JSONL on stdout)
```

### The one rule that shapes everything

> **A containment control that cannot fail cannot be trusted.**

The implementation this replaces (`d2-signalloom/apps/signalloom-stun-sentinel/freezer.go`)
writes `1`, spins five times over `cgroup.events`, and then `return nil` regardless of what it
read. Every freeze it has ever performed reported success, including any that did not happen.

`Freeze` here returns `nil` only after a read-back of `cgroup.events` reported `frozen 1`. If
the deadline expires it returns `ErrFreezeDeadline` naming the observed state, the poll count,
and the elapsed time. `TestFreezeReturnsDeadlineErrorWhenNeverFrozen` is the test that pins this,
and the mutation sweep in the errata confirms it fails when the guard is removed.

### Error taxonomy

Five typed errors, because collapsing them loses the operational response:

| Error | Cause | What the operator should do |
| :---- | :---- | :---- |
| `ErrCgroupNotFound` | no cgroup for that UID, or the control file vanished mid-poll | the pod terminated; nothing to contain |
| `ErrPermission` | EACCES writing `cgroup.freeze` | the DaemonSet mount is read-only or the container is not privileged |
| `ErrFreezeDeadline` | write succeeded, `frozen 1` never observed | **containment is unproven** — escalate to eviction |
| `ErrUnauthorized` | resume attempted without a valid governance credential | expected; the refusal is the feature |
| `ErrInvalidPodUID` | empty UID, or one containing a path separator | malformed caller |

`ErrPermission` and `ErrCgroupNotFound` are the pair most worth keeping apart: conflated, a
missing hostPath mount sends an operator hunting for a pod that is in fact right there.

### Discovery: the candidate matrix

```
roots                                        QoS tiers                 pod directory
─────────────────────────────────────────    ──────────────────────    ───────────────────────
kubelet.slice/kubelet-kubepods.slice   (systemd, Kind / KubeletCgroups)
kubepods.slice                         (systemd, stock)                <base>-<qos>-pod<UID_>.slice
kubepods                               (cgroupfs)                      pod<UID-dashed>
kubelet/kubepods                       (cgroupfs, nested)
                                             guaranteed (no tier dir)
                                             burstable
                                             besteffort
```

Twelve candidates, each a single `stat`. Selection requires `cgroup.freeze` to be **present**,
not merely that the directory exists — a directory of the right name without the control file is
not a freezable cgroup, and resolving to it would defer the failure to write time with a much
less useful error.

If no candidate matches, a depth-bounded walk (max depth 6) looks for any directory whose name
embeds the UID in either mangled or literal form. An unanticipated layout therefore costs a
slower lookup rather than an outright failure.

Pod UIDs are validated before use: empty, containing `/` or `\`, or containing `..` is
`ErrInvalidPodUID`. The UID reaches the filesystem as a path component, so this is a traversal
guard, not a formatting nicety.

### The fork race

The card lists "forking race condition: new child process created while freeze is being
asserted" as an expected failure mode. cgroup v2 handles the *containment* half in-kernel: the
freeze applies to the whole subtree atomically, so a child forked mid-assertion is frozen along
with its parent. There is nothing for userspace to do about that, and any code that tried would
be racing a race it cannot win.

What userspace *must* get right is the **audit** half. `Freeze` reads `cgroup.procs` recursively
**after** `frozen 1` is confirmed, never before. A census taken before confirmation is stale by
construction and would omit exactly the process an incident responder most wants to see.
`TestFreezeCensusIsTakenAfterConfirmationAndSeesForkedChild` pins the ordering.

The read is recursive because a pod cgroup delegates to one child cgroup per container; the
pod-level `cgroup.procs` is empty on every runtime tested.

### Unfreeze is asymmetric on purpose

Freeze needs no credential. Unfreeze does.

Halting a workload suspected of compromise is a safe default — the cost of a false positive is a
stalled container. Returning capability to it is not: an attacker who reaches the resume path
undoes containment entirely. `Unfreeze` consults a `CredentialValidator` and returns
`ErrUnauthorized` when it fails. The default validator is `DenyAllCredentials`, and an
unconfigured `STUN_RESUME_TOKEN` denies everything rather than accepting everything — a daemon
deployed without governance wiring must refuse, not hand capability back to anyone who asks.

The credential travels in an `Authorization` header, never in the URL, and is read from the
environment rather than a flag so it does not appear in `ps` or in the pod spec.

## Health probe

`/healthz` creates and immediately removes a transient cgroup under the hierarchy root.

A `stat` would not do. **A read-only bind mount of `/sys/fs/cgroup` passes every stat, every
read, and every "does the path exist" probe, and fails only on write** — that is, only at the
moment containment is needed. The probe performs the one operation that distinguishes the two,
so the misconfiguration surfaces at deploy time. `run()` performs the same check at startup and
refuses to serve if it fails.

## Measured results

Live cycle, single-process target (`scripts/test-cgroup-freezer.sh`, 12/12 probes):

| Measurement | Value |
| :---- | :---- |
| Kernel | `7.1.3+deb13-amd64`, cgroup2 unified |
| CPU over 500 ms, running | 572,317 µs (≈114% of one core) |
| CPU over 500 ms, **frozen** | **0 µs** |
| CPU over 500 ms, after authorised resume | 557,533 µs |
| Freeze latency (write → `frozen 1`) | **0.042 ms** — deadline 50 ms |
| `cgroup.events` before / after | `frozen 0` / `frozen 1` |
| Resume without credential | HTTP 403 |

Benchmark, 8-worker target, 100 iterations (`test/bench-cgroup-freezer.sh`):

| Percentile | Latency |
| :---- | :---- |
| min | 0.93 ms |
| p50 | 1.51 ms |
| p90 | 2.55 ms |
| **p99** | **5.64 ms** (budget 25 ms) |
| max | 7.80 ms |

**The two latency figures measure different things and are not in conflict.** The 0.042 ms
figure is the Go implementation's own measurement — one `write(2)`, one `read(2)` of
`cgroup.events`. The benchmark's ~1.5 ms p50 is a shell loop that forks `grep` and `date` on
every poll, so it is dominated by process-spawn overhead and represents a conservative upper
bound including tooling. Both are inside budget; the shell figure is the one to quote when you
want a number nobody can accuse of being optimistic.

Each benchmark iteration thaws before it freezes, so every sample is a genuine `0→1` transition.
Freezing an already-frozen cgroup settles instantly and would flatter the numbers into
meaninglessness.

## Deployment

`d2-signalloom/deploy/stun-sentinel-daemonset.yaml`. The three host privileges and why each is
unavoidable:

- **`hostPath: /sys/fs/cgroup`, read-write** — the freeze *is* a write to the host hierarchy.
- **`privileged: true`** — writing another container's cgroup control files is denied to an
  unprivileged process whatever the file modes say.
- **`hostPID: true`** — so the PIDs in the audit record mean something outside this pod.

Narrowed elsewhere: read-only root filesystem, `RuntimeDefault` seccomp, read-only Kubernetes
RBAC (`get`/`list`/`watch` on pods only — Tier 1 label writes belong to CRKC-P1-1, deliberately
separated so a compromise of the Tier 0 daemon cannot rewrite the audit trail it produces),
`system-node-critical` priority so containment is not evicted under the pressure an attacker may
be causing, and no CPU limit so it is not throttled under that same load.

## Relationship to the existing `signalloom-stun-sentinel`

`d2-signalloom/apps/signalloom-stun-sentinel/` predates this board and is a shared surface with
CRKC-P1-3 (eBPF/TC network containment). It was **not modified by CRKC-P1-2** — editing it would
have collided with a live sibling worktree and would have breached this card's declared merge
boundary.

The new package is a standalone, importable Go module with no k8s client-go dependency in the
freezer path, so a Governor can wire it into either daemon without a rewrite. The recommended
follow-up is to replace the older `cgroupFreezer` with `pkg/cgroup.Freezer`, because the older
one cannot report a failed freeze.

## Testing

| Layer | File | What it proves |
| :---- | :---- | :---- |
| Unit | `pkg/cgroup/freezer_test.go` | discovery across 10 layouts, deadline enforcement, error taxonomy, fork-race ordering, health probe. 92.6% statement coverage, `-race` clean. Runs with no cluster. |
| Unit | `pkg/telemetry/emitter_test.go` | JSONL framing, required fields, concurrency safety |
| Unit | `cmd/stun-sentinel/main_test.go` | HTTP status mapping, credential gating, startup refusal |
| Live harness | `scripts/test-cgroup-freezer.sh` | 12 probes against the real kernel; emits the proof artifact |
| Integration | `test/cgroup-freeze-stun.bats` | 23 tests asserting the artifact and making independent kernel observations |
| Benchmark | `test/bench-cgroup-freezer.sh` | p50/p90/p99/max over 100 real transitions |

Two anti-false-green measures are built in, both of which caught real defects during
development. The BATS suite asserts its own test count, because `bats -f` with a zero-match
filter exits 0 and a suite that stops parsing partway through simply reports fewer tests. The
benchmark gates on its statistics parsing, because an awk syntax error produces no stdout, and
empty values compare as zero — which renders as a flawless `p99 0.0000 ms — pass`.

```bash
# unit only, no cluster needed
GOFLAGS=-buildvcs=false go test -C d2-signalloom/apps/stun-sentinel -race -cover ./...

# full live suite (requires the Kind cluster)
bats test/cgroup-freeze-stun.bats

# live cycle on its own, writing a fresh proof artifact
bash scripts/test-cgroup-freezer.sh --json docs/signalloom/evidence/cgroup-freeze-proof.json

# benchmark
bash test/bench-cgroup-freezer.sh --iterations 100 --workers 8
```
