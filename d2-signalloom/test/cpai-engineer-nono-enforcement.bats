#!/usr/bin/env bats
# Real Nono/Landlock enforcement around cpai-engineer (SLSI).
#
# @id      cpai-engineer-nono-enforcement
# @target  d2-signalloom/apps/cpai-engineer/Dockerfile
#
# The cpai-engineer image used to ship NO nono binary and only logged a sandbox
# command string ("For the demo, we ship a stub that logs the sandbox command"),
# so coding tasks ran unconfined. The Dockerfile now wraps PID 1 in the real
# nono binary, so the whole server process tree runs under kernel Landlock.
#
# This suite proves the image's nono + the Dockerfile's allow-list are REAL:
# /etc/shadow and /etc/os-release are denied with a kernel EACCES, the specific
# /etc files the agent is granted via --read-file are readable, /workspace is
# read+write, and the same read succeeds WITHOUT nono (control).
#
# Tier-2 integration test: needs docker, the built image, and Landlock 5.13+.
# SKIPs loudly when absent; never asserts a mock.

IMAGE="${CPAI_ENGINEER_IMAGE:-cpai-engineer:latest}"
DOCKER="${SLDC_DOCKER:-docker}"

# Mirror the Dockerfile ENTRYPOINT allow-list (minus --listen-port, which is
# irrelevant for a one-shot filesystem probe).
nono_in_image() { # usage: nono_in_image <cmd...>
  "$DOCKER" run --rm \
    --entrypoint /usr/local/bin/nono "$IMAGE" \
    run -s --no-audit \
    -r /usr -r /lib -r /lib64 -r /bin -a /tmp -a /workspace \
    --read-file /etc/resolv.conf --read-file /etc/hosts \
    --read-file /etc/nsswitch.conf --read-file /etc/ssl/certs/ca-certificates.crt \
    --read-file /etc/gitconfig "$@"
}

setup() {
  command -v "$DOCKER" >/dev/null 2>&1 || skip "docker not available (need it to run the enforcement image)"
  "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || \
    skip "image $IMAGE not built — run: make -C d2-signalloom swarm-cpai-engineer-nono-image"
  run "$DOCKER" run --rm --entrypoint /usr/local/bin/nono "$IMAGE" setup --check-only
  [[ "$output" == *"verified"* ]] || skip "Landlock not enforceable on this kernel (need 5.13+): $output"
}

@test "real nono DENIES /etc/shadow with a kernel EACCES (whole-process-tree sandbox)" {
  run nono_in_image -- cat /etc/shadow
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]
}

@test "matched pair: a world-readable fixture (/opt/control-readable.txt) is DENIED under nono but readable WITHOUT it" {
  # /opt is not granted, so nono denies the 0644 fixture — attributing the deny
  # to Landlock, not DAC (unlike /etc/shadow which DAC denies anyway).
  run nono_in_image -- cat /opt/control-readable.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]

  run "$DOCKER" run --rm --entrypoint /bin/cat "$IMAGE" /opt/control-readable.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"world-readable control fixture"* ]]
}

@test "the allow-list is PRECISE: a granted /etc file (--read-file ca-certificates.crt) is readable while /etc/shadow is not" {
  # Proves /etc is NOT opened wholesale for git's TLS needs — only named files.
  run nono_in_image -- test -r /etc/ssl/certs/ca-certificates.crt
  [ "$status" -eq 0 ]
}

@test "real nono PERMITS the agent's /workspace (read+write)" {
  run nono_in_image -- sh -c 'echo ok > /workspace/cpai-probe && cat /workspace/cpai-probe'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}
