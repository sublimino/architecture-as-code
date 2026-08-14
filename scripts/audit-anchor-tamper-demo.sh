#!/usr/bin/env bash
# Prove the audit-log verifier detects a real tamper in a real database.
#
# A verifier nobody has watched fail is not a verifier. This script inserts audit
# rows into the live public.audit_events table, anchors them, then modifies and
# deletes rows directly in Postgres -- behind the application, the way an
# attacker with database access would -- and shows the verifier going red and
# naming the affected checkpoint.
#
# It also does the converse, which matters just as much: it restores the tampered
# row to its exact original value and shows the verifier going green again. A
# detector that goes red and stays red is indistinguishable from one that is
# simply broken, and the restore is what demonstrates the digest is genuinely
# reproducible rather than merely unstable.
#
# SCOPE AND SAFETY
#
# Everything is written under a dedicated tenant_id, and the checkpoints are
# built with --tenant-scope for that tenant, so no row belonging to tenant-demo
# is read, written, or anchored. The cluster is shared with other work. Cleanup
# removes every row this script created, on any exit path.
set -euo pipefail

cd "$(dirname "$0")/.."

TENANT="${TENANT:-tenant-anchor-tamper-demo}"
PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-15432}"
DSN="${DATABASE_URL:-postgresql://signalloom:signalloom@${PGHOST}:${PGPORT}/signalloom}"
PYTHON="${PYTHON:-python3}"
SRC="d2-signalloom/apps/fe-signalloom/src"
ANCHOR_DIR="${AUDIT_ANCHOR_DIR:-$(mktemp -d)/audit-anchors}"

# shellcheck source=scripts/lib/keys.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/keys.sh"
# Absolute, resolved once, against the repo root we just cd'd to. The anchor()
# helper below runs from a subdirectory, so a relative key path would resolve
# against that subdirectory -- and the previous version of this script simply
# concatenated the repo root onto whatever KEYS_DIR held, which turned an
# absolute value into /repo/root/home/andy/.../.keys/witness.pem. It only ever
# worked because this worktree happened to contain its own .keys, and .keys is
# per-checkout by design, so an absolute KEYS_DIR from the Makefile is the
# NORMAL case rather than the exotic one.
KEYS_ABS="$(keys_dir_abs "$(pwd)")"

export AUDIT_ANCHOR_DIR="${ANCHOR_DIR}"

cleanup() {
  # Deliberately not inside the trap's own failure path: a failing last command
  # in a bash EXIT trap replaces the script's exit status, which has already
  # turned one green run in this repository into a reported failure.
  local status=$?
  "${PYTHON}" - "${DSN}" "${TENANT}" <<'PYEOF' >/dev/null 2>&1 || true
import asyncio, sys, asyncpg
async def main():
    c = await asyncpg.connect(dsn=sys.argv[1])
    await c.execute("DELETE FROM public.audit_events WHERE tenant_id = $1", sys.argv[2])
    await c.close()
asyncio.run(main())
PYEOF
  echo
  echo "cleanup: removed every audit_events row for ${TENANT}"
  exit "${status}"
}
trap cleanup EXIT

banner() { printf '\n\033[1m══ %s\033[0m\n' "$*"; }

sql() {
  "${PYTHON}" - "${DSN}" "$1" <<'PYEOF'
import asyncio, sys, asyncpg
async def main():
    c = await asyncpg.connect(dsn=sys.argv[1])
    result = await c.execute(sys.argv[2])
    print(result)
    await c.close()
asyncio.run(main())
PYEOF
}

anchor() {
  ( cd "${SRC}" && AUDIT_ANCHOR_DIR="${ANCHOR_DIR}" "${PYTHON}" -m audit_anchor \
      --dsn "${DSN}" \
      --private-key "${KEYS_ABS}/witness.pem" \
      --public-key "${KEYS_ABS}/witness-pub.pem" \
      --tenant-scope "${TENANT}" "$@" )
}

# ── Signing key ───────────────────────────────────────────────────────────────
# The same ed25519 key scripts/attested-test.sh signs Archivista attestations
# with, generated the same way `make signing-keys` generates it.
if [ ! -f "${KEYS_ABS}/witness.pem" ]; then
  banner "generating ${KEYS_ABS}/witness.pem"
  mkdir -p "${KEYS_ABS}"
  openssl genpkey -algorithm ed25519 -out "${KEYS_ABS}/witness.pem"
  openssl pkey -in "${KEYS_ABS}/witness.pem" -pubout -out "${KEYS_ABS}/witness-pub.pem"
fi

# Fail before touching the database. A key that cannot be read is a setup
# error, and there is no reason to discover it only after writing audit rows
# that then have to be cleaned up. Printing the resolved path is not decoration:
# the bug this preflight exists alongside was a path the script REPORTED
# correctly and PASSED incorrectly, so the resolved value is stated once, here,
# and every later invocation is built from the same variable.
echo "signing keys: ${KEYS_ABS}"
for key in "${KEYS_ABS}/witness.pem" "${KEYS_ABS}/witness-pub.pem"; do
  [ -f "${key}" ] || { echo "signing key not found: ${key}" >&2; exit 1; }
done

# ── 1. Seed ───────────────────────────────────────────────────────────────────
banner "1. writing audit rows for ${TENANT}"
sql "
INSERT INTO public.audit_events (tenant_id, event_type, agent_name, actor, detail)
VALUES
  ('${TENANT}', 'agent.created',     'Cardvault Agent', 'platform-admin',
   '{\"agent_ref\": \"agent-cardvault\", \"outcome\": \"created\"}'),
  ('${TENANT}', 'agent.transitioned','Cardvault Agent', 'platform-admin',
   '{\"from_state\": \"pending\", \"to_state\": \"active\", \"outcome\": \"promoted\"}'),
  ('${TENANT}', 'agent.stunned',     'Cardvault Agent', 'compliance-engine',
   '{\"reason\": \"compliance-failure: securityContext not set\", \"to_state\": \"suspended\", \"outcome\": \"stunned\"}'),
  ('${TENANT}', 'violation.acknowledged', NULL, 'platform-admin',
   '{\"violation\": \"CIS-5.2.1\", \"outcome\": \"acknowledged\"}')
"

# ── 2. Anchor ─────────────────────────────────────────────────────────────────
# --settle-lag 0 because the rows were written seconds ago and this is a demo.
# In service the default 300s lag applies; the transaction clamp is what makes
# the boundary safe either way.
banner "2. publishing a checkpoint"
anchor checkpoint --settle-lag 0

banner "3. verifying an untouched log -- expect INTACT, exit 0"
anchor verify && echo "EXIT: 0 (intact)"

# ── 3b. A second window, so divergence has somewhere to be localised ──────────
# One checkpoint can only ever answer "something changed". The claim worth
# testing is that a chain localises the change to the window it began in, and
# that requires at least two.
banner "3b. more audit activity, then a SECOND checkpoint"
sql "
INSERT INTO public.audit_events (tenant_id, event_type, agent_name, actor, detail)
VALUES
  ('${TENANT}', 'agent.credential_issued', 'Cardvault Agent', 'supercred-proxy',
   '{\"lease\": \"openbao/creds/cardvault\", \"outcome\": \"issued\"}'),
  ('${TENANT}', 'agent.credential_revoked', 'Cardvault Agent', 'supercred-proxy',
   '{\"lease\": \"openbao/creds/cardvault\", \"outcome\": \"revoked\"}')
"
anchor checkpoint --settle-lag 0
anchor show

banner "3c. verifying the two-checkpoint chain -- expect INTACT, exit 0"
anchor verify && echo "EXIT: 0 (intact)"

# ── 4. Tamper: modify ─────────────────────────────────────────────────────────
# The tampered row is in the FIRST window. The verifier must name checkpoint 0,
# not merely report that something somewhere is wrong.
banner "4. TAMPER -- rewriting a stun as an approval, directly in Postgres"
echo "    UPDATE audit_events SET detail = ... WHERE event_type = 'agent.stunned'"
sql "
UPDATE public.audit_events
   SET detail = '{\"reason\": \"reviewed and cleared\", \"to_state\": \"active\", \"outcome\": \"allowed\"}'
 WHERE tenant_id = '${TENANT}' AND event_type = 'agent.stunned'
"

banner "5. verifying the tampered log -- expect DIVERGED, exit 2"
set +e
anchor verify
verify_status=$?
set -e
echo "EXIT: ${verify_status}"
[ "${verify_status}" -eq 2 ] || { echo "FAIL: expected exit 2, got ${verify_status}"; exit 1; }
LOCALISATION_CHECK="$(mktemp)"
cat >"${LOCALISATION_CHECK}" <<'PYEOF'
import json, sys
result = json.load(sys.stdin)
diverged = [d["checkpoint_index"] for d in result["divergences"]]
assert diverged == [0], "expected divergence in checkpoint 0 only, got %r" % (diverged,)
print("    localisation confirmed: checkpoint 0 only, of %d checked; checkpoint 1 clean"
      % result["checkpoints_checked"])
PYEOF
# Two subtleties, both of which produced a wrong verdict while writing this.
# The checker reads stdin, so it must live in a file: a heredoc would BE stdin
# and would silently displace the piped JSON. And `verify` exits 2 by design
# here, so under `pipefail` a pipeline would inherit that 2 even though the
# checker succeeded -- the run reported FAIL immediately after printing that the
# check had passed. Redirect to a file and check separately.
LOCALISATION_JSON="$(mktemp)"
anchor verify --json >"${LOCALISATION_JSON}" 2>/dev/null || true
"${PYTHON}" "${LOCALISATION_CHECK}" <"${LOCALISATION_JSON}" \
  || { echo "FAIL: divergence was not localised to checkpoint 0"; exit 1; }

# ── 6. Restore ────────────────────────────────────────────────────────────────
banner "6. restoring the row byte-for-byte -- expect INTACT again, exit 0"
echo "    A detector that goes red and stays red is indistinguishable from one"
echo "    that is simply broken. Going green again proves the digest reproduces."
sql "
UPDATE public.audit_events
   SET detail = '{\"reason\": \"compliance-failure: securityContext not set\", \"to_state\": \"suspended\", \"outcome\": \"stunned\"}'
 WHERE tenant_id = '${TENANT}' AND event_type = 'agent.stunned'
"
anchor verify && echo "EXIT: 0 (intact)"

# ── 7. Re-serialise the JSONB with a different key order ──────────────────────
banner "7. rewriting the same JSON with its keys in a different order"
echo "    The canonicalisation hashes VALUES, not the text Postgres happens to"
echo "    render. Same content, different source order, must stay INTACT."
sql "
UPDATE public.audit_events
   SET detail = '{\"outcome\": \"stunned\", \"to_state\": \"suspended\", \"reason\": \"compliance-failure: securityContext not set\"}'
 WHERE tenant_id = '${TENANT}' AND event_type = 'agent.stunned'
"
anchor verify && echo "EXIT: 0 (intact)"

# ── 8. Tamper: delete ─────────────────────────────────────────────────────────
banner "8. TAMPER -- deleting an anchored row outright"
sql "
DELETE FROM public.audit_events
 WHERE tenant_id = '${TENANT}' AND event_type = 'violation.acknowledged'
"

banner "9. verifying after the deletion -- expect DIVERGED, exit 2"
set +e
anchor verify
verify_status=$?
set -e
echo "EXIT: ${verify_status}"
[ "${verify_status}" -eq 2 ] || { echo "FAIL: expected exit 2, got ${verify_status}"; exit 1; }

banner "PASS -- the verifier detected modification and deletion, and cleared a restore"
