# SLER Phase 4 — Kernel-Version Floor Cross-Reference for P5-2

**Filed by:** SLER-P4-GOV · **Date:** 2026-09-15 06:39:38+01:00
**Companion to:** `docs/signalloom/sler-p4-gov-review.md` §3.4
**Consumer:** SLER-P5-2 (published denial matrix)

This file exists so P5-2 does not have to infer the freeze plane's node-pool caveat from
prose buried in a completion report. It states one number and everything that qualifies it.

---

## 1. The floor

**Linux ≥ 5.2.**

`cgroup.freeze` was added to the cgroup-v2 unified hierarchy in Linux 5.2. Below that
release the control file does not exist and the freeze plane has no enforcement primitive
at all — it cannot degrade gracefully, it simply has nothing to write to. The engine has no
other kernel-version dependency on the freeze path.

Claim source: `docs/signalloom/sler-p4-1-proof.md` §5, "Minimum Kernel Requirement: Linux
`>= 5.2`". Independently consistent with the upstream cgroup-v2 freezer landing in 5.2.

---

## 2. The caveat P5-2 must publish alongside it

**The floor was never checked against a fleet.** P4-1's proof calls P4-PRE's probe a "fleet
check"; it is a single-node probe.

`docs/signalloom/sler-p4-pre-freezer-diff.md` §4.1 records exactly one node:

| Property | Observed value |
| :--- | :--- |
| Node | `osramp-control-plane` (Kind cluster `kind-osramp`) |
| OS | Debian GNU/Linux 13 (trixie) |
| Kernel | `7.1.3+deb13-amd64` |
| Container runtime | containerd 2.3.1 |
| `stat -f /sys/fs/cgroup` | `cgroup2fs` (magic `57c51bcfc13bf2f5`) |
| `cgroup.freeze` | present and writable |
| Hierarchy | `kubelet.slice/kubelet-kubepods.slice/{burstable,besteffort}` |

Two things follow.

**n = 1.** No second node, no second kernel version, no second distribution, no second
container runtime was probed. Nothing in the evidence establishes that any *other* node in
any *other* pool satisfies the floor.

**The one node is the developer host.** `uname -r` on the machine that produced this review
also returns `7.1.3+deb13-amd64`. The Kind "cluster" node shares the host kernel, as Kind
nodes always do. So the probe confirms the *developer workstation* meets the floor — it
says nothing about a production node pool, and a Kind node cannot say anything about one.

---

## 3. Suggested wording for the denial matrix

> Freeze plane requires Linux ≥ 5.2 with cgroup-v2 unified hierarchy and a writable
> `cgroup.freeze`. Verified on 1 node (Kind `osramp-control-plane`, kernel 7.1.3, containerd
> 2.3.1). **Not verified against any production node pool.** Nodes below 5.2, or running a
> cgroup-v1 or hybrid hierarchy, have no freeze-plane enforcement — this is a hard absence of
> the primitive, not degraded performance.

---

## 4. What would close this

A per-node-pool probe recording, for every pool the fleet schedules agents onto:
`uname -r`, `stat -fc %T /sys/fs/cgroup`, and a write-probe of `cgroup.freeze` on a
transient cgroup (the engine's own `HealthCheck()` mkdir/rmdir already does exactly this and
is exposed at `/healthz`). Until that exists, the floor is a code-level requirement with a
single-node confirmation, and the denial matrix should say so.

**Related caveat, same class:** the freeze latency figures P5-2 will publish (p95 12 ms,
mean 13 ms under 100% CPU load) come from 10 cycles on this same single node. See
`sler-p4-gov-review.md` §3.1. And unfreeze-to-rotation latency is **unmeasured** — see §3.3
of that report. The mission's out-of-scope rule forbids claiming a latency figure not
measured at the stated fleet size; both caveats are that rule applied.
