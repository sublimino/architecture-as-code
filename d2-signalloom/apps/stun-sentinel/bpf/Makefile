# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# Compile rules for the in-sentinel syscall probe (SLDC-P1-1).
#
# This file is the single statement of the clang flags. It runs INSIDE the
# pinned toolchain image; the host entrypoint is `./build.sh sentinel`, which
# supplies clang >= 14, libbpf headers and Go without touching the host.
#
#   make check-clang   assert clang >= $(CLANG_MIN_MAJOR) and a BPF target
#   make probe         sentinel_probe.c -> sentinel_probe.o (+ ELF verification)
#   make generate      bpf2go -> ../pkg/ebpf/probe_bpf{el,eb}.{go,o}
#   make all           all of the above
#
# @id      stun-sentinel-probe-make
# @tests   ../pkg/ebpf/loader_test.go

CLANG           ?= clang
LLVM_READELF    ?= llvm-readelf
GO              ?= go
CLANG_MIN_MAJOR := 14

SRC := sentinel_probe.c
OBJ := sentinel_probe.o

# -g is mandatory: it emits .BTF/.BTF.ext, which CO-RE relocation and bpf2go
# -type both depend on. -Werror: a warning in code the verifier polices is a
# warning worth stopping on.
BPF_CFLAGS := -O2 -g -Wall -Werror -D__TARGET_ARCH_x86
BPF_INCLUDES := -Iheaders -I/usr/include/x86_64-linux-gnu

REQUIRED_SECTIONS := \
	tracepoint/syscalls/sys_enter_openat \
	tracepoint/syscalls/sys_enter_openat2 \
	tracepoint/syscalls/sys_enter_execve \
	tracepoint/syscalls/sys_enter_connect \
	.maps .BTF .BTF.ext license

.PHONY: all check-clang probe verify generate clean

all: probe generate

check-clang:
	@command -v $(CLANG) >/dev/null 2>&1 || { echo "FATAL: $(CLANG) not found" >&2; exit 1; }
	@major=$$($(CLANG) -dumpversion | cut -d. -f1); \
	if [ "$$major" -lt $(CLANG_MIN_MAJOR) ]; then \
		echo "FATAL: clang $$major < $(CLANG_MIN_MAJOR) (ringbuf + CO-RE need >= $(CLANG_MIN_MAJOR))" >&2; exit 1; \
	fi; \
	$(CLANG) -print-targets | grep -qw bpf || { echo "FATAL: clang cannot emit target bpf" >&2; exit 1; }; \
	echo "clang $$($(CLANG) -dumpversion) OK (>= $(CLANG_MIN_MAJOR), bpf target present)"

$(OBJ): $(SRC) headers/vmlinux.h | check-clang
	$(CLANG) -target bpf $(BPF_CFLAGS) $(BPF_INCLUDES) -c $(SRC) -o $(OBJ)

probe: $(OBJ) verify

verify: $(OBJ)
	@$(LLVM_READELF) -h $(OBJ) | grep -q EM_BPF || { echo "FATAL: $(OBJ) is not EM_BPF" >&2; exit 1; }
	@for s in $(REQUIRED_SECTIONS); do \
		$(LLVM_READELF) -S $(OBJ) | grep -qF " $$s " || { echo "FATAL: missing section $$s" >&2; exit 1; }; \
	done
	@echo "$(OBJ) sections OK; sha256 $$(sha256sum $(OBJ) | cut -d' ' -f1)"

# bpf2go reads its flags from ../pkg/ebpf/gen.go; this target only runs it.
generate: check-clang
	cd ../pkg/ebpf && $(GO) generate ./...

clean:
	rm -f $(OBJ)
