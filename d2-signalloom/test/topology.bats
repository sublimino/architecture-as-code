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
assert 'resources: ["pods"]' in fleet
assert 'verbs: ["get", "list", "watch"]' in fleet
PY
  [ "$status" -eq 0 ]
}
