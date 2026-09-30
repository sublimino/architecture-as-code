// SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)
// Copyright 2026 ControlPlane Security Authors
//
// sentinel_probe.c -- in-sentinel kernel syscall telemetry (SLDC-P1-1).
//
// Captures the three syscalls the containment loop acts on, at the kernel
// boundary, with no external daemonset:
//
//   tracepoint/syscalls/sys_enter_openat   type 1  file access
//   tracepoint/syscalls/sys_enter_execve   type 2  process execution
//   tracepoint/syscalls/sys_enter_connect  type 3  outbound connect (INET/INET6)
//   tracepoint/syscalls/sys_enter_openat2  type 4  file access via openat2(2)
//
// openat2 is captured because openat-only coverage is a trivial bypass: a
// process that calls openat2 directly never touches sys_enter_openat.
//
// Every record is a fixed-size struct syscall_event_t written to one 16 MiB
// BPF ring buffer. Filtering happens here, in kernel space, before a slot is
// reserved: kernel context (tgid 0), the sentinel's own tgid, and non-INET
// connect() calls (AF_UNIX et al.) never cost ring space.
//
// Paths are the RAW user-supplied strings. Canonicalisation (../, symlinks,
// dirfd-relative paths) is the userspace normaliser's job (SLDC-P1-2); do not
// write policy against these strings as if they were resolved.
//
// Build: bpf/Makefile (flags) via bpf/build.sh sentinel (hermetic toolchain).

#include "headers/vmlinux.h" /* resolved relative to this file: works with and without -Iheaders */
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_endian.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

#define SENTINEL_EVT_OPENAT  1
#define SENTINEL_EVT_EXECVE  2
#define SENTINEL_EVT_CONNECT 3
#define SENTINEL_EVT_OPENAT2 4

#define SENTINEL_COMM_LEN     16
#define SENTINEL_FILENAME_LEN 256
#define SENTINEL_RINGBUF_SIZE (1 << 24) /* 16,777,216 bytes */

#define SENTINEL_AF_INET  2
#define SENTINEL_AF_INET6 10

/*
 * FROZEN WIRE CONTRACT -- consumed by pkg/ebpf (Go decoder) and SLDC-P1-2.
 * Fields are ordered largest-alignment first so the compiler inserts NO
 * implicit padding; every pad byte is explicit and named. sizeof == 328
 * (41 * 8). Any change here must update SyscallEventSize and the offset table
 * in pkg/ebpf/event.go, which TestSyscallEventLayoutMatchesBTF enforces.
 *
 * offset  size  field
 *      0     8  ts_ns        bpf_ktime_get_ns() (CLOCK_MONOTONIC)
 *      8     8  cgroup_id    bpf_get_current_cgroup_id() (cgroup v2 inode)
 *     16     4  pid          thread id  (lower 32 bits of pid_tgid)
 *     20     4  tgid         process id (upper 32 bits of pid_tgid)
 *     24     4  uid
 *     28     1  type         SENTINEL_EVT_*
 *     29     1  _pad0
 *     30     2  family       connect only: AF_INET / AF_INET6
 *     32     2  dport        connect only: destination port, HOST byte order
 *     34     6  _pad1
 *     40    16  daddr        connect only: v4 in [0..3], v6 in [0..15], network order
 *     56    16  comm
 *     72   256  filename     openat/openat2: path arg; execve: binary path
 */
struct syscall_event_t {
	__u64 ts_ns;
	__u64 cgroup_id;
	__u32 pid;
	__u32 tgid;
	__u32 uid;
	__u8 type;
	__u8 _pad0;
	__u16 family;
	__u16 dport;
	__u8 _pad1[6];
	__u8 daddr[16];
	char comm[SENTINEL_COMM_LEN];
	char filename[SENTINEL_FILENAME_LEN];
};

_Static_assert(sizeof(struct syscall_event_t) == 328, "syscall_event_t wire size changed");
_Static_assert(__builtin_offsetof(struct syscall_event_t, daddr) == 40, "daddr offset changed");
_Static_assert(__builtin_offsetof(struct syscall_event_t, comm) == 56, "comm offset changed");
_Static_assert(__builtin_offsetof(struct syscall_event_t, filename) == 72, "filename offset changed");

/* Forces syscall_event_t into BTF so bpf2go -type can emit the Go mirror. */
const struct syscall_event_t *unused_syscall_event_t __attribute__((unused));

struct {
	__uint(type, BPF_MAP_TYPE_RINGBUF);
	__uint(max_entries, SENTINEL_RINGBUF_SIZE);
} events SEC(".maps");

/*
 * Reservation failures (ring saturated). Per-CPU so the hot path never takes
 * a cross-CPU atomic; userspace sums the slots.
 */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} drops SEC(".maps");

/*
 * The sentinel's own process, rewritten by the loader before load. Without
 * this filter the sentinel's own openat()s (reading /proc, cgroupfs) feed
 * back into the ring and amplify under load. sentinel_self_tgid == 0
 * disables it.
 *
 * The tgid is the one the sentinel sees for itself (getpid()), so it is only
 * meaningful inside the sentinel's PID namespace, identified by the nsfs
 * dev/inode of /proc/self/ns/pid. Comparing it against
 * bpf_get_current_pid_tgid() (which reports the INIT namespace) silently
 * never matches in any pod without hostPID -- measured, not hypothetical.
 */
volatile const __u32 sentinel_self_tgid = 0;
volatile const __u64 sentinel_pidns_dev = 0;
volatile const __u64 sentinel_pidns_ino = 0;

static __always_inline void count_drop(void)
{
	__u32 key = 0;
	__u64 *slot = bpf_map_lookup_elem(&drops, &key);

	if (slot)
		*slot += 1;
}

static __always_inline int is_sentinel_self(void)
{
	struct bpf_pidns_info ns = {};

	if (sentinel_self_tgid == 0)
		return 0;
	/* Non-zero return: the task is not in the sentinel's PID namespace. */
	if (bpf_get_ns_current_pid_tgid(sentinel_pidns_dev, sentinel_pidns_ino, &ns, sizeof(ns)))
		return 0;
	return ns.tgid == sentinel_self_tgid;
}

/* Returns the init-namespace tgid, or 0 when the task must not be traced. */
static __always_inline __u32 traced_tgid(__u64 pid_tgid)
{
	__u32 tgid = pid_tgid >> 32;

	if (tgid == 0 || is_sentinel_self())
		return 0;
	return tgid;
}

/*
 * Reserve and fill the common header. Ring buffer memory is NOT zeroed, so
 * every header byte is written explicitly; filename is NUL-terminated at [0]
 * and the decoder stops at the first NUL.
 */
static __always_inline struct syscall_event_t *reserve_event(__u64 pid_tgid, __u32 tgid, __u8 type)
{
	struct syscall_event_t *e;

	e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
	if (!e) {
		count_drop();
		return NULL;
	}

	e->ts_ns = bpf_ktime_get_ns();
	e->cgroup_id = bpf_get_current_cgroup_id();
	e->pid = (__u32)pid_tgid;
	e->tgid = tgid;
	e->uid = (__u32)bpf_get_current_uid_gid();
	e->type = type;
	e->_pad0 = 0;
	e->family = 0;
	e->dport = 0;
	__builtin_memset(e->_pad1, 0, sizeof(e->_pad1));
	__builtin_memset(e->daddr, 0, sizeof(e->daddr));
	bpf_get_current_comm(&e->comm, sizeof(e->comm));
	e->filename[0] = '\0';
	return e;
}

/*
 * Common body for every "path in args[idx]" syscall. bpf_probe_read_user_str
 * is bounded by sizeof(filename) and returns an error (not a fault) on a bad
 * user pointer; on error the record is still emitted with an empty filename,
 * because "something called openat with an unreadable path" is itself signal.
 */
static __always_inline int emit_path_event(struct trace_event_raw_sys_enter *ctx, __u8 type, int idx)
{
	__u64 pid_tgid = bpf_get_current_pid_tgid();
	__u32 tgid = traced_tgid(pid_tgid);
	struct syscall_event_t *e;
	const char *upath;

	if (!tgid)
		return 0;

	e = reserve_event(pid_tgid, tgid, type);
	if (!e)
		return 0;

	upath = (const char *)ctx->args[idx];
	if (bpf_probe_read_user_str(&e->filename, sizeof(e->filename), upath) < 0)
		e->filename[0] = '\0';

	bpf_ringbuf_submit(e, 0);
	return 0;
}

SEC("tracepoint/syscalls/sys_enter_openat")
int trace_enter_openat(struct trace_event_raw_sys_enter *ctx)
{
	/* openat(int dfd, const char *filename, int flags, umode_t mode) */
	return emit_path_event(ctx, SENTINEL_EVT_OPENAT, 1);
}

SEC("tracepoint/syscalls/sys_enter_openat2")
int trace_enter_openat2(struct trace_event_raw_sys_enter *ctx)
{
	/* openat2(int dfd, const char *filename, struct open_how *how, size_t usize) */
	return emit_path_event(ctx, SENTINEL_EVT_OPENAT2, 1);
}

SEC("tracepoint/syscalls/sys_enter_execve")
int trace_enter_execve(struct trace_event_raw_sys_enter *ctx)
{
	/* execve(const char *filename, const char *const *argv, const char *const *envp) */
	return emit_path_event(ctx, SENTINEL_EVT_EXECVE, 0);
}

/* User-space sockaddr layouts (UAPI, stable). Kept local: 24 bytes of stack. */
struct sentinel_sockaddr_in {
	__u16 family;
	__be16 port;
	__u8 addr[4];
};

struct sentinel_sockaddr_in6 {
	__u16 family;
	__be16 port;
	__u32 flowinfo;
	__u8 addr[16];
};

SEC("tracepoint/syscalls/sys_enter_connect")
int trace_enter_connect(struct trace_event_raw_sys_enter *ctx)
{
	/* connect(int fd, struct sockaddr *uservaddr, int addrlen) */
	__u64 pid_tgid = bpf_get_current_pid_tgid();
	__u32 tgid = traced_tgid(pid_tgid);
	const void *uaddr;
	__u64 addrlen;
	struct sentinel_sockaddr_in6 sa = {};
	struct syscall_event_t *e;

	if (!tgid)
		return 0;

	uaddr = (const void *)ctx->args[1];
	addrlen = ctx->args[2];

	/*
	 * Read the family before reserving: most connect() traffic on a node is
	 * AF_UNIX (dbus, containerd, kubelet), and reserving then discarding
	 * would burn ring bandwidth on exactly the noise we filter out.
	 */
	if (bpf_probe_read_user(&sa.family, sizeof(sa.family), uaddr) < 0)
		return 0;

	if (sa.family == SENTINEL_AF_INET) {
		if (addrlen < sizeof(struct sentinel_sockaddr_in))
			return 0;
		if (bpf_probe_read_user(&sa, sizeof(struct sentinel_sockaddr_in), uaddr) < 0)
			return 0;
	} else if (sa.family == SENTINEL_AF_INET6) {
		if (addrlen < sizeof(struct sentinel_sockaddr_in6))
			return 0;
		if (bpf_probe_read_user(&sa, sizeof(sa), uaddr) < 0)
			return 0;
	} else {
		return 0;
	}

	e = reserve_event(pid_tgid, tgid, SENTINEL_EVT_CONNECT);
	if (!e)
		return 0;

	e->family = sa.family;
	e->dport = bpf_ntohs(sa.port);
	if (sa.family == SENTINEL_AF_INET) {
		/* sockaddr_in keeps the v4 address where v6 keeps flowinfo. */
		__builtin_memcpy(e->daddr, &sa.flowinfo, 4);
	} else {
		__builtin_memcpy(e->daddr, sa.addr, 16);
	}

	bpf_ringbuf_submit(e, 0);
	return 0;
}
