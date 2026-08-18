#!/usr/bin/env bash
#
# edge-probe-bypass.sh -- prove the load balancer is the only way in.
#
# The whole edge posture is worthless if the application VM can be reached
# directly, around Cloud Armor. This probe attempts exactly that: it talks to
# the VM's INTERNAL RFC1918 address on the backend port from a host outside the
# VPC. There must be no route.
#
# The polarity of this probe is inverted relative to the other two: SUCCESS of
# the connection is the FAILURE of the control. A completed HTTP exchange means
# the backend is directly reachable and every Cloud Armor rule can be skipped.
#
# Usage:
#   edge-probe-bypass.sh <internal-ip> <port> [--timeout 8] [--dry-run]
#
# Exit codes:
#   0  no route -- connection timed out (or was refused), the bypass failed
#   2  usage error
#   3  a response was received -- THE BACKEND IS DIRECTLY REACHABLE
#   4  curl failed for a reason unrelated to reachability -- inconclusive
set -Eeuo pipefail

readonly PROBE_NAME="edge-probe-bypass"
readonly EXIT_USAGE=2
readonly EXIT_REACHABLE=3
readonly EXIT_INCONCLUSIVE=4

# curl(1) exit codes that constitute "nothing is listening for us out here".
readonly CURL_COULD_NOT_CONNECT=7
readonly CURL_OPERATION_TIMEDOUT=28

usage() {
  cat <<'USAGE'
Usage: edge-probe-bypass.sh <internal-ip> <port> [options]

Attempts to reach the application VM's internal address directly from outside
the VPC, bypassing the load balancer and Cloud Armor. No route is the pass
condition; a completed request is a hard failure.

Arguments:
  <internal-ip>       The VM's RFC1918 internal address (e.g. 10.128.0.2).
                      Refused if the address is not RFC1918 -- probing a public
                      address with this script proves nothing.
  <port>              The backend application port (e.g. 8080).

Options:
  --timeout <secs>    Connect timeout in seconds. Default: 8
  --dry-run           Print exactly what would be done and exit 0. Makes no
                      network request whatsoever, so this is safe offline.
  -h, --help          Show this help.

Exit codes: 0 pass (no route), 2 usage, 3 backend reachable, 4 inconclusive.
USAGE
}

log() { printf '[%s] %s\n' "$PROBE_NAME" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$PROBE_NAME" "$*" >&2; }
fail() {
  local code="$1"
  shift
  printf '[%s] FAIL: %s\n' "$PROBE_NAME" "$*" >&2
  exit "$code"
}

is_rfc1918() {
  local ip="$1"
  case "$ip" in
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  local internal_ip="" port="" timeout="8" dry_run="false"
  local positional=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
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
        positional+=("$1")
        shift
        ;;
    esac
  done

  [ "${#positional[@]}" -eq 2 ] || {
    usage >&2
    fail "$EXIT_USAGE" "expected exactly two positional arguments (<internal-ip> <port>), got ${#positional[@]}"
  }
  internal_ip="${positional[0]}"
  port="${positional[1]}"

  case "$port" in
    '' | *[!0-9]*) fail "$EXIT_USAGE" "port must be an integer between 1 and 65535" ;;
    *) { [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; } || fail "$EXIT_USAGE" "port must be between 1 and 65535" ;;
  esac
  case "$timeout" in
    '' | *[!0-9]*) fail "$EXIT_USAGE" "--timeout must be a positive integer" ;;
    *) [ "$timeout" -gt 0 ] || fail "$EXIT_USAGE" "--timeout must be greater than zero" ;;
  esac

  is_rfc1918 "$internal_ip" || fail "$EXIT_USAGE" \
    "\"${internal_ip}\" is not an RFC1918 address. This probe only means something against the VM's internal address; pointing it at a public address would produce a meaningless pass."

  local url="http://${internal_ip}:${port}/"

  if [ "$dry_run" = "true" ]; then
    log "DRY RUN -- no network request is made."
    log "would run: curl --silent --show-error --output /dev/null --write-out '%{http_code}' --connect-timeout ${timeout} --max-time ${timeout} --request GET -- ${url}"
    log "pass condition:   curl exit ${CURL_OPERATION_TIMEDOUT} (no route) or ${CURL_COULD_NOT_CONNECT} (refused)"
    log "fail condition:   ANY completed HTTP exchange (exit ${EXIT_REACHABLE}) -- the backend is directly reachable"
    log "                  any other curl failure (exit ${EXIT_INCONCLUSIVE})"
    log "precondition:     run this from a host OUTSIDE the environment's VPC, with no VPN,"
    log "                  no IAP tunnel, and no Cloud Shell session into the project"
    exit 0
  fi

  log "attempting direct connection to ${url} from outside the VPC; expecting no route"

  local code="" curl_status=0
  code="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --connect-timeout "$timeout" --max-time "$timeout" --request GET -- "$url" 2>/dev/null)" || curl_status="$?"

  if [ "$curl_status" -eq 0 ]; then
    fail "$EXIT_REACHABLE" \
      "received HTTP ${code} directly from ${url}. The backend is reachable without traversing the load balancer, so every Cloud Armor rule can be bypassed. Check for an access_config (external IP) on the instance and for a firewall rule with a 0.0.0.0/0 source."
  fi

  case "$curl_status" in
    "$CURL_OPERATION_TIMEDOUT")
      log "PASS: connection to ${url} timed out (curl exit ${curl_status}) -- no route from outside the VPC."
      ;;
    "$CURL_COULD_NOT_CONNECT")
      warn "connection was actively refused rather than black-holed (curl exit ${curl_status}). That is still a pass, but a refusal usually comes from the local network rather than from GCP. Confirm this host is genuinely outside the VPC before trusting the result."
      log "PASS: connection to ${url} could not be established."
      ;;
    *)
      fail "$EXIT_INCONCLUSIVE" \
        "curl exited ${curl_status}, which is neither a timeout (${CURL_OPERATION_TIMEDOUT}) nor a connect failure (${CURL_COULD_NOT_CONNECT}). Reachability was not determined; this is not a pass."
      ;;
  esac
}

main "$@"
