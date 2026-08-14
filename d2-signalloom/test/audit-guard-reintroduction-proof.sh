#!/usr/bin/env bash
#
# Prove the audit-provenance guards fail on a reintroduction of each violation
# class they exist for.
#
# WHY THIS IS A COMMITTED SCRIPT AND NOT A ONE-OFF
# -----------------------------------------------
# A guard nobody has watched fail is not a guard. Three separate checks in this
# repository have been found green-and-blind: test_audit_event_types.py read
# only one module, then only understood literals; Playwright silently skipped
# four specs no project claimed. Each read as coverage for as long as nobody
# looked.
#
# So the failure is demonstrated rather than asserted. Each case mutates the
# tree to reintroduce one violation, runs the guard, and requires it to go red.
# A case that stays green prints a warning that is hard to miss and exits
# non-zero.
#
# This script found two real defects in the guards themselves on its first run:
#
#   * The vacuity check asserted "stun_agent still resolves client-supplied
#     fields", which went RED when CASE 9 simulated the fix. A guard that fails
#     when the defect is repaired trains people to delete it. It is now pinned
#     to a synthetic fixture that cannot be fixed.
#
#   * The harness's own restore ran `git checkout -- <src dir>`, which reverted
#     in-progress edits to a tracked test file in that directory. CASE 4 then
#     ran against the old weak guard and reported "did not fire" -- a harness
#     bug that reads exactly like a guard defect. Restore names files now.
#
# Usage:  d2-signalloom/test/audit-guard-reintroduction-proof.sh
# Requires: python3 with pytest. No cluster, no database.

set -eo pipefail   # deliberately NOT -u: the shell snapshot's grep wrapper
                   # references $ZSH_VERSION unguarded, and nounset makes every
                   # grep call in this script fatal.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SRC="$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src"
GUARD="$SRC/tests/test_audit_provenance.py"
SNAPSHOT=$(mktemp -d)
FAILURES=0

# Restore only the files each case mutates. Never `git checkout` a whole
# directory: it also reverts uncommitted work by whoever is running this.
PRODUCTION_FILES=(
  d2-signalloom/apps/fe-signalloom/src/api_compat.py
  d2-signalloom/apps/dashboard-signalloom/src/api/client.ts
)

restore() {
  git -C "$REPO_ROOT" checkout -- "${PRODUCTION_FILES[@]}" 2>/dev/null || true
  [ -f "$SNAPSHOT/guard.py" ] && cp "$SNAPSHOT/guard.py" "$GUARD"
  return 0
}
cleanup() { restore; rm -rf "$SNAPSHOT"; }
trap cleanup EXIT

cp "$GUARD" "$SNAPSHOT/guard.py"

run() {
  ( cd "$SRC" && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 timeout 300 python3 -m pytest "$1" -q 2>&1 ) \
    | grep -E "^E +AssertionError" | head -2
}

case_start() { printf '\n=== %s\n' "$1"; restore; }

verdict() {
  if [ -n "$1" ]; then
    printf '  RED as required\n%s\n' "$1"
  else
    printf '  *** GUARD DID NOT FIRE — this check is decoration ***\n'
    FAILURES=$((FAILURES + 1))
  fi
}

patch_py() { python3 -c "$1"; }

# --------------------------------------------------------------------------
case_start "CASE 1  a client-supplied field reaches an audit write (new site)"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = "\"agent.created\", str(row[\"id\"]), body.name, principal.actor, {\"source\": \"api\"})"
new = "\"agent.created\", str(row[\"id\"]), body.name, principal.actor, {\"source\": \"api\", \"note\": body.description})"
assert old in s, "CASE 1 anchor missing"
p.write_text(s.replace(old, new))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 2  widening a KNOWN violation (per-field keying, not per-handler)"
patch_py '
import pathlib
p = pathlib.Path("'"$GUARD"'"); s = p.read_text()
a = s.index("            (\n                \"detail\", \"outcome\",")
b = s.index("            (\n                \"detail\", \"reason\",")
p.write_text(s[:a] + s[b:])
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 3  hardcoded actor, plain literal (what the original guard caught)"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = "\"nhi.enrolled\", None, None, principal.actor,"
new = "\"nhi.enrolled\", None, None, \"demo-actor\","
assert old in s, "CASE 3 anchor missing"
p.write_text(s.replace(old, new))
'
verdict "$(run tests/test_audit_event_types.py)"

# --------------------------------------------------------------------------
case_start "CASE 4  hardcoded actor behind a module constant (THE GAP that was open)"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = "\"nhi.dismissed\", None, None, principal.actor,"
new = "\"nhi.dismissed\", None, None, NHI_ACTOR,"
assert old in s, "CASE 4 anchor missing"
s = s.replace(old, new)
s = s.replace("_STORE_LOCK = threading.Lock()", "NHI_ACTOR = \"nhi-service\"\n_STORE_LOCK = threading.Lock()", 1)
p.write_text(s)
'
verdict "$(run tests/test_audit_event_types.py)"

# --------------------------------------------------------------------------
case_start "CASE 5  a new mutating route that audits nothing"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
anchor = "@router.get(\"/audit\", response_model=AuditListResponse, responses=ERROR_RESPONSES)"
add = """@router.post("/agents/{agent_id}/quarantine")
async def quarantine_agent(
    agent_id: str,
    tenant_id: Annotated[str, Depends(authenticated_tenant)],
) -> dict[str, str]:
    pool = await _get_pool()
    if pool is not None:
        await pool.execute(
            "UPDATE agent_registry SET lifecycle_state = $1 WHERE id = $2",
            "quarantined", _try_uuid(agent_id),
        )
    return {"status": "quarantined"}


"""
assert anchor in s, "CASE 5 anchor missing"
p.write_text(s.replace(anchor, add + anchor, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 6  a new in-memory (non-durable) audit path"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = """        await _audit_log(
            conn, tenant_id, "violation.acknowledged", None, None, principal.actor,
            {"violation_id": violation_id},
        )"""
new = """        if conn is None:
            _record_memory_audit(
                tenant_id, "violation.acknowledged", None, None, principal.actor,
                {"violation_id": violation_id},
            )
""" + old
assert old in s, "CASE 6 anchor missing"
p.write_text(s.replace(old, new, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 7  the browser writing the audit trail"
patch_py '
import pathlib
p = pathlib.Path("'"$REPO_ROOT"'/d2-signalloom/apps/dashboard-signalloom/src/api/client.ts"); s = p.read_text()
old = "  auditExportCsv: async ("
new = """  recordAuditEvent: (token: string, body: unknown) =>
    req<void>('"'"'/audit/events'"'"', token, { method: '"'"'POST'"'"', data: body }),

  auditExportCsv: async ("""
assert old in s, "CASE 7 anchor missing"
p.write_text(s.replace(old, new, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 8  writer signature drift (a reorder repoints every check one arg out)"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = "    executor: Any,\n    tenant_id: str,\n    event_type: str,\n    agent_id: str | None,"
new = "    executor: Any,\n    tenant_id: str,\n    agent_id: str | None,\n    event_type: str,"
assert old in s, "CASE 8 anchor missing"
p.write_text(s.replace(old, new, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 9  a stale exemption (fixing stun must FORCE its entries out)"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
before = s
s = s.replace("    reason = req.reason or \"operator-initiated stun\"\n    outcome = req.outcome or \"stunned\"\n",
              "    reason = \"operator-initiated stun\"\n    outcome = \"stunned\"\n", 1)
s = s.replace("            \"namespace\": req.namespace,\n", "            \"namespace\": None,\n", 1)
s = s.replace("            agent_name = req.agent_name or (None if agent is None else str(agent[\"name\"]))\n",
              "            agent_name = None if agent is None else str(agent[\"name\"])\n", 1)
s = s.replace("        agent_name = req.agent_name or (None if row is None else row[\"name\"])\n",
              "        agent_name = None if row is None else row[\"name\"]\n", 1)
assert s != before, "CASE 9 anchors missing"
p.write_text(s)
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 10  audit row written outside the transaction carrying the change"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
old = """        await _audit_log(
            conn, tenant_id, "violation.acknowledged", None, None, principal.actor,"""
new = """        await _audit_log(
            pool, tenant_id, "violation.acknowledged", None, None, principal.actor,"""
assert old in s, "CASE 10 anchor missing"
p.write_text(s.replace(old, new, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 11  a new endpoint whose only job is to record something elsewhere"
patch_py '
import pathlib
p = pathlib.Path("'"$SRC"'/api_compat.py"); s = p.read_text()
anchor = "@router.get(\"/audit\", response_model=AuditListResponse, responses=ERROR_RESPONSES)"
add = """@router.post("/agents/{agent_id}/record-external-action")
async def record_external_action(
    agent_id: str,
    principal: Annotated[Principal, Depends(authenticated_principal)],
) -> dict[str, str]:
    pool = await _get_pool()
    if pool is not None:
        await _audit_log(
            pool, principal.tenant, "agent.transitioned", agent_id, None,
            principal.actor, {"note": "performed by another service"},
        )
    return {"status": "recorded"}


"""
assert anchor in s, "CASE 11 anchor missing"
p.write_text(s.replace(anchor, add + anchor, 1))
'
verdict "$(run tests/test_audit_provenance.py)"

# --------------------------------------------------------------------------
case_start "CASE 12  losing f-string SQL (the blind spot test_write_transactions has)"
patch_py '
import pathlib
p = pathlib.Path("'"$GUARD"'"); s = p.read_text()
old = """    if isinstance(node, ast.JoinedStr):
        return "".join(
            part.value for part in node.values
            if isinstance(part, ast.Constant) and isinstance(part.value, str)
        )
"""
assert old in s, "CASE 12 anchor missing"
p.write_text(s.replace(old, "", 1))
'
verdict "$(run tests/test_audit_provenance.py)"

restore
printf '\n=== tree restored\n'
git -C "$REPO_ROOT" status --porcelain "${PRODUCTION_FILES[@]}" | sed 's/^/  /' || true

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s guard(s) failed to fire. Fix them before trusting this suite.\n' "$FAILURES"
  exit 1
fi
printf '\nAll cases red as required.\n'
