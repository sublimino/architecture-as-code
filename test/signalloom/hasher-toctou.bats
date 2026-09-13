#!/usr/bin/env bats
#
# test/signalloom/hasher-toctou.bats — AMXO-P4-4
#
# BATS test suite for Bounded Streaming Hasher and TOCTOU Post-Read Identity Validation.
# Tests CLI invocations, descriptor isolation, rate limits, oversize caps, and escape rejections.

setup_file() {
  export PATH="/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"

  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export SENSOR_DIR="$REPO_ROOT/d2-signalloom/apps/agentmaxxing-host-sensor"
  export PYTHONPATH="$SENSOR_DIR:$PYTHONPATH"

  for cmd in python3 jq sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "required tool '$cmd' is missing — failing suite" >&2
      return 1
    fi
  done
}

setup() {
  TEST_ROOT="$BATS_FILE_TMPDIR/root_$BATS_TEST_NUMBER"
  mkdir -p "$TEST_ROOT"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

@test "hasher CLI hashes clean regular file with matching SHA-256" {
  echo "Pristine payload content for BATS verification" > "$TEST_ROOT/valid.txt"
  EXPECTED_SHA="$(sha256sum "$TEST_ROOT/valid.txt" | awk '{print $1}')"

  run python3 "$SENSOR_DIR/cli.py" hash-relative \
    --root-dir "$TEST_ROOT" \
    --relpath "valid.txt" \
    --root-id "agent-work"

  [ "$status" -eq 0 ]
  OBSERVATION="$(echo "$output" | jq -r '.observation_state')"
  INTEGRITY="$(echo "$output" | jq -r '.integrity_state')"
  ACTUAL_SHA="$(echo "$output" | jq -r '.sha256')"
  ARTIFACT_ID="$(echo "$output" | jq -r '.artifact_id')"

  [ "$OBSERVATION" = "observed" ]
  [ "$INTEGRITY" = "verified" ]
  [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ]
  [[ "$ARTIFACT_ID" =~ ^hmac-sha256:[0-9a-f]{64}$ ]]
}

@test "hasher CLI rejects path traversal escape above root (RESOLVE_BENEATH)" {
  run python3 "$SENSOR_DIR/cli.py" hash-relative \
    --root-dir "$TEST_ROOT" \
    --relpath "../../../etc/passwd" \
    --root-id "agent-work"

  [ "$status" -eq 1 ]
  OBSERVATION="$(echo "$output" | jq -r '.observation_state')"
  SHA="$(echo "$output" | jq -r '.sha256')"
  REASON="$(echo "$output" | jq -r '.reason_code')"

  [ "$OBSERVATION" = "denied" ]
  [ "$SHA" = "null" ]
  [ "$REASON" = "openat2_escape_rejected" ]
}

@test "hasher CLI rejects symbolic links" {
  echo "Real target" > "$TEST_ROOT/real.txt"
  ln -s "$TEST_ROOT/real.txt" "$TEST_ROOT/symlink.txt"

  run python3 "$SENSOR_DIR/cli.py" hash-relative \
    --root-dir "$TEST_ROOT" \
    --relpath "symlink.txt" \
    --root-id "agent-work"

  [ "$status" -eq 1 ]
  OBSERVATION="$(echo "$output" | jq -r '.observation_state')"
  SHA="$(echo "$output" | jq -r '.sha256')"

  [ "$OBSERVATION" = "denied" ]
  [ "$SHA" = "null" ]
}

@test "hasher CLI rejects files with multiple hard links" {
  echo "Multi link file" > "$TEST_ROOT/orig.txt"
  ln "$TEST_ROOT/orig.txt" "$TEST_ROOT/hardlink.txt"

  run python3 "$SENSOR_DIR/cli.py" hash-relative \
    --root-dir "$TEST_ROOT" \
    --relpath "orig.txt" \
    --root-id "agent-work"

  [ "$status" -eq 1 ]
  OBSERVATION="$(echo "$output" | jq -r '.observation_state')"
  SHA="$(echo "$output" | jq -r '.sha256')"
  REASON="$(echo "$output" | jq -r '.reason_code')"

  [ "$OBSERVATION" = "denied" ]
  [ "$SHA" = "null" ]
  [ "$REASON" = "hardlink_forbidden" ]
}

@test "hasher CLI rejects oversize file exceeding max-file-size threshold" {
  head -c 4096 /dev/urandom > "$TEST_ROOT/large.bin"

  run python3 "$SENSOR_DIR/cli.py" hash-relative \
    --root-dir "$TEST_ROOT" \
    --relpath "large.bin" \
    --max-file-size 1024 \
    --root-id "agent-work"

  [ "$status" -eq 1 ]
  OBSERVATION="$(echo "$output" | jq -r '.observation_state')"
  SHA="$(echo "$output" | jq -r '.sha256')"
  REASON="$(echo "$output" | jq -r '.reason_code')"

  [ "$OBSERVATION" = "unobserved" ]
  [ "$SHA" = "null" ]
  [ "$REASON" = "max_file_size_exceeded" ]
}

@test "hasher CLI enforces sliding window file count rate limit" {
  for i in 1 2; do
    echo "file $i" > "$TEST_ROOT/file$i.txt"
    run python3 "$SENSOR_DIR/cli.py" hash-relative \
      --root-dir "$TEST_ROOT" \
      --relpath "file$i.txt" \
      --max-files-per-window 2
    [ "$status" -eq 0 ]
  done

  echo "file 3" > "$TEST_ROOT/file3.txt"
  # In a single process CLI call with limiter initialized with max 2 files:
  # Using python one-liner to verify multi-file sequence in single session
  run python3 -c '
import sys, os
from hasher import BoundedArtifactHasher
from ratelimit import RateLimiter

limiter = RateLimiter(max_files_per_window=2, window_seconds=60.0)
hasher = BoundedArtifactHasher(rate_limiter=limiter)
r1 = hasher.hash_relative_path("'"$TEST_ROOT"'", "file1.txt")
r2 = hasher.hash_relative_path("'"$TEST_ROOT"'", "file2.txt")
r3 = hasher.hash_relative_path("'"$TEST_ROOT"'", "file3.txt")

assert r1.observation_state == "observed"
assert r2.observation_state == "observed"
assert r3.observation_state == "unobserved"
assert r3.reason_code == "max_files_per_window_exceeded"
print("RATE_LIMIT_ENFORCED_PASS")
'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "RATE_LIMIT_ENFORCED_PASS" ]]
}
