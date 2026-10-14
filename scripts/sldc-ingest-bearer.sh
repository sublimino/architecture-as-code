#!/usr/bin/env bash
# @id scripts/sldc-ingest-bearer.sh
# @tests test/sldc-ingest-bearer.bats
# @doc d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml
#
# sldc-ingest-bearer.sh — the issuer of signal-ingest's named static keys.
#
#   sldc-ingest-bearer.sh --context CTX [--key NAME]...          create if absent, else converge / no-op
#   sldc-ingest-bearer.sh --context CTX [--key NAME]... --rotate replace with newly generated values
#   ... | sldc-ingest-bearer.sh --context CTX --key NAME --from-stdin   install the value read from stdin
#   sldc-ingest-bearer.sh --context CTX --key NAME --emit-remote-secrets DIR   write the consumer Secret as YAML
#
# --emit-remote-secrets DIR converges the selected keys as usual, then writes
# each one's consumer Secret to DIR/<secret>.yaml for `kubectl apply` on
# ANOTHER cluster. Nothing is applied to a remote cluster by this script, and
# nothing is written for a key whose caller is an operator tool with no
# consumer Secret. The warden's remote key is
# `--key signalloom-warden`, whose consumer Secret is
# fe-signalloom-agents/signalloom-warden-ingest-token, which is the name the
# remote-tenant overlay's DaemonSet reads.
#
# DIR is created mode 0700 and each file written mode 0600. The files hold key
# material in clear base64. Hand them over on an agreed secure channel and
# delete them. scripts/fleet-manager-caller-keys.sh --emit-remote-secrets
# writes the same ingest Secret plus the fleet caller key, so one of the two
# commands is usually enough.
#
# Without --key, every key in KEYS below. One key per caller, each a random
# 32-byte token (base64url) held in two Secrets with the same value:
#   issuer    fe-signalloom/signal-ingest-key-<name>, keys token and expires
#             (YYYY-MM-DD, 90 days from minting), projected into signal-ingest as
#             /etc/signal-ingest/static-keys/<name> and <name>.expires
#   consumer  <namespace>/<secret> from KEYS, key token, read by the caller
#             (none for a key whose caller is an operator tool outside the
#             cluster; it reads the issuer Secret)
#
# A value is never printed, never placed in argv, never written to a ConfigMap.
# It travels only through shell variables and the stdin of `kubectl apply`
# (printf is a builtin, so nothing is exec'd with it). Writes are server-side
# apply, so no kubectl.kubernetes.io/last-applied-configuration annotation
# carries a second copy of the Secret's data.
#
# Idempotent per key: with both Secrets present, equal and ≥32 bytes, a run
# writes nothing. If they disagree, or only one exists, the issuer's value is
# copied to the other (the issuer is what signal-ingest authenticates
# against). A stored value under 32 bytes is replaced.
#
# Running pods read the keys at start: after a rotation, restart
# deploy/signal-ingest and the caller (printed on stderr).
#
# Injectable: KUBECTL_BIN (default kubectl), SLDC_INGEST_KEYS (registry rows).
# Exit codes: 0 ok (created, converged, rotated or unchanged), 2 usage,
# 3 kubectl failed (cluster unreachable, forbidden), 4 invalid value on stdin.

KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"

ISSUER_NS=fe-signalloom
ISSUER_PREFIX=signal-ingest-key-
# name|consumer-namespace|consumer-secret|restart-target   (empty consumer: none)
KEYS=(
	"stun-sentinel|fe-signalloom-agents|stun-sentinel-ingest-token|ds/stun-sentinel"
	"signalloom-warden|inf-signalloom-warden|signalloom-warden-ingest-token|ds/signalloom-warden"
	"fe-signalloom-gateway|fe-signalloom|fe-signalloom-ingest-key|deploy/fe-signalloom"
	"signalfusion-demo|fe-signalloom|signalfusion-demo-ingest-key|deploy/supercred-demo-runner"
	# Operator tools outside the cluster read the issuer Secret directly.
	"sldc-live-bats|||"
	"sldc-evidence-reader|||"
)
# Tests (and a one-off operator) may substitute the registry: newline-separated rows.
if [[ -n "${SLDC_INGEST_KEYS:-}" ]]; then
	mapfile -t KEYS <<<"$SLDC_INGEST_KEYS"
fi
MIN_BYTES=32
# signal-ingest refuses an expiry more than 90 days after it loads the key
# (api.MaxStaticKeyLifetime), so a key is minted with exactly that lifetime.
LIFETIME_DAYS=90
FIELD_MANAGER=sldc-ingest-bearer

log() { printf '[sldc-ingest-bearer] %s\n' "$*" >&2; }
usage() {
	sed -n '7,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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
	kube get namespace "$1" >/dev/null 2>&1 || kube create namespace "$1" >/dev/null 2>&1 || true
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/managed-by: sldc-ingest-bearer\n    signalloom.io/credential: ingest-static-bearer\ntype: Opaque\ndata:\n  token: %s\n' \
		"$2" "$1" "$b64" |
		kube apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null ||
		die 3 "could not write Secret $1/$2 in context $CONTEXT; the two Secrets may now disagree — re-run to converge them"
}

valid() { [[ ${#1} -ge $MIN_BYTES ]]; }

# expiry_date -> today (UTC, or SLDC_INGEST_TODAY) + LIFETIME_DAYS, as YYYY-MM-DD.
# perl, not `date -d`: the same script runs on macOS (BSD date) and Linux.
expiry_date() {
	perl -MTime::Local -MPOSIX=strftime -e '
		my ($today, $days) = @ARGV;
		my $t = time;
		if ($today) { my ($y, $m, $d) = split /-/, $today; $t = timegm(0, 0, 12, $d, $m - 1, $y); }
		print strftime("%Y-%m-%d", gmtime($t + $days * 86400));
	' "${SLDC_INGEST_TODAY:-}" "$LIFETIME_DAYS"
}

# read_field NS NAME FIELD -> the decoded data field, empty if absent.
read_field() {
	local b64
	b64=$(kube -n "$1" get secret "$2" --ignore-not-found -o "jsonpath={.data.$3}") ||
		die 3 "could not read Secret $1/$2 in context $CONTEXT"
	[[ -n "$b64" ]] || return 0
	printf '%s' "$b64" | base64 -d 2>/dev/null ||
		die 3 "Secret $1/$2 in context $CONTEXT holds a $3 that is not base64"
}

# write_issuer NS NAME TOKEN EXPIRES: the issuer Secret carries the value and its expiry.
write_issuer() {
	local b64 exp
	b64=$(printf '%s' "$3" | base64 | tr -d '\n')
	exp=$(printf '%s' "$4" | base64 | tr -d '\n')
	printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/managed-by: sldc-ingest-bearer\n    signalloom.io/credential: ingest-static-bearer\ntype: Opaque\ndata:\n  token: %s\n  expires: %s\n' \
		"$2" "$1" "$b64" "$exp" |
		kube apply --server-side --field-manager="$FIELD_MANAGER" -f - >/dev/null ||
		die 3 "could not write Secret $1/$2 in context $CONTEXT; the two Secrets may now disagree — re-run to converge them"
}

# emit_consumer_secret NS NAME TOKEN: write the consumer Secret to EMIT_DIR as
# YAML for `kubectl apply` on another cluster. Nothing is applied here.
#
# Same document shape as write_token, so the file a remote cluster applies and
# the Secret this cluster holds are the same object with the same labels. The
# subshell sets umask 077 before mkdir and before the redirect, so neither the
# directory nor the file is ever group- or world-readable, not even briefly.
emit_consumer_secret() {
	local b64 out="$EMIT_DIR/$2.yaml"
	b64=$(printf '%s' "$3" | base64 | tr -d '\n')
	(
		umask 077
		mkdir -p "$EMIT_DIR" || exit 1
		printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/managed-by: sldc-ingest-bearer\n    signalloom.io/credential: ingest-static-bearer\ntype: Opaque\ndata:\n  token: %s\n' \
			"$2" "$1" "$b64" >"$out" || exit 1
	) || die 3 "could not write $out"
	log "  wrote $out (apply it on the REMOTE cluster, then delete it)"
}

# key_row NAME -> the KEYS row, or nothing.
key_row() {
	local row
	for row in "${KEYS[@]}"; do
		[[ "${row%%|*}" == "$1" ]] && { printf '%s' "$row"; return 0; }
	done
	return 1
}

# converge_key ROW STDIN_VALUE: create, converge, rotate or leave one key.
converge_key() {
	local name consumer_ns consumer_secret restart issuer consumer want action
	IFS='|' read -r name consumer_ns consumer_secret restart <<<"$1"
	local issuer_secret="${ISSUER_PREFIX}${name}"

	issuer=$(read_token "$ISSUER_NS" "$issuer_secret") || exit $?
	local issuer_expires want_expires
	issuer_expires=$(read_field "$ISSUER_NS" "$issuer_secret" expires) || exit $?
	consumer=""
	if [[ -n "$consumer_ns" ]]; then
		consumer=$(read_token "$consumer_ns" "$consumer_secret") || exit $?
	fi

	if [[ -n "$2" ]]; then
		want="$2"
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
	valid "$want" || die 3 "generated value is shorter than $MIN_BYTES bytes; /dev/urandom unreadable?"
	# A new value gets a new lifetime; converging keeps the one it has (never extends it) and
	# only fills in an expiry that is missing.
	want_expires="$issuer_expires"
	if [[ "$action" != converged || -z "$issuer_expires" ]]; then
		want_expires=$(expiry_date)
	fi

	if [[ "$issuer" == "$want" && "$issuer_expires" == "$want_expires" && ( -z "$consumer_ns" || "$consumer" == "$want" ) ]]; then
		log "key $name in $CONTEXT: unchanged"
		return 0
	fi
	# Consumer first: if the issuer write then fails, signal-ingest still holds
	# the old value and a re-run converges the caller back to it.
	if [[ -n "$consumer_ns" && "$consumer" != "$want" ]]; then
		write_token "$consumer_ns" "$consumer_secret" "$want"
		if [[ "$consumer_ns" == "inf-signalloom-warden" ]]; then
			write_token "fe-signalloom-agents" "$consumer_secret" "$want" 2>/dev/null || true
		fi
	fi
	if [[ "$issuer" != "$want" || "$issuer_expires" != "$want_expires" ]]; then
		write_issuer "$ISSUER_NS" "$issuer_secret" "$want" "$want_expires"
	fi
	log "key $name in $CONTEXT: $action (expires $want_expires)"
	if [[ -n "$issuer$consumer" ]]; then
		log "  running pods read keys at start; load it with:"
		log "    $KUBECTL_BIN --context $CONTEXT -n $ISSUER_NS rollout restart deploy/signal-ingest"
		[[ -z "$restart" ]] || log "    $KUBECTL_BIN --context $CONTEXT -n $consumer_ns rollout restart $restart"
	fi
}

main() {
	CONTEXT="" ROTATE="" FROM_STDIN="" EMIT_DIR=""
	local selected=() row
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--context)
			[[ -n "${2:-}" ]] || die 2 "--context needs a value"
			CONTEXT="$2"
			shift 2
			;;
		--key)
			[[ -n "${2:-}" ]] || die 2 "--key needs a value"
			row=$(key_row "$2") || die 2 "unknown key: $2 (known: $(printf '%s ' "${KEYS[@]%%|*}"))"
			selected+=("$row")
			shift 2
			;;
		--rotate) ROTATE=1; shift ;;
		--from-stdin) FROM_STDIN=1; shift ;;
		--emit-remote-secrets)
			[[ -n "${2:-}" ]] || die 2 "--emit-remote-secrets needs a directory"
			EMIT_DIR="$2"
			shift 2
			;;
		-h | --help) usage; return 0 ;;
		*) usage; die 2 "unknown argument: $1" ;;
		esac
	done
	[[ -n "$CONTEXT" ]] || { usage; die 2 "--context is required"; }
	((${#selected[@]})) || selected=("${KEYS[@]}")

	local stdin_value=""
	if [[ -n "$FROM_STDIN" ]]; then
		[[ ${#selected[@]} -eq 1 ]] || die 2 "--from-stdin installs one key: name it with --key"
		IFS= read -r stdin_value || [[ -n "$stdin_value" ]] || die 4 "no value on stdin"
		[[ "$stdin_value" != *[[:space:]]* ]] || die 4 "value on stdin contains whitespace"
		valid "$stdin_value" || die 4 "value on stdin must be at least $MIN_BYTES bytes"
	fi
	for row in "${selected[@]}"; do
		converge_key "$row" "$stdin_value"
	done
	# Emission is a second pass over the same rows, after every key has
	# converged: a file written from a value that a later failure would have
	# changed is worse than no file.
	if [[ -n "$EMIT_DIR" ]]; then
		local name consumer_ns consumer_secret rest token
		for row in "${selected[@]}"; do
			IFS='|' read -r name consumer_ns consumer_secret rest <<<"$row"
			[[ -n "$consumer_ns" ]] || {
				log "key $name has no consumer Secret; nothing to emit"
				continue
			}
			token=$(read_token "$ISSUER_NS" "${ISSUER_PREFIX}${name}") || exit $?
			valid "$token" || die 3 "key $name is absent or too short after converging; refusing to emit"
			emit_consumer_secret "$consumer_ns" "$consumer_secret" "$token"
		done
	fi
}

main "$@"
