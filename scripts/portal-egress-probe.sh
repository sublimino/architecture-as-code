#!/usr/bin/env bash
# portal-egress-probe.sh — live end-to-end check of security exemption
# SA-TODO-001: the portal pod can reach the public AI provider APIs on 443, and
# private in-cluster addresses outside its allow-list are still blocked.
#
# Register:  docs/signalloom/security-architecture-todos.md (SA-TODO-001)
# Policy:    d2-signalloom/apps/fe-signalloom/base/networkpolicy.yaml
#            (allow-portal-public-https-egress)
# Tests:     d2-signalloom/test/portal-egress-probe.bats (offline, stub client)
#            d2-signalloom/test/portal-public-egress.bats (policy shape)
#
# Read-only. It runs one short Python helper inside the running portal
# container (discovery-portal, python:3.12-slim), which opens sockets and
# prints one line per target. It changes nothing in the cluster.
#
# Targets and the verdict each one needs:
#   public   api.anthropic.com, api.openai.com, claude.ai, anthropic.com on 443
#            PASS = TLS handshake and an HTTP status line. No credentials are
#            sent, so 401/403/404/421 are all proof of reach.
#   blocked  a dashboard-signalloom pod IP on 443 and 8080
#            PASS = TIMEOUT only. NetworkPolicy drops, so a refusal means the
#            SYN reached the pod and the private range is open.
#   control  signal-ingest:8082, which the portal is allowed to reach
#            PASS = CONNECTED. Proves that pod networking works, so a blocked
#            TIMEOUT is the policy and not a dead pod.
#
# Exit status:
#   0  every target passed
#   1  at least one target failed (the table says which)
#   2  usage error
#   3  the probe could not run: no portal pod, no blocked target, exec failed,
#      or the helper returned the wrong number of results. Never read as pass.
#
# Usage: see usage() below, or run with --help.

set -o errexit -o pipefail

KUBECTL="${PORTAL_EGRESS_KUBECTL:-kubectl}"
CONTEXT=""
NAMESPACE="fe-signalloom"
TIMEOUT=8
BLOCKED_IP=""
PUBLIC_HOSTS=(api.anthropic.com api.openai.com claude.ai anthropic.com)
CONTROL_TARGET="signal-ingest:8082"
PORTAL_SELECTOR="app.kubernetes.io/name=fe-signalloom,bao.controlplane.io/consumer=fe-signalloom"
DASHBOARD_SELECTOR="app.kubernetes.io/name=dashboard-signalloom"

usage() {
	cat <<'EOF'
Usage: scripts/portal-egress-probe.sh --context CONTEXT [options]

Prove from inside the running portal pod that public HTTPS to the AI providers
works and that unlisted private addresses stay blocked (SA-TODO-001).

Options:
  --context CONTEXT   kubeconfig context to probe (required), e.g. kind-osramp
  --namespace NS      portal namespace (default: fe-signalloom)
  --timeout SECONDS   per-target connect and read timeout (default: 8)
  --blocked-ip IP     private IPv4 to use as the blocked target instead of a
                      dashboard-signalloom pod IP
  -h, --help          show this help

Exit: 0 all pass, 1 a target failed, 2 usage error, 3 probe could not run.
EOF
}

die_usage() {
	echo "portal-egress-probe: $1" >&2
	echo "run with --help for usage" >&2
	exit 2
}

die_run() {
	echo "portal-egress-probe: cannot run: $1" >&2
	exit 3
}

is_private_ipv4() {
	local ip="$1" a b
	[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	a="${BASH_REMATCH[1]}"
	b="${BASH_REMATCH[2]}"
	((a == 10)) && return 0
	((a == 172 && b >= 16 && b <= 31)) && return 0
	((a == 192 && b == 168)) && return 0
	return 1
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h | --help)
				usage
				exit 0
				;;
			--context | --namespace | --timeout | --blocked-ip)
				[[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die_usage "$1 needs a value"
				case "$1" in
					--context) CONTEXT="$2" ;;
					--namespace) NAMESPACE="$2" ;;
					--timeout) TIMEOUT="$2" ;;
					--blocked-ip) BLOCKED_IP="$2" ;;
				esac
				shift 2
				;;
			*) die_usage "unknown option: $1" ;;
		esac
	done
	[[ -n "$CONTEXT" ]] || die_usage "--context is required"
	[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die_usage "--timeout must be a positive integer"
	if [[ -n "$BLOCKED_IP" ]] && ! is_private_ipv4 "$BLOCKED_IP"; then
		die_usage "--blocked-ip must be a private IPv4 address"
	fi
}

kube() {
	"$KUBECTL" --context "$CONTEXT" -n "$NAMESPACE" "$@"
}

# The in-pod helper. Arguments: TIMEOUT then KIND:MODE:HOST:PORT specs.
# One output line per spec: KIND HOST:PORT RESULT DETAIL...
# shellcheck disable=SC2016
HELPER='
import socket, ssl, sys
timeout = float(sys.argv[1])
for spec in sys.argv[2:]:
    kind, mode, host, port = spec.split(":")
    port = int(port)
    target = "%s:%d" % (host, port)
    try:
        # IPv4 only: the policy is an IPv4 ipBlock and the pods have no v6 route.
        addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)[0][4]
        sock = socket.create_connection(addr, timeout=timeout)
    except socket.timeout:
        print(kind, target, "TIMEOUT", "-"); continue
    except ConnectionRefusedError:
        print(kind, target, "REFUSED", "-"); continue
    except OSError as e:
        print(kind, target, "ERROR", type(e).__name__); continue
    peer = sock.getpeername()[0]
    if mode == "tcp":
        sock.close(); print(kind, target, "CONNECTED", peer); continue
    try:
        tls = ssl.create_default_context().wrap_socket(sock, server_hostname=host)
        tls.settimeout(timeout)
        tls.sendall(("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: portal-egress-probe\r\nConnection: close\r\n\r\n" % host).encode())
        line = tls.makefile("rb").readline().decode("latin-1").split()
        tls.close()
        if len(line) >= 2 and line[0].startswith("HTTP/") and line[1].isdigit():
            print(kind, target, "HTTP", line[1], peer)
        else:
            print(kind, target, "NO_STATUS", peer)
    except ssl.SSLError as e:
        print(kind, target, "TLS_ERROR", type(e).__name__)
    except socket.timeout:
        print(kind, target, "READ_TIMEOUT", peer)
    except OSError as e:
        print(kind, target, "ERROR", type(e).__name__)
'

# verdict KIND RESULT CODE -> PASS or FAIL
verdict() {
	local kind="$1" result="$2" code="$3"
	case "$kind" in
		public) [[ "$result" == HTTP && "$code" =~ ^[1-5][0-9][0-9]$ ]] ;;
		blocked) [[ "$result" == TIMEOUT ]] ;;
		control) [[ "$result" == CONNECTED ]] ;;
		*) false ;;
	esac && echo PASS || echo FAIL
}

main() {
	parse_args "$@"

	local pod
	pod="$(kube get pods -l "$PORTAL_SELECTOR" --field-selector=status.phase=Running \
		-o 'jsonpath={.items[0].metadata.name}' 2>/dev/null)" || true
	[[ -n "$pod" ]] || die_run "no running portal pod ($PORTAL_SELECTOR) in $NAMESPACE on $CONTEXT"

	if [[ -z "$BLOCKED_IP" ]]; then
		BLOCKED_IP="$(kube get pods -l "$DASHBOARD_SELECTOR" --field-selector=status.phase=Running \
			-o 'jsonpath={.items[0].status.podIP}' 2>/dev/null)" || true
		[[ -n "$BLOCKED_IP" ]] || die_run "no running dashboard-signalloom pod to use as the blocked target (pass --blocked-ip)"
	fi

	local specs=() h
	for h in "${PUBLIC_HOSTS[@]}"; do specs+=("public:tls:$h:443"); done
	specs+=("blocked:tcp:$BLOCKED_IP:443" "blocked:tcp:$BLOCKED_IP:8080")
	specs+=("control:tcp:$CONTROL_TARGET")

	# The helper goes in on stdin, so nothing large or quoted crosses argv.
	local out rc=0
	out="$(printf '%s' "$HELPER" | kube exec -i "$pod" -c discovery-portal -- \
		python3 - "$TIMEOUT" "${specs[@]}" 2>&1)" || rc=$?

	local lines
	lines="$(grep -cE '^(public|blocked|control) ' <<<"$out" || true)"
	if [[ "$lines" -ne "${#specs[@]}" ]]; then
		echo "$out" >&2
		die_run "expected ${#specs[@]} results from the in-pod helper, got $lines (exec rc=$rc)"
	fi

	local failed=0 kind target result code rest v
	printf '%-8s %-24s %-4s %s\n' KIND TARGET VERDICT RESULT
	while read -r kind target result code rest; do
		[[ "$kind" =~ ^(public|blocked|control)$ ]] || continue
		v="$(verdict "$kind" "$result" "$code")"
		[[ "$v" == PASS ]] || failed=1
		printf '%-8s %-24s %s %s %s %s\n' "$kind" "$target" "$v" "$result" "$code" "$rest"
	done <<<"$out"

	if ((failed)); then
		echo "portal-egress-probe: FAIL (context $CONTEXT, pod $pod)" >&2
		exit 1
	fi
	echo "portal-egress-probe: PASS (context $CONTEXT, pod $pod)"
}

main "$@"
