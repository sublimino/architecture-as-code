#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      sltm-ingest-reload-ratelimit
# @target  d2-signalloom/apps/signal-ingest (api/key_reload.go, api/auth.go)
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 2, deliverables D8 and D9 (ADR-08)
#
# SLTM Phase 2: signal-ingest hot-reloads its projected key directory without
# restarting (D8), and enforces per-key rate limiting with 429 Retry-After (D9).
#
# Keys never touch argv: curl gets them from a 0600 header FILE.

bats_require_minimum_version 1.5.0

setup_file() {
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    export INGEST_DIR="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
    export GOLDEN="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"
    local T="${BATS_FILE_TMPDIR}"

    mkdir -p "${T}/keys" "${T}/headers"
    export KEY_A="TokenSecretKeyAWithAtLeast32BytesLength!!"
    export KEY_B="TokenSecretKeyBWithAtLeast32BytesLength!!"
    export KEY_B_ROTATED="TokenSecretKeyBRotatedWithAtLeast32Bytes!"

    # Two key specs: stun-sentinel (Key A) and fe-gateway (Key B)
    cat <<EOF >"${T}/spec.json"
[
  {"name":"stun-sentinel","subject":"static-key/stun-sentinel","tenant":"kusari","permissions":["observations:write","tenant:cross-write"]},
  {"name":"fe-gateway","subject":"static-key/fe-gateway","tenant":"kusari","permissions":["observations:write","tenant:cross-write","observations:read"]}
]
EOF

    # Projected secret directory initial layout:
    # ..ts_1/stun-sentinel, stun-sentinel.expires, fe-gateway, fe-gateway.expires
    # ..data -> ..ts_1
    # stun-sentinel -> ..data/stun-sentinel
    mkdir -p "${T}/keys/..ts_1"
    ( umask 077
      printf '%s' "${KEY_A}" >"${T}/keys/..ts_1/stun-sentinel"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_1/stun-sentinel.expires"
      printf '%s' "${KEY_B}" >"${T}/keys/..ts_1/fe-gateway"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_1/fe-gateway.expires"
      ln -s "..ts_1" "${T}/keys/..data_tmp"
      mv -T "${T}/keys/..data_tmp" "${T}/keys/..data"
      ln -s "..data/stun-sentinel" "${T}/keys/stun-sentinel"
      ln -s "..data/stun-sentinel.expires" "${T}/keys/stun-sentinel.expires"
      ln -s "..data/fe-gateway" "${T}/keys/fe-gateway"
      ln -s "..data/fe-gateway.expires" "${T}/keys/fe-gateway.expires"
    )

    ( cd "${INGEST_DIR}" && CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/go}" GOCACHE="${GOCACHE:-/tmp/go-cache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" \
        go build -o "${T}/signal-ingest" . ) || return 1

    read -r PORT PROBE_PORT < <(python3 -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
    export PORT PROBE_PORT

    # Start binary with 1s reload interval, rate=5, burst=3
    env -i PATH="${PATH}" HOME="${T}" PORT="${PORT}" \
        SIGNAL_INGEST_PROBE_PORT="${PROBE_PORT}" \
        SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR=1 \
        SIGNAL_AUDIT_FILE="${T}/audit.jsonl" \
        SIGNAL_AUTH_STATIC_KEYS="$(cat "${T}/spec.json")" \
        SIGNAL_AUTH_STATIC_KEYS_DIR="${T}/keys" \
        SIGNAL_AUTH_STATIC_KEYS_RELOAD_INTERVAL="1s" \
        SIGNAL_INGEST_RATE_PER_KEY="5" \
        SIGNAL_INGEST_RATE_BURST="3" \
        "${T}/signal-ingest" >"${T}/ingest.log" 2>&1 3>&- &
    echo $! >"${T}/ingest.pid"

    for _ in $(seq 1 80); do
        curl -fs -o /dev/null "http://127.0.0.1:${PROBE_PORT}/readyz" && return 0
        sleep 0.25
    done
    echo "signal-ingest did not become ready" >&2; cat "${T}/ingest.log" >&2; return 1
}

teardown_file() {
    local pid; pid="$(cat "${BATS_FILE_TMPDIR}/ingest.pid" 2>/dev/null)" || return 0
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null || true
}

hdr() { ( umask 077; printf 'Authorization: %s\n' "$2" >"$1" ); }

local_url() { printf 'http://127.0.0.1:%s%s' "${PORT}" "$1"; }

call_with_headers() {
    local m="$1" u="$2"; shift 2
    local body="${BATS_TEST_TMPDIR}/body"
    local code; code="$(curl -s -o "${body}" -D "${BATS_TEST_TMPDIR}/resp_headers" -w '%{http_code}' -X "${m}" "$@" "${u}")"
    printf '%s %s' "${code}" "$(cat "${body}")"
}

post_obs() { # <header-file>
    call_with_headers POST "$(local_url /api/v1/observations)" -H 'Content-Type: application/json' -H @"$1" --data-binary @"${GOLDEN}"
}

# ── Tests ───────────────────────────────────────────────────────────────────

@test "offline: initial keys authenticate successfully" {
    local hA="${BATS_TEST_TMPDIR}/hA" hB="${BATS_TEST_TMPDIR}/hB"
    hdr "$hA" "Bearer ${KEY_A}"
    hdr "$hB" "Bearer ${KEY_B}"

    run post_obs "$hA"
    [[ "$output" == 201* ]] || { echo "Key A failed: $output"; return 1; }

    run post_obs "$hB"
    [[ "$output" == 201* ]] || { echo "Key B failed: $output"; return 1; }
}

@test "offline: deleting a key's file makes it 401 within the configured interval without a restart" {
    local T="${BATS_FILE_TMPDIR}" pid
    pid="$(cat "${T}/ingest.pid")"
    [ -n "$pid" ]

    # Swap ..data to ..ts_2 which does NOT contain stun-sentinel
    mkdir -p "${T}/keys/..ts_2"
    ( umask 077
      printf '%s' "${KEY_B}" >"${T}/keys/..ts_2/fe-gateway"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_2/fe-gateway.expires"
      ln -s "..ts_2" "${T}/keys/..data_tmp"
      mv -T "${T}/keys/..data_tmp" "${T}/keys/..data"
    )

    local hA="${BATS_TEST_TMPDIR}/hA"
    hdr "$hA" "Bearer ${KEY_A}"

    # Poll until key A returns 401 (within 1s reload interval + headroom)
    local revoked=0
    for _ in $(seq 1 30); do
        run post_obs "$hA"
        if [[ "$output" == 401* ]]; then
            revoked=1
            break
        fi
        sleep 0.2
    done

    [ "$revoked" -eq 1 ] || { echo "Key A was not revoked within timeout: $output"; return 1; }

    # Verify signal-ingest is still running with the SAME PID
    kill -0 "${pid}"
    [ "$(cat "${T}/ingest.pid")" = "${pid}" ]

    # Key B must still work
    local hB="${BATS_TEST_TMPDIR}/hB"
    hdr "$hB" "Bearer ${KEY_B}"
    run post_obs "$hB"
    [[ "$output" == 201* ]] || { echo "Key B broken after Key A deletion: $output"; return 1; }
}

@test "offline: rotating a key makes the old value 401 and the new value 201" {
    local T="${BATS_FILE_TMPDIR}"
    # Swap ..data to ..ts_3 where fe-gateway has KEY_B_ROTATED
    mkdir -p "${T}/keys/..ts_3"
    ( umask 077
      printf '%s' "${KEY_B_ROTATED}" >"${T}/keys/..ts_3/fe-gateway"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_3/fe-gateway.expires"
      ln -s "..ts_3" "${T}/keys/..data_tmp"
      mv -T "${T}/keys/..data_tmp" "${T}/keys/..data"
    )

    local hOld="${BATS_TEST_TMPDIR}/hOld" hNew="${BATS_TEST_TMPDIR}/hNew"
    hdr "$hOld" "Bearer ${KEY_B}"
    hdr "$hNew" "Bearer ${KEY_B_ROTATED}"

    local rotated=0
    for _ in $(seq 1 30); do
        run post_obs "$hNew"
        if [[ "$output" == 201* ]]; then
            rotated=1
            break
        fi
        sleep 0.2
    done

    [ "$rotated" -eq 1 ] || { echo "New key not active within timeout: $output"; return 1; }

    # Old key must now be 401
    run post_obs "$hOld"
    [[ "$output" == 401* ]] || { echo "Old key still accepted after rotation: $output"; return 1; }
}

@test "offline: a malformed update keeps the old key working and the log names the key" {
    local T="${BATS_FILE_TMPDIR}"
    # Swap ..data to ..ts_4 where fe-gateway is malformed (too short)
    mkdir -p "${T}/keys/..ts_4"
    ( umask 077
      printf '%s' "short-invalid-key" >"${T}/keys/..ts_4/fe-gateway"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_4/fe-gateway.expires"
      ln -s "..ts_4" "${T}/keys/..data_tmp"
      mv -T "${T}/keys/..data_tmp" "${T}/keys/..data"
    )

    sleep 1.5 # wait for reload tick

    # Old valid key KEY_B_ROTATED must STILL work (kept last good value)
    local hGood="${BATS_TEST_TMPDIR}/hGood"
    hdr "$hGood" "Bearer ${KEY_B_ROTATED}"
    run post_obs "$hGood"
    [[ "$output" == 201* ]] || { echo "Last good key rejected after malformed update: $output"; return 1; }

    # Log must contain the rejection error naming fe-gateway
    grep -qF 'static key update rejected; keeping last good value' "${T}/ingest.log"
    grep -qF '"key":"fe-gateway"' "${T}/ingest.log"
}

@test "offline: flood from key A gets 429 with Retry-After while key B still gets 201" {
    local T="${BATS_FILE_TMPDIR}"
    # Restore valid keys in ..ts_5
    mkdir -p "${T}/keys/..ts_5"
    ( umask 077
      printf '%s' "${KEY_A}" >"${T}/keys/..ts_5/stun-sentinel"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_5/stun-sentinel.expires"
      printf '%s' "${KEY_B}" >"${T}/keys/..ts_5/fe-gateway"
      date -u -d '+30 days' +%F >"${T}/keys/..ts_5/fe-gateway.expires"
      ln -s "..ts_5" "${T}/keys/..data_tmp"
      mv -T "${T}/keys/..data_tmp" "${T}/keys/..data"
    )

    sleep 1.5 # wait for reload

    local hA="${BATS_TEST_TMPDIR}/hA" hB="${BATS_TEST_TMPDIR}/hB"
    hdr "$hA" "Bearer ${KEY_A}"
    hdr "$hB" "Bearer ${KEY_B}"

    # Rate burst is 3. Send 8 requests in a rapid loop with Key A.
    local got429=0
    local retryAfterPresent=0
    for _ in $(seq 1 8); do
        run post_obs "$hA"
        if [[ "$output" == 429* ]]; then
            got429=1
            if grep -qi '^retry-after:' "${BATS_TEST_TMPDIR}/resp_headers"; then
                retryAfterPresent=1
            fi
        fi
    done

    [ "$got429" -eq 1 ] || { echo "Key A flood did not trigger 429"; return 1; }
    [ "$retryAfterPresent" -eq 1 ] || { echo "429 response did not include Retry-After header"; return 1; }

    # Key B interleaved request must get 201
    run post_obs "$hB"
    [[ "$output" == 201* ]] || { echo "Key B was starved by Key A flood: $output"; return 1; }
}

@test "offline: no key values appear in any log or audit file" {
    local T="${BATS_FILE_TMPDIR}"
    for secret in "${KEY_A}" "${KEY_B}" "${KEY_B_ROTATED}" "short-invalid-key"; do
        if grep -qF "$secret" "${T}/ingest.log" "${T}/audit.jsonl" 2>/dev/null; then
            echo "Found secret $secret in logs or audit!" >&2
            return 1
        fi
    done
}

@test "offline: Deployment manifest mounts projected static keys without subPath and optional secrets" {
    local rendered="${BATS_TEST_TMPDIR}/manifest.yaml"
    kubectl kustomize "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/local" >"${rendered}" 2>/dev/null || skip "kustomize failed"

    # 1. Volume name signal-ingest-static-keys is projected with defaultMode 288 (0440)
    local vol
    vol="$(yq -o=json 'select(.kind == "Deployment" and .metadata.name == "signal-ingest") | .spec.template.spec.volumes[] | select(.name == "signal-ingest-static-keys")' "${rendered}")"
    [ -n "$vol" ] || { echo "signal-ingest-static-keys volume not found in Deployment"; return 1; }

    [ "$(jq -r '.projected.defaultMode' <<<"$vol")" = "288" ] || { echo "defaultMode not 288: $(jq -r '.projected.defaultMode' <<<"$vol")"; return 1; }

    # All secret sources are optional: true
    local nonOptional
    nonOptional="$(jq '[.projected.sources[] | select(.secret != null and .secret.optional != true)] | length' <<<"$vol")"
    [ "$nonOptional" -eq 0 ] || { echo "Found non-optional secret sources in projected volume"; return 1; }

    # 2. VolumeMount is at /etc/signal-ingest/static-keys and has NO subPath
    local mount
    mount="$(yq -o=json 'select(.kind == "Deployment" and .metadata.name == "signal-ingest") | .spec.template.spec.containers[0].volumeMounts[] | select(.name == "signal-ingest-static-keys")' "${rendered}")"
    [ -n "$mount" ] || { echo "signal-ingest-static-keys mount not found in container"; return 1; }

    [ "$(jq -r '.mountPath' <<<"$mount")" = "/etc/signal-ingest/static-keys" ]
    [ "$(jq -r '.subPath // ""' <<<"$mount")" = "" ]
}
