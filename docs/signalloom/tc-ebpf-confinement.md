# TC eBPF Confinement — Tier 0 Host-Side Network Severance

> **Card:** CRKC-P1-3 · **Component:** `d2-signalloom/apps/stun-sentinel`
> **Evidence:** [`evidence/tc-drop-proof.json`](evidence/tc-drop-proof.json)
> **Suite:** `test/tc-ebpf-drop.bats` · **Benchmark:** `test/bench-tc-drop.sh`

## 1. Why this exists

Signal Loom can already mark an agent pod as stunned at the Kubernetes configuration layer (labels plus Flux `spec.ignore`, CRKC-P1-1) and freeze its cgroup so no userspace instruction executes (CRKC-P1-2). Neither of those severs the network.

A frozen process still holds its established TCP sessions. The sockets survive in the kernel, conntrack still lists the flows, and the moment the freeze lifts — or if the freeze is partial, racy, or applied to the wrong cgroup — the in-flight request resumes and half-written exfiltration completes. Freezing stops the agent from *deciding* to send more; it does not stop what the kernel has already accepted responsibility for.

This component closes that gap. It is the packet-path half of Tier 0 containment: every packet on a specific container's veth is destroyed in both directions, and the conntrack entries that would let a stalled flow resume are deleted.

## 2. Architecture

```
  host netns                                pod netns
                                     ┌──────────────────┐
   ┌──────────────┐                  │                  │
   │  veth-host   │══════════════════│     eth0         │
   │  (peer idx N)│                  │  10.244.0.7      │
   └──────┬───────┘                  │                  │
          │                          └──────────────────┘
     clsact qdisc
          │
    ┌─────┴──────┐
    │  ingress   │ pref 49152 ─┐
    │  egress    │ pref 49153 ─┤── both run stun_tc_drop (direct-action)
    └────────────┘             │
                               ▼
                   ┌────────────────────────┐
                   │  stun_isolation_map    │  key: ifindex
                   │  stun_isolation_ip_map │  key: __be32 IPv4
                   └────────────────────────┘
                     pinned at /sys/fs/bpf/stun-sentinel
```

### The lifetime split — the reason sub-100ms is honest

Two operations with very different costs are deliberately kept apart:

| Operation | Cost | When |
|---|---|---|
| `Attach` / `Detach` | Verifier runs, qdisc and filters created | Once, at pod adoption |
| `Isolate` / `Release` | **A single BPF map write** | On the stun critical path |

Isolation is not "load a program and attach it quickly". It is a hash-map `Put` against a program that has been sitting on the interface doing nothing since adoption. That is why the measured activation is ~5 ms and stays there under a million packets per second: the expensive work already happened.

An attached-but-not-isolated filter costs one hash lookup per packet and returns `TC_ACT_OK`.

### Why conntrack must also be flushed

Dropping packets does **not** terminate an established TCP session. The conntrack entry survives, both peers retransmit with exponential backoff, and the flow resumes intact if the filter is ever removed. Deleting the conntrack entry makes the kernel treat every subsequent segment as `INVALID`, so the flow cannot resume.

The flush is **by exact tuple**, never `conntrack -F`. A table-wide flush would destroy every unrelated flow on the node and hold a global lock long enough to show up as interrupt latency. `pkg/tc/conntrack.go` dumps the table over `NETLINK_NETFILTER`, filters in userspace, and deletes only tuples where the target IP is either endpoint — both directions, because an egress flow carries the container in `SrcIP` and an ingress flow carries it in `DstIP`.

## 3. Files

| Path | Role |
|---|---|
| `bpf/tc_drop.bpf.c` | The classifier. `SEC("classifier/drop")`, returns `TC_ACT_SHOT` on match. |
| `bpf/tc_drop.bpf.o` | Compiled BTF-bearing ELF, **committed**. |
| `bpf/build.sh` | Compiles the ELF in the pinned container. |
| `bpf/Dockerfile.builder` | Pinned clang/llvm/bpftool/iproute2/conntrack toolchain. |
| `bpf/scenario.sh` | The live experiment. Measures; asserts nothing. |
| `pkg/tc/loader.go` | qdisc + filter lifecycle, isolate/release, stats. |
| `pkg/tc/conntrack.go` | Hand-rolled `NETLINK_NETFILTER` tuple deletion. |
| `pkg/tc/discover.go` | pod netns → host veth resolution by exact peer index. |
| `pkg/tc/metrics.go` | Prometheus exposition, sourced from the BPF map. |
| `cmd/stun-tcctl/` | CLI and HTTP trigger endpoints. |
| `test/tc-ebpf-drop.bats` | The assertions. |
| `test/bench-tc-drop.sh` | Activation latency under load. |
| `scripts/test-tc-ebpf.sh` | Orchestrates the containerised live run. |

## 4. Building

The build host needs **docker and Go — not clang**. The compiled object is committed, so ordinary consumers just `go build`.

```bash
d2-signalloom/apps/stun-sentinel/bpf/build.sh     # rebuild the ELF
cd d2-signalloom/apps/stun-sentinel && go build ./...
```

`build.sh` compiles with `-O2 -g -Wall -Wextra -Werror` and verifies the result carries `EM_BPF`, `.BTF`, `.BTF.ext` and the `classifier/drop` section.

> **A note on loop checking.** Do not add a `grep "goto -"` loop guard to the build. The compiler emits backward branches to *shared epilogue blocks* — this object contains 18 of them and the source has no loop at all. Such a grep would fail a correct program, and would equally pass one whose loop had been unrolled forwards. The authoritative oracle for loop safety is the in-kernel verifier, which rejects unbounded loops outright; that check runs for real in the BATS suite.

## 5. Operating

```bash
stun-tcctl attach  --interface veth123                      # adopt (verifier runs)
stun-tcctl isolate --interface veth123 --ip 10.244.0.7      # sever  (map write)
stun-tcctl status  --interface veth123 --json               # drop counters
stun-tcctl release --interface veth123 --ip 10.244.0.7      # restore
stun-tcctl detach  --interface veth123                      # remove filters
stun-tcctl serve   --addr :8082                             # HTTP trigger + /metrics
```

Trigger endpoints are **POST only** — a GET that mutates kernel state would be reachable by any prefetcher on the node network.

```
POST /v1/isolate?interface=veth123&ip=10.244.0.7
POST /v1/release?interface=veth123&ip=10.244.0.7
GET  /metrics
```

### Required capabilities

`CAP_NET_ADMIN` and `CAP_BPF` (or `CAP_SYS_ADMIN` on older kernels), plus `hostNetwork: true` and a `/sys/fs/bpf` mount. A missing capability surfaces as `ErrPermission`, distinct from every other failure, because the remedy is a securityContext change rather than a retry.

## 6. Safety properties

**Attachment is refused for non-veth devices.** This is the highest-consequence guard in the component: an unconditional drop filter on `eth0` takes the node off the network with no in-cluster recovery path. The check is an **allowlist** of container-veth prefixes (`veth`, `lxc`, `cali`, `cni`, `eni`, `azv`, `tap`, `vethwe`) plus an explicit denylist, and it fires **before any kernel call** — a refusal means nothing was attached, not that something was attached and undone.

**Ingress and egress attach together.** An egress failure rolls the ingress attach back. A half-attached interface is worse than an unattached one: it drops replies while permitting exfiltration, and it reads as "isolated" to any check that looks at one direction.

**The clsact qdisc is never removed.** It is shared infrastructure that a CNI may also be using. `Detach` removes only the two Sentinel filters, identified by exact `pref`.

**Release and Detach are fail-open and idempotent.** Every step is attempted even after an earlier one fails, and failures are aggregated rather than short-circuiting, because a stuck filter is a production outage. Deleting an absent map key is success.

**Maps are pinned to bpffs** so isolation survives a Sentinel restart. If the daemon is OOM-killed while a hostile agent is severed, an unpinned map would be destroyed with it and the agent would silently return to the network. Where bpffs is unavailable the loader falls back to unpinned maps and reports it through `Pinned()` — a Sentinel that refuses to start is strictly worse than one whose isolation does not survive a restart.

## 7. Measured results

From `evidence/tc-drop-proof.json`, on Linux 7.1.3:

| Property | Measured |
|---|---|
| Positive control (path live before isolation) | ✅ 5 lines received |
| clsact + ingress + egress filters attached | ✅ all three |
| Program type / name | `sched_cls` / `stun_tc_drop` |
| Isolate call latency | **9 ms** wall, 4.50 ms reported |
| Established stream last-byte gap | **0 ms** (budget: <100 ms) |
| Reachable after isolation | ❌ (correct) |
| Packets / bytes destroyed | 20 / 2,114 |
| Conntrack entries for target IP | 1 → **0** |
| Reachable after release | ✅ |
| Filters after detach | none |
| Activation under load | **12 ms** at **1,080,213 pps** (target 50,000) |

### How severance is measured, and why not the obvious way

Severance is measured as the gap between the isolate call returning and the **last byte** that arrived on a continuously-flowing stream.

It is *not* measured as "the socket returned an error", because an established TCP connection whose packets are dropped does not fail fast — the kernel retransmits with exponential backoff for minutes. A test asserting that `nc` exits within 100 ms would fail against a perfectly working drop filter and pass against a dead server. What happens within 100 ms, and what actually matters for containment, is that data stops moving.

## 8. Test doctrine

Three failure shapes the suite is built to exclude:

**A control the failure mode also satisfies.** "The connection timed out" is satisfied by a dead server, a wrong address and a working filter alike. So the suite runs a **positive control first** — proving the path was live — and treats a control failure as fatal to every downstream conclusion rather than as one test among sixteen.

**A check that never ran looking like a check that passed.** Every field in the evidence document defaults to JSON `null`, never to `0` or `false`, so an unexecuted step is distinguishable from a measured negative. Missing docker is a hard failure, **not a `skip`** — bats renders a skip as `ok N # skip`, which `grep -c '^ok '` counts as a pass. The final test asserts the suite's own declared test count, because a `.bats` file with a conflict marker stops loading and its tests vanish from the tally instead of failing.

**Absence mistaken for enforcement.** Unreachability alone proves nothing, so severance is corroborated by the eBPF drop counter read out of the BPF map.

### What the mutation test established

Flipping `TC_ACT_SHOT` to `TC_ACT_OK` in the C source, rebuilding, and re-running the suite turned tests **8** (stream stops <100 ms) and **13** (conntrack reaches zero) red while the other fourteen stayed green. The severance assertions are falsifiable.

It also falsified a claim in the original comments, which is recorded here because it changes how the evidence should be read: **the drop counter still incremented under the mutant.** `account_drop()` runs before the verdict is returned, so the counter proves the classifier *executed against real traffic on this interface* — not that it *destroyed* the packet. All three assertions are kept: the counter localises the effect to our program, tests 8 and 13 prove the packets actually died.

## 9. Relationship to the rest of Tier 0

Per shared pattern SP-2, containment has two tiers. This component is **Tier 0, packet path**:

| Tier | Control | Card |
|---|---|---|
| 0 — kernel execution state | cgroup-v2 freeze | CRKC-P1-2 |
| 0 — kernel packet path | **eBPF TC drop + conntrack flush** | **CRKC-P1-3** |
| 1 — Kubernetes config state | Flux `spec.ignore` label survival | CRKC-P1-1 |

Neither Tier 0 control is visible to the API server, which is the point: they hold even when the control plane is compromised or unreachable.

### Note on module layout

This ships as an **independent Go module** at `d2-signalloom/apps/stun-sentinel`, separate from the existing `d2-signalloom/apps/signalloom-stun-sentinel` daemon that owns the cgroup-freeze half. That is the path the card names, and it avoids a `go.mod` dependency collision with CRKC-P1-2, which was in flight concurrently. Unifying the two entrypoints is a Governor concern; the packages are already modular and the CLI is the integration seam.

The sibling daemon's `network.go` retains an iproute2 `matchall action drop` path. This component supersedes it functionally — it adds per-IP targeting, drop telemetry, and conntrack invalidation, none of which `matchall` provides — but it does not remove it, because that file belongs to another card.

## 10. Reproducing

```bash
scripts/test-tc-ebpf.sh --out docs/signalloom/evidence/tc-drop-proof.json
bats test/tc-ebpf-drop.bats
test/bench-tc-drop.sh --flooders 8 --seconds 5
cd d2-signalloom/apps/stun-sentinel && go test ./... && go vet ./...
```

The BATS suite re-runs the live experiment by default. To assert against a previously captured artifact without docker, set `TC_DROP_EVIDENCE=/path/to/proof.json`.
