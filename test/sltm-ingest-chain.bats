#!/usr/bin/env bats
#
# sltm-ingest-chain.bats — verify signal-ingest D10 batch chain verification and audit trail.
#
# Runs offline (KUBECONFIG=/dev/null) against a freshly built signal-ingest binary.

setup_file() {
    T="${BATS_FILE_TMPDIR}"
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    INGEST_DIR="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
    GOLDEN_PAYLOAD="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"

    export T REPO_ROOT INGEST_DIR GOLDEN_PAYLOAD

    [ -f "${GOLDEN_PAYLOAD}" ] || {
        echo "golden payload fixture missing: ${GOLDEN_PAYLOAD}" >&2
        return 1
    }

    cat >"${T}/probe-spec.json" <<'EOF'
[
  {
    "name": "stun-sentinel",
    "subject": "static-key/stun-sentinel",
    "tenant": "kusari",
    "permissions": ["observations:write"]
  }
]
EOF

    mkdir -p "${T}/keys"
    ( umask 077
      head -c 36 /dev/urandom | base64 | tr -d '\n/+=' >"${T}/keys/stun-sentinel"
      date -u -d '+30 days' +%F >"${T}/keys/stun-sentinel.expires" )

    ( cd "${INGEST_DIR}" && CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/go}" GOCACHE="${GOCACHE:-/tmp/go-cache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" \
        go build -o "${T}/signal-ingest" . ) || return 1

    read -r PORT PROBE_PORT < <(python3 -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
    export PORT PROBE_PORT

    env -i PATH="${PATH}" HOME="${T}" PORT="${PORT}" \
        SIGNAL_INGEST_PROBE_PORT="${PROBE_PORT}" \
        SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR=1 \
        SIGNAL_AUDIT_FILE="${T}/audit.jsonl" \
        SIGNAL_AUTH_STATIC_KEYS="$(cat "${T}/probe-spec.json")" \
        SIGNAL_AUTH_STATIC_KEYS_DIR="${T}/keys" \
        "${T}/signal-ingest" >"${T}/ingest.log" 2>&1 3>&- &
    echo $! >"${T}/ingest.pid"

    for _ in $(seq 1 80); do
        if curl -fs -o /dev/null "http://127.0.0.1:${PROBE_PORT}/readyz"; then
            return 0
        fi
        sleep 0.25
    done
    echo "signal-ingest did not become ready" >&2; cat "${T}/ingest.log" >&2; return 1
}

teardown_file() {
    local pid
    pid="$(cat "${BATS_FILE_TMPDIR}/ingest.pid" 2>/dev/null)" || return 0
    if [ -n "${pid}" ]; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    fi
}

local_url() {
    printf 'http://127.0.0.1:%s%s' "${PORT}" "$1"
}

probe_key() {
    cat "${BATS_FILE_TMPDIR}/keys/stun-sentinel"
}

hdr() {
    ( umask 077; printf 'Authorization: Bearer %s\n' "$(probe_key)" >"$1" )
}

@test "unchained payload without D10 headers returns 201 and audits unchained" {
    local hfile="${BATS_TEST_TMPDIR}/auth.hdr"
    hdr "${hfile}"
    local body="${BATS_TEST_TMPDIR}/resp.body"

    local code
    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"ingested":2' "${body}"
}

@test "contiguous batch chain sequence returns 201 and emits epoch_started" {
    local hfile="${BATS_TEST_TMPDIR}/auth.hdr"
    hdr "${hfile}"
    local body="${BATS_TEST_TMPDIR}/resp.body"
    local epoch="abababababababababababababababab"

    local code
    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        -H "X-SignalLoom-Batch-Epoch: ${epoch}" \
        -H "X-SignalLoom-Batch-Seq: 1" \
        -H "X-SignalLoom-Batch-Prev: " \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"ingested":2' "${body}"

    # Compute prev hash for seq 2
    local prev
    prev="$(sha256sum "${GOLDEN_PAYLOAD}" | awk '{print $1}')"

    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        -H "X-SignalLoom-Batch-Epoch: ${epoch}" \
        -H "X-SignalLoom-Batch-Seq: 2" \
        -H "X-SignalLoom-Batch-Prev: ${prev}" \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"ingested":2' "${body}"
}

@test "replayed exact duplicate batch returns 201 with duplicate:true and audits replay" {
    local hfile="${BATS_TEST_TMPDIR}/auth.hdr"
    hdr "${hfile}"
    local body="${BATS_TEST_TMPDIR}/resp.body"
    local epoch="abababababababababababababababab"

    local prev
    prev="$(sha256sum "${GOLDEN_PAYLOAD}" | awk '{print $1}')"

    # Re-send seq 2 (identical duplicate)
    local code
    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        -H "X-SignalLoom-Batch-Epoch: ${epoch}" \
        -H "X-SignalLoom-Batch-Seq: 2" \
        -H "X-SignalLoom-Batch-Prev: ${prev}" \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"duplicate":true' "${body}"
    grep -q '"ingested":0' "${body}"
}

@test "sequence gap returns 201 and audits gap with missing range" {
    local hfile="${BATS_TEST_TMPDIR}/auth.hdr"
    hdr "${hfile}"
    local body="${BATS_TEST_TMPDIR}/resp.body"
    local epoch="abababababababababababababababab"

    local prev
    prev="$(sha256sum "${GOLDEN_PAYLOAD}" | awk '{print $1}')"

    # Send seq 5 (gap: missing 3, 4)
    local code
    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        -H "X-SignalLoom-Batch-Epoch: ${epoch}" \
        -H "X-SignalLoom-Batch-Seq: 5" \
        -H "X-SignalLoom-Batch-Prev: ${prev}" \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"ingested":2' "${body}"
}

@test "new epoch returns 201 and audits epoch_started" {
    local hfile="${BATS_TEST_TMPDIR}/auth.hdr"
    hdr "${hfile}"
    local body="${BATS_TEST_TMPDIR}/resp.body"
    local epochNew="cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd"

    local code
    code="$(curl -s -o "${body}" -w '%{http_code}' \
        -X POST \
        -H "Content-Type: application/json" \
        -H @"${hfile}" \
        -H "X-SignalLoom-Batch-Epoch: ${epochNew}" \
        -H "X-SignalLoom-Batch-Seq: 1" \
        -H "X-SignalLoom-Batch-Prev: " \
        --data-binary @"${GOLDEN_PAYLOAD}" \
        "$(local_url /api/v1/observations)")"

    [ "${code}" -eq 201 ]
    grep -q '"ingested":2' "${body}"
}

@test "audit file records exact expected event type counts and key name never leaks key value" {
    local auditFile="${BATS_FILE_TMPDIR}/audit.jsonl"
    [ -f "${auditFile}" ]

    # Check that bearer secret value is nowhere in audit lines
    local secret
    secret="$(probe_key)"
    if grep -qF "${secret}" "${auditFile}"; then
        echo "audit file leaks secret key value!" >&2
        return 1
    fi

    # Check key name (subject) is present in audit entries
    grep -q "static-key/stun-sentinel" "${auditFile}"

    # Check event counts by outcome
    local unchainedCount
    unchainedCount="$(jq -s '[.[] | select(.event_type == "batch_chain" and .detail.outcome == "unchained")] | length' "${auditFile}")"
    [ "${unchainedCount}" -ge 1 ]

    local epochStartedCount
    epochStartedCount="$(jq -s '[.[] | select(.event_type == "batch_chain" and .detail.outcome == "epoch_started")] | length' "${auditFile}")"
    [ "${epochStartedCount}" -eq 2 ]

    local replayCount
    replayCount="$(jq -s '[.[] | select(.event_type == "batch_chain" and .detail.outcome == "replayed")] | length' "${auditFile}")"
    [ "${replayCount}" -eq 1 ]

    local gapCount
    gapCount="$(jq -s '[.[] | select(.event_type == "batch_chain" and .detail.outcome == "gap")] | length' "${auditFile}")"
    [ "${gapCount}" -eq 1 ]
}
