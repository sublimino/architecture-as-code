# Signal Loom Warden: eBPF DNS & Kernel TLS Peeking Architecture Reference

## Executive Summary & Scope

Signal Loom Warden (`signalloom-warden`, runtime binary `stun-sentinel`) provides kernel-native DNS observability and TLS ClientHello Server Name Indication (SNI) peeking. Warden attaches eBPF Traffic Control (`tc`) filters to container host-side virtual ethernet (`veth`) interfaces. It intercepts, parses, and attributes domain resolutions and outbound encrypted connections without sidecar proxies or CoreDNS query logging.

Warden captures RFC 1035 DNS queries and responses at the network boundary. It binds ephemeral IP addresses back to canonical domain names when packets cross container interfaces. Joined with TLS handshake inspection and syscall telemetry, Warden performs real-time cross-checks. It detects direct-to-IP beaconing, domain fronting, SNI spoofing, and DGA reconnaissance before traffic leaves the node.

```mermaid
flowchart TB
  subgraph KERNEL["Linux Kernel (Host Network Stack)"]
    VETH["Container Host veth Interface"]
    CLSACT["clsact qdisc"]
    DROP["stun_tc_drop<br/>(Priority 49152/49153, Handle 1)<br/>Action: SHOT / OK"]
    MON["tc_monitor<br/>(Priority 49150/49151, Handle 2)<br/>Action: TC_ACT_OK"]
    RINGBUF["BPF Ringbuffer<br/>(4 MiB Capacity)"]
    
    VETH --> CLSACT
    CLSACT --> MON
    CLSACT --> DROP
    MON -.->|"DNS / TLS Events"| RINGBUF
  end

  subgraph USERSPACE["Warden Userspace Daemon (stun-sentinel)"]
    DECODER["Zero-Alloc BPF Event Decoders<br/>(pkg/ebpf)"]
    ATTR["Interface-to-Pod Attribution<br/>(ifindex -> veth -> netns -> cgroup)"]
    CACHE["DNSCache (LRU, TTL-aware)<br/>(pkg/correlator/dns_cache.go)"]
    HEUR["Appendix C Anomaly Engine<br/>(pkg/correlator/dns_heuristics.go)"]
    PFILT["Presentation Filter (-67% volume)<br/>(pkg/correlator/presentation_filter.go)"]
    PSEUDO["HKDF-SHA256 Pseudonymiser<br/>(pkg/correlator/pseudonymiser.go)"]
    
    RINGBUF --> DECODER
    DECODER --> ATTR
    ATTR --> CACHE
    ATTR --> HEUR
    CACHE --> HEUR
    HEUR --> PFILT
    PFILT --> PSEUDO
  end

  subgraph DOWNSTREAM["Downstream Pipeline"]
    INGEST["signal-ingest / FrostDB Store<br/>(Labels: domain_pseudonym, sni_pseudonym)"]
    PSEUDO --> INGEST
  end
```

---

## TC Attachment Model and Priority Coexistence

Warden attaches additive eBPF Traffic Control (`tc`) filters to container host-side virtual ethernet (`veth`) peers under the kernel `clsact` queuing discipline (qdisc). This mechanism ensures packet inspection without modifying container network namespaces or injecting iptables rules.

### Filter Priority and Handle Allocations

The monitoring filter (`tc_monitor`) coexists with Warden's containment filter (`stun_tc_drop`). It uses distinct filter preferences and handles from the Traffic Control priority space (`1..65535`).

| Subsystem | Program Symbol | Ingress Preference | Egress Preference | Netlink Handle | Action Verdict | BPF Map Pinning Path |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Containment Dropper** | `stun_tc_drop` | `49152` (`SentinelIngressPref`) | `49153` (`SentinelEgressPref`) | `1` (`netlink.MakeHandle(0, 1)`) | `TC_ACT_SHOT` (match) / `TC_ACT_OK` (fallthrough) | `/sys/fs/bpf/stun-sentinel` |
| **Additive Peeker** | `tc_monitor` | `49150` (`MonitorIngressPref`) | `49151` (`MonitorEgressPref`) | `2` (`netlink.MakeHandle(0, 2)`) | `TC_ACT_OK` (unconditional) | `/sys/fs/bpf/stun-sentinel/monitor` |

### Coexistence Rule and Containment Regression Proof

1. **Unconditional Pass-Through (`TC_ACT_OK`):** `tc_monitor` returns `TC_ACT_OK` for every packet, ensuring that inspection never drops, delays, or alters network traffic.
2. **Independent Filter Handles:** Attaching `tc_monitor` creates distinct filter entries on the shared `clsact` qdisc. Detaching `tc_monitor` removes only preferences `49150`/`49151`, leaving containment preferences `49152`/`49153` active.
3. **Isolated Map Pinning:** Monitor maps (`dns_events_ringbuf`, `monitor_stats`) are pinned under `/sys/fs/bpf/stun-sentinel/monitor`, preventing pin collisions with containment maps (`stun_isolation_map`, `stun_isolation_ip_map`) under `/sys/fs/bpf/stun-sentinel`.
4. **Verified Regression Invariant:** Automated tests `TestContainmentSurvivesMonitorAttach` and `TestLiveMonitorAndContainmentCoexistence` prove coexistence. Isolated workloads remain dropped while monitoring is attached.

---

## Interface-to-Pod Attribution Path

In Linux eBPF, Traffic Control (`tc`) filters execute within the softirq packet processing path and lack task or process context (`task_struct`). Calling `bpf_get_current_pid_tgid()` inside a TC program returns the arbitrary thread executing softirq, which corrupts process attribution.

Warden resolves actor identity exclusively through interface attribution in userspace:

```
[Packet at veth] -> [tc_monitor captures ifindex] -> [Ringbuffer event]
      │
      ▼
[HostInterfaceForPeer / sysfs mapping]
      │
      ▼
[Container netns /sys/class/net/eth0/iflink]
      │
      ▼
[cgroup.procs -> Container ID -> Pod Metadata (Name, Namespace, UID)]
      │
      ▼
[Join with cgroup-keyed syscall probes in reportConnect()]
```

### Attribution Workflow

1. **Kernel Packet Capture:** `tc_monitor.bpf.c` reads `skb->ifindex` and populates the `ifindex` field in `dns_event_t` or `tls_sni_event_t`.
2. **Reverse Interface Discovery:** The userspace resolver (`InterfaceIndexResolver` / `HostInterfaceForPeer` in `d2-signalloom/apps/stun-sentinel/pkg/tc/discover.go`) maps `ifindex` to the host `veth` interface name.
3. **Container Network Namespace Linkage:** Warden identifies container PIDs from `cgroup.procs`. It enters the container netns via `unix.Setns` and correlates `/sys/class/net/eth0/iflink` back to the host interface index.
4. **Syscall Stream Join:** Userspace correlation joins the interface-attributed domain resolution with the cgroup-attributed outbound socket `connect()` events captured by `sentinel_probe.c`.

---

## Dynamic In-Memory Resolution Cache (`DNSCache`)

Warden maintains an in-memory resolution cache (`DNSCache` in `d2-signalloom/apps/stun-sentinel/pkg/correlator/dns_cache.go`) to correlate subsequent network connections back to previous DNS queries.

### Architectural Invariants

- **Compound Keying:** Cache entries are keyed by `(pod_or_cgroup, ip)` to isolate namespace lookups across multi-tenant workloads.
- **Multi-Address Indexing:** For DNS responses containing multiple A/AAAA resource records (e.g. CDNs or cloud endpoints), `DNSCache` indexes every returned address against the query domain.
- **CNAME Alias Resolution:** Warden resolves CNAME alias chains (`qname -> cname`) up to a maximum depth of 16, mapping alias targets back to the canonical owning domain.
- **TTL-Aware Expiration:** Expiration is derived from the DNS record's own TTL rather than a fixed sliding window. Expiry is floored at 30 seconds (to tolerate brief network skew) and ceiled at 3,600 seconds (1 hour).
- **Bounded LRU Eviction:** The cache enforces a bounded capacity with Least-Recently-Used (LRU) eviction to prevent memory exhaustion under query floods. Eviction counters are exported as Prometheus metrics.

---

## Anomaly Detection Heuristics Matrix (Appendix C)

Warden implements five core anomaly heuristics in `d2-signalloom/apps/stun-sentinel/pkg/correlator/dns_heuristics.go`. Each heuristic is designed with strict false-positive exclusions to prevent alert fatigue.

| Scenario | Detection Condition | Must Not Fire On (Exclusions) | Severity | Reaction & Lifecycle |
| :--- | :--- | :--- | :--- | :--- |
| **Direct IP Outbound Egress** | `connect()` to an external IP with no matching entry in `DNSCache` across all unexpired records for that pod. Expiry uses record TTL (30s floor, 3600s ceiling). | - Secondary or tertiary IPs of multi-answer CDN records.<br/>- Persistent keep-alive connections outliving short TTLs.<br/>- Workloads active before Warden daemonset startup. | **CRITICAL** | Emits `anomaly=direct_ip_egress` security alert. Optional Tier 0 automated containment trigger. |
| **DNS vs. TLS SNI Mismatch** | Target IP is in `DNSCache` for domain A, but ClientHello SNI specifies domain B, where neither is a CNAME alias of the other. | - Valid CNAME alias chains (`app.example.com` → `cdn.cloudflare.net`).<br/>- Shared virtual hosts resolving to identical IP endpoints.<br/>- Packets where `parse_status != TLS_CH_OK`. | **CRITICAL** | Emits `anomaly=dns_sni_mismatch` security alert flagging potential domain fronting or SNI spoofing. |
| **Non-Cluster DNS Resolver** | DNS query destination `resolver_addr` does not match dynamically discovered cluster DNS resolvers or NodeLocal cache. Zero hardcoded IP addresses. | - Clusters where DNS Service IP is non-standard (not `10.96.0.10`).<br/>- Pods with custom `dnsConfig.nameservers` overrides.<br/>- Local NodeLocal DNSCache instances (`169.254.20.10`). | **WARN** | Emits `anomaly=non_cluster_dns` alert capturing target resolver IP to flag DNS policy evasion. |
| **NXDOMAIN Burst / DGA** | More than 10 NXDOMAIN responses for distinct domain names from a single pod within a 10-second window. | - Repeated retry loops querying one unresolvable domain.<br/>- Normal search-domain expansion (`domain.cluster.local`, `domain.svc...`). | **WARN** | Emits `anomaly=nxdomain_burst` alert flagging automated reconnaissance or Domain Generation Algorithms. |
| **Unparsed Capture** | Packet parse status indicates truncation (`DNS_PARSE_TRUNCATED`), name overflow, pointer loop, or `TLS_CH_SEGMENTED`/`TLS_CH_MALFORMED`, or ringbuffer drops. | — Never suppressed. Blind spots are explicitly surfaced. | **WARN** | Increments `unparsed_capture_total` metric. Ensures unparsed traffic is never silently treated as absent. |

### Dynamic Resolver Discovery

Warden avoids hardcoding DNS Service IPs (such as `10.96.0.10`). Resolvers are discovered dynamically at runtime via:
1. Pod resolver configuration (`/etc/resolv.conf` nameservers).
2. Kubernetes CoreDNS Service API lookup (`kube-system/kube-dns`).
3. NodeLocal DNSCache listener detection.

---

## Presentation Filter and Privacy Contract

To prevent telemetry floods into downstream storage (`signal-ingest` / FrostDB), Warden applies a 3-tier presentation filter and strict cryptographic pseudonymisation before emitting observations.

### Presentation Filter Deduplication

The presentation filter (`pkg/correlator/presentation_filter.go`) suppresses routine duplicate queries while preserving immediate alerting:
- **Tier 1 (Anomalies):** All anomaly events (direct IP, SNI mismatch, non-cluster resolver, NXDOMAIN burst) are emitted **immediately and unconditionally**.
- **Tier 2 (First Encounter):** The first occurrence of a domain resolution from a pod is emitted immediately to record network topology.
- **Tier 3 (Routine Duplicates):** Repeated resolutions for the same domain within its TTL are suppressed, refreshing only upon TTL expiration.
- **Measured Reduction:** Achieves a measured **67.00% reduction** in raw event volume on standard workloads.

### Cryptographic Pseudonymisation Contract

In compliance with data minimization and zero-cleartext telemetry policies (Milestone 3 / P3-2):

```
Raw FQDN / SNI String
        │
        ▼
[HKDF-SHA256 Key Derivation]
  ├── Domain: signalloom/identity/alias-pseudonym/v1
  ├── Secret: SIGNAL_SEGMENT_PSEUDONYM_KEY (>= 32 bytes, fail-closed)
  └── Epoch:  SIGNAL_SEGMENT_PSEUDONYM_EPOCH
        │
        ▼
[HMAC-SHA256 Output -> Hex Digest]
        │
        ▼
Emitted Observation Labels:
  - domain_pseudonym: "4f8a9b..."
  - sni_pseudonym:    "d3c2e1..."
(Cleartext `domain` and `sni` fields are strictly forbidden on wire and in store)
```

Byte-for-byte replay equality across successive analysis runs is verified via `TestReplay_EqualsLiveWithDomainPseudonym`.

---

## Measured Performance & KPI Benchmarks

Key Performance Indicators (KPIs) measured on the reference host development kernel (`7.1.3+deb13-amd64`) demonstrate sub-microsecond latency and strict memory bounding:

| KPI Metric | Target Threshold | Measured Performance | Test Command & Probe | Evaluation |
| :--- | :--- | :--- | :--- | :--- |
| **Decoder Throughput Per Core** | > 50,000 events/sec/core (0 allocs/op) | **DNS: 7.758 ns/op (128.9M events/s/core, 0 allocs/op)**<br/>**TLS: 3.771 ns/op (265.2M events/s/core, 0 allocs/op)** | `go test -bench=BenchmarkDecode -benchmem ./pkg/ebpf/...` | **met** |
| **Added Packet Parse Latency** | ≤ 1.5 µs per packet at container veth | **Attached vs Detached Traversal:**<br/>- Baseline Detached: 2113 ns/op<br/>- Attached DNS: 2084 ns/op<br/>- Attached TLS: 2052 ns/op<br/>Parse latency delta: **< 0.1 µs (< 100 ns)** | `go test -bench=BenchmarkPacketTraversal -benchmem ./pkg/tc/...` | **met** |
| **Warden Memory Bound Under Load** | Bounded RSS under flood / < 64 MiB total RSS | **Baseline VmRSS:** 18.08 MiB<br/>**Peak Flood VmRSS:** 22.61 MiB (50,000 event ringbuffer flood)<br/>**Steady-State VmRSS:** 22.61 MiB (HeapAlloc: 577 KiB, Net: +4.53 MiB) | `go test -v -run=TestRingbufferFlood ./pkg/tc/...` | **met** |
| **Telemetry Ingest Overhead** | ≤ 5% volume overhead / > 50% suppression | **67.00% volume reduction** on synthetic resolution sequences (1,000 raw events -> 330 emitted events) | `go test -v -run=TestPresentationFilter ./pkg/correlator/...` | **met** |

---

## Operator Runbook & Diagnostic Procedures

### 1. Verifying Filter Attachment

Check that `tc_monitor` and `stun_tc_drop` filters are active on the host veth peer:

```bash
# Inspect ingress filters on target interface
tc filter show dev vethxxxx ingress

# Inspect egress filters on target interface
tc filter show dev vethxxxx egress
```

Expected output confirms both preferences attached under `clsact`:
- `pref 49150` (or `49151`): `handle 0x2 bpf ... [tc_monitor]`
- `pref 49152` (or `49153`): `handle 0x1 bpf ... [stun_tc_drop]`

### 2. Inspecting Pinned BPF Maps and Drop Counters

Inspect pinned BPF maps using `bpftool`:

```bash
# List pinned monitor maps
bpftool map show pinned /sys/fs/bpf/stun-sentinel/monitor/dns_events_ringbuf
bpftool map show pinned /sys/fs/bpf/stun-sentinel/monitor/monitor_stats

# Dump drop counters and parsing metrics
bpftool map dump pinned /sys/fs/bpf/stun-sentinel/monitor/monitor_stats
```

### 3. Triage Workflows

1. **Direct IP Alert (`anomaly=direct_ip_egress`):**
   - Query if the destination is an external IP (non-RFC 1918).
   - Check `unparsed_capture_total` to verify if DNS resolution was dropped due to ringbuffer saturation.
   - Cross-reference with pod startup timestamp to check if the connection was established before Warden attachment.
2. **DNS/SNI Mismatch (`anomaly=dns_sni_mismatch`):**
   - Check if destination domain uses third-party CDN hosting or multi-tenant ingress.
   - Inspect CNAME alias depth in `DNSCache`.
   - If no CNAME or shared host exists, investigate for potential domain fronting or TLS egress evasion.
3. **Non-Cluster DNS Alert (`anomaly=non_cluster_dns`):**
   - Inspect pod `dnsConfig` in Kubernetes manifest.
   - Confirm if target IP is an external public resolver (`8.8.8.8`, `1.1.1.1`) indicating policy bypass.

---

## Limitations & Unverified Scope

In accordance with Scope Summary Constraint 3 and verified errata records, the following boundaries and unverified items are explicitly documented:

1. **Encrypted Client Hello (ECH):**
   - When TLS 1.3 Encrypted Client Hello (ECH) is negotiated, the outer ClientHello SNI is a generic fronting domain while the inner SNI is encrypted. Warden peeks the outer SNI only. Inspecting the encrypted inner SNI in eBPF is cryptographically impossible without TLS termination keys.
2. **DNS over HTTPS (DoH) / DNS over TLS (DoT):**
   - Workloads issuing encrypted DNS queries over port 443 (DoH) or port 853 (DoT) bypass port 53 UDP/TCP packet inspection. Warden detects these connections as Direct IP egress or non-cluster DNS connections rather than parsing internal query payloads.
3. **Segmented ClientHello (segmented ClientHello):**
   - eBPF TC filters execute per packet without multi-packet TCP stream reassembly. A TLS ClientHello spanning multiple TCP segment boundaries (a segmented ClientHello) cannot be parsed in kernel space. Warden flags this condition with parse status `TLS_CH_SEGMENTED` and surfaces it as an unparsed capture metric.
4. **Multi-Kernel CI Matrix Coverage (Unverified Status):**
   - Verification was executed against the host development kernel (`7.1.3+deb13-amd64`).
   - The multi-kernel CI workflow is authored at `.github/workflows/warden-ebpf-multi-kernel.yaml`. It targets Ubuntu 22.04 (`5.15`), Ubuntu 24.04 (`6.8`), Debian 12 (`6.1`), Debian 13 (`7.1`), COS (`6.6 LTS`), and Bottlerocket (`6.1-aws`).
   - **Per Scope Summary constraint 3, execution across non-host kernels in the matrix remains unverified by this board** until dedicated multi-kernel bare-metal CI runners are provisioned.
