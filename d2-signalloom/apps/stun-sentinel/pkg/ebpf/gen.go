// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

package ebpf

// Regenerate with `bpf/build.sh sentinel` (hermetic clang + Go). The generated
// probe_bpf{el,eb}.{go,o} are committed so `go build` needs no eBPF toolchain.
//
//go:generate go run github.com/cilium/ebpf/cmd/bpf2go -cc clang -cflags "-O2 -g -Wall -Werror -D__TARGET_ARCH_x86" -target bpfel,bpfeb -type syscall_event_t probe ../../bpf/sentinel_probe.c -- -I../../bpf/headers -I/usr/include/x86_64-linux-gnu
