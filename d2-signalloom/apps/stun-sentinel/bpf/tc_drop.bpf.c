// SPDX-License-Identifier: GPL-2.0
// Copyright 2026 ControlPlane Security Authors
//
// tc_drop.bpf.c — Tier 0 host-side network severance for stunned agent pods.
//
// Attached to the clsact qdisc of a container's HOST-SIDE veth peer, on both
// the ingress and the egress hook. When an isolation entry exists for the
// interface (or for the container's IPv4 address), every packet returns
// TC_ACT_SHOT and is destroyed by the kernel before it reaches the network
// stack proper. When no entry exists the program returns TC_ACT_OK and the
// packet takes its normal path, so an attached-but-not-isolated filter is a
// no-op with a single hash lookup of overhead.
//
// The design deliberately separates two lifetimes:
//
//   attach/detach  — expensive, involves the verifier, happens once when the
//                    Sentinel adopts a pod.
//   isolate/release — a single map update, happens on the stun critical path.
//
// That split is what makes the sub-100ms severance budget honest: at stun time
// the kernel work is one hash-map write, not a program load.
//
// Verifier contract (see docs/signalloom/tc-ebpf-confinement.md):
//   * no loops of any kind, bounded or otherwise
//   * every packet dereference is preceded by an explicit data_end bound check
//   * every map lookup result is NULL-checked before use
//   * no uninitialised stack reads: all stack structs are fully assigned

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif
#ifndef ETH_P_IPV6
#define ETH_P_IPV6 0x86DD
#endif
#ifndef ETH_P_ARP
#define ETH_P_ARP 0x0806
#endif

// Traffic direction recorded on the isolation entry so userspace can tell an
// ingress-only attach from a fully bidirectional one.
#define STUN_DIR_INGRESS 1
#define STUN_DIR_EGRESS  2

// stun_isolation_val is the per-interface isolation record. It is both the
// switch (presence == isolated) and the telemetry sink (drop counters read
// back by the Prometheus exporter).
//
// Field order is part of the userspace ABI: pkg/tc/loader.go decodes this
// struct with encoding/binary in little-endian host order.
struct stun_isolation_val {
	__u64 packets_dropped; // total packets destroyed on this interface
	__u64 bytes_dropped;   // total wire bytes destroyed on this interface
	__u32 target_ip;       // container IPv4 (network byte order), 0 == any
	__u32 flags;           // bitmask of STUN_DIR_*
};

// Primary switch: keyed on the host-side veth ifindex. All traffic crossing a
// container's veth belongs to that container, so ifindex alone is a complete
// and unambiguous selector — no packet parsing is required to make the drop
// decision. Parsing happens only to attribute bytes and to support the
// secondary IP-keyed path.
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 1024);
	__type(key, __u32); // ifindex
	__type(value, struct stun_isolation_val);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} stun_isolation_map SEC(".maps");

// Secondary switch: keyed on the container IPv4 address in network byte order.
// This exists so that a caller who knows only the pod IP (for example a
// controller reacting to a Kubernetes event before it has resolved the veth)
// can still isolate, and so that a shared/bridged device can be targeted
// without cutting every workload behind it.
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__uint(max_entries, 1024);
	__type(key, __u32); // __be32 IPv4
	__type(value, struct stun_isolation_val);
	__uint(pinning, LIBBPF_PIN_BY_NAME);
} stun_isolation_ip_map SEC(".maps");

// account_drop records one destroyed packet against an isolation entry.
// __sync_fetch_and_add compiles to BPF_XADD, which is atomic across CPUs; a
// plain increment would lose counts under concurrent softirq processing on a
// multi-queue device and make the drop counter useless as attribution
// evidence.
static __always_inline void account_drop(struct stun_isolation_val *val, __u32 len)
{
	__sync_fetch_and_add(&val->packets_dropped, 1);
	__sync_fetch_and_add(&val->bytes_dropped, (__u64)len);
}

// classify is the whole decision. It is deliberately branch-flat and
// loop-free.
static __always_inline int classify(struct __sk_buff *skb)
{
	// ---- Path 1: interface-keyed isolation ------------------------------
	// Checked first and without touching packet memory, so an isolated
	// interface drops malformed, truncated and non-IP frames too. A
	// severance that only covers well-formed IPv4 is not a severance.
	__u32 ifindex = skb->ifindex;
	struct stun_isolation_val *val = bpf_map_lookup_elem(&stun_isolation_map, &ifindex);
	if (val) {
		account_drop(val, skb->len);
		return TC_ACT_SHOT;
	}

	// ---- Path 2: address-keyed isolation --------------------------------
	// Requires parsing, so every dereference below is bounds-checked. The
	// verifier rejects the program outright if any of these checks are
	// removed, which is the property ISC-47 asserts.
	void *data = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;

	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end) {
		// Truncated frame. Nothing is isolated by ifindex, so this is
		// ordinary traffic on an unmanaged device: let the stack deal
		// with it.
		return TC_ACT_OK;
	}

	__u16 proto = bpf_ntohs(eth->h_proto);

	if (proto == ETH_P_ARP) {
		// ARP carries no IPv4 header at the IP offset. Dereferencing
		// one here would be both wrong and a verifier error. An
		// isolated interface already dropped ARP via Path 1.
		return TC_ACT_OK;
	}

	if (proto == ETH_P_IPV6) {
		// IPv6 is covered by Path 1 (ifindex) only. The IP-keyed map is
		// IPv4; see Out of Scope in the ISA. Explicitly enumerated so
		// the fall-through below cannot silently mis-parse it.
		return TC_ACT_OK;
	}

	if (proto != ETH_P_IP) {
		return TC_ACT_OK;
	}

	struct iphdr *ip = (void *)(eth + 1);
	if ((void *)(ip + 1) > data_end) {
		return TC_ACT_OK;
	}

	// Check both endpoints: egress packets carry the container address in
	// saddr, ingress packets carry it in daddr. Checking only one direction
	// is the "asymmetric routing" failure mode called out on the card.
	__u32 saddr = ip->saddr;
	struct stun_isolation_val *sval = bpf_map_lookup_elem(&stun_isolation_ip_map, &saddr);
	if (sval) {
		account_drop(sval, skb->len);
		return TC_ACT_SHOT;
	}

	__u32 daddr = ip->daddr;
	struct stun_isolation_val *dval = bpf_map_lookup_elem(&stun_isolation_ip_map, &daddr);
	if (dval) {
		account_drop(dval, skb->len);
		return TC_ACT_SHOT;
	}

	return TC_ACT_OK;
}

// The card mandates this exact section name. cilium/ebpf resolves the
// "classifier" prefix to BPF_PROG_TYPE_SCHED_CLS; pkg/tc/loader.go additionally
// pins the type explicitly so the loader does not depend on section-name
// heuristics.
SEC("classifier/drop")
int stun_tc_drop(struct __sk_buff *skb)
{
	return classify(skb);
}

// Both hooks run the identical decision. They are separate entry points only so
// that `bpftool net show` and `tc filter show` name the direction, which makes
// an asymmetric attach visible in operational output rather than silent.
SEC("classifier/drop_ingress")
int stun_tc_drop_ingress(struct __sk_buff *skb)
{
	return classify(skb);
}

SEC("classifier/drop_egress")
int stun_tc_drop_egress(struct __sk_buff *skb)
{
	return classify(skb);
}

char LICENSE[] SEC("license") = "GPL";
