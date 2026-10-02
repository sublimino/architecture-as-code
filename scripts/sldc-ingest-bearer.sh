#!/usr/bin/env bash
# @id scripts/sldc-ingest-bearer.sh
# @tests test/sldc-ingest-bearer.bats
# @doc d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml
#
# sldc-ingest-bearer.sh — mint, converge or rotate the shared ingest credential.
#
#   sldc-ingest-bearer.sh --context CTX              create if absent, else converge / no-op
#   sldc-ingest-bearer.sh --context CTX --rotate     replace with a newly generated token
#   ... | sldc-ingest-bearer.sh --context CTX --from-stdin   install the token read from stdin
#
# One random token (32 bytes, base64url) held in two Secrets with the same value:
#   signal-ingest-static-bearer/token  in fe-signalloom          issuer: signal-ingest
#   stun-sentinel-ingest-token/token   in fe-signalloom-agents   consumer: the sentinel
#
# The token is never printed, never placed in argv, never written to a ConfigMap.
# It travels only through shell variables and the stdin of `kubectl apply`
# (printf is a builtin, so nothing is exec'd with it). Writes are server-side
# apply, so no kubectl.kubernetes.io/last-applied-configuration annotation
# carries a second copy of the Secret's data.
#
# Idempotent: with both Secrets present, equal and ≥32 bytes, a run writes
# nothing. If they disagree, or only one exists, the issuer's value is copied
# to the other (the issuer is what signal-ingest authenticates against). A
# stored value under 32 bytes is replaced.
#
# Running pods read the token from env at start: after a rotation, restart
# deploy/signal-ingest and ds/stun-sentinel (printed on stderr).
#
# Injectable: KUBECTL_BIN (default kubectl).
# Exit codes: 0 ok (created, converged, rotated or unchanged), 2 usage,
# 3 kubectl failed (cluster unreachable, forbidden), 4 invalid token on stdin.

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

ISSUER_NS=fe-signalloom
ISSUER=signal-ingest-static-bearer
CONSUMER_NS=fe-signalloom-agents
CONSUMER=stun-sentinel-ingest-token
MIN_BYTES=32
FIELD_MANAGER=sldc-ingest-bearer

log() { printf '[sldc-ingest-bearer] %s\n' "$*" >&2; }
usage() {
	sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}
die() { # die CODE MESSAGE
	log "ERROR: $2"
	exit "$1"
}

kube() { "$KUBECTL_BIN" --context "$CONTEXT" "$@"; }

generate_token() {
	head -c 32 /dev/urandom | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '='
}

# read_token NS NAME -> the decoded token on stdout, empty if the Secret is absent.
read_token() {
	local b64
	b64=$(kube -n "$1" get secret "$2" --ignore-not-found -o 'jsonpath={.data.token}') ||
		die 3 "could not read Secret $1/$2 in context $CONTEXT"
	[[ -n "$b64" ]] || return 0
	printf '%s' "$b64" | base64 -d 2>/dev/null ||
		die 3 "Secret $1/$2 in context $CONTEXT holds a token that is not base64"
}

# write_token NS NAME TOKEN
write_token() {
	local b64
	b64=$(printf '%s' "$3" | base64 | tr -d '\n')
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/managed-by: sldc-ingest-bearer\n    signalloom.io/credential: ingest-static-bearer\ntype: Opaque\ndata:\n  token: %s\n' \
		"$2" "$1" "$b64" |
		kube apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null ||
		die 3 "could not write Secret $1/$2 in context $CONTEXT; the two Secrets may now disagree — re-run to converge them"
}

valid() { [[ ${#1} -ge $MIN_BYTES ]]; }

main() {
	CONTEXT="" ROTATE="" FROM_STDIN=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--context)
			[[ -n "${2:-}" ]] || die 2 "--context needs a value"
			CONTEXT="$2"
			shift 2
			;;
		--rotate) ROTATE=1; shift ;;
		--from-stdin) FROM_STDIN=1; shift ;;
		-h | --help) usage; return 0 ;;
		*) usage; die 2 "unknown argument: $1" ;;
		esac
	done
	[[ -n "$CONTEXT" ]] || { usage; die 2 "--context is required"; }

	local issuer consumer want action
	if [[ -n "$FROM_STDIN" ]]; then
		IFS= read -r want || [[ -n "$want" ]] || die 4 "no token on stdin"
		[[ "$want" != *[[:space:]]* ]] || die 4 "token on stdin contains whitespace"
		valid "$want" || die 4 "token on stdin must be at least $MIN_BYTES bytes"
	fi

	issuer=$(read_token "$ISSUER_NS" "$ISSUER") || exit $?
	consumer=$(read_token "$CONSUMER_NS" "$CONSUMER") || exit $?

	if [[ -n "$FROM_STDIN" ]]; then
		action=installed
	elif [[ -n "$ROTATE" ]] || { [[ -n "$issuer" ]] && ! valid "$issuer"; }; then
		want=$(generate_token)
		action=rotated
	elif [[ -n "$issuer" ]]; then
		want="$issuer"
		action=converged
	elif valid "$consumer"; then
		want="$consumer"
		action=converged
	else
		want=$(generate_token)
		action=created
	fi
	valid "$want" || die 3 "generated token is shorter than $MIN_BYTES bytes; /dev/urandom unreadable?"

	if [[ "$issuer" == "$want" && "$consumer" == "$want" ]]; then
		log "$ISSUER_NS/$ISSUER and $CONSUMER_NS/$CONSUMER in $CONTEXT: unchanged"
		return 0
	fi
	# Consumer first: if the issuer write then fails, signal-ingest still holds
	# the old token and a re-run converges the sentinel back to it.
	[[ "$consumer" == "$want" ]] || write_token "$CONSUMER_NS" "$CONSUMER" "$want"
	[[ "$issuer" == "$want" ]] || write_token "$ISSUER_NS" "$ISSUER" "$want"
	log "$ISSUER_NS/$ISSUER and $CONSUMER_NS/$CONSUMER in $CONTEXT: $action"
	if [[ -n "$issuer$consumer" ]]; then
		log "running pods read the token at start; load it with:"
		log "  $KUBECTL_BIN --context $CONTEXT -n $ISSUER_NS rollout restart deploy/signal-ingest"
		log "  $KUBECTL_BIN --context $CONTEXT -n $CONSUMER_NS rollout restart ds/stun-sentinel"
	fi
}

main "$@"
