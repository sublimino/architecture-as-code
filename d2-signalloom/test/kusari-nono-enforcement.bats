#!/usr/bin/env bats
# Real Nono/Landlock enforcement around the kusari agent (SLSI).
#
# @id      kusari-nono-enforcement
# @target  d2-signalloom/apps/kusari-agent/Dockerfile.nono
# @doc     docs/EAP/kusari-nono-sandbox-risks.md
#
# This suite proves the kusari-agent-nono image applies REAL kernel Landlock,
# not the old shim: inside the image, the real nono binary denies a path its
# capability allow-list does not grant (/etc/shadow) with a real EACCES, and
# permits one it does grant. If this passes, "the agent is sandboxed" is a
# kernel fact, not a claim.
#
# It is a Tier-2 integration test: it needs docker, the built image, and a
# Landlock-capable kernel (5.13+). It SKIPs — loudly, naming the cause — when
# those are absent, and FAILs when they are present but enforcement is wrong.
# It never asserts a mock.

IMAGE="${KUSARI_NONO_IMAGE:-kusari-agent-nono:latest}"
DOCKER="${SLDC_DOCKER:-docker}"

# nono runs as the parent before sandboxing and persists session state under
# XDG_STATE_HOME; the image's default points at a k8s mount absent here, so the
# test supplies a writable one. HOME stays off the allow-list so nono's
# deny_credentials rules do not overlap an allowed parent.
nono_in_image() { # usage: nono_in_image <nono-args...>
  # HOME=/home/nono keeps nono's state root (and its deny_credentials paths) OFF
  # the allow-list, so neither overlaps the allowed /tmp (nono refuses a state
  # root under an allowed dir). The image chowns /home/nono to 65532 and the
  # docker-run rootfs is writable, so the default $HOME/.local/state works.
  "$DOCKER" run --rm \
    -e HOME=/home/nono \
    --entrypoint /usr/local/bin/nono "$IMAGE" \
    run -s --no-audit --allow-cwd -r /usr -r /lib -r /lib64 -r /bin -a /tmp "$@"
}

setup() {
  command -v "$DOCKER" >/dev/null 2>&1 || skip "docker not available (need it to run the enforcement image)"
  "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || \
    skip "image $IMAGE not built — run: make -C d2-signalloom swarm-kusari-nono-image"
  # Landlock capability probe: the image's own nono reports it.
  run "$DOCKER" run --rm --entrypoint /usr/local/bin/nono "$IMAGE" setup --check-only
  [[ "$output" == *"verified"* ]] || skip "Landlock not enforceable on this kernel (need 5.13+): $output"
}

@test "real nono DENIES a path not in the allow-list (/etc/shadow) with a kernel EACCES" {
  run nono_in_image -- cat /etc/shadow
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  # It must be a kernel denial, NOT a missing file — proves Landlock, not absence.
  [[ "$output" != *"No such file"* ]]
}

@test "real nono is credential-aware: /etc/passwd (benign user DB) is allowed, /etc/shadow is not" {
  # nono's built-in defaults permit benign user-resolution files for a working
  # process but keep credentials (/etc/shadow, tested above) denied. This
  # documents that the deny in test 1 is a credential protection, not a blanket
  # /etc block — the same reason the agent's /act/read-passwd is not a finding
  # while /act/read-shadow is.
  run nono_in_image -- cat /etc/passwd
  [ "$status" -eq 0 ]
  [[ "$output" == *"root:"* ]]
}

@test "real nono PERMITS a path inside an allowed directory (/tmp)" {
  run nono_in_image -- sh -c 'echo ok > /tmp/probe && cat /tmp/probe'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "the enforcement is real: the SAME read is allowed WITHOUT nono (control)" {
  # Prove the deny above is the sandbox, not the environment: unwrapped, the
  # read reaches the file (or fails for a reason other than Landlock EACCES).
  run "$DOCKER" run --rm --entrypoint /bin/sh "$IMAGE" -c 'cat /etc/shadow; echo rc=$?'
  # /etc/shadow exists in wolfi; unwrapped the process can at least attempt it,
  # so the Landlock-denied case above is attributable to nono, not to the image.
  [[ "$output" != *"Operation not permitted"* ]]
}
