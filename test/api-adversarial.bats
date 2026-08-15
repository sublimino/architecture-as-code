#!/usr/bin/env bats
#
# Adversarial probes against the live API surface through the Gateway.
#
# These tests exercise the DEPLOYED system, not mocks. They verify that
# authentication, authorization, method restrictions, and input validation
# behave correctly under hostile input. Each test explains what attack it
# simulates, what the correct response is, and why.
#
# Requires: a running cluster with the Envoy Gateway port-forwarded or
# accessible. GATEWAY_URL can be overridden; defaults to port-forward setup.

setup_file() {
    export GATEWAY_URL="${GATEWAY_URL:-https://dashboard.osramp.acme.local:18443}"
    export RESOLVE="--resolve dashboard.osramp.acme.local:18443:127.0.0.1"

    # Start port-forward if the gateway is not already reachable.
    if ! curl -k -s -o /dev/null -w '%{http_code}' $RESOLVE "$GATEWAY_URL/" 2>/dev/null | grep -q '[23]'; then
        kubectl port-forward -n ingress svc/envoy-ingress-cluster-6b24dc08 18443:443 >/dev/null 2>&1 &
        export BATS_PF_PID=$!
        local i=0
        while ! curl -k -s -o /dev/null $RESOLVE "$GATEWAY_URL/" 2>/dev/null && [ $i -lt 15 ]; do
            sleep 1; i=$((i + 1))
        done
        if ! curl -k -s -o /dev/null -w '%{http_code}' $RESOLVE "$GATEWAY_URL/" 2>/dev/null | grep -q '[23]'; then
            echo "FATAL: Gateway unreachable after 15s" >&2
            kill "$BATS_PF_PID" 2>/dev/null || true
            return 1
        fi
    fi
}

teardown_file() {
    [ -n "${BATS_PF_PID:-}" ] && kill "$BATS_PF_PID" 2>/dev/null && wait "$BATS_PF_PID" 2>/dev/null || true
}

setup() {
    repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
    export GATEWAY_URL="${GATEWAY_URL:-https://dashboard.osramp.acme.local:18443}"
    export RESOLVE="--resolve dashboard.osramp.acme.local:18443:127.0.0.1"
}

curl_status() {
    curl -k -s -o /dev/null -w '%{http_code}' $RESOLVE "$@"
}

curl_body() {
    curl -k -s $RESOLVE "$@"
}

# ---------------------------------------------------------------------------
# Authentication enforcement
# ---------------------------------------------------------------------------

@test "unauthenticated POST to /demo-api/runs returns 401" {
    # Attack: drive the demo without credentials.
    local status
    status="$(curl_status -X POST "$GATEWAY_URL/demo-api/runs")"
    [ "$status" = "401" ]
}

@test "unauthenticated POST to /demo-api/reset returns 401" {
    local status
    status="$(curl_status -X POST "$GATEWAY_URL/demo-api/reset")"
    [ "$status" = "401" ]
}

@test "forged JWT is rejected by /demo-api/runs" {
    # Attack: present a well-formed but unsigned JWT.
    local fake_jwt="eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhdHRhY2tlckBldmlsLmNvbSIsImlhdCI6MTcxNjc2ODAwMCwiZXhwIjoxNzE2NzcxNjAwfQ.fake-signature"
    local status
    status="$(curl_status -X POST -H "Authorization: Bearer $fake_jwt" "$GATEWAY_URL/demo-api/runs")"
    # Should be 401 (bad signature) or 403 (no superadmin claim), not 200
    [[ "$status" =~ ^(401|403)$ ]]
}

# ---------------------------------------------------------------------------
# Method restriction on unauthenticated prefixes
# ---------------------------------------------------------------------------

@test "POST to /supercred-api/ is denied (nginx limit_except)" {
    local status
    status="$(curl_status -X POST "$GATEWAY_URL/supercred-api/agents/test/stun")"
    [ "$status" = "403" ]
}

@test "DELETE to /supercred-api/ is denied" {
    local status
    status="$(curl_status -X DELETE "$GATEWAY_URL/supercred-api/_test/requests")"
    [ "$status" = "403" ]
}

@test "PUT to /supercred-api/ is denied" {
    local status
    status="$(curl_status -X PUT -d '{}' "$GATEWAY_URL/supercred-api/_test/fixtures/evil")"
    [ "$status" = "403" ]
}

# ---------------------------------------------------------------------------
# Input validation / injection resistance
# ---------------------------------------------------------------------------

@test "path traversal in /supercred-api/ returns 404 not a file" {
    # Attack: escape the proxy prefix to reach nginx's filesystem.
    local status body
    status="$(curl_status "$GATEWAY_URL/supercred-api/../../etc/passwd")"
    body="$(curl_body "$GATEWAY_URL/supercred-api/../../etc/passwd")"
    # Must not return file contents. 400 or 404 or redirect are all acceptable.
    [[ ! "$body" =~ root: ]]
}

@test "null byte in URL does not bypass routing" {
    local status
    status="$(curl_status "$GATEWAY_URL/supercred-api/agents%00.html")"
    # Must not serve static content or crash
    [[ "$status" =~ ^(400|404|502)$ ]]
}

@test "oversized request body to /demo-api/ is rejected" {
    # Attack: send a multi-megabyte body to exhaust memory.
    python3 -c 'print("{\"x\":\"" + "A"*5000000 + "\"}")' > /tmp/bats-bigbody.json
    local status
    status="$(curl_status -X POST -H 'Content-Type: application/json' \
        -d @/tmp/bats-bigbody.json "$GATEWAY_URL/demo-api/runs" 2>/dev/null)"
    rm -f /tmp/bats-bigbody.json
    # 000 = connection closed by proxy (correct — Envoy drops oversized bodies)
    # 401/413/400 are all acceptable rejections. Only 200 is wrong.
    [[ "$status" != "200" ]]
}

# ---------------------------------------------------------------------------
# Header injection
# ---------------------------------------------------------------------------

@test "CRLF injection in Host header does not split the response" {
    # Attack: inject a second header via the Host field.
    local body
    body="$(curl -k -s $RESOLVE -H $'Host: dashboard.osramp.acme.local\r\nX-Injected: true' \
        "$GATEWAY_URL/" 2>/dev/null)"
    # Response must not contain the injected header as a reflected value
    [[ ! "$body" =~ X-Injected ]]
}

@test "oversized Host header is handled gracefully" {
    local status
    status="$(curl_status -H "Host: $(python3 -c 'print("A"*8192)')" "$GATEWAY_URL/" 2>/dev/null || true)"
    # Envoy closes the connection before completing an HTTP response for
    # oversized headers, so curl reports 000 (no status code received) or
    # exits non-zero. Both are correct rejections. Only 200 is wrong.
    [[ "$status" != "200" ]]
}

# ---------------------------------------------------------------------------
# Information leakage
# ---------------------------------------------------------------------------

@test "Dex does not expose admin endpoints to external callers" {
    # /dex/api/v1/... should not be reachable through the gateway
    local status
    status="$(curl_status "$GATEWAY_URL/dex/api/v1/connectors")"
    # 404 or 403 — not 200 with connector config
    [[ "$status" != "200" ]]
}

@test "error pages do not leak server version or stack traces" {
    local body
    body="$(curl_body "$GATEWAY_URL/nonexistent-path-12345")"
    # Must not contain Envoy version, nginx version, or Python tracebacks
    [[ ! "$body" =~ envoy ]]
    [[ ! "$body" =~ nginx/ ]]
    [[ ! "$body" =~ Traceback ]]
}

# ---------------------------------------------------------------------------
# Audit integrity (live, not mocked)
# ---------------------------------------------------------------------------

@test "GET /supercred-api/agents returns valid JSON" {
    local body
    body="$(curl_body "$GATEWAY_URL/supercred-api/agents")"
    echo "$body" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
}

@test "Dex OIDC discovery endpoint returns valid JSON with issuer" {
    local body
    body="$(curl_body "$GATEWAY_URL/dex/.well-known/openid-configuration")"
    echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "issuer" in d, "no issuer"'
}
