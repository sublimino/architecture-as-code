#!/usr/bin/env bats
#
# @id      slaws-live-lab
# @target  scripts/slaws-live-lab.sh, infra/aws/slaws-lab
#
# SLAWS D13: Live AWS lab as code for testing the live collector end to end.
# Refuses execution with rc 3 and prints the operator command when credentials are absent.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  script="$repo_root/scripts/slaws-live-lab.sh"
}

@test "refuses without credentials and prints the operator command" {
  local fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  cat <<'EOF' > "$fake_bin/aws"
#!/usr/bin/env bash
if [[ "$*" == *"sts get-caller-identity"* ]]; then
  echo "The security token included in the request is invalid." >&2
  exit 1
fi
exec /usr/bin/aws "$@"
EOF
  chmod +x "$fake_bin/aws"

  PATH="$fake_bin:$PATH" AWS_PROFILE="" AWS_ACCESS_KEY_ID="" AWS_SECRET_ACCESS_KEY="" run "$script" --region us-east-1
  [ "$status" -eq 3 ] || { echo "expected rc 3, got status=$status output=$output"; return 1; }
  [[ "$output" =~ AWS_PROFILE=[^[:space:]]*[[:space:]]*scripts/slaws-live-lab\.sh ]] || {
    echo "output did not contain expected operator command: $output"
    return 1
  }
}

@test "--help prints usage and exits 0" {
  run "$script" --help
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; return 1; }
  [[ "$output" =~ "Usage:" ]] || { echo "missing Usage: $output"; return 1; }
  [[ "$output" =~ "--profile" ]] || { echo "missing --profile in usage: $output"; return 1; }
  [[ "$output" =~ "--region" ]] || { echo "missing --region in usage: $output"; return 1; }
  [[ "$output" =~ "--dry-run" ]] || { echo "missing --dry-run in usage: $output"; return 1; }
}

@test "--dry-run validates configuration without applying" {
  run "$script" --dry-run --region us-east-1
  [ "$status" -eq 0 ] || { echo "status=$status output=$output"; return 1; }
  [[ "$output" =~ "dry-run" ]] || { echo "missing dry-run confirmation: $output"; return 1; }
}

@test "unknown option exits with code 2" {
  run "$script" --unknown-flag
  [ "$status" -eq 2 ] || { echo "expected rc 2, got status=$status output=$output"; return 1; }
  [[ "$output" =~ "unknown option" ]] || { echo "expected unknown option message: $output"; return 1; }
}
