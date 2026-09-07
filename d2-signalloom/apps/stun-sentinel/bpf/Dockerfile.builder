# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# Pinned eBPF build and live-test toolchain for the stun-sentinel TC classifier.
#
# Carries two distinct sets of tooling because it serves two jobs:
#   1. compile  — clang/llvm/libbpf produce the committed BPF ELF
#   2. prove    — iproute2/conntrack/bpftool/netcat exercise the real kernel
#                 under `docker run --privileged` in test/tc-ebpf-drop.bats
#
# Keeping them in one image means the object under test and the kernel tooling
# that inspects it never drift apart.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      clang \
      llvm \
      libbpf-dev \
      linux-libc-dev \
      make \
      iproute2 \
      conntrack \
      bpftool \
      netcat-openbsd \
      curl \
      iputils-ping \
      procps \
      iptables \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
