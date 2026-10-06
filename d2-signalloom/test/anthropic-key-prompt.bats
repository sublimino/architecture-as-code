#!/usr/bin/env bats
# @id      anthropic-key-prompt-test
# @target  scripts/anthropic-key-prompt.sh
# @doc     docs/kagent-d5.md

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/anthropic-key-prompt.sh"
  WORK="$(mktemp -d)"
  git -C "$WORK" init -q
  printf '.env\n' > "$WORK/.gitignore"
  export SIGNALLOOM_ENV_FILE="$WORK/.env"
  KEY="sk-ant-test-0123456789abcdefghijklmnop"
}

teardown() { rm -rf "$WORK"; }

@test "writes the key, mode 600, never echoes it" {
  run bash -c "printf '%s\n' '$KEY' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$KEY"* ]]
  grep -qx "ANTHROPIC_API_KEY=$KEY" "$WORK/.env"
  [ "$(stat -c '%a' "$WORK/.env")" = "600" ]
}

@test "replaces an existing key and keeps other lines" {
  printf 'FOO=bar\nANTHROPIC_API_KEY=old-value-xxxxxxxxxxxxxxx\nBAZ=qux\n' > "$WORK/.env"
  run bash -c "printf '%s\n' '$KEY' | '$SCRIPT'"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^ANTHROPIC_API_KEY=' "$WORK/.env")" -eq 1 ]
  grep -qx 'FOO=bar' "$WORK/.env"
  grep -qx 'BAZ=qux' "$WORK/.env"
  grep -qx "ANTHROPIC_API_KEY=$KEY" "$WORK/.env"
}

@test "rejects empty, truncated and mock keys without touching .env" {
  printf 'FOO=bar\n' > "$WORK/.env"
  for bad in "" "sk-ant-short" "mock-anthropic-key""-for-local-demo"; do
    run bash -c "printf '%s\n' '$bad' | '$SCRIPT'"
    [ "$status" -ne 0 ]
  done
  [ "$(cat "$WORK/.env")" = "FOO=bar" ]
}

@test "refuses a .env that git would track" {
  : > "$WORK/.gitignore"
  run bash -c "printf '%s\n' '$KEY' | '$SCRIPT'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not gitignored"* ]]
  [ ! -s "$WORK/.env" ]
}

@test "rejects unknown options" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}
