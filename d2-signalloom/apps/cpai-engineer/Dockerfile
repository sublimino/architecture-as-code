# Dockerfile builds cpai-engineer (Workload Type 4A: in-cluster sandboxed
# coding harness) under REAL fail-closed nono/Landlock enforcement.
#
# The previous image shipped NO nono binary and carried the comment "For the
# demo, we ship a stub that logs the sandbox command." That is the shim this
# change removes: the in-process NonoWrapper (nono.go) only ever *logged* a
# sandbox command string, and because no nono binary existed on PATH the agent
# ran every coding task unconfined.
#
# DECISION — wrap PID 1, not just the inner exec. We make enforcement REAL by
# wrapping the whole cpai-engineer server process in the real nono binary at the
# ENTRYPOINT. Linux Landlock restrictions are INHERITED by every child process
# and cannot be relaxed by a child, so git, OpenCode, and anything the LLM
# induces the agent to spawn all run inside the same kernel-enforced sandbox as
# PID 1. This is strictly stronger than the per-exec in-process wrapper and does
# not depend on nono.go being correct. It is fail-closed: if nono cannot install
# Landlock (old kernel, LSM disabled) the server never starts — the pod
# CrashLoops rather than silently serving unconfined.
#
# The in-process NonoWrapper (nono.go) is now defence-in-depth only; its CLI
# flags are tracked separately and are out of scope for this image. Even if that
# inner wrapper is a no-op or errors, PID 1's Landlock already confines the
# entire process tree.
#
# nono.real is staged into the build context (gitignored, ~30 MB, glibc-linked).
# Stage it with:
#   cp "$(command -v nono)" d2-signalloom/apps/cpai-engineer/nono.real
# (the Makefile swarm-cpai-engineer-nono-image target does this). nono --version
# must be >= 0.79.0.
#
# Build context MUST be d2-signalloom/apps/cpai-engineer/:
#   docker build -t cpai-engineer:latest .
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/cpai-engineer .

FROM cgr.dev/chainguard/wolfi-base:latest
# libgcc provides libgcc_s.so.1 that the nono binary links; git is the agent's
# repo tool.
RUN apk add --no-cache libgcc git

# The real nono binary wraps PID 1. No shim, no unconfined fallback.
COPY nono.real /usr/local/bin/nono
COPY --from=build /out/cpai-engineer /usr/local/bin/cpai-engineer
COPY nono-profiles/ /etc/nono/profiles/

# HOME must be writable by the runtime user AND outside the allow-list, so
# nono's pre-sandbox state write succeeds and its deny_credentials paths do not
# overlap an allowed dir. /home/cpai sits outside the allow-list below.
RUN mkdir -p /home/cpai/.local/state /home/cpai/.config /workspace/.cpai /tmp /opt \
 && echo "world-readable control fixture" > /opt/control-readable.txt \
 && chmod 0644 /opt/control-readable.txt \
 && chown -R 65534:65534 /home/cpai /workspace /tmp
ENV HOME=/home/cpai \
    XDG_STATE_HOME=/home/cpai/.local/state \
    XDG_CONFIG_HOME=/home/cpai/.config
USER 65534:65534
# WORKDIR must be inside the allow-list (/workspace, granted -a below) so nono's
# working-directory check passes without --allow-cwd.
WORKDIR /workspace
EXPOSE 8084

# REAL enforcement for the whole server process tree:
#   -r /usr /lib /lib64 /bin    read+exec binaries and shared libraries
#   -a /tmp                      read+write (Go runtime + agent scratch)
#   -a /workspace                read+write (session DB + cloned repos)
#   --listen-port 8084           Landlock network allow for the HTTP listener
#   --read-file /etc/...         ONLY the specific /etc files git/TLS/DNS need
# /etc is NOT granted as a directory, so /etc/shadow and /etc/passwd stay denied
# at the kernel while git can still read CA certs, resolver and host config.
# Egress is owned by the NetworkPolicy + sentinel (--block-net omitted so the
# listener survives), matching the kusari defence-in-depth split.
ENTRYPOINT ["/usr/local/bin/nono", "run", "-s", "--no-audit", \
            "--listen-port", "8084", \
            "-r", "/usr", "-r", "/lib", "-r", "/lib64", "-r", "/bin", \
            "-a", "/tmp", "-a", "/workspace", \
            "--read-file", "/etc/resolv.conf", \
            "--read-file", "/etc/hosts", \
            "--read-file", "/etc/nsswitch.conf", \
            "--read-file", "/etc/ssl/certs/ca-certificates.crt", \
            "--read-file", "/etc/gitconfig", \
            "--", "/usr/local/bin/cpai-engineer"]
