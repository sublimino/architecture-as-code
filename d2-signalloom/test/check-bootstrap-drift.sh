#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
python3 "$root/d2-signalloom/infra/inf-signalloom/scripts/generate-bootstrap.py" \
  --source "$root/d2-signalloom/apps/fe-signalloom/src/db/migrations" --output "$tmp"
cmp --silent "$tmp" "$root/d2-signalloom/contracts/discovery-portal-bootstrap.sql"
cmp --silent "$tmp" "$root/d2-signalloom/infra/inf-signalloom/configs/base/bootstrap/discovery-portal-bootstrap.sql"
printf 'Discovery Portal bootstrap drift validation passed.\n'
