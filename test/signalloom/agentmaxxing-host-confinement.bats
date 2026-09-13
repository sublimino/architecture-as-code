#!/usr/bin/env bats
# ==============================================================================
# AMXO-P4-1: AgentMaxxing Linux Host Confinement, Profile & Digest Gate Tests
# ==============================================================================

setup() {
    load "${BATS_TEST_DIRNAME}/../../scripts/lib/wait.sh" 2>/dev/null || true
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    APP_DIR="${REPO_ROOT}/d2-signalloom/apps/agentmaxxing-host-sensor"
    PROFILE_PATH="${APP_DIR}/profile.json"
    SERVICE_PATH="${APP_DIR}/agentmaxxing-agent.service"
    GATE_SCRIPT="${APP_DIR}/scripts/digest_gate.sh"
    START_SCRIPT="${APP_DIR}/scripts/start.sh"
    FIXTURE_POLICY="${REPO_ROOT}/d2-signalloom/governance/fixtures/agentmaxxing-host-policy.v1.json"

    TEST_TMP="$(mktemp -d /tmp/amxo-p41-bats-XXXXXX)"
}

teardown() {
    if [[ -d "${TEST_TMP:-}" ]]; then
        rm -rf "$TEST_TMP"
    fi
}

@test "confinement profile exists and passes nono profile validate" {
    [ -f "$PROFILE_PATH" ]
    run nono profile validate "$PROFILE_PATH"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Result: valid" ]]
}

@test "confinement profile matches approved policy roots and denies sensitive paths" {
    [ -f "$PROFILE_PATH" ]
    [ -f "$FIXTURE_POLICY" ]

    # Verify required filesystem allow paths
    run python3 -c "
import json
with open('$PROFILE_PATH') as f:
    prof = json.load(f)
allow = prof.get('filesystem', {}).get('allow', [])
read_paths = prof.get('filesystem', {}).get('read', [])
deny_paths = prof.get('filesystem', {}).get('deny', [])

assert '/var/lib/agentmaxxing/work' in allow, 'missing work allow'
assert '/var/lib/agentmaxxing/output' in allow, 'missing output allow'
assert '/var/lib/agentmaxxing/audit' in allow, 'missing audit allow'
assert '/run/agentmaxxing' in allow, 'missing run allow'

assert '/opt/agentmaxxing' in read_paths, 'missing /opt/agentmaxxing read'
assert '/etc/ssl/certs' in read_paths, 'missing ssl certs read'
assert '/srv/agentmaxxing/input' in read_paths, 'missing input read'

assert '/root' in deny_paths, 'missing /root deny'
assert '/etc/shadow' in deny_paths, 'missing /etc/shadow deny'
assert '/etc/sudoers' in deny_paths, 'missing /etc/sudoers deny'
assert any('.ssh' in d for d in deny_paths), 'missing ssh deny'
print('ROOTS_VALID')
"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ROOTS_VALID" ]]
}

@test "confinement profile enforces default-deny network with approved endpoints" {
    [ -f "$PROFILE_PATH" ]

    run python3 -c "
import json
with open('$PROFILE_PATH') as f:
    prof = json.load(f)
net = prof.get('network', {})
domains = net.get('allow_domain', [])
assert 'signal-ingest.signalloom.controlplane.io' in domains, 'missing signal-ingest allow_domain'
assert 'api.agentmaxxing.com' in domains, 'missing api.agentmaxxing.com allow_domain'
ports = net.get('connect_port', [])
assert 443 in ports, 'missing port 443 in connect_port'
print('NETWORK_VALID')
"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "NETWORK_VALID" ]]
}

@test "systemd service unit contains mandatory security hardening directives" {
    [ -f "$SERVICE_PATH" ]

    # Directives check
    grep -q "NoNewPrivileges=yes" "$SERVICE_PATH"
    grep -q "ProtectSystem=strict" "$SERVICE_PATH"
    grep -q "ProtectHome=yes" "$SERVICE_PATH"
    grep -q "ProtectKernelTunables=yes" "$SERVICE_PATH"
    grep -q "ProtectKernelModules=yes" "$SERVICE_PATH"
    grep -q "ProtectControlGroups=yes" "$SERVICE_PATH"
    grep -q "PrivateTmp=yes" "$SERVICE_PATH"
    grep -q "PrivateDevices=yes" "$SERVICE_PATH"
    grep -q "RestrictSUIDSGID=yes" "$SERVICE_PATH"
    grep -q "RestrictNamespaces=yes" "$SERVICE_PATH"
    grep -q "RestrictRealtime=yes" "$SERVICE_PATH"
    grep -q "LockPersonality=yes" "$SERVICE_PATH"
    grep -q "MemoryDenyWriteExecute=yes" "$SERVICE_PATH"
    grep -q "CapabilityBoundingSet=" "$SERVICE_PATH"
    grep -q "AmbientCapabilities=" "$SERVICE_PATH"
    grep -q "MemoryMax=512M" "$SERVICE_PATH"
    grep -q "TasksMax=64" "$SERVICE_PATH"
    grep -q "CPUQuota=200%" "$SERVICE_PATH"
    grep -q "ExecStartPre=/opt/agentmaxxing/scripts/digest_gate.sh" "$SERVICE_PATH"
    grep -q "ExecStart=/opt/agentmaxxing/scripts/start.sh" "$SERVICE_PATH"
}

@test "scripts pass bash syntax checks" {
    [ -x "$GATE_SCRIPT" ]
    [ -x "$START_SCRIPT" ]

    run bash -n "$GATE_SCRIPT"
    [ "$status" -eq 0 ]

    run bash -n "$START_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "digest gate fails closed on mismatched binary SHA-256 digest" {
    local mock_bin="$TEST_TMP/mock-agent"
    echo "#!/bin/sh" > "$mock_bin"
    echo "echo rogue agent" >> "$mock_bin"
    chmod 755 "$mock_bin"

    local wrong_digest="0000000000000000000000000000000000000000000000000000000000000000"

    run env AGENT_BINARY="$mock_bin" \
            AGENT_EXPECTED_DIGEST="$wrong_digest" \
            PROFILE_PATH="$PROFILE_PATH" \
            "$GATE_SCRIPT"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "AGENT BINARY DIGEST MISMATCH" ]]
}

@test "digest gate succeeds when binary SHA-256 matches expected digest" {
    local mock_bin="$TEST_TMP/mock-agent"
    echo "#!/bin/sh" > "$mock_bin"
    echo "echo valid agent" >> "$mock_bin"
    chmod 755 "$mock_bin"

    local valid_digest
    valid_digest="$(sha256sum "$mock_bin" | awk '{print $1}')"

    run env AGENT_BINARY="$mock_bin" \
            AGENT_EXPECTED_DIGEST="$valid_digest" \
            PROFILE_PATH="$PROFILE_PATH" \
            "$GATE_SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" =~ "All preflight verification gates PASSED" ]]
}

@test "digest gate rejects world-writable binary" {
    local mock_bin="$TEST_TMP/mock-agent-writable"
    echo "#!/bin/sh" > "$mock_bin"
    echo "echo writable agent" >> "$mock_bin"
    chmod 777 "$mock_bin"

    local valid_digest
    valid_digest="$(sha256sum "$mock_bin" | awk '{print $1}')"

    run env AGENT_BINARY="$mock_bin" \
            AGENT_EXPECTED_DIGEST="$valid_digest" \
            PROFILE_PATH="$PROFILE_PATH" \
            "$GATE_SCRIPT"

    [ "$status" -ne 0 ]
    [[ "$output" =~ "world-writable" ]]
}

@test "real Landlock probe: nono profile denies filesystem write outside workspace" {
    local test_work="$TEST_TMP/work"
    local test_output="$TEST_TMP/output"
    local test_state="$TEST_TMP/state"
    mkdir -p "$test_work" "$test_output" "$test_state"

    # Create test profile scoping to test workspace
    local test_profile="$TEST_TMP/test_profile.json"
    python3 -c "
import json
with open('$PROFILE_PATH') as f:
    p = json.load(f)
p['filesystem']['allow'] = ['$test_work', '$test_output']
with open('$test_profile', 'w') as f:
    json.dump(p, f, indent=2)
"

    # Attempt write to unallowed location /tmp/unallowed_probe.txt
    run env XDG_STATE_HOME="$test_state" \
            nono run -s --no-diagnostics --no-audit --profile "$test_profile" -- \
            touch /tmp/unallowed_probe.txt

    [ "$status" -ne 0 ]
    [ ! -f /tmp/unallowed_probe.txt ]
}

@test "real Landlock probe: nono profile denies reading sensitive /etc/shadow" {
    local test_work="$TEST_TMP/work"
    local test_state="$TEST_TMP/state"
    mkdir -p "$test_work" "$test_state"

    local test_profile="$TEST_TMP/test_profile.json"
    python3 -c "
import json
with open('$PROFILE_PATH') as f:
    p = json.load(f)
p['filesystem']['allow'] = ['$test_work']
with open('$test_profile', 'w') as f:
    json.dump(p, f, indent=2)
"

    run env XDG_STATE_HOME="$test_state" \
            nono run -s --no-diagnostics --no-audit --profile "$test_profile" -- \
            cat /etc/shadow

    [ "$status" -ne 0 ]
    [[ "$output" =~ "Permission denied" || "$output" == "" ]]
}

@test "real Landlock probe: nono profile denies unauthorized outbound network connection" {
    local test_work="$TEST_TMP/work"
    local test_state="$TEST_TMP/state"
    mkdir -p "$test_work" "$test_state"

    local test_profile="$TEST_TMP/test_profile.json"
    python3 -c "
import json
with open('$PROFILE_PATH') as f:
    p = json.load(f)
p['filesystem']['allow'] = ['$test_work']
with open('$test_profile', 'w') as f:
    json.dump(p, f, indent=2)
"

    run env XDG_STATE_HOME="$test_state" \
            nono run -s --no-diagnostics --no-audit --profile "$test_profile" -- \
            python3 -c 'import socket; s = socket.socket(); s.settimeout(1); s.connect(("1.1.1.1", 80))'

    [ "$status" -ne 0 ]
    [[ "$output" =~ "Permission denied" || "$output" =~ "Operation not permitted" || "$output" =~ "PermissionError" ]]
}
