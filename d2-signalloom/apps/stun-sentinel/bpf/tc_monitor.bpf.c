// SPDX-License-Identifier: GPL-2.0
// Copyright 2026 ControlPlane Security Authors
//
// tc_monitor.bpf.c — Additive TC monitor for RFC 1035 DNS and TLS ClientHello SNI.
//
// Attached to the clsact qdisc of a container host-side veth peer alongside
// stun_tc_drop. Unlike stun_tc_drop, tc_monitor returns TC_ACT_OK unconditionally
// and asserts no containment verdict.
//
// Verifier contract:
//   * branch-flat and loop-free
//   * every pointer dereference is preceded by an explicit data_end bound check
//   * no reference to pid/tgid (TC has no process context)
//   * ifindex is the sole attribution key

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <linux/pkt_cls.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>
#include "dns_event.h"

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif
#ifndef ETH_P_IPV6
#define ETH_P_IPV6 0x86DD
#endif
#ifndef ETH_P_ARP
#define ETH_P_ARP 0x0806
#endif

#ifndef IPPROTO_UDP
#define IPPROTO_UDP 17
#endif
#ifndef IPPROTO_TCP
#define IPPROTO_TCP 6
#endif

/* Export wire contracts into BTF for bpf2go / loader introspection. */
const struct dns_event_t *unused_dns_event_t __attribute__((unused));
const struct tls_sni_event_t *unused_tls_sni_event_t __attribute__((unused));

/*
 * BPF ring buffer maps: 4 MiB capacity (1 << 22 = 4194304 bytes) each,
 * matching the Shared Patterns bound.
 */
struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 1 << 22);
} dns_events SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, 1 << 22);
} tls_events SEC(".maps");

/*
 * Reservation failure (ring saturated) counters. Per-CPU arrays so the hot
 * path never takes a cross-CPU atomic.
 */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} dns_drops SEC(".maps");

struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} tls_drops SEC(".maps");

/*
 * Parse status counters:
 *   [0..7]   DNS_PARSE_*
 *   [8..15]  TLS_CH_* (offset by 8)
 */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 16);
	__type(key, __u32);
	__type(value, __u64);
} parse_status_stats SEC(".maps");

static __always_inline void count_dns_drop(void)
{
	__u32 key = 0;
	__u64 *slot = bpf_map_lookup_elem(&dns_drops, &key);
	if (slot)
		*slot += 1;
}

static __always_inline void count_tls_drop(void)
{
	__u32 key = 0;
	__u64 *slot = bpf_map_lookup_elem(&tls_drops, &key);
	if (slot)
		*slot += 1;
}

static __always_inline void count_parse_status(__u32 status_idx)
{
	if (status_idx < 16) {
		__u32 key = status_idx;
		__u64 *slot = bpf_map_lookup_elem(&parse_status_stats, &key);
		if (slot)
			*slot += 1;
	}
}

/*
 * DNS Header (RFC 1035 §4.1.1) — 12 bytes
 */
struct dnshdr {
	__u16 id;
	__u16 flags;
	__u16 qdcount;
	__u16 ancount;
	__u16 nscount;
	__u16 arcount;
};

static __always_inline void parse_dns(
	struct __sk_buff *skb,
	void *data_end,
	void *payload,
	__u8 is_tcp,
	__u8 is_ipv6,
	__u16 sport,
	__u16 dport,
	const __u8 *src_ip,
	const __u8 *dst_ip)
{
	struct dns_event_t *e = bpf_ringbuf_reserve(&dns_events, sizeof(*e), 0);
	if (!e) {
		count_dns_drop();
		return;
	}

	__builtin_memset(e, 0, sizeof(*e));
	e->ts_ns = bpf_ktime_get_ns();
	e->ifindex = skb->ifindex;
	e->is_ipv6 = is_ipv6;

	const __u8 *dns_base = (const __u8 *)payload;
	__u32 off = 0;

	/* For TCP DNS (RFC 1035 §4.2.2), payload begins with 2-byte message length */
	if (is_tcp) {
		if ((void *)(dns_base + 2) > data_end) {
			e->parse_status = DNS_PARSE_TRUNCATED;
			if (sport == 53) {
				e->is_response = 1;
				__builtin_memcpy(e->resolver_addr, src_ip, 16);
			} else {
				e->is_response = 0;
				__builtin_memcpy(e->resolver_addr, dst_ip, 16);
			}
			count_parse_status(DNS_PARSE_TRUNCATED);
			bpf_ringbuf_submit(e, 0);
			return;
		}
		dns_base += 2;
	}

	if ((void *)(dns_base + sizeof(struct dnshdr)) > data_end) {
		e->parse_status = DNS_PARSE_TRUNCATED;
		if (sport == 53) {
			e->is_response = 1;
			__builtin_memcpy(e->resolver_addr, src_ip, 16);
		} else {
			e->is_response = 0;
			__builtin_memcpy(e->resolver_addr, dst_ip, 16);
		}
		count_parse_status(DNS_PARSE_TRUNCATED);
		bpf_ringbuf_submit(e, 0);
		return;
	}

	const struct dnshdr *dns = (const struct dnshdr *)dns_base;
	__u16 flags = bpf_ntohs(dns->flags);
	__u8 qr = (flags >> 15) & 1;
	__u8 opcode = (flags >> 11) & 0x0F;
	__u8 rcode = flags & 0x0F;

	e->qdcount = bpf_ntohs(dns->qdcount);
	e->ancount = bpf_ntohs(dns->ancount);
	e->rcode = rcode;
	e->is_response = qr;

	if (qr == 1) {
		/* Response: resolver is server that answered (src_ip) */
		__builtin_memcpy(e->resolver_addr, src_ip, 16);
	} else {
		/* Query: resolver is target server (dst_ip) */
		__builtin_memcpy(e->resolver_addr, dst_ip, 16);
	}

	if (opcode != 0) {
		e->parse_status = DNS_PARSE_UNSUPPORTED;
	}

	off = sizeof(struct dnshdr);
	__u32 qname_len = 0;
	__u8 label_rem = 0;

	/* Decode Question Section QNAME */
	if (e->qdcount > 0 && e->parse_status == DNS_PARSE_OK) {
		#pragma unroll 32
		for (int i = 0; i < 32; i++) {
			if ((void *)(dns_base + off + 1) > data_end) {
				e->parse_status = DNS_PARSE_TRUNCATED;
				break;
			}
			__u8 c = dns_base[off++];
			if (c == 0) {
				break;
			}
			if ((c & 0xC0) == 0xC0) {
				if ((void *)(dns_base + off + 1) > data_end) {
					e->parse_status = DNS_PARSE_TRUNCATED;
				} else {
					e->parse_status = DNS_PARSE_COMPRESSED;
					off++;
				}
				break;
			}
			if (label_rem == 0) {
				if ((c & 0xC0) != 0) {
					e->parse_status = DNS_PARSE_UNSUPPORTED;
					break;
				}
				label_rem = c;
				if (qname_len > 0 && qname_len < DNS_MAX_NAME_LEN - 1) {
					e->qname[qname_len++] = '.';
				}
			} else {
				if (qname_len < DNS_MAX_NAME_LEN - 1) {
					e->qname[qname_len++] = (char)c;
				} else {
					e->parse_status = DNS_PARSE_NAME_TOO_LONG;
				}
				label_rem--;
			}
		}

		if (qname_len < DNS_MAX_NAME_LEN) {
			e->qname[qname_len] = '\0';
		}

		if (e->parse_status == DNS_PARSE_OK) {
			if ((void *)(dns_base + off + 4) > data_end) {
				e->parse_status = DNS_PARSE_TRUNCATED;
			} else {
				e->qtype = bpf_ntohs(*(__u16 *)(dns_base + off));
				off += 4; /* skip qtype (2) and qclass (2) */
			}
		}
	}

	/* Decode Answer Section (up to DNS_MAX_ANSWERS = 4) */
	if (e->is_response == 1 && e->ancount > 0 && e->parse_status == DNS_PARSE_OK) {
		#pragma unroll 4
		for (int a = 0; a < DNS_MAX_ANSWERS; a++) {
			if (a >= e->ancount || e->parse_status != DNS_PARSE_OK)
				break;

			/* Skip Answer Name (compression pointer or root) */
			if ((void *)(dns_base + off + 1) > data_end) {
				e->parse_status = DNS_PARSE_TRUNCATED;
				break;
			}
			__u8 b = dns_base[off];
			if ((b & 0xC0) == 0xC0) {
				if ((void *)(dns_base + off + 2) > data_end) {
					e->parse_status = DNS_PARSE_TRUNCATED;
					break;
				}
				off += 2;
			} else if (b == 0) {
				off += 1;
			} else {
				e->parse_status = DNS_PARSE_UNSUPPORTED;
				break;
			}

			/* TYPE(2), CLASS(2), TTL(4), RDLENGTH(2) = 10 bytes */
			if ((void *)(dns_base + off + 10) > data_end) {
				e->parse_status = DNS_PARSE_TRUNCATED;
				break;
			}

			__u16 rtype = bpf_ntohs(*(__u16 *)(dns_base + off));
			__u32 rttl  = bpf_ntohl(*(__u32 *)(dns_base + off + 4));
			__u16 rdlen = bpf_ntohs(*(__u16 *)(dns_base + off + 8));
			off += 10;

			if (rtype == 1 && rdlen == 4) { // TYPE A
				if ((void *)(dns_base + off + 4) > data_end) {
					e->parse_status = DNS_PARSE_TRUNCATED;
					break;
				}
				if (e->answers_parsed < DNS_MAX_ANSWERS) {
					__builtin_memcpy(e->answers[e->answers_parsed], dns_base + off, 4);
					e->answer_ttls[e->answers_parsed] = rttl;
					e->answers_parsed++;
					e->is_ipv6 = 0;
				}
				off += 4;
			} else if (rtype == 28 && rdlen == 16) { // TYPE AAAA
				if ((void *)(dns_base + off + 16) > data_end) {
					e->parse_status = DNS_PARSE_TRUNCATED;
					break;
				}
				if (e->answers_parsed < DNS_MAX_ANSWERS) {
					__builtin_memcpy(e->answers[e->answers_parsed], dns_base + off, 16);
					e->answer_ttls[e->answers_parsed] = rttl;
					e->answers_parsed++;
					e->is_ipv6 = 1;
				}
				off += 16;
			} else if (rtype == 5) { // TYPE CNAME
				if ((void *)(dns_base + off + 2) > data_end) {
					e->parse_status = DNS_PARSE_TRUNCATED;
					break;
				}
				__u8 clen = dns_base[off];
				if ((clen & 0xC0) == 0xC0) {
					__u16 ptr_off = ((clen & 0x3F) << 8) | dns_base[off + 1];
					if (ptr_off == 12) {
						__builtin_memcpy(e->cname, e->qname, sizeof(e->cname));
					} else {
						e->parse_status = DNS_PARSE_COMPRESSED;
					}
					off += 2;
				} else {
					e->parse_status = DNS_PARSE_COMPRESSED;
					break;
				}
			} else {
				/* Unknown or unhandled RR type: stop decoding further answers safely */
				break;
			}
		}
	}

	count_parse_status(e->parse_status);
	bpf_ringbuf_submit(e, 0);
}

static __always_inline void parse_tls_client_hello(
	struct __sk_buff *skb,
	void *data_end,
	void *payload,
	__u8 is_ipv6,
	__u16 dport,
	const __u8 *dst_ip)
{
	const __u8 *tls_data = (const __u8 *)payload;
	if ((void *)(tls_data + 5) > data_end) {
		return;
	}

	/* Content Type: 0x16 is Handshake */
	if (tls_data[0] != 0x16) {
		return;
	}

	const __u8 *hs = tls_data + 5;
	if ((void *)(hs + 4) > data_end) {
		return;
	}

	/* Handshake Type: 0x01 is ClientHello */
	if (hs[0] != 0x01) {
		return;
	}

	struct tls_sni_event_t *te = bpf_ringbuf_reserve(&tls_events, sizeof(*te), 0);
	if (!te) {
		count_tls_drop();
		return;
	}

	__builtin_memset(te, 0, sizeof(*te));
	te->ts_ns = bpf_ktime_get_ns();
	te->ifindex = skb->ifindex;
	te->dport = dport;
	te->is_ipv6 = is_ipv6;
	__builtin_memcpy(te->daddr, dst_ip, 16);
	te->parse_status = TLS_CH_NO_SNI;

	__u16 rec_len = ((__u16)tls_data[3] << 8) | tls_data[4];
	if (skb->len < (__u32)(5 + rec_len)) {
		te->parse_status = TLS_CH_SEGMENTED;
	}

	do {
		if ((void *)(hs + 39) > data_end) {
			te->parse_status = TLS_CH_SEGMENTED;
			break;
		}

		__u8 session_id_len = hs[38];
		if (session_id_len > 32) {
			te->parse_status = TLS_CH_MALFORMED;
			break;
		}

		const __u8 *cur = hs + 39 + (session_id_len & 0x3f);

		/* cipher_suites_len (2) */
		if ((void *)(cur + 2) > data_end) {
			te->parse_status = TLS_CH_SEGMENTED;
			break;
		}
		__u16 cipher_suites_len = ((__u16)cur[0] << 8) | cur[1];
		if (cipher_suites_len > 256) {
			te->parse_status = TLS_CH_MALFORMED;
			break;
		}
		cur += 2 + (cipher_suites_len & 0x01ff);

		/* compression_methods_len (1) */
		if ((void *)(cur + 1) > data_end) {
			te->parse_status = TLS_CH_SEGMENTED;
			break;
		}
		__u8 comp_methods_len = *cur;
		if (comp_methods_len > 16) {
			te->parse_status = TLS_CH_MALFORMED;
			break;
		}
		cur += 1 + (comp_methods_len & 0x1f);

		/* Extensions block */
		if ((void *)(cur + 2) > data_end) {
			te->parse_status = TLS_CH_SEGMENTED;
			break;
		}

		cur += 2;

		#pragma unroll 8
		for (int e_idx = 0; e_idx < 8; e_idx++) {
			if ((void *)(cur + 4) > data_end) {
				break;
			}
			__u16 ext_type = ((__u16)cur[0] << 8) | cur[1];
			__u16 ext_len  = ((__u16)cur[2] << 8) | cur[3];
			cur += 4;

			if (ext_len > 256) {
				break;
			}

			if (ext_type == 0xfe0d) { // ECH outer extension
				te->parse_status = TLS_CH_ENCRYPTED;
			} else if (ext_type == 0x0000) { // server_name (SNI)
				if (te->parse_status != TLS_CH_ENCRYPTED) {
					if (ext_len >= 5) {
						if ((void *)(cur + 5) > data_end) {
							te->parse_status = TLS_CH_MALFORMED;
							break;
						}
						__u8 name_type = cur[2];
						if (name_type == 0) { // host_name
							__u16 name_len = ((__u16)cur[3] << 8) | cur[4];
							if (name_len > 128 || 5 + name_len > ext_len) {
								te->parse_status = TLS_CH_MALFORMED;
							} else {
								const __u8 *name_ptr = cur + 5;
								__u16 copy_len = name_len;
								if (copy_len >= DNS_MAX_NAME_LEN) {
									copy_len = DNS_MAX_NAME_LEN - 1;
								}
								te->sni_len = name_len;
								#pragma unroll 32
								for (int s = 0; s < 32; s++) {
									if (s >= copy_len)
										break;
									if ((void *)(name_ptr + s + 1) > data_end) {
										te->parse_status = TLS_CH_SEGMENTED;
										break;
									}
									te->sni[s] = (char)name_ptr[s];
								}
								if (copy_len < DNS_MAX_NAME_LEN) {
									te->sni[copy_len] = '\0';
								}
								if (te->parse_status != TLS_CH_SEGMENTED) {
									te->parse_status = TLS_CH_OK;
								}
							}
						}
					} else {
						te->parse_status = TLS_CH_MALFORMED;
					}
				}
			}

			cur += (ext_len & 0x01ff);
		}
	} while (0);

	count_parse_status(8 + te->parse_status);
	bpf_ringbuf_submit(te, 0);
}

static __always_inline int monitor(struct __sk_buff *skb)
{
	void *data = (void *)(long)skb->data;
	void *data_end = (void *)(long)skb->data_end;

	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return TC_ACT_OK;

	__u16 proto = bpf_ntohs(eth->h_proto);
	if (proto == ETH_P_ARP)
		return TC_ACT_OK;

	__u8 is_ipv6 = 0;
	__u8 l4_proto = 0;
	void *l4_hdr = (void *)0;
	__u8 src_ip[16] = {};
	__u8 dst_ip[16] = {};

	if (proto == ETH_P_IP) {
		struct iphdr *ip = (void *)(eth + 1);
		if ((void *)(ip + 1) > data_end)
			return TC_ACT_OK;
		__u32 ip_hdr_len = ip->ihl * 4;
		if (ip_hdr_len < sizeof(*ip) || (void *)ip + ip_hdr_len > data_end)
			return TC_ACT_OK;
		is_ipv6 = 0;
		l4_proto = ip->protocol;
		l4_hdr = (void *)ip + ip_hdr_len;
		__builtin_memcpy(src_ip, &ip->saddr, 4);
		__builtin_memcpy(dst_ip, &ip->daddr, 4);
	} else if (proto == ETH_P_IPV6) {
		struct ipv6hdr *ip6 = (void *)(eth + 1);
		if ((void *)(ip6 + 1) > data_end)
			return TC_ACT_OK;
		is_ipv6 = 1;
		l4_proto = ip6->nexthdr;
		l4_hdr = (void *)(ip6 + 1);
		__builtin_memcpy(src_ip, &ip6->saddr, 16);
		__builtin_memcpy(dst_ip, &ip6->daddr, 16);
	} else {
		return TC_ACT_OK;
	}

	__u16 sport = 0;
	__u16 dport = 0;
	void *payload = (void *)0;
	__u8 is_tcp = 0;

	if (l4_proto == IPPROTO_UDP) {
		struct udphdr *udp = l4_hdr;
		if ((void *)(udp + 1) > data_end)
			return TC_ACT_OK;
		sport = bpf_ntohs(udp->source);
		dport = bpf_ntohs(udp->dest);
		payload = (void *)(udp + 1);
		is_tcp = 0;
	} else if (l4_proto == IPPROTO_TCP) {
		struct tcphdr *tcp = l4_hdr;
		if ((void *)(tcp + 1) > data_end)
			return TC_ACT_OK;
		sport = bpf_ntohs(tcp->source);
		dport = bpf_ntohs(tcp->dest);
		__u32 tcp_hdr_len = tcp->doff * 4;
		if (tcp_hdr_len < sizeof(*tcp) || (void *)tcp + tcp_hdr_len > data_end)
			return TC_ACT_OK;
		payload = (void *)tcp + tcp_hdr_len;
		is_tcp = 1;
	} else {
		return TC_ACT_OK;
	}

	if (sport == 53 || dport == 53) {
		parse_dns(skb, data_end, payload, is_tcp, is_ipv6, sport, dport, src_ip, dst_ip);
	} else if (is_tcp && dport == 443) {
		parse_tls_client_hello(skb, data_end, payload, is_ipv6, dport, dst_ip);
	}

	return TC_ACT_OK;
}

SEC("classifier/monitor")
int stun_tc_monitor(struct __sk_buff *skb)
{
	return monitor(skb);
}

SEC("classifier/monitor_ingress")
int stun_tc_monitor_ingress(struct __sk_buff *skb)
{
	return monitor(skb);
}

SEC("classifier/monitor_egress")
int stun_tc_monitor_egress(struct __sk_buff *skb)
{
	return monitor(skb);
}

char LICENSE[] SEC("license") = "GPL";
