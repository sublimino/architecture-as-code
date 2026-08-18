#!/usr/bin/env bash
#
# edge-probe-positive.sh -- prove the allowlist did not become the only control.
#
# Run this from a source address that IS in the environment's allowlist. Getting
# through Cloud Armor is only half the assertion. The half that matters is what
# the application does next: an allowlisted, UNAUTHENTICATED client must be
# stopped at the authentication boundary (302 to an identity provider, or 401).
#
# An anonymous HTTP 200 is the failure this script exists to catch. It means
# network position alone granted access -- the allowlist silently became
# authentication, which is precisely the threat the proposal names.
#
# Usage:
#   edge-probe-positive.sh <hostname> [--path /] [--timeout 10] [--dry-run]
#
# Exit codes:
#   0  302 or 401 observed -- the authentication boundary held
#   2  usage error
#   3  anonymous 200 -- ALLOWLIST BECAME AUTHENTICATION, the critical failure
#   4  the request did not complete -- inconclusive, treated as failure
#   5  403 -- this source is not allowlisted, so nothing was proven
#   6  any other status code -- unexpected, treated as failure
set -Eeuo pipefail

readonly PROBE_NAME="edge-probe-positive"
readonly EXIT_USAGE=2
readonly EXIT_ANONYMOUS_200=3
readonly EXIT_INCONCLUSIVE=4
readonly EXIT_NOT_ALLOWLISTED=5
readonly EXIT_UNEXPECTED_RESPONSE=6

usage() {
  cat <<'USAGE'
Usage: edge-probe-positive.sh <hostname> [options]

Probes the Signal Loom edge from an ALLOWLISTED source address and asserts that
an unauthenticated request is stopped at the authentication boundary (302/401).
An anonymous 200 is a hard failure.

Arguments:
  <hostname>          Public hostname of the environment (e.g. demo-1.example.invalid).
                      Never hardcoded; always supplied by the caller.

Options:
  --path <path>       Request path. Default: /
  --timeout <secs>    Maximum seconds for the whole request. Default: 10
  --dry-run           Print exactly what would be done and exit 0. Makes no
                      network request whatsoever, so this is safe offline.
  -h, --help          Show this help.

Exit codes: 0 pass (302/401), 2 usage, 3 anonymous 200, 4 inconclusive,
            5 403 (source not allowlisted), 6 unexpected status.
USAGE
}

log() { printf '[%s] %s\n' "$PROBE_NAME" "$*"; }
fail() {
  local code="$1"
  shift
  printf '[%s] FAIL: %s\n' "$PROBE_NAME" "$*" >&2
  exit "$code"
}

main() {
  local hostname="" path="/" timeout="10" dry_run="false"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path)
        [ "$#" -ge 2 ] || fail "$EXIT_USAGE" "--path requires a value"
        path="$2"
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || fail "$EXIT_USAGE" "--timeout requires a value"
        timeout="$2"
        shift 2
        ;;
      --dry-run)
        dry_run="true"
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        usage >&2
        fail "$EXIT_USAGE" "unknown option: $1"
        ;;
      *)
        [ -z "$hostname" ] || fail "$EXIT_USAGE" "unexpected extra argument: $1"
        hostname="$1"
        shift
        ;;
    esac
  done

  [ -n "$hostname" ] || {
    usage >&2
    fail "$EXIT_USAGE" "hostname is required"
  }
  case "$timeout" in
    '' | *[!0-9]*) fail "$EXIT_USAGE" "--timeout must be a positive integer" ;;
    *) [ "$timeout" -gt 0 ] || fail "$EXIT_USAGE" "--timeout must be greater than zero" ;;
  esac

  local url="https://${hostname}${path}"

  if [ "$dry_run" = "true" ]; then
    log "DRY RUN -- no network request is made."
    log "would run: curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time ${timeout} --request GET -- ${url}"
    log "pass condition:   HTTP 302 or 401 -- the application's authentication boundary"
    log "fail conditions:  HTTP 200 anonymous (exit ${EXIT_ANONYMOUS_200}) -- allowlist became authentication;"
    log "                  HTTP 403 (exit ${EXIT_NOT_ALLOWLISTED}) -- this source is not allowlisted, nothing proven;"
    log "                  any other status (exit ${EXIT_UNEXPECTED_RESPONSE});"
    log "                  request did not complete (exit ${EXIT_INCONCLUSIVE})"
    log "precondition:     run this from a source address present in allowed_ipv4/allowed_ipv6,"
    log "                  and send NO credentials, cookies, or bearer tokens"
    exit 0
  fi

  log "probing ${url} from this host with no credentials, expecting 302 or 401"

  local code="" curl_status=0
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time "$timeout" --request GET -- "$url" 2>/dev/null)" || curl_status="$?"

  if [ "$curl_status" -ne 0 ]; then
    fail "$EXIT_INCONCLUSIVE" \
      "request to ${url} did not complete (curl exit ${curl_status}). Nothing was measured; this is not a pass."
  fi

  case "$code" in
    302 | 401)
      log "PASS: HTTP ${code} -- an allowlisted but unauthenticated client was stopped at the authentication boundary."
      return 0
      ;;
    200)
      fail "$EXIT_ANONYMOUS_200" \
        "HTTP 200 returned to an UNAUTHENTICATED client at ${url}. Network position alone granted access: the IP allowlist has become the only control. Application OIDC is not enforcing. Treat this as an open service."
      ;;
    403)
      fail "$EXIT_NOT_ALLOWLISTED" \
        "HTTP 403 from ${url}. This source is not on the allowlist, so the authentication boundary was never reached and nothing was proven. Re-run from an allowlisted source."
      ;;
    *)
      fail "$EXIT_UNEXPECTED_RESPONSE" \
        "unexpected HTTP ${code} from ${url}. Expected 302 or 401."
      ;;
  esac
}

main "$@"
