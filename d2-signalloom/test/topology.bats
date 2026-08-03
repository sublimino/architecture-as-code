#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/../.." && pwd)"
}

@test "split-ready Signalloom topology validates without a control-plane bootstrap" {
  run "$repo_root/d2-signalloom/test/validate-topology.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"topology validation passed"* ]]
}

@test "Phase 1 frontend reconciliation does not wait on later acceptance jobs" {
  run python3 - "$repo_root/d2-osramp-fleet/tenants/local/signalloom.yaml" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
apps = text[text.index('name: apps\n', text.index('name: signalloom-apps')):]
assert 'wait: false' in apps
assert 'wait: true' not in apps.split('postBuild:', 1)[0]
PY
  [ "$status" -eq 0 ]
}

@test "agent inventory resources are fleet-owned outside apps target namespace" {
  run python3 - "$repo_root" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
apps = (root / 'd2-signalloom/apps/fe-signalloom/base/kustomization.yaml').read_text()
fleet = (root / 'd2-osramp-fleet/tenants/local/signalloom.yaml').read_text()

assert 'agents-namespace.yaml' not in apps
assert 'agents-rbac.yaml' not in apps
assert 'agents-baseline.yaml' not in apps
assert 'name: fe-signalloom-agents' in fleet
assert 'name: agent-inventory-reader' in fleet
assert 'namespace: inf-signalloom' in fleet

# Pin agent-inventory-reader's grant exactly, rather than substring-matching a
# verb list that any other Role in this file could satisfy.
#
# This previously asserted `verbs: ["get", "list", "watch"]` appeared somewhere
# in the file. That broke when the Role legitimately gained `patch` (the
# SuperCred stun flow needs to relabel a pod), and it would equally have been
# satisfied by an unrelated Role elsewhere in the file — so it was both brittle
# and weak. Scope the assertion to this Role's own rules block and state the
# full expected verb set, so a genuine widening still fails the test.
reader = fleet[fleet.index('name: agent-inventory-reader'):]
rules = reader[reader.index('rules:'):reader.index('kind: RoleBinding')]

assert 'resources: ["pods"]' in rules, 'agent-inventory-reader must be pods-scoped'
assert 'verbs: ["get", "list", "watch", "patch"]' in rules, (
    'agent-inventory-reader verbs changed; confirm the widening is intended '
    'before updating this assertion'
)
# patch is the ceiling: the proxy may relabel an existing agent, never create,
# replace or remove one.
for forbidden in ('create', 'update', 'delete', 'deletecollection', '*'):
    assert f'"{forbidden}"' not in rules, f'agent-inventory-reader must not grant {forbidden}'
assert 'apiGroups: [""]' in rules, 'agent-inventory-reader must stay in the core API group'
PY
  [ "$status" -eq 0 ]
}

@test "Signal Loom artifact packages the SuperCred runner beside frontend manifests" {
  run python3 - "$repo_root" <<'PY'
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1])
push = (root / "scripts/push-local.sh").read_text()
activate = (root / "scripts/signalloom-local.sh").read_text()
restore = (root / "scripts/signalloom-up.sh").read_text()

assert '"signalloom/apps/fe-signalloom|d2-signalloom/apps"' in push
assert '"environment":"fe-signalloom/local"' in activate
assert '"environment":"fe-signalloom/local"' in restore

with tempfile.TemporaryDirectory() as temporary:
    artifact = Path(temporary) / "apps"
    shutil.copytree(root / "d2-signalloom/apps", artifact)
    subprocess.run(
        ["kubectl", "kustomize", str(artifact / "fe-signalloom/local")],
        check=True,
        stdout=subprocess.DEVNULL,
    )
PY
  [ "$status" -eq 0 ]
}
