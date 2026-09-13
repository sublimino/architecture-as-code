#!/usr/bin/env bats

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export SENSOR_DIR="$REPO_ROOT/d2-signalloom/apps/agentmaxxing-host-sensor"
  export PYTHONPATH="$SENSOR_DIR:$PYTHONPATH"
}

setup() {
  TEST_TMP="$(mktemp -d /tmp/bats_anti_escape_XXXXXX)"
  export TEST_TMP
}

teardown() {
  if [ -d "$TEST_TMP" ]; then
    rm -rf "$TEST_TMP"
  fi
}

@test "file validator hashes valid regular file beneath pinned root" {
  echo '{"data": "artifact_payload_123"}' > "$TEST_TMP/valid.json"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "valid.json"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Status: eligible" ]]
  [[ "$output" =~ "SHA256:" ]]
  [[ "$output" =~ "Revalidation: Passed" ]]
}

@test "file validator rejects symlink pointing inside root with zero bytes read" {
  echo "target data" > "$TEST_TMP/target.txt"
  ln -s "target.txt" "$TEST_TMP/sym_in.txt"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "sym_in.txt"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: symlink_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects symlink pointing outside root with zero bytes read" {
  ln -s "/etc/passwd" "$TEST_TMP/sym_out.txt"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "sym_out.txt"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: symlink_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects path traversal escape (..) with zero bytes read" {
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "../../etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: escape_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects absolute path escape with zero bytes read" {
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "/etc/passwd"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: escape_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects hard-linked file (nlink > 1) with zero bytes read" {
  echo "hardlink data" > "$TEST_TMP/orig.txt"
  ln "$TEST_TMP/orig.txt" "$TEST_TMP/hardlink.txt"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "hardlink.txt"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: hardlink_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects directory target with zero bytes read" {
  mkdir "$TEST_TMP/subdir"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "subdir"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: directory_rejected" || "$output" =~ "Reason: non_regular_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "file validator rejects FIFO named pipe with zero bytes read without hanging" {
  mkfifo "$TEST_TMP/pipe.fifo"
  run python3 "$SENSOR_DIR/file_validator.py" "$TEST_TMP" "pipe.fifo"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "Reason: fifo_rejected" || "$output" =~ "Reason: non_regular_rejected" ]]
  [[ "$output" =~ "Bytes Read: 0" ]]
}

@test "pytest suite for file validator executes and passes all 16 adversarial assertions" {
  run python3 -m pytest -p no:libtmux -v "$SENSOR_DIR/test_file_validator.py"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "16 passed" ]]
}
