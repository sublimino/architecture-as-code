# Tetragon Telemetry Pipeline

**Card:** CRKC-P1-4 · **Status:** implemented, live confirmation deferred to CRKC-P1-GOV

Tetragon is a **telemetry producer** in Signal Loom. It does not enforce anything.

---

## 1. Why Tetragon is decoupled from enforcement

The earlier design note `docs/signalloom/ebpf-enforcer-spec.md` describes Tetragon as "the primary
kernel-level enforcement engine", issuing an LSM `Override` that returns `EACCES` on service-account
token reads. That position is withdrawn. Three reasons, in order of severity:

**A killed process is not evidence.** Tier 0 containment (CRKC-P1-2, CRKC-P1-3) works by *freezing* a
cgroup and dropping its packets at the host veth. The workload stops but stays intact and inspectable —
that is the entire product argument for forensic containment. A Tetragon `Sigkill` racing the freezer
destroys the process state the freeze exists to preserve, and does so non-deterministically, because
which one wins depends on scheduler timing.

**Two enforcers on one LSM hook is a stability problem.** Tetragon's `Override` and the Tier 0 path both
install BPF programs against overlapping kernel paths. Hook contention between independent enforcers is
a documented source of node instability, and the failure surfaces as a kernel-level symptom that looks
nothing like its cause.

**An observed violation is worth more than a blocked one.** Signal Loom's value is pricing risk, not
silently denying syscalls. A blocked token read produces one `EACCES` the agent may handle and retry.
An *observed* token read produces an evidence record that flows into FAIR loss-event frequency. The
former hides the signal; the latter is the product.

So: Tetragon observes, `stun-sentinel` acts.

### How this is enforced rather than merely stated

`test/tetragon-telemetry-stream.bats` fails the build if `d2-signalloom/deploy/tetragon-agent-telemetry.yaml`
gains any of `Sigkill`, `Override`, `NotifyEnforcer`, an `action: Signal`, or a `matchActions:` block.
The manifest also carries `signalloom.io/enforcement: disabled` on every document, so the position is
queryable with `kubectl get tracingpolicynamespaced -l signalloom.io/enforcement=disabled` rather than
inferable from the absence of something.

---

## 2. Tracepoint and kprobe schema

Three policies, applied per namespace to `fe-signalloom-agents` and `kagent`. Every policy is
`TracingPolicyNamespaced` and additionally gated on `podSelector: signalloom.io/observed: "true"`.
Cluster-wide tracing is not merely discouraged here — an unscoped `sys_enter_execve` on a single-node
kind cluster starves the node with events from kube-system, Cilium, and the container runtime itself.

| Policy | Hook | Kind | Arguments captured | Filter |
|---|---|---|---|---|
| `agent-execve-audit` | `syscalls/sys_enter_execve` | tracepoint | `[5] filename (string)` | non-host PID namespace |
| `agent-tcp-connect-audit` | `tcp_connect` | kprobe | `[0] sock` | — |
| `agent-sensitive-file-audit` | `syscalls/sys_enter_openat` | tracepoint | `[5] dfd (int)`, `[6] filename (string)` | `Prefix` match on credential paths |

The openat filter is scoped to `/var/run/secrets/kubernetes.io/serviceaccount`, `/run/secrets`,
`/etc/shadow`, `/root/.ssh`, and `/var/run/cilium/tetragon`. Unfiltered `openat` is the highest-volume
tracepoint on a busy node and will saturate the ring buffer on its own.

> **Argument indices are kernel-version-dependent.** They are ABI-stable within a kernel release but not
> across them. Validate at install time against
> `/sys/kernel/debug/tracing/events/syscalls/sys_enter_openat/format`. The indices above are correct for
> the 6.x series kind's node image ships.

---

## 3. Export contract

| Property | Value |
|---|---|
| gRPC service | `tetragon.FineGuidanceSensors/GetEvents` |
| Socket | `unix:///var/run/cilium/tetragon/tetragon.sock` |
| JSON export | `/var/run/cilium/tetragon/tetragon.log`, newline-delimited |
| Protobuf API | `github.com/cilium/tetragon/api` **v1.1.0**, pinned exactly |
| Helm chart | `cilium/tetragon` **1.1.0** |

The socket path appears in three places — `tetragon-helm-values.yaml`, the
`tetragon-telemetry-contract` ConfigMap, and `ebpf.DefaultSocketPath`. Drift between them is silent (the
collector dials a path nothing serves and reports a connection error indistinguishable from Tetragon
being down), so a BATS test asserts all three agree.

The API pin is not cosmetic. A chart/API version skew changes the wire format of `GetEventsResponse`,
which is the failure mode the pin exists to prevent. The JSON decoder sets `DiscardUnknown` so an agent
one *minor* version ahead still decodes into everything we understand; a renamed or retyped field still
fails loudly.

---

## 4. Data path

```
Tetragon agent (DaemonSet, kube-system)
  │
  ├─ gRPC  FineGuidanceSensors/GetEvents  ── unix socket
  └─ JSON  tetragon.log                   ── newline-delimited
        │
        ▼
  ebpf.StreamClient          reconnects, capped exponential backoff + deterministic jitter
        │
        ▼
  ebpf.Normalizer            Tetragon event → netebpf.InboundFlowEvent, per-node SeqNum
        │
        ▼
  ebpf.RingBuffer            bounded (4096), drop-oldest, counted
        │
        ▼
  netebpf.LiveNetworkEgressCollector   ← unchanged; gap detection works as-is
        │
        ▼
  collectors.IngestionSink → FrostDB
```

The reader goroutine and the drain goroutine are separate on purpose: the kernel-facing reader must
never block on a slow FrostDB write. That is the entire reason a bounded buffer sits between them.

---

## 5. Normalisation into `InboundFlowEvent`

The canonical schema is **not modified**. Tetragon events normalise *into* the existing
`netebpf.InboundFlowEvent`; an anti-criterion test counts its fields and fails if one is added or
removed, because the SFDP-P2-4 contract and every sibling fixture depend on that struct being stable.

| `InboundFlowEvent` field | Source |
|---|---|
| `NodeName` | `GetEventsResponse.node_name` |
| `Time`, `TimestampNs` | `GetEventsResponse.time` (both, from one source) |
| `SeqNum` | **synthesised** — strictly monotonic per node |
| `Provider` | literal `"tetragon"` |
| `PodName`, `PodNamespace` | `Process.pod.name` / `.namespace` |
| `PodUID` | `pod_labels["signalloom.io/pod-uid"]`, falling back to container id |
| `ServiceAccount` | `pod_labels["signalloom.io/service-account"]` |
| `AgentRole`, `SPIFFEID` | `pod_labels["signalloom.io/agent-role"]` / `["…/spiffe-id"]` |
| `CgroupID` | FNV-1a hash of `Process.docker` |
| `SrcIP`/`DstIP`/`SrcPort`/`DstPort`/`Family`/`SockCookie` | `KprobeArgument.sock_arg` |
| `Domain` | executed binary (exec) or accessed path (file) |
| `Classification` | `process_exec` \| `network_connect` \| `file_access` \| `unattributed` |

### Two things that are not obvious

**Tetragon v1.1.0 has no pod UID and no service account.** Its `Pod` message carries exactly six fields:
`namespace`, `name`, `container`, `pod_labels`, `workload`, `workload_kind`. The canonical schema wants
both a UID and an SA, so they are recovered from well-known pod labels, which Tetragon propagates when
`tetragon.enableK8sAPI: true`. If the labels are absent the fields are empty and the event is **still
ingested** — absence degrades attribution, it never drops evidence. `PodUID` falls back to the container
id rather than an empty string, because an empty UID is shared by every unattributed event in the
cluster and would collapse them into one identity-graph node.

**`SeqNum` is synthesised, not read.** Tetragon's wire format has no sequence field, but the existing
`netebpf` gap detector finds telemetry holes by looking for discontinuities in `SeqNum` per node. The
normaliser supplies a strictly monotonic per-node counter, which is what lets that detector work
unchanged against a Tetragon-sourced stream — including detecting drops our own ring buffer reports.

An event with **no** pod metadata is classified `unattributed` and ingested anyway. A syscall we cannot
place is exactly what an escaped workload produces; filtering it would blind us to the case the control
exists for.

---

## 6. Backpressure and the drop policy

| Property | Value |
|---|---|
| Structure | fixed-capacity circular buffer |
| Default capacity | 4096 (`TETRAGON_RING_CAPACITY` to override) |
| Policy on overflow | **drop-oldest**, counted |
| Blocking | `Push` never blocks and never grows the backing array |

Drop-oldest rather than drop-newest: under sustained overrun the newest events describe what the
workload is doing *now*, which is what a containment decision needs. And refusing the write instead
would make the buffer a bottleneck on the kernel reader — the opposite of its purpose.

Every drop increments `tetragon_events_dropped_total`. A silently dropped telemetry event is a hole in
the evidence chain that nothing downstream can detect.

---

## 7. Metrics

Prometheus text exposition, sorted for byte-stable output.

| Metric | Meaning |
|---|---|
| `tetragon_events_received_total` | events read off the stream, pre-filter |
| `tetragon_flow_events_ingested_total` | events normalised and accepted downstream |
| `tetragon_events_dropped_total` | events discarded by the drop policy |
| `tetragon_stream_errors_total` | gRPC failures, reconnects, undecodable JSON lines |
| `tetragon_events_skipped_total` | well-formed events with no normalisable payload |

`skipped` exists so that a quiet stream is distinguishable from a broken normaliser. Without it,
`received` would climb while `ingested` stayed flat and there would be no way to tell which.

---

## 8. Configuration

| Variable | Default | Purpose |
|---|---|---|
| `COLLECTOR_TETRAGON_MODE` | `off` | `live` \| `fixture` \| `off` |
| `TETRAGON_SOCKET_PATH` | `/var/run/cilium/tetragon/tetragon.sock` | gRPC export socket |
| `TETRAGON_RING_CAPACITY` | `4096` | bounded buffer size |
| `TETRAGON_NAMESPACES` | *(unset — no restriction)* | comma-separated namespace allow-list |

`off` by default matches every sibling collector: a collector that started dialling a socket merely
because the binary was upgraded would be a surprise in production.

`TETRAGON_NAMESPACES` is defence in depth behind the TracingPolicy scoping. If a cluster-wide policy is
ever applied by mistake, the collector still refuses out-of-contract namespaces rather than flooding the
store. Unattributed events pass the filter regardless — see above.

---

## 9. Verification

```bash
# Go unit suite — 33 tests, offline
make test-tetragon

# End-to-end stream harness — mock gRPC server → real collector → /metrics
scripts/test-tetragon-stream.sh 1000

# Full structural + stream BATS suite
bats test/tetragon-telemetry-stream.bats
```

Everything above runs **offline**. There is no cluster-gated skip anywhere in the suite: a suite that
skips its way to green is indistinguishable from one that passes, and the point of this card is that the
contract is provable before Tetragon exists.

The offline harness is not a stub. It drives `ebpf.MockTetragonServer`, which implements the genuine
generated `FineGuidanceSensors` service, so events traverse real protobuf marshalling and real gRPC
framing over a real unix socket. The only thing absent is the kernel.

Evidence lands in `docs/signalloom/evidence/tetragon-stream-proof.json`.

---

## 10. Install (not performed by this card)

Tetragon is **not installed** into `kind-osramp` by CRKC-P1-4. Three sibling cards were operating eBPF
programs against that cluster concurrently, and introducing a second eBPF DaemonSet with BPF-LSM hooks
mid-flight risks exactly the kernel contention this card exists to prevent. Live confirmation is
CRKC-P1-GOV's.

```bash
helm repo add cilium https://helm.cilium.io
helm -n kube-system upgrade --install tetragon cilium/tetragon --version 1.1.0 \
  -f d2-signalloom/deploy/tetragon-helm-values.yaml

kubectl apply -f d2-signalloom/deploy/tetragon-agent-telemetry.yaml

# Label the workloads to be observed — the podSelector gate.
kubectl -n fe-signalloom-agents label pod -l app=agent signalloom.io/observed=true

# Readiness signal.
kubectl -n kube-system logs -l app.kubernetes.io/name=tetragon -c tetragon \
  | grep 'Listening on /var/run/cilium/tetragon/tetragon.sock'
```

Then flip the collector on:

```bash
kubectl -n inf-signalloom set env deploy/signal-ingest \
  COLLECTOR_TETRAGON_MODE=live \
  TETRAGON_NAMESPACES=fe-signalloom-agents,kagent
```

### Live-confirmation checklist for CRKC-P1-GOV

1. `kubectl -n kube-system logs -l app.kubernetes.io/name=tetragon -c tetragon` shows the listening line
   and **no LSM denial or enforcement-collision errors**.
2. `tetragon_events_received_total > 0` on the signal-ingest `/metrics` endpoint.
3. `tetragon_events_dropped_total == 0` under a `kubectl exec` + `curl` burst.
4. `go test -race ./collectors/ebpf/...` — deferred here because the build sandbox denies `/usr/include`
   to the cgo compiler, and the race detector requires cgo. This is a pre-existing environment
   constraint, not a property of this code; it breaks `test/netebpf-adversarial.bats` identically.
