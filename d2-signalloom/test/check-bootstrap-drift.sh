#!/usr/bin/env bash
#
# The bootstrap SQL is generated from the migrations directory. This asserts the
# two committed copies still match what the generator produces.
#
# It previously used `cmp --silent` under `set -e`, so a drifted file exited 1
# and printed NOTHING. The check had been failing since migration 006 without
# anyone noticing: the committed copy stopped at 005, so a fresh cluster's
# initdb was three migrations behind. A guard that fails silently is worse than
# no guard, because a red exit code with no message reads as tooling noise.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

generator="$root/d2-signalloom/infra/inf-signalloom/scripts/generate-bootstrap.py"
migrations="$root/d2-signalloom/apps/fe-signalloom/src/db/migrations"

python3 "$generator" --source "$migrations" --output "$tmp"

status=0
for committed in \
  "$root/d2-signalloom/contracts/discovery-portal-bootstrap.sql" \
  "$root/d2-signalloom/infra/inf-signalloom/configs/base/bootstrap/discovery-portal-bootstrap.sql"
do
  if ! cmp --silent "$tmp" "$committed"; then
    status=1
    rel="${committed#"$root"/}"
    echo "DRIFT: $rel does not match the generated output" >&2
    echo "  generated: $(wc -l < "$tmp") lines   committed: $(wc -l < "$committed") lines" >&2
    # Name the migrations present in one and not the other — the usual cause is
    # a new migration that nobody regenerated for.
    missing="$(comm -23 \
      <(grep -oE '^-- BEGIN [0-9]{3}_.*' "$tmp" | sort) \
      <(grep -oE '^-- BEGIN [0-9]{3}_.*' "$committed" | sort) || true)"
    if [ -n "$missing" ]; then
      echo "  missing from the committed copy:" >&2
      echo "$missing" | sed 's/^-- BEGIN /    /' >&2
    fi
    echo "  fix: python3 $generator --source $migrations --output $committed" >&2
  fi
done

if [ "$status" -ne 0 ]; then
  echo "" >&2
  echo "Regenerate BOTH copies and commit them. The migrations are the source of" >&2
  echo "truth; these files are build artefacts and must never be hand-edited." >&2
  exit 1
fi

printf 'Discovery Portal bootstrap drift validation passed.\n'
