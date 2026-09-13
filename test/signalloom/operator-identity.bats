#!/usr/bin/env bats

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export REPO_ROOT
  export API_SRC="$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src"
  export MIGRATION="$API_SRC/db/migrations/038_operator_identities.sql"
  export POLICY="$REPO_ROOT/docs/signalloom/agentmaxxing-operator-policy.json"
}

@test "operator policy records individual OIDC attribution" {
  run python3 - "$POLICY" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
assert p["identity"]["source"] == "oidc"
assert p["identity"]["canonical_key"] == ["issuer", "subject"]
assert p["identity"]["account_kind"] == "individual"
assert p["identity"]["shared_accounts"] == "reject"
assert p["identity"]["anonymous_accounts"] == "reject"
PY
  [ "$status" -eq 0 ]
}

@test "operator policy records the approved authorization matrix" {
  run python3 - "$POLICY" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["authorization_matrix"]
assert set(m["admin"]) == {"operator:create", "operator:list", "operator:remove", "operator:sign-in"}
assert m["editor"] == ["operator:sign-in"]
assert m["viewer"] == ["operator:sign-in"]
PY
  [ "$status" -eq 0 ]
}

@test "operator policy names removal ownership and denial" {
  run python3 - "$POLICY" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))["removal"]
assert r["accountable_owner"] == "Andrew Martin"
assert r["operational_role"] == "admin"
assert r["post_removal_authentication"] == "reject"
assert r["audit_history"] == "retain"
PY
  [ "$status" -eq 0 ]
}

@test "database extension forbids shared rows and preserves attribution" {
  run python3 - "$MIGRATION" <<'PY'
import sys
s = open(sys.argv[1]).read()
assert "CHECK (identity_kind = 'individual')" in s
assert "UNIQUE (issuer, subject)" in s
for column in ("actor_user_id", "actor_issuer", "actor_subject"):
    assert f"ADD COLUMN IF NOT EXISTS {column}" in s
assert "DROP TABLE" not in s
assert "UPDATE public.platform_users" not in s
PY
  [ "$status" -eq 0 ]
}

@test "wire models reject shared identity and tenant spoofing" {
  run env PYTHONPATH="$API_SRC" python3 - <<'PY'
from pydantic import ValidationError
from operator_identity import OperatorIdentityCreateRequest

base = {
    "provider_subject": "fixture-operator",
    "email": "operator@agentmaxxing.example",
    "display_name": "Fixture Operator",
    "role": "editor",
}
for update in ({"identity_kind": "shared"}, {"tenant_id": "victim"}):
    try:
        OperatorIdentityCreateRequest.model_validate(base | update)
    except ValidationError:
        continue
    raise AssertionError(f"unsafe request accepted: {update}")
PY
  [ "$status" -eq 0 ]
}

@test "focused operator lifecycle tests execute without skips" {
  run env PYTHONPATH="$API_SRC" python3 -m pytest -p no:libtmux \
    "$API_SRC/tests/test_platform_users.py" -q -k test_operator_identity
  [ "$status" -eq 0 ]
  [[ "$output" == *"passed"* ]]
  [[ "$output" != *"skipped"* ]]
}
