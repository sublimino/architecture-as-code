#!/usr/bin/env bats
# Real Nono/Landlock enforcement + fail-closed for the SP-5 evidenced agent image.
#
# @id      agent-nono-evidenced-enforcement
# @target  d2-signalloom/infra/agent-swarm/agent-nono-evidenced/Dockerfile.nono
#
# The deployed evidenced agent used to run a stock kubectl image whose inline
# script found no nono, logged "executing unconfined", and emitted
# status:"healthy" heartbeats forever. This image ships the real nono binary and
# the fail-closed probe-nono-capability.sh as its entrypoint. This suite proves,
# IN the built image:
#   * enforced: a denied path returns a real kernel EACCES and /tmp is allowed;
#   * fail-closed: with Landlock forced unavailable, the agent exits non-zero and
#     emits NO healthy heartbeat and NO landlock evidence.
#
# Tier-2 integration test: needs docker, the built image, and Landlock 5.13+.
# SKIPs loudly when absent; never asserts a mock.

IMAGE="${AGENT_NONO_EVIDENCED_IMAGE:-agent-nono-evidenced:latest}"
DOCKER="${SLDC_DOCKER:-docker}"

setup() {
  command -v "$DOCKER" >/dev/null 2>&1 || skip "docker not available (need it to run the enforcement image)"
  "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || \
    skip "image $IMAGE not built — run: make -C d2-signalloom swarm-agent-nono-evidenced-image"
  run "$DOCKER" run --rm --entrypoint /usr/local/bin/nono "$IMAGE" setup --check-only
  [[ "$output" == *"verified"* ]] || skip "Landlock not enforceable on this kernel (need 5.13+): $output"
}

@test "ENFORCED: --check reports enforced and exits 0" {
  run "$DOCKER" run --rm "$IMAGE" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status":"enforced"'* ]]
}

@test "ENFORCED: the wrapped workload is denied a non-allowed path with a kernel EACCES" {
  run "$DOCKER" run --rm "$IMAGE" -- cat /etc/shadow
  [ "$status" -ne 0 ]
  [[ "$output" == *'"status":"enforced"'* ]]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]
}

@test "ENFORCED: the wrapped workload CAN write its allowed /tmp" {
  run "$DOCKER" run --rm "$IMAGE" -- touch /tmp/evidenced-probe
  [ "$status" -eq 0 ]
}

@test "FAIL-CLOSED: Landlock forced unavailable -> non-zero, status unenforced, NO healthy, NO landlock evidence" {
  run "$DOCKER" run --rm -e NONO_FORCE_FALLBACK=1 "$IMAGE" --check
  [ "$status" -ne 0 ]
  [[ "$output" == *'"status":"unenforced"'* ]]
  [[ "$output" == *'"enforcement":"none"'* ]]
  [[ "$output" != *'"status":"healthy"'* ]]
  [[ "$output" != *"landlock"* ]]
  [[ "$output" != *'"nono_capability_available":true'* ]]
}
