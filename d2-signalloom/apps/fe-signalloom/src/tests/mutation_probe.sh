#!/usr/bin/env bash
# Falsification harness: mutate a control, run a test selection, restore.
#
# Every authorization test in this directory must be shown to FAIL when the
# control it guards is removed. A test that stays green under mutation is
# proving nothing, which is the exact defect shape this repo keeps producing:
# a passing test whose subject was silently deleted.
#
# Usage:  mutation_probe.sh <mutation-id> [pytest args...]
# The mutation is applied to a scratch copy, the suite runs, the original is
# restored from that copy on every exit path including a failed run.
set -eo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUT="${1:?mutation id required}"
shift || true

declare -A FILES=(
  [agent_by_id_tenant_filter]="api_compat.py"
  [agent_list_tenant_filter]="api_compat.py"
  [audit_tenant_filter]="api_compat.py"
  [nhi_detail_tenant_filter]="api_compat.py"
  [violation_ack_tenant_filter]="api_compat.py"
  [subject_tenant_map]="api_compat.py"
  [jwt_algorithms]="api_compat.py"
  [jwt_audience]="api_compat.py"
  [jwt_issuer]="api_compat.py"
  [jwt_azp]="api_compat.py"
  [superadmin_gate]="superadmin.py"
)

declare -A FROM=(
  [agent_by_id_tenant_filter]='"SELECT * FROM agent_registry WHERE id = $1 AND tenant_id = $2", agent_uuid, tenant_id,'
  [agent_list_tenant_filter]='"SELECT * FROM agent_registry WHERE tenant_id = $1 ORDER BY created_at", tenant_id,'
  [audit_tenant_filter]='    conditions = ["tenant_id = $1"]'
  [nhi_detail_tenant_filter]='        "SELECT * FROM nhi_discovered_accounts WHERE id = $1 AND tenant_id = $2",'
  [violation_ack_tenant_filter]='               WHERE id = $1 AND tenant_id = $2""",'
  [subject_tenant_map]='    tenant = settings.api_subject_tenants.get(claims["sub"])'
  [jwt_algorithms]='            algorithms=["RS256"],'
  [jwt_audience]='            audience=settings.api_jwt_audience,'
  [jwt_issuer]='            issuer=settings.api_jwt_issuer,'
  [jwt_azp]='    if claims.get("azp") != settings.api_jwt_authorized_party:'
  [superadmin_gate]='    if not is_superadmin(principal):'
)

declare -A TO=(
  [agent_by_id_tenant_filter]='"SELECT * FROM agent_registry WHERE id = $1 AND $2 IS NOT NULL", agent_uuid, tenant_id,'
  [agent_list_tenant_filter]='"SELECT * FROM agent_registry WHERE $1 IS NOT NULL ORDER BY created_at", tenant_id,'
  [audit_tenant_filter]='    conditions = ["$1 IS NOT NULL"]'
  [nhi_detail_tenant_filter]='        "SELECT * FROM nhi_discovered_accounts WHERE id = $1 AND $2 IS NOT NULL",'
  [violation_ack_tenant_filter]='               WHERE id = $1 AND $2 IS NOT NULL""",'
  [subject_tenant_map]='    tenant = claims.get("tenant_id") or settings.api_subject_tenants.get(claims["sub"])'
  [jwt_algorithms]='            algorithms=["RS256", "HS256"],'
  [jwt_audience]='            audience=None, options={"verify_aud": False},'
  [jwt_issuer]='            issuer=None,'
  [jwt_azp]='    if False:'
  [superadmin_gate]='    if False:'
)

file="${FILES[$MUT]:-}"
if [[ -z "$file" ]]; then
  echo "unknown mutation: $MUT" >&2
  printf 'known: %s\n' "${!FILES[@]}" >&2
  exit 64
fi

target="$SRC_DIR/$file"
backup="$(mktemp "${TMPDIR:-/tmp}/mutation_probe.XXXXXX")"
cp "$target" "$backup"
# Restore unconditionally. `git checkout` is never used here: it would revert
# unrelated in-progress edits in the same file.
trap 'cp "$backup" "$target"; rm -f "$backup"' EXIT

python3 - "$target" "${FROM[$MUT]}" "${TO[$MUT]}" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
count = text.count(old)
# Assert before writing. A no-op substitution that prints success is how a
# mutation run reports "the test survived" when the mutation never happened.
if count != 1:
    sys.exit(f"MUTATION NOT APPLIED: pattern occurs {count} times (need exactly 1) in {path}\n  {old!r}")
open(path, "w").write(text.replace(old, new))
print(f"mutation applied to {path}")
PY

echo "--- running pytest with mutation '$MUT' applied ---"
set +e
(cd "$SRC_DIR" && UV_CACHE_DIR="${UV_CACHE_DIR:-/home/andy/src/.worktrees/.uvcache}" \
  uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
  --with-requirements requirements.txt python -m pytest "$@")
rc=$?
set -e
echo "--- pytest exit code: $rc ---"
exit "$rc"
