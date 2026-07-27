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
