/* SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause) */
/* Copyright 2026 ControlPlane Security Authors */
/*
 * Minimal CO-RE kernel type subset for sentinel_probe.c.
 *
 * A full `bpftool btf dump file /sys/kernel/btf/vmlinux format c` is ~4 MB and
 * pins the repository to whichever kernel generated it. The probe touches
 * the syscall tracepoint context and, for the caller's executable identity,
 * task_struct -> mm -> exe_file -> f_inode; only those fields are declared here, under preserve_access_index. libbpf / cilium/ebpf
 * relocate every field access against the running kernel's BTF at load time,
 * which is the CO-RE guarantee a full dump would give us, at 1/10000th the
 * size and without a kernel-version-specific artifact in git.
 *
 * UAPI types (__u32, enum bpf_map_type, ...) come from linux-libc-dev, which
 * is stable ABI and needs no relocation.
 *
 * Adding a field access? Add the type here under the same pragma, and never
 * dereference a kernel pointer without BPF_CORE_READ().
 */
#ifndef __SENTINEL_VMLINUX_H__
#define __SENTINEL_VMLINUX_H__

#include <linux/types.h>
#include <linux/bpf.h>

#ifndef BPF_NO_PRESERVE_ACCESS_INDEX
#pragma clang attribute push(__attribute__((preserve_access_index)), apply_to = record)
#endif

struct trace_entry {
	unsigned short type;
	unsigned char flags;
	unsigned char preempt_count;
	int pid;
};

/* Context for every tracepoint/syscalls/sys_enter_* program. */
struct trace_event_raw_sys_enter {
	struct trace_entry ent;
	long id;
	unsigned long args[6];
	char __data[0];
};

/*
 * The caller's executable, for set_exe_identity(): current->mm->exe_file's
 * inode number and size. Only the fields read are declared; CO-RE relocates
 * each by name against the running kernel.
 */
struct inode {
	unsigned long i_ino;
	long long i_size;
};

struct file {
	struct inode *f_inode;
};

struct mm_struct {
	struct file *exe_file;
};

struct task_struct {
	struct mm_struct *mm;
};

#ifndef BPF_NO_PRESERVE_ACCESS_INDEX
#pragma clang attribute pop
#endif

#endif /* __SENTINEL_VMLINUX_H__ */
