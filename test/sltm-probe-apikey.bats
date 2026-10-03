#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      sltm-probe-apikey
# @target  d2-signalloom/apps/signal-ingest (api/static_keys.go, api/static_bearer.go)
# @doc     docs/Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4).md
# @spec    SLTM Phase 1, deliverables D1-D4 and D6 (ADR-03)
#
# SLTM Phase 1: the probe in the Kusari cluster authenticates to signal-ingest
# with ONE static API key in an `Authorization: Bearer` header, verified by the
# signal-ingest in that same cluster. Nothing else: no SPIRE, no JWT, no token
# refresh, no cross-cluster trust.
#
# Offline tier (always runs, no cluster): builds the REAL signal-ingest binary,
# starts it with the stun-sentinel key spec exactly as the deployed manifest
# renders it, and drives the auth contract over HTTP.
#
# Live tier (SLTM_LIVE=1 and a real KUBECONFIG): the same contract against the
# deployed signal-ingest on the Kusari cluster, using the probe's real key from
# its Secret, plus the same-cluster and no-cross-cluster-key invariants.
#
# Keys never touch argv: curl gets them from a 0600 header FILE.

bats_require_minimum_version 1.5.0

setup_file() {
    export REPO_ROOT="${BATS_TEST_DIRNAME}/.."
    export INGEST_DIR="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
    export GOLDEN="${REPO_ROOT}/d2-signalloom/apps/stun-sentinel/pkg/correlator/testdata/ingest-observation.golden.json"
    export WL_CONTEXT="${WL_CONTEXT:-kind-osramp}"
    export HUB_CONTEXT="${HUB_CONTEXT:-kind-signalloom-hub}"
    local T="${BATS_FILE_TMPDIR}"

    # The probe's key spec, exactly as the reconciled manifest renders it.
    kubectl kustomize "${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/local" 2>/dev/null \
        | yq -o=json 'select(.kind == "ConfigMap" and .data.SIGNAL_AUTH_STATIC_KEYS != null) | .data.SIGNAL_AUTH_STATIC_KEYS' \
        | jq -r 'fromjson? // . ' | jq -c '[.[] | select(.name == "stun-sentinel")]' >"${T}/probe-spec.json"
    [ "$(jq length "${T}/probe-spec.json")" = 1 ] || { echo "no stun-sentinel key in the rendered manifest" >&2; return 1; }
    # The same spec plus a key that expired yesterday (disabled at load).
    jq -c '. + [{"name":"expired-probe","subject":"static-key/expired-probe","tenant":"kusari","permissions":["observations:write"]}]' \
        "${T}/probe-spec.json" >"${T}/spec.json"

    mkdir -p "${T}/keys"
    ( umask 077
      head -c 36 /dev/urandom | base64 | tr -d '\n/+=' >"${T}/keys/stun-sentinel"
      date -u -d '+30 days' +%F >"${T}/keys/stun-sentinel.expires"
      head -c 36 /dev/urandom | base64 | tr -d '\n/+=' >"${T}/keys/expired-probe"
      date -u -d '-1 day' +%F >"${T}/keys/expired-probe.expires" )

    ( cd "${INGEST_DIR}" && CGO_ENABLED=0 GOPATH="${GOPATH:-/tmp/go}" GOCACHE="${GOCACHE:-/tmp/go-cache}" GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}" \
        go build -o "${T}/signal-ingest" . ) || return 1

    read -r PORT PROBE_PORT < <(python3 -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
    export PORT PROBE_PORT

    # Static keys only: no DATABASE_URL, no JWKS (every JWT is refused).
    env -i PATH="${PATH}" HOME="${T}" PORT="${PORT}" \
        SIGNAL_INGEST_PROBE_PORT="${PROBE_PORT}" \
        SIGNAL_INGEST_ALLOW_NOOP_ENCRYPTOR=1 \
        SIGNAL_AUDIT_FILE="${T}/audit.jsonl" \
        SIGNAL_AUTH_STATIC_KEYS="$(cat "${T}/spec.json")" \
        SIGNAL_AUTH_STATIC_KEYS_DIR="${T}/keys" \
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

# absent <needle> <file>: the needle is NOT in the file. bats does not fail a
# test on `! cmd` (errexit ignores negated commands), so assert explicitly.
absent() { if grep -qF -- "$1" "$2"; then echo "found in $2" >&2; return 1; fi; }

# hdr <file> <value>: write an Authorization header file, 0600, never argv.
hdr() { ( umask 077; printf 'Authorization: %s\n' "$2" >"$1" ); }

# call <method> <url> [curl args...]: prints "<status> <body>".
call() {
    local m="$1" u="$2"; shift 2
    local body="${BATS_TEST_TMPDIR}/body"
    local code; code="$(curl -s -o "${body}" -w '%{http_code}' -X "${m}" "$@" "${u}")"
    printf '%s %s' "${code}" "$(cat "${body}")"
}

local_url() { printf 'http://127.0.0.1:%s%s' "${PORT}" "$1"; }
probe_key() { cat "${BATS_FILE_TMPDIR}/keys/stun-sentinel"; }

post_golden() { # <header-file or empty>
    if [ -n "${1:-}" ]; then
        call POST "$(local_url /api/v1/observations)" -H 'Content-Type: application/json' -H @"$1" --data-binary @"${GOLDEN}"
    else
        call POST "$(local_url /api/v1/observations)" -H 'Content-Type: application/json' --data-binary @"${GOLDEN}"
    fi
}

# ── offline tier: the real binary, the deployed key spec ─────────────────────

@test "offline: the probe's key spec is observations:write plus cross-tenant write, nothing else" {
    run jq -c '.[0].permissions | sort' "${BATS_FILE_TMPDIR}/probe-spec.json"
    [ "$status" -eq 0 ]
    [ "$output" = '["observations:write","tenant:cross-write"]' ]
}

@test "offline: no Authorization header is 401" {
    run post_golden ""
    [[ "$output" == 401* ]]
    [[ "$output" == *authentication_failed* ]]
}

@test "offline: a wrong key, a prefix, a suffix and a padded key are each 401" {
    local h="${BATS_TEST_TMPDIR}/h" k; k="$(probe_key)"
    for bad in "Bearer not-the-probe-key-0123456789abcdefghij" "Bearer ${k%?}" "Bearer ${k}x" "Bearer  ${k} "; do
        hdr "$h" "$bad"
        run post_golden "$h"
        [[ "$output" == 401* ]] || { echo "accepted: ${bad:0:12}… -> ${output:0:40}"; return 1; }
    done
}

@test "offline: the right key under the Basic scheme is 401" {
    local h="${BATS_TEST_TMPDIR}/h"
    hdr "$h" "Basic $(probe_key)"
    run post_golden "$h"
    [[ "$output" == 401* ]]
}

@test "offline: a valid key beside a second Authorization header is 401" {
    local h="${BATS_TEST_TMPDIR}/h"
    printf 'Authorization: Bearer %s\nAuthorization: Bearer forged\n' "$(probe_key)" >"$h"
    run post_golden "$h"
    [[ "$output" == 401* ]]
}

@test "offline: an expired key is 401" {
    local h="${BATS_TEST_TMPDIR}/h"
    hdr "$h" "Bearer $(cat "${BATS_FILE_TMPDIR}/keys/expired-probe")"
    run post_golden "$h"
    [[ "$output" == 401* ]]
}

@test "offline: the probe's key posts the sentinel's real payload and gets 201" {
    local h="${BATS_TEST_TMPDIR}/h"
    hdr "$h" "Bearer $(probe_key)"
    run post_golden "$h"
    [[ "$output" == 201* ]] || { echo "$output"; return 1; }
    [ "$(printf '%s' "${output#201 }" | jq '.ingested')" = "$(jq length "${GOLDEN}")" ]
}

@test "offline: the probe's key on a read route is 403" {
    local h="${BATS_TEST_TMPDIR}/h"
    hdr "$h" "Bearer $(probe_key)"
    run call GET "$(local_url '/api/v1/observations?limit=1')" -H @"$h"
    [[ "$output" == 403* ]] || { echo "$output"; return 1; }
}

@test "offline: health answers on the probe port without a key, and the API port wants one" {
    run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PROBE_PORT}/healthz"
    [ "$output" = 200 ]
    run curl -s -o /dev/null -w '%{http_code}' "$(local_url /healthz)"
    [ "$output" = 401 ]
}

@test "offline: the key value is in no argv, environment, log or audit line; its name is logged" {
    local pid k; pid="$(cat "${BATS_FILE_TMPDIR}/ingest.pid")"; k="$(probe_key)"
    tr '\0' '\n' <"/proc/${pid}/cmdline" >"${BATS_TEST_TMPDIR}/cmdline"
    tr '\0' '\n' <"/proc/${pid}/environ" >"${BATS_TEST_TMPDIR}/environ"
    absent "$k" "${BATS_TEST_TMPDIR}/cmdline"
    absent "$k" "${BATS_TEST_TMPDIR}/environ"
    absent "$k" "${BATS_FILE_TMPDIR}/ingest.log"
    absent "$k" "${BATS_FILE_TMPDIR}/audit.jsonl"
    grep -qF '"key":"stun-sentinel"' "${BATS_FILE_TMPDIR}/ingest.log"
}

# ── live tier: the Kusari cluster ────────────────────────────────────────────

live_or_skip() {
    [ "${SLTM_LIVE:-}" = 1 ] && [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG}" != /dev/null ] \
        || skip "live tier: set SLTM_LIVE=1 and a real KUBECONFIG"
}

# live_post <header-file or empty> [GET]: one request to the Kusari cluster's
# signal-ingest through a port-forward (3>&- keeps it off bats' fd 3).
live_call() {
    local h="$1" method="${2:-POST}" port="${SLTM_LIVE_PORT:-28093}" pf out
    kubectl --context "${WL_CONTEXT}" -n fe-signalloom port-forward svc/signal-ingest "${port}:8082" >/dev/null 2>&1 3>&- &
    pf=$!
    for _ in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:${port}/" && break; sleep 0.25; done
    local args=(-H 'Content-Type: application/json')
    [ -n "$h" ] && args+=(-H @"$h")
    if [ "$method" = GET ]; then
        out="$(call GET "http://127.0.0.1:${port}/api/v1/observations?limit=1" "${args[@]}")"
    else
        out="$(call POST "http://127.0.0.1:${port}/api/v1/observations" "${args[@]}" --data-binary @"${GOLDEN}")"
    fi
    kill "$pf" 2>/dev/null; wait "$pf" 2>/dev/null
    printf '%s' "$out"
}

live_probe_key_hdr() { # writes the probe's real key, from its Secret, into a header file
    local k
    k="$(kubectl --context "${WL_CONTEXT}" -n fe-signalloom-agents get secret stun-sentinel-ingest-token \
        -o 'jsonpath={.data.token}' | base64 -d)" || return 1
    [ -n "$k" ] || return 1
    hdr "$1" "Bearer ${k}"
}

@test "live: the Kusari cluster's signal-ingest runs an immutable image, not the side-loaded :local" {
    live_or_skip
    run kubectl --context "${WL_CONTEXT}" -n fe-signalloom get deploy signal-ingest -o 'jsonpath={.spec.template.spec.containers[0].image}'
    [ "$status" -eq 0 ]
    [[ "$output" == *signal-ingest:src-* ]] || { echo "image: $output"; return 1; }
}

@test "live: the probe posts to its own cluster's signal-ingest, with its key from a Secret" {
    live_or_skip
    local ds; ds="$(kubectl --context "${WL_CONTEXT}" -n fe-signalloom-agents get ds stun-sentinel -o json)"
    [ "$(jq -r '.spec.template.spec.containers[0].env[] | select(.name=="SIGNAL_INGEST_TOKEN") | .valueFrom.secretKeyRef.name' <<<"$ds")" = stun-sentinel-ingest-token ]
    run kubectl --context "${WL_CONTEXT}" -n fe-signalloom-agents get cm stun-sentinel-config -o 'jsonpath={.data.SIGNAL_INGEST_URL}'
    [ "$output" = "http://signal-ingest.fe-signalloom.svc.cluster.local:8082" ]
}

@test "live: anonymous and wrong-key writes to the Kusari cluster's signal-ingest are 401" {
    live_or_skip
    run live_call ""
    [[ "$output" == 401* ]] || { echo "$output"; return 1; }
    local h="${BATS_TEST_TMPDIR}/h"
    hdr "$h" "Bearer not-the-probe-key-0123456789abcdefghij"
    run live_call "$h"
    [[ "$output" == 401* ]] || { echo "$output"; return 1; }
}

@test "live: the probe's key writes (201) and cannot read (403)" {
    live_or_skip
    local h="${BATS_TEST_TMPDIR}/h"
    live_probe_key_hdr "$h"
    run live_call "$h"
    [[ "$output" == 201* ]] || { echo "$output"; return 1; }
    run live_call "$h" GET
    [[ "$output" == 403* ]] || { echo "$output"; return 1; }
}

@test "live: the running probe holds its key and is posting with it" {
    live_or_skip
    run kubectl --context "${WL_CONTEXT}" -n fe-signalloom-agents logs ds/stun-sentinel --since=24h
    [ "$status" -eq 0 ]
    printf '%s' "$output" >"${BATS_TEST_TMPDIR}/sentinel.log"
    absent '"event":"ingest_token_missing"' "${BATS_TEST_TMPDIR}/sentinel.log"
    run kubectl --context "${WL_CONTEXT}" -n fe-signalloom logs deploy/signal-ingest --since=24h
    grep -qF '"key":"stun-sentinel"' <<<"$output"
}

@test "live: no ingest key exists on any other cluster (no cross-cluster auth)" {
    live_or_skip
    run kubectl --context "${HUB_CONTEXT}" get secrets -A -o 'jsonpath={range .items[*]}{.metadata.name}{"\n"}{end}'
    [ "$status" -eq 0 ]
    if grep -E -e '^(signal-ingest-key-|stun-sentinel-ingest-token$|signal-ingest-static-bearer)' <<<"$output"; then return 1; fi
}

@test "live: the probe's key value appears in no pod spec on the Kusari cluster" {
    live_or_skip
    local h="${BATS_TEST_TMPDIR}/h" k
    live_probe_key_hdr "$h"; k="$(sed 's/^Authorization: Bearer //' "$h")"
    run kubectl --context "${WL_CONTEXT}" get pods,deploy,ds,cm -A -o json
    [ "$status" -eq 0 ]
    printf '%s' "$output" >"${BATS_TEST_TMPDIR}/specs.json"
    absent "$k" "${BATS_TEST_TMPDIR}/specs.json"
}
