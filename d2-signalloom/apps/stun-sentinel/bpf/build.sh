#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# build.sh — compile tc_drop.bpf.c to a BTF-bearing BPF ELF.
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
# @tests   test/tc-ebpf-drop.bats
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

main() {
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

main "$@"
