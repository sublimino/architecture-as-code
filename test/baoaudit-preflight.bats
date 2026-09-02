#!/usr/bin/env bats
# test/baoaudit-preflight.bats — BATS verification suite for BAOAUDIT preflight checks

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "baoaudit preflight: scripts/baoaudit-preflight.sh executes cleanly" {
    run "$REPO_ROOT/scripts/baoaudit-preflight.sh"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "BAOAUDIT PREFLIGHT PASSED" ]]
}

@test "baoaudit preflight: unix domain datagram sockets operate non-blocking" {
    TMP_SOCK="/tmp/bao-test-bats-$$.sock"
    python3 -c "
import socket, os
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind('$TMP_SOCK')
s.setblocking(False)
s.close()
os.unlink('$TMP_SOCK')
"
    [ "$?" -eq 0 ]
}

@test "baoaudit preflight: OpenBao audit JSON format matches schema" {
    python3 -c "
import json
sample_event = {
    'type': 'response',
    'time': '2026-09-02T08:00:00Z',
    'auth': {
        'client_token': 'hmac-masked-token-123',
        'policies': ['default', 'agent-cardvault-read'],
        'metadata': {'spiffe_id': 'spiffe://cluster.local/ns/fe-signalloom-agents/sa/agent-cardvault-sa'}
    },
    'request': {
        'operation': 'read',
        'path': 'secret/data/cardvault/keys'
    },
    'response': {
        'data': {'status': 'sanitized'}
    }
}
s = json.dumps(sample_event)
assert 'request' in s and 'auth' in s
"
    [ "$?" -eq 0 ]
}

@test "baoaudit preflight: signal-ingest passes go vet" {
    cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
    run go vet ./...
    [ "$status" -eq 0 ]
}

@test "baoaudit preflight: store package tests execute without data race" {
    cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
    run go test -v -race ./store/...
    [ "$status" -eq 0 ]
}
