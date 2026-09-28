#!/usr/bin/env bats
# SLSEC F6/F7/F2: the dashboard nginx front must emit a complete security-header
# set, suppress its version banner, and rate-limit the Dex token endpoint.
# Static parse of the checked-in config — no running server required.

CONF="${BATS_TEST_DIRNAME}/../apps/dashboard-signalloom/nginx.conf"

setup() {
  [ -f "$CONF" ] || { echo "nginx.conf not found at $CONF"; return 1; }
}

@test "server_tokens is disabled (no version banner)" {
  grep -qE '^\s*server_tokens\s+off;' "$CONF"
}

@test "Content-Security-Policy header present and always" {
  grep -qE 'add_header\s+Content-Security-Policy\s+.*always;' "$CONF"
  grep -qE "frame-ancestors 'none'" "$CONF"
}

@test "X-Frame-Options DENY always" {
  grep -qE 'add_header\s+X-Frame-Options\s+"DENY"\s+always;' "$CONF"
}

@test "X-Content-Type-Options nosniff always" {
  grep -qE 'add_header\s+X-Content-Type-Options\s+"nosniff"\s+always;' "$CONF"
}

@test "Referrer-Policy no-referrer always" {
  grep -qE 'add_header\s+Referrer-Policy\s+"no-referrer"\s+always;' "$CONF"
}

@test "Strict-Transport-Security present always" {
  grep -qE 'add_header\s+Strict-Transport-Security\s+.*max-age=[0-9]+.*always;' "$CONF"
}

@test "Permissions-Policy present always" {
  grep -qE 'add_header\s+Permissions-Policy\s+.*always;' "$CONF"
}

@test "Dex token endpoint is rate-limited (F2)" {
  grep -qE 'limit_req_zone\s+\$binary_remote_addr\s+zone=dex_token' "$CONF"
  # exact-match location so only the token endpoint is throttled
  grep -qE 'location\s*=\s*/dex/token' "$CONF"
  grep -qE 'limit_req\s+zone=dex_token' "$CONF"
}

@test "login/JWKS path is NOT throttled (only the token endpoint is)" {
  # Extract the body of the general "location /dex/ {" prefix block and assert
  # it contains no limit_req (only the exact-match /dex/token block is throttled).
  body="$(awk '/location \/dex\/ \{/{f=1;next} f&&/^\s*\}/{f=0} f{print}' "$CONF")"
  [ -n "$body" ]
  ! echo "$body" | grep -q 'limit_req'
}
