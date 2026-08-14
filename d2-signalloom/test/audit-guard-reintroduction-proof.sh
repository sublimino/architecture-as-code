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

# How to invoke pytest.
#
# The harness used a bare `python3 -m pytest`, which is the ONLY thing in this
# repository that assumes a system-wide pytest. Every CI stage uses
# `uv run --with pytest ...` instead, and the CI VM has no system pytest at all:
#
#   pytest: /usr/bin/python3: No module named pytest
#
# So on the VM the guard could never run, every case reported "GUARD DID NOT
# FIRE", and the stage emitted a ZERO-BYTE report -- while passing 12/12 in 7s
# on any developer box with pytest installed. Invisible locally by construction.
#
# Prefer uv, matching the rest of CI; fall back to python3 -m pytest so a
# machine without uv still works.
pytest_cmd() {
  if command -v uv >/dev/null 2>&1; then
    printf 'uv run --python 3.12 --with pytest --with pytest-asyncio --quiet python -m pytest'
  else
    printf 'python3 -m pytest'
  fi
}

# `-o addopts=` neutralises whatever src/pytest.ini asks for.
#
# That ini gained `-n auto --dist worksteal` when the suite was parallelised.
# This harness runs with PYTEST_DISABLE_PLUGIN_AUTOLOAD=1, so pytest-xdist is
# not loaded, so `-n` and `--dist` are UNRECOGNISED ARGUMENTS and pytest exits
# on a usage error before collecting anything. No test ran, therefore no
# `E AssertionError` line appeared, therefore every single case reported
# "GUARD DID NOT FIRE — this check is decoration" and the harness announced
# that all 12 audit guards were decoration.
#
# A five-times speedup silently converted this proof into an alarm that fires
# constantly and means nothing. The message it produced was the most alarming
# one available -- indistinguishable, to a reader, from every audit-integrity
# guard having genuinely rotted.
#
# Parallelism is irrelevant here anyway: each case runs one file and wants a
# deterministic single process. Overriding addopts is narrower than pinning the
# plugin, and stays correct whatever else lands in that ini later.
run() {
  ( cd "$SRC" && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 timeout 300 \
      $(pytest_cmd) -o addopts= "$1" -q 2>&1 ) \
    | grep -E "^E +AssertionError" | head -2
}

# Did pytest actually execute the guard, or did it fail to start?
#
# The defect above was invisible because `run()` returns empty for BOTH "the
# guard ran and did not fire" and "pytest never ran at all", and verdict()
# reported the second as the first. That is the same conflation
# check-deployed-staleness.sh exists to avoid: "verified matching" and "cannot
# verify" are different answers and must not share an exit path.
#
# Called once before any case, so a broken invocation aborts loudly instead of
# being reported twelve times as a security finding.
assert_pytest_can_run() {
  # The strong form: run the guard UNMUTATED and require it to PASS.
  #
  # The first version of this preflight only asked whether pytest could
  # *collect*, and that was not enough. On the CI VM collection succeeded and
  # all twelve cases still reported "GUARD DID NOT FIRE", because a test that
  # ERRORS (a missing import, an unavailable dependency) emits no
  # "E AssertionError" line either -- and run() cannot tell an error from a
  # guard that stayed quiet. A weaker check in the same shape as the defect it
  # was written to catch.
  #
  # Requiring a clean green baseline collapses every one of those cases: if the
  # guard cannot pass on an unmodified tree, nothing below it means anything,
  # whatever the reason.
  local out rc
  out="$( cd "$SRC" && PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 timeout 300 \
            $(pytest_cmd) -o addopts= -q "$GUARD" 2>&1 )"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FATAL: the guard does not pass on an UNMODIFIED tree (pytest exit %s).\n' "$rc"
    printf 'Every case below would report "GUARD DID NOT FIRE" and mean nothing,\n'
    printf 'because run() cannot distinguish a quiet guard from one that never ran.\n'
    printf 'Fix the baseline first. Output:\n%s\n' "$out"
    exit 2
  fi
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

# Every case's patch already asserts its anchors, but NOTHING CHECKED THE EXIT
# CODE. This script is not `set -e`, so a failed assert printed a traceback and
# execution carried on -- the case then ran against an UNMUTATED file, the guard
# correctly stayed quiet because there was nothing to find, and the harness
# reported "GUARD DID NOT FIRE — this check is decoration".
#
# So the single most alarming message this tool can produce was reachable from a
# stale string anchor. The asserts were the mechanism; nobody read their verdict.
patch_py() {
  if ! python3 -c "$1"; then
    printf '\n  *** PATCH FAILED TO APPLY — this case did not test anything ***\n'
    printf '  The anchor assert above says which one. A case whose mutation never\n'
    printf '  landed reports "GUARD DID NOT FIRE" for a reason that has nothing to\n'
    printf '  do with the guard.\n'
    FAILURES=$((FAILURES + 1))
    return 1
  fi
}

# Assert the mechanism before testing it. Everything below is meaningless if
# pytest cannot start, and the failure looks exactly like a real finding.
assert_pytest_can_run

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
# Rewritten 2026-08-14, same reason as CASE 9: this used to delete one of the
# four stun exemptions to prove the dict keys per FIELD rather than per handler,
# and the stun fix removed the block it cut into.
#
# It now works the other way round -- add a SECOND violating field to a handler
# that already has one exempted. If the dict keyed per handler, the existing
# entry would cover the new field and nothing would fire. That tests the same
# property from the opposite direction and does not depend on there being more
# than one exemption for any given handler.
patch_py '
import pathlib
# Two edits: introduce a violation, then exempt a DIFFERENT field on the SAME
# handler. If the dict keyed per handler, that exemption would swallow the
# violation and nothing would fire.
src = pathlib.Path("'"$SRC"'/api_compat.py"); s = src.read_text()
old = "\"agent.created\", str(row[\"id\"]), body.name, principal.actor, {\"source\": \"api\"})"
assert old in s, "CASE 2 source anchor missing"
new = "\"agent.created\", str(row[\"id\"]), body.name, principal.actor, {\"source\": \"api\", \"note\": body.description})"
src.write_text(s.replace(old, new, 1))

g = pathlib.Path("'"$GUARD"'"); t = g.read_text()
anchor = "ACCEPTED_CLIENT_SUPPLIED_FIELDS: dict[tuple[str, str, str, str], str] = {"
assert anchor in t, "CASE 2 guard anchor missing"
g.write_text(t.replace(anchor, anchor + """
    ("api_compat.py", "create_agent", "detail", "name"): (
        "CASE 2 probe: exempts a DIFFERENT field on the same handler as the "
        "injected violation. If this silences the violation, the dict keys per "
        "handler and one accepted field grants an amnesty to every other."
    ),""", 1))
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
case_start "CASE 9  a stale exemption must FORCE its own removal"
# Rewritten 2026-08-14. This case used to patch api_compat.py to SIMULATE the
# stun fix, so that the four stun exemptions went stale. The stun fix has since
# landed for real and those entries are gone, which broke the case outright --
# it searched for source that no longer exists.
#
# That is the case doing its job and then outliving its target, and it is worth
# recording rather than quietly repointing: a proof anchored to one handler's
# source shape has a shelf life measured in fixes. Anchoring instead to the
# exemption dict itself tests the same property -- an entry that no longer
# describes a violation must fail -- and cannot rot when a handler changes,
# because a non-violating call site is what it asserts about.
patch_py '
import pathlib
p = pathlib.Path("'"$GUARD"'"); s = p.read_text()
anchor = "ACCEPTED_CLIENT_SUPPLIED_FIELDS: dict[tuple[str, str, str, str], str] = {"
assert anchor in s, "CASE 9 anchor missing"
# acknowledge_violation takes no request body at all -- it performs its own
# UPDATE and sources the actor from the principal. Exempting it is therefore
# exempting a call site that cannot violate, which is exactly the shape of a
# stale entry left behind after a fix.
s = s.replace(anchor, anchor + """
    ("api_compat.py", "acknowledge_violation", "detail", "reason"): (
        "CASE 9 probe: an exemption for a handler that accepts no client "
        "content at all. If this passes, a real exemption can outlive the "
        "defect it described and go on covering whatever moves in behind it."
    ),""", 1)
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
