#!/usr/bin/env bats
# ==============================================================================
# SLCD-P6-1: Detective Telemetry Mission CI Parity & Suite Integrity Tests
# ==============================================================================

setup() {
    load "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh" 2>/dev/null || true
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    APP_DIR="${REPO_ROOT}/d2-signalloom/apps/agentmaxxing-host-sensor"
}

@test "all 5 mission-wide test suites exist in sensor app directory" {
    [ -f "${APP_DIR}/test_mission_security_prohibited_procfs.py" ]
    [ -f "${APP_DIR}/test_mission_adversarial_leak_falsification.py" ]
    [ -f "${APP_DIR}/test_mission_full_sensor_integration.py" ]
    [ -f "${APP_DIR}/test_mission_tenant_isolation.py" ]
    [ -f "${APP_DIR}/test_mission_performance_overhead.py" ]
}

@test "python unittest discover loads every test_*.py module without orphan omission" {
    run python3 -c "
import os
import unittest
from pathlib import Path

app_dir = Path('$APP_DIR')
test_files = sorted([f.name for f in app_dir.glob('test_*.py')])
assert len(test_files) >= 20, f'Expected >= 20 test files, found {len(test_files)}'

loader = unittest.TestLoader()
suite = loader.discover(str(app_dir), pattern='test_*.py')
discovered_count = suite.countTestCases()
assert discovered_count >= 400, f'Expected >= 400 test cases, found {discovered_count}'
print(f'DISCOVERED_{len(test_files)}_FILES_{discovered_count}_CASES')
"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DISCOVERED_" ]]
}

@test "no un-prefixed orphan test files exist in agentmaxxing-host-sensor" {
    run python3 -c "
from pathlib import Path
app_dir = Path('$APP_DIR')
orphans = [
    f.name for f in app_dir.glob('*test*.py')
    if not f.name.startswith('test_')
]
assert len(orphans) == 0, f'Found orphan test files not matching test_*.py: {orphans}'
print('NO_ORPHAN_TEST_FILES')
"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "NO_ORPHAN_TEST_FILES" ]]
}

@test "prohibited procfs deny-list is pinned to exactly 17 entries across proc.py and test suites" {
    run python3 -c "
import sys
sys.path.insert(0, '$APP_DIR')
from proc import PROHIBITED_PROC_ENTRIES
from test_mission_security_prohibited_procfs import FROZEN_PROHIBITED_PROC_ENTRIES

assert len(PROHIBITED_PROC_ENTRIES) == 17, f'Expected 17 entries, got {len(PROHIBITED_PROC_ENTRIES)}'
assert frozenset(PROHIBITED_PROC_ENTRIES) == FROZEN_PROHIBITED_PROC_ENTRIES, 'Deny-list mismatch with security suite pin'
print('DENYLIST_17_PINNED')
"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "DENYLIST_17_PINNED" ]]
}

@test "mission security prohibited procfs suite passes" {
    run python3 -m unittest "${APP_DIR}/test_mission_security_prohibited_procfs.py"
    [ "$status" -eq 0 ]
}

@test "mission adversarial leak falsification suite passes" {
    run python3 -m unittest "${APP_DIR}/test_mission_adversarial_leak_falsification.py"
    [ "$status" -eq 0 ]
}

@test "mission full sensor multi-harness integration suite passes" {
    run python3 -m unittest "${APP_DIR}/test_mission_full_sensor_integration.py"
    [ "$status" -eq 0 ]
}

@test "mission tenant isolation and cryptographic partitioning suite passes" {
    run python3 -m unittest "${APP_DIR}/test_mission_tenant_isolation.py"
    [ "$status" -eq 0 ]
}

@test "mission performance and resource overhead suite passes" {
    run python3 -m unittest "${APP_DIR}/test_mission_performance_overhead.py"
    [ "$status" -eq 0 ]
}

@test "Makefile wires slcd-ci-parity into demo-agentmaxxing-host-test" {
    run grep -E "slcd-ci-parity\.bats" "${REPO_ROOT}/Makefile"
    [ "$status" -eq 0 ]
}
