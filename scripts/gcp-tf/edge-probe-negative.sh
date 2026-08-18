#!/usr/bin/env bash
#
# edge-probe-negative.sh -- prove the Cloud Armor default deny is doing its job.
#
# Run this from a source address that is NOT in the environment's allowlist.
# The pass condition is a 403 issued by Cloud Armor. Anything else fails,
# INCLUDING a connection timeout: a timeout proves nothing about the policy,
# it only proves the packet did not arrive, and treating "not 200" as success
# is exactly how a wide-open edge gets certified as closed.
#
# Usage:
#   edge-probe-negative.sh <hostname> [--path /] [--timeout 10] [--dry-run]
#
# Exit codes:
#   0  403 observed -- the default deny fired
#   2  usage error
#   3  a response other than 403 -- the edge answered an unlisted source
#   4  the request did not complete -- inconclusive, treated as failure
set -Eeuo pipefail

readonly PROBE_NAME="edge-probe-negative"
readonly EXIT_USAGE=2
readonly EXIT_UNEXPECTED_RESPONSE=3
readonly EXIT_INCONCLUSIVE=4
readonly EXPECTED_CODE="403"

usage() {
  cat <<'USAGE'
Usage: edge-probe-negative.sh <hostname> [options]

Probes the Signal Loom edge from an UNLISTED source address and asserts that
Cloud Armor returns 403.

Arguments:
  <hostname>          Public hostname of the environment (e.g. demo-1.example.invalid).
                      Never hardcoded; always supplied by the caller.

Options:
  --path <path>       Request path. Default: /
  --timeout <secs>    Maximum seconds for the whole request. Default: 10
  --dry-run           Print exactly what would be done and exit 0. Makes no
                      network request whatsoever, so this is safe offline.
  -h, --help          Show this help.

Exit codes: 0 pass (403), 2 usage, 3 unexpected response, 4 inconclusive.
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
    log "would run: curl --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time ${timeout} --location-trusted --request GET -- ${url}"
    log "pass condition:   HTTP ${EXPECTED_CODE} (Cloud Armor default deny)"
    log "fail conditions:  any other status code (exit ${EXIT_UNEXPECTED_RESPONSE});"
    log "                  request did not complete (exit ${EXIT_INCONCLUSIVE})"
    log "precondition:     run this from a source address absent from allowed_ipv4/allowed_ipv6"
    exit 0
  fi

  log "probing ${url} from this host, expecting HTTP ${EXPECTED_CODE}"

  local code="" curl_status=0
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time "$timeout" --request GET -- "$url" 2>/dev/null)" || curl_status="$?"

  if [ "$curl_status" -ne 0 ]; then
    fail "$EXIT_INCONCLUSIVE" \
      "request to ${url} did not complete (curl exit ${curl_status}). A timeout or DNS failure is NOT evidence that Cloud Armor denied the request; it is evidence that nothing was measured."
  fi

  if [ "$code" != "$EXPECTED_CODE" ]; then
    fail "$EXIT_UNEXPECTED_RESPONSE" \
      "expected HTTP ${EXPECTED_CODE} from an unlisted source, observed HTTP ${code}. The edge answered a source that is not on the allowlist."
  fi

  log "PASS: HTTP ${EXPECTED_CODE} -- the Cloud Armor default deny rejected an unlisted source."
}

main "$@"
