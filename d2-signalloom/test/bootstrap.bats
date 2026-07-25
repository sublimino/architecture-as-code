#!/usr/bin/env bats

@test "committed bootstrap is regenerated without drift" {
  run bash ./test/check-bootstrap-drift.sh
  [ "$status" -eq 0 ]
}

@test "generator rejects duplicate migration identifiers" {
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' RETURN
  printf 'SELECT 1;\n' > "$temp/001_one.sql"
  printf 'SELECT 2;\n' > "$temp/001_two.sql"
  run python3 ./infra/inf-signalloom/scripts/generate-bootstrap.py --source "$temp" --output "$temp/out.sql"
  [ "$status" -ne 0 ]
  [[ "$output" == *"duplicate migration identifier"* ]]
}
