# Dockerfile builds the nono-containment-probe under REAL fail-closed
# nono/Landlock enforcement. It used to ship a shell SHIM at
# /usr/local/bin/nono that merely stripped the "--" and exec'd the probe with
# NO sandbox at all — so every "blocked" result the probe reported was a lie:
# the EACCES checks in probes.go had nothing enforcing them. This image wraps
# the probe in the real nono binary (nono.real, v0.79.0) so a capability
# allow-list is installed at the kernel Landlock LSM before the probe runs, and
# every path the probe was NOT granted is denied by the kernel.
#
# With real enforcement the probe's EACCES assertions become kernel facts:
#   read /etc/shadow      -> real EACCES (/, /etc not in the allow-list)
#   read /root/.ssh/*     -> real EACCES (not in the allow-list)
#   write /usr/local/evil -> real EACCES (/usr is read-only)
#   read/write /workspace -> allowed (granted read+write)
#
# nono.real is the real binary staged into the build context (gitignored,
# ~30 MB, dynamically linked against glibc) because committing it is wrong and
# a network fetch mid-build is non-hermetic. Stage it with:
#   cp "$(command -v nono)" d2-signalloom/apps/nono-containment-probe/nono.real
# (the Makefile swarm-nono-probe-image target does this). nono --version must
# be >= 0.79.0.
#
# Build context MUST be d2-signalloom/apps/nono-containment-probe/:
#   docker build -t nono-containment-probe:latest .
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/nono-containment-probe .

# wolfi-base is glibc-based; libgcc provides libgcc_s.so.1 that the nono binary
# links. A missing shared lib would make nono fail to exec, which under its
# fail-closed design means the pod never starts — safe, but we provide the lib.
FROM cgr.dev/chainguard/wolfi-base:latest
RUN apk add --no-cache libgcc

# The real nono binary wraps the probe. There is NO shim and NO unconfined
# fallback: if nono cannot apply Landlock the probe never runs.
COPY nono.real /usr/local/bin/nono
COPY --from=build /out/nono-containment-probe /usr/local/bin/nono-containment-probe

# nono (the parent, pre-sandbox) persists session state under its state dir.
# HOME must be writable by the runtime user AND must NOT sit under any child
# allow path, or nono refuses to start (a state root under an allowed dir, or
# a deny_credentials path overlapping an allowed parent). /home/nono is
# writable and sits outside the allow-list below.
RUN mkdir -p /home/nono/.local/state /home/nono/.config /workspace /opt \
 && echo "nono-containment-probe: workspace test file" > /workspace/test.txt \
 && echo "world-readable control fixture" > /opt/control-readable.txt \
 && chmod 0644 /opt/control-readable.txt \
 && chown -R 65532:65532 /home/nono /workspace
ENV HOME=/home/nono \
    XDG_STATE_HOME=/home/nono/.local/state \
    XDG_CONFIG_HOME=/home/nono/.config
USER 65532:65532
# WORKDIR must be inside the allow-list (/workspace, granted -a below) so nono's
# working-directory check passes without --allow-cwd.
WORKDIR /workspace

# REAL enforcement. Allow only what the probe legitimately needs:
#   -r /usr /lib /lib64 /bin   read+exec the binary and shared libraries
#   -a /tmp                    read+write (Go runtime temp files)
#   -a /workspace              read+write (the probe's allowed sandbox dir)
# DENIED by omission at the kernel Landlock LSM: /etc (shadow/passwd), /root
# (.ssh), /dev — so the probe's read_shadow / write_outside provocations fail
# with a REAL EACCES. Egress is owned by the NetworkPolicy + sentinel, not by
# nono here (--block-net is deliberately omitted; the probe has no listener to
# protect but blanket socket blocking is the network layer's job), matching the
# kusari defence-in-depth split. --no-audit avoids needing a privileged audit
# sink in-cluster.
ENTRYPOINT ["/usr/local/bin/nono", "run", "-s", "--no-audit", \
            "-r", "/usr", "-r", "/lib", "-r", "/lib64", "-r", "/bin", \
            "-a", "/tmp", "-a", "/workspace", \
            "--", "/usr/local/bin/nono-containment-probe"]
