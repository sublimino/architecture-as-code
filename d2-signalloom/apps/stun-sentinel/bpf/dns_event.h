/* bpf/dns_event.h */
#ifndef __DNS_EVENT_H__
#define __DNS_EVENT_H__

#include <linux/types.h>

#define DNS_MAX_NAME_LEN 128

#define DNS_MAX_ANSWERS 4

/* Parse outcome. A record is emitted for every outcome, including the
 * failures: a silently dropped packet is indistinguishable from a packet
 * that never arrived, which is the one thing this telemetry cannot afford. */
#define DNS_PARSE_OK           0
#define DNS_PARSE_TRUNCATED    1  /* hit data_end mid-record */
#define DNS_PARSE_NAME_TOO_LONG 2 /* qname exceeded DNS_MAX_NAME_LEN */
#define DNS_PARSE_COMPRESSED   3  /* pointer compression beyond our depth */
#define DNS_PARSE_UNSUPPORTED  4  /* opcode/class we do not decode */

struct dns_event_t {
    __u64 ts_ns;          /* CLOCK_MONOTONIC timestamp */
    __u32 ifindex;        /* Host veth interface index — the ONLY attribution
                           * key available at TC. Pod and cgroup are resolved
                           * from it in userspace; there is no process context
                           * in a TC program. */
    __u16 qtype;          /* A (1), AAAA (28), CNAME (5), TXT (16), etc. */
    __u16 qdcount;        /* question count as declared on the wire */
    __u16 ancount;        /* answer count as declared on the wire */
    __u8  answers_parsed; /* how many of ancount we actually decoded */
    __u8  rcode;          /* NOERROR (0), NXDOMAIN (3), etc. */
    __u8  is_response;    /* 0 = Query, 1 = Response */
    __u8  parse_status;   /* DNS_PARSE_* — never silently discard a packet */
    __u8  is_ipv6;        /* address family of the answers below */
    __u8  resolver_addr[16]; /* the server this query went to, for off-cluster
                              * resolver detection; no hardcoded service IP */
    /* Every answer address, not just the first: a CDN A-record set rotates,
     * and keeping one address makes a connection to the second look like
     * direct-IP egress. */
    __u8  answers[DNS_MAX_ANSWERS][16];
    __u32 answer_ttls[DNS_MAX_ANSWERS]; /* per-record TTL drives cache expiry */
    char  qname[DNS_MAX_NAME_LEN]; /* Null-terminated decoded domain string */
    char  cname[DNS_MAX_NAME_LEN]; /* final CNAME target when present, so the
                                    * alias chain resolves to one owner */
};

#define TLS_CH_OK            0
#define TLS_CH_SEGMENTED     1  /* ClientHello spans TCP segments */
#define TLS_CH_NO_SNI        2  /* no SNI extension present */
#define TLS_CH_ENCRYPTED     3  /* ECH: outer SNI only, inner unreadable */
#define TLS_CH_MALFORMED     4

struct tls_sni_event_t {
    __u64 ts_ns;
    __u32 ifindex;
    __u16 dport;
    __u8  is_ipv6;
    __u8  parse_status;   /* TLS_CH_* — a segmented ClientHello is a counted
                           * miss, never an absent connection */
    __u8  daddr[16];
    __u16 sni_len;
    char  sni[DNS_MAX_NAME_LEN];
};

#endif /* __DNS_EVENT_H__ */
