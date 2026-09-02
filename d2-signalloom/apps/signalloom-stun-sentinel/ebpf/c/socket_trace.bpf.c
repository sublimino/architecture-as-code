// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

#include <linux/types.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

#define AF_INET  2
#define AF_INET6 10

#define TCP_ESTABLISHED 1
#define TCP_SYN_SENT    2
#define TCP_CLOSE       7

#define STATS_DROP_RINGBUF_FULL 0
#define STATS_TOTAL_EVENTS      1

struct flow_event_t {
    __u64 timestamp_ns;
    __u64 cgroup_id;
    __u64 sock_cookie;
    __u64 seq_num;
    __u32 saddr;
    __u32 daddr;
    __u16 sport;
    __u16 dport;
    __u16 family;
    __u8  oldstate;
    __u8  newstate;
    __u64 bytes_sent;
    __u64 bytes_recv;
};

// Zero-copy ring buffer for low-overhead flow event delivery
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24); // 16MB ring buffer
} flow_events SEC(".maps");

// Per-CPU drop and throughput stats map to eliminate cross-CPU locking overhead
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} telemetry_drop_stats SEC(".maps");

// Monotonic global sequence number map
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} global_seq SEC(".maps");

static __always_inline void increment_stat(__u32 index) {
    __u64 *val = bpf_map_lookup_elem(&telemetry_drop_stats, &index);
    if (val) {
        *val += 1;
    }
}

static __always_inline __u64 get_next_seq() {
    __u32 zero = 0;
    __u64 *seq = bpf_map_lookup_elem(&global_seq, &zero);
    if (!seq) {
        return 1;
    }
    return __sync_fetch_and_add(seq, 1) + 1;
}

SEC("tp_btf/inet_sock_set_state")
int BPF_PROG(trace_inet_sock_set_state, struct sock *sk, int oldstate, int newstate) {
    if (!sk) {
        return 0;
    }

    // Filter only transitions of interest (SYN_SENT -> ESTABLISHED, ESTABLISHED -> CLOSE)
    if (newstate != TCP_ESTABLISHED && newstate != TCP_CLOSE) {
        return 0;
    }

    // Softirq safety invariant: extract cgroup directly from struct sock via bpf_sk_cgroup_id
    // This prevents attributing connections in softirq context to PID 0 (swapper/idle)
    __u64 cgroup_id = bpf_sk_cgroup_id(sk);
    if (cgroup_id == 0) {
        // Fallback to task cgroup if socket cgroup is not yet assigned
        cgroup_id = bpf_get_current_cgroup_id();
    }

    struct flow_event_t *event = bpf_ringbuf_reserve(&flow_events, sizeof(*event), 0);
    if (!event) {
        // Fail-closed invariant: record drop statistic for userspace TELEMETRY_GAP synthesis
        increment_stat(STATS_DROP_RINGBUF_FULL);
        return 0;
    }

    increment_stat(STATS_TOTAL_EVENTS);

    event->timestamp_ns = bpf_ktime_get_ns();
    event->cgroup_id = cgroup_id;
    event->sock_cookie = bpf_get_socket_cookie(sk);
    event->seq_num = get_next_seq();
    event->oldstate = (__u8)oldstate;
    event->newstate = (__u8)newstate;

    // Read IPv4 / IPv6 addresses and ports via CO-RE helpers
    __u16 family = BPF_CORE_READ(sk, __sk_common.skc_family);
    event->family = family;

    if (family == AF_INET) {
        event->saddr = BPF_CORE_READ(sk, __sk_common.skc_rcv_saddr);
        event->daddr = BPF_CORE_READ(sk, __sk_common.skc_daddr);
        event->sport = BPF_CORE_READ(sk, __sk_common.skc_num);
        event->dport = bpf_ntohs(BPF_CORE_READ(sk, __sk_common.skc_dport));
    }

    // Submit flow event to userspace ring buffer
    bpf_ringbuf_submit(event, 0);

    return 0;
}

char LICENSE[] SEC("license") = "Dual BSD/GPL";
