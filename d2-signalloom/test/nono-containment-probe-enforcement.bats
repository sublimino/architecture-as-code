#!/usr/bin/env bats
# Real Nono/Landlock enforcement around the nono-containment-probe (SLSI).
#
# @id      nono-containment-probe-enforcement
# @target  d2-signalloom/apps/nono-containment-probe/Dockerfile
#
# Proves the nono-containment-probe image applies REAL kernel Landlock, not the
# old shell shim that stripped "--" and exec'd the probe unconfined. Inside the
# image, the real nono binary denies a path its allow-list does not grant
# (/etc/shadow, /etc/os-release) with a real EACCES, permits the probe's granted
# /workspace, and — run with no override — the probe's own JSON output reports
# read_shadow blocked with errno EACCES and landlock_enforced:true.
#
# Tier-2 integration test: needs docker, the built image, and a Landlock-capable
# kernel (5.13+). SKIPs — loudly, naming the cause — when any is absent, and
# FAILs when present but enforcement is wrong. It never asserts a mock.

IMAGE="${NONO_PROBE_IMAGE:-nono-containment-probe:latest}"
DOCKER="${SLDC_DOCKER:-docker}"

# Run the image's real nono with the probe's own allow-list (mirrors the
# Dockerfile ENTRYPOINT: -r /usr /lib /lib64 /bin -a /tmp -a /workspace).
nono_in_image() { # usage: nono_in_image <cmd...>
  "$DOCKER" run --rm \
    --entrypoint /usr/local/bin/nono "$IMAGE" \
    run -s --no-audit -r /usr -r /lib -r /lib64 -r /bin -a /tmp -a /workspace "$@"
}

setup() {
  command -v "$DOCKER" >/dev/null 2>&1 || skip "docker not available (need it to run the enforcement image)"
  "$DOCKER" image inspect "$IMAGE" >/dev/null 2>&1 || \
    skip "image $IMAGE not built — run: make -C d2-signalloom swarm-nono-probe-image"
  run "$DOCKER" run --rm --entrypoint /usr/local/bin/nono "$IMAGE" setup --check-only
  [[ "$output" == *"verified"* ]] || skip "Landlock not enforceable on this kernel (need 5.13+): $output"
}

@test "real nono DENIES /etc/shadow (not in allow-list) with a kernel EACCES" {
  run nono_in_image -- cat /etc/shadow
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  # Kernel denial, NOT a missing file — proves Landlock, not absence.
  [[ "$output" != *"No such file"* ]]
}

@test "matched pair: a world-readable fixture (/opt/control-readable.txt) is DENIED under nono but readable WITHOUT it" {
  # /opt is not in the allow-list, so nono denies the fixture even though its
  # DAC bits are 0644 — this attributes the deny to Landlock, not to file
  # permissions or absence (unlike /etc/shadow, which DAC denies anyway).
  run nono_in_image -- cat /opt/control-readable.txt
  [ "$status" -ne 0 ]
  [[ "$output" == *"Permission denied"* || "$output" == *"permission denied"* ]]
  [[ "$output" != *"No such file"* ]]

  # Same path, no sandbox: readable. The ONLY difference is nono.
  run "$DOCKER" run --rm --entrypoint /bin/cat "$IMAGE" /opt/control-readable.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"world-readable control fixture"* ]]
}

@test "real nono PERMITS the probe's granted /workspace (read seeded file + write)" {
  run nono_in_image -- sh -c 'cat /workspace/test.txt && echo written > /workspace/probe-out && cat /workspace/probe-out'
  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace test file"* ]]
  [[ "$output" == *"written"* ]]
}

@test "the probe's OWN output reflects real Landlock: read_shadow blocked, errno EACCES, landlock_enforced true" {
  # Default entrypoint runs: nono run ... -- nono-containment-probe. Its JSON is
  # emitted by a process the kernel is actually confining.
  run "$DOCKER" run --rm "$IMAGE"
  # The probe exits 0 (it only reports); assert the enforced read_shadow line.
  [[ "$output" == *'"probe":"read_shadow"'* ]]
  [[ "$output" == *'"result":"blocked"'* ]]
  [[ "$output" == *'"errno":"EACCES"'* ]]
  [[ "$output" == *'"landlock_enforced":true'* ]]
  # And the granted workspace read is allowed.
  [[ "$output" == *'"probe":"workspace_read"'*'"result":"allowed"'* ]]
}
