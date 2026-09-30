#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# build.sh — compile the stun-sentinel BPF objects to BTF-bearing ELFs.
#
#   build.sh [tc]      tc_drop.bpf.c -> pkg/tc/tc_drop.bpf.o  (default, unchanged)
#   build.sh sentinel  sentinel_probe.c -> bpf2go bindings in pkg/ebpf (SLDC-P1-1)
#   build.sh test      live pkg/ebpf loader tests in a privileged container
#
# The build host deliberately does NOT need clang, llvm or bpftool. It needs
# docker. Everything eBPF happens inside a pinned image so the artifact is
# reproducible across the laptop, the CI VM and the GCP lane, none of which
# have a consistent LLVM.
#
# The resulting .o is COMMITTED to the repository. Downstream consumers build
# with plain `go build` and no eBPF toolchain at all, which is the strategy
# CRKC-P1-PRE recorded in docs/signalloom/crkc-p1-preflight-proof.md §5.2.
#
# @id      stun-sentinel-bpf-build
# @doc     docs/signalloom/tc-ebpf-confinement.md
# @tests   test/tc-ebpf-drop.bats, pkg/ebpf/loader_test.go
set -euo pipefail

HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"

# Pinned builder. Bump deliberately; a floating tag makes the committed object
# non-reproducible and every future diff unreviewable.
BUILDER_IMAGE="${STUN_BPF_BUILDER_IMAGE:-signalloom-bpf-builder:trixie}"
BUILDER_DOCKERFILE="${HERE}/Dockerfile.builder"

SRC="tc_drop.bpf.c"
OBJ="tc_drop.bpf.o"

log() { printf '[bpf-build] %s\n' "$*" >&2; }

ensure_builder() {
	if docker image inspect "$BUILDER_IMAGE" >/dev/null 2>&1; then
		log "builder image present: $BUILDER_IMAGE"
		return 0
	fi
	log "building builder image: $BUILDER_IMAGE"
	docker build -q -f "$BUILDER_DOCKERFILE" -t "$BUILDER_IMAGE" "$HERE" >/dev/null
}

build_tc() {
	command -v docker >/dev/null 2>&1 || {
		log "FATAL: docker is required to build the BPF object"
		exit 1
	}
	ensure_builder

	log "compiling ${SRC} -> ${OBJ}"
	# -g is REQUIRED: it is what emits .BTF / .BTF.ext. Without BTF, CO-RE
	# relocations and bpftool's pretty map dump both stop working.
	# -Werror is deliberate. A warning in a program the verifier will police
	# is a warning worth stopping on.
	# --user keeps the emitted object owned by the invoking user. Without it
	# docker writes it as root and the artifact cannot be committed, rebuilt
	# or deleted without privileges the build host does not have.
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		-v "${HERE}:/src" \
		-w /src \
		"$BUILDER_IMAGE" \
		clang \
		-target bpf \
		-D__TARGET_ARCH_x86 \
		-mcpu=v3 \
		-O2 -g \
		-Wall -Wextra -Werror \
		-Wno-unused-parameter \
		-Wno-compare-distinct-pointer-types \
		-I/usr/include/x86_64-linux-gnu \
		-c "$SRC" -o "$OBJ"

	log "verifying artifact"
	docker run --rm -v "${HERE}:/src" -w /src "$BUILDER_IMAGE" \
		bash -c '
			set -e
			obj='"$OBJ"'
			# Machine type is the authoritative architecture claim. The
			# directory name and the .o suffix are not evidence.
			llvm-readelf -h "$obj" | grep -q "EM_BPF" \
				|| { echo "not an eBPF ELF (machine is not EM_BPF)" >&2; exit 1; }
			llvm-readelf -S "$obj" | grep -q "\.BTF" \
				|| { echo "missing .BTF" >&2; exit 1; }
			llvm-readelf -S "$obj" | grep -q "\.BTF\.ext" \
				|| { echo "missing .BTF.ext" >&2; exit 1; }
			llvm-readelf -S "$obj" | grep -q "classifier/drop" \
				|| { echo "missing classifier/drop section" >&2; exit 1; }
			llvm-objdump -S "$obj" >/dev/null \
				|| { echo "disassembly failed" >&2; exit 1; }

			# NOTE ON LOOP SAFETY. Do not add a grep for "goto -" here.
			# The compiler emits backward branches to SHARED EPILOGUE
			# blocks (tail merging); this object contains 18 of them and
			# has no loop in the source at all. A grep would fail a
			# correct program and, worse, would pass a program whose loop
			# the compiler had unrolled forwards.
			#
			# The authoritative oracle for loop safety is the in-kernel
			# verifier, which rejects unbounded loops outright. That check
			# lives in TestVerifierAcceptsProgram (pkg/tc) and in
			# test/tc-ebpf-drop.bats, both of which load this object for
			# real. See ISC-37/38/46.
		'

	log "OK: ${HERE}/${OBJ}"
	ls -l "${HERE}/${OBJ}" >&2
}

# --- SLDC-P1-1: in-sentinel syscall probe ----------------------------------
#
# bpf2go needs Go and clang in one filesystem, so the probe uses its own pinned
# image (Dockerfile.bpf2go). The compile flags live in bpf/Makefile; this
# function only supplies the hermetic toolchain and a writable Go cache.
SENTINEL_IMAGE="${STUN_BPF2GO_IMAGE:-signalloom-bpf2go:trixie-go1.27}"
SENTINEL_DOCKERFILE="${HERE}/Dockerfile.bpf2go"
GO_CACHE_DIR="${STUN_BPF_GO_CACHE:-${TMPDIR:-/tmp}/stun-sentinel-bpf-go}"

ensure_sentinel_image() {
	if docker image inspect "$SENTINEL_IMAGE" >/dev/null 2>&1; then
		log "toolchain image present: $SENTINEL_IMAGE"
		return 0
	fi
	log "building toolchain image: $SENTINEL_IMAGE"
	docker build -q -f "$SENTINEL_DOCKERFILE" -t "$SENTINEL_IMAGE" "$HERE" >/dev/null
}

# run_in_toolchain [docker-args...] -- <command...>
run_in_toolchain() {
	local -a dargs=()
	while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
		dargs+=("$1")
		shift
	done
	shift
	mkdir -p "$GO_CACHE_DIR/mod" "$GO_CACHE_DIR/build"
	docker run --rm \
		-e HOME=/tmp \
		-e GOMODCACHE=/gocache/mod \
		-e GOCACHE=/gocache/build \
		-e GOFLAGS=-mod=mod \
		-e GOTOOLCHAIN=local \
		-v "$GO_CACHE_DIR:/gocache" \
		-v "${HERE%/bpf}:/src" \
		"${dargs[@]}" \
		"$SENTINEL_IMAGE" "$@"
}

build_sentinel() {
	command -v docker >/dev/null 2>&1 || {
		log "FATAL: docker is required to build the BPF object"
		exit 1
	}
	ensure_sentinel_image
	log "compiling sentinel_probe.c and regenerating bpf2go bindings"
	run_in_toolchain --user "$(id -u):$(id -g)" -w /src/bpf -- make all
}

# Live tests need CAP_BPF, CAP_PERFMON and tracefs, i.e. root in a privileged
# container. SENTINEL_REQUIRE_LIVE_BPF=1 makes a missing privilege a FAILURE,
# so this lane can never go green by skipping.
test_sentinel() {
	command -v docker >/dev/null 2>&1 || {
		log "FATAL: docker is required to run the live probe tests"
		exit 1
	}
	ensure_sentinel_image
	log "running live pkg/ebpf tests (privileged)"
	# Root in the container writes root-owned cache entries; keep them out of
	# the cache the unprivileged `sentinel` build writes to.
	GO_CACHE_DIR="${GO_CACHE_DIR}-root"
	run_in_toolchain --privileged -e SENTINEL_REQUIRE_LIVE_BPF=1 -w /src -- \
		bash -c 'mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
			exec go test -count=1 -v '"${STUN_TEST_ARGS:-}"' ./pkg/ebpf/...'
}

main() {
	case "${1:-tc}" in
	tc) build_tc ;;
	sentinel) build_sentinel ;;
	test) test_sentinel ;;
	*)
		log "usage: build.sh [tc|sentinel|test]"
		exit 2
		;;
	esac
}

main "$@"
