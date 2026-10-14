#!/usr/bin/env bats
# @id test/sldc-ingest-bearer.bats
# @target scripts/sldc-ingest-bearer.sh
# @doc d2-signalloom/apps/signal-ingest/deploy/jwt-auth-config.yaml
#
# The ingest credential contract, per named key: one random value, ≥32 bytes,
# held in two Secrets with the same value —
#   signal-ingest-key-<name>/token  (fe-signalloom)       issuer
#   <consumer secret>/token         (caller's namespace)  consumer, if any
# minted or rotated per --context, idempotently, and never printed, never in
# argv, never in a ConfigMap. The single-key cases use the shipped registry
# (stun-sentinel); the multi-key cases substitute SLDC_INGEST_KEYS.
#
# The fake kubectl keeps Secrets in a state directory (so idempotence and
# convergence are questions about what the PREVIOUS call wrote) and logs every
# argv, so a test can assert what was NOT called and that no token ever crossed
# into a command line.

# `run !` (used by the --emit-remote-secrets cases) needs 1.5.0 or later.
bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/sldc-ingest-bearer.sh"

ISSUER_NS=fe-signalloom
ISSUER=signal-ingest-key-stun-sentinel
CONSUMER_NS=fe-signalloom-agents
CONSUMER=stun-sentinel-ingest-token
GOOD_TOKEN="qV3x9Lw2pN7cR1tY8kD4hF6jS0aZ5mE2uB7oG3iX1wQ"

setup() {
	export KUBECONFIG=/dev/null
	# Pin "today" so the minted expiry (today + 90 days) is exact.
	export SLDC_INGEST_TODAY=2026-10-02
	FAKE="$BATS_TEST_TMPDIR/fake"
	mkdir -p "$FAKE/bin" "$FAKE/state"
	export FAKE_STATE="$FAKE/state" FAKE_LOG="$FAKE/state/calls.log"
	: >"$FAKE_LOG"
	cat >"$FAKE/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# A kubectl that remembers Secrets. Real failure is reported through the exit
# status, as kubectl does.
printf '%s\n' "$*" >>"$FAKE_LOG"
ctx="" ns="" args=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--context) ctx="$2"; shift 2 ;;
	-n | --namespace) ns="$2"; shift 2 ;;
	*) args+=("$1"); shift ;;
	esac
done
set -- "${args[@]}"
[[ -n "$ctx" ]] || { echo "error: no context" >&2; exit 1; }
if [[ -n "${FAKE_UNREACHABLE:-}" ]]; then
	echo "Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused" >&2
	exit 1
fi
case "$1 $2" in
"get secret")
	field=token
	for a in "$@"; do
		[[ "$a" == "jsonpath={.data."*"}" ]] && { field="${a#jsonpath=\{.data.}"; field="${field%\}}"; }
	done
	f="$FAKE_STATE/$ctx/$ns/$3"
	[[ "$field" == token ]] || f="$f.$field"
	[[ -f "$f" ]] || exit 0 # --ignore-not-found: absent is empty and success
	printf '%s' "$(cat "$f")"
	exit 0
	;;
"apply --server-side")
	doc=$(cat)
	name=$(yq -r '.metadata.name' <<<"$doc")
	dns=$(yq -r '.metadata.namespace' <<<"$doc")
	if [[ "${FAKE_FAIL_APPLY_NS:-}" == "$dns" ]]; then
		echo "Error from server (Forbidden): secrets \"$name\" is forbidden" >&2
		exit 1
	fi
	[[ "$(yq -r '.kind' <<<"$doc")" == Secret ]] || { echo "not a Secret" >&2; exit 1; }
	mkdir -p "$FAKE_STATE/$ctx/$dns"
	yq -r '.data.token' <<<"$doc" >"$FAKE_STATE/$ctx/$dns/$name"
	if [[ "$(yq -r '.data.expires // ""' <<<"$doc")" != "" ]]; then
		yq -r '.data.expires' <<<"$doc" >"$FAKE_STATE/$ctx/$dns/$name.expires"
	else
		rm -f "$FAKE_STATE/$ctx/$dns/$name.expires"
	fi
	printf '%s\n' "$doc" >"$FAKE_STATE/$ctx/$dns/$name.yaml"
	echo "secret/$name serverside-applied"
	;;
*)
	echo "fake kubectl: unsupported: $*" >&2
	exit 1
	;;
esac
STUB
	chmod +x "$FAKE/bin/kubectl"
	export KUBECTL_BIN="$FAKE/bin/kubectl"
}

# token CONTEXT NS NAME -> the decoded token held in that Secret
token() { base64 -d <"$FAKE_STATE/$1/$2/$3" 2>/dev/null; }
# expiry CONTEXT NS NAME -> the decoded expiry held in that Secret, or nothing
expiry() { [[ -f "$FAKE_STATE/$1/$2/$3.expires" ]] && base64 -d <"$FAKE_STATE/$1/$2/$3.expires" 2>/dev/null; }

seed() { # seed CONTEXT NS NAME VALUE
	mkdir -p "$FAKE_STATE/$1/$2"
	printf '%s' "$4" | base64 | tr -d '\n' >"$FAKE_STATE/$1/$2/$3"
}

# rg -c prints nothing (and exits 1) on zero matches, so count with awk.
applies() { awk '/ apply --server-side/ { n++ } END { print n + 0 }' "$FAKE_LOG"; }

assert_never_leaked() { # assert_never_leaked VALUE
	! rg -qF -- "$1" "$FAKE_LOG"
	[[ "$output" != *"$1"* ]]
}

@test "no --context is a usage error (exit 2) and touches no cluster" {
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"--context is required"* ]]
	[ ! -s "$FAKE_LOG" ]
}

@test "an unknown argument is a usage error (exit 2)" {
	run "$SCRIPT" --context kind-osramp --token=abc
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown argument: --token=abc"* ]]
	[ ! -s "$FAKE_LOG" ]
}

@test "a fresh cluster gets one generated ≥32-byte token in both Secrets" {
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	issuer=$(token kind-osramp "$ISSUER_NS" "$ISSUER")
	consumer=$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")
	[ "${#issuer}" -ge 43 ]
	[[ "$issuer" =~ ^[A-Za-z0-9_-]+$ ]]
	[ "$issuer" = "$consumer" ]
	[[ "$output" == *"created"* ]]
	assert_never_leaked "$issuer"
}

@test "every kubectl call names the requested context" {
	run "$SCRIPT" --context kind-signalloom-hub
	[ "$status" -eq 0 ]
	[ "$(wc -l <"$FAKE_LOG")" -gt 0 ]
	! rg -v -e '--context kind-signalloom-hub' "$FAKE_LOG"
	[ -f "$FAKE_STATE/kind-signalloom-hub/$ISSUER_NS/$ISSUER" ]
	[ ! -d "$FAKE_STATE/kind-osramp" ]
}

@test "writes are server-side apply: no last-applied annotation copies the token" {
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	rg -q -e 'apply --server-side --field-manager=sldc-ingest-bearer -f -' "$FAKE_LOG"
	! rg -q 'last-applied' "$FAKE_STATE/kind-osramp/$ISSUER_NS/$ISSUER.yaml"
}

@test "a re-run is a no-op: exit 0, 'unchanged', and no write at all" {
	"$SCRIPT" --context kind-osramp 2>/dev/null
	before=$(token kind-osramp "$ISSUER_NS" "$ISSUER")
	: >"$FAKE_LOG"
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	[[ "$output" == *"unchanged"* ]]
	[ "$(applies)" -eq 0 ]
	[ "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" = "$before" ]
}

@test "--from-stdin installs the given token in both Secrets without echoing it" {
	run bash -c "printf '%s\n' '$GOOD_TOKEN' | '$SCRIPT' --context kind-osramp --key stun-sentinel --from-stdin"
	[ "$status" -eq 0 ]
	[ "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" = "$GOOD_TOKEN" ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$GOOD_TOKEN" ]
	assert_never_leaked "$GOOD_TOKEN"
}

@test "--from-stdin refuses a token under 32 bytes (exit 4) and writes nothing" {
	run bash -c "printf '%s' 'sentinel-in-cluster-token' | '$SCRIPT' --context kind-osramp --key stun-sentinel --from-stdin"
	[ "$status" -eq 4 ]
	[[ "$output" == *"at least 32 bytes"* ]]
	[ "$(applies)" -eq 0 ]
	assert_never_leaked "sentinel-in-cluster-token"
}

@test "--from-stdin refuses a token with whitespace inside (exit 4)" {
	run bash -c "printf 'abcdefghijklmnop qrstuvwxyz0123456789' | '$SCRIPT' --context kind-osramp --key stun-sentinel --from-stdin"
	[ "$status" -eq 4 ]
	[[ "$output" == *"whitespace"* ]]
	[ "$(applies)" -eq 0 ]
}

@test "--rotate replaces the token in both Secrets with a new one" {
	seed kind-osramp "$ISSUER_NS" "$ISSUER" "$GOOD_TOKEN"
	seed kind-osramp "$CONSUMER_NS" "$CONSUMER" "$GOOD_TOKEN"
	run "$SCRIPT" --context kind-osramp --rotate
	[ "$status" -eq 0 ]
	new=$(token kind-osramp "$ISSUER_NS" "$ISSUER")
	[ "$new" != "$GOOD_TOKEN" ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$new" ]
	[[ "$output" == *"rotated"* ]]
	[[ "$output" == *"rollout restart"* ]]
	assert_never_leaked "$new"
}

@test "only the issuer Secret exists: the consumer converges to the issuer's token" {
	seed kind-osramp "$ISSUER_NS" "$ISSUER" "$GOOD_TOKEN"
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$GOOD_TOKEN" ]
	[ "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" = "$GOOD_TOKEN" ]
	[[ "$output" == *"converged"* ]]
}

@test "the two Secrets disagree: the issuer's value wins in both" {
	seed kind-osramp "$ISSUER_NS" "$ISSUER" "$GOOD_TOKEN"
	seed kind-osramp "$CONSUMER_NS" "$CONSUMER" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$GOOD_TOKEN" ]
	[[ "$output" == *"converged"* ]]
}

@test "a stored token under 32 bytes (the retired literal) is replaced, not kept" {
	seed kind-osramp "$ISSUER_NS" "$ISSUER" "sentinel-in-cluster-token"
	seed kind-osramp "$CONSUMER_NS" "$CONSUMER" "sentinel-in-cluster-token"
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	new=$(token kind-osramp "$ISSUER_NS" "$ISSUER")
	[ "${#new}" -ge 43 ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$new" ]
	[[ "$output" == *"rotated"* ]]
}

@test "an unreachable cluster fails with exit 3, names the context, and writes nothing" {
	FAKE_UNREACHABLE=1 run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 3 ]
	[[ "$output" == *"kind-osramp"* ]]
	[[ "$output" == *"read Secret $ISSUER_NS/$ISSUER"* ]]
	[ "$(applies)" -eq 0 ]
}

@test "a refused write fails with exit 3 naming the Secret; a re-run converges both" {
	FAKE_FAIL_APPLY_NS="$CONSUMER_NS" run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 3 ]
	[[ "$output" == *"write Secret $CONSUMER_NS/$CONSUMER"* ]]
	[[ "$output" == *"re-run"* ]]
	run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	[ "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" = "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" ]
	[ -n "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" ]
}

@test "--help prints usage and exits 0 without touching a cluster" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"--context"* ]]
	[ ! -s "$FAKE_LOG" ]
}

@test "an unknown --key is a usage error (exit 2) naming the known keys" {
	run "$SCRIPT" --context kind-osramp --key nobody
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown key: nobody"* ]]
	[[ "$output" == *"stun-sentinel"* ]]
	[ ! -s "$FAKE_LOG" ]
}

TWO_KEYS=$'stun-sentinel|fe-signalloom-agents|stun-sentinel-ingest-token|ds/stun-sentinel\nsldc-evidence-reader|||'

@test "every key gets its own value; a key with no consumer writes only its issuer Secret" {
	SLDC_INGEST_KEYS="$TWO_KEYS" run "$SCRIPT" --context kind-osramp
	[ "$status" -eq 0 ]
	sentinel=$(token kind-osramp "$ISSUER_NS" signal-ingest-key-stun-sentinel)
	reader=$(token kind-osramp "$ISSUER_NS" signal-ingest-key-sldc-evidence-reader)
	[ "${#reader}" -ge 43 ]
	[ "$sentinel" != "$reader" ]
	[ "$(token kind-osramp "$CONSUMER_NS" "$CONSUMER")" = "$sentinel" ]
	[ "$(applies)" -eq 3 ]
	assert_never_leaked "$reader"
}

@test "--key limits the run to the named key" {
	SLDC_INGEST_KEYS="$TWO_KEYS" run "$SCRIPT" --context kind-osramp --key sldc-evidence-reader
	[ "$status" -eq 0 ]
	[ -f "$FAKE_STATE/kind-osramp/$ISSUER_NS/signal-ingest-key-sldc-evidence-reader" ]
	[ ! -f "$FAKE_STATE/kind-osramp/$ISSUER_NS/$ISSUER" ]
}

@test "--from-stdin across more than one key is a usage error (exit 2): one value, one caller" {
	SLDC_INGEST_KEYS="$TWO_KEYS" run bash -c "printf '%s' '$GOOD_TOKEN' | '$SCRIPT' --context kind-osramp --from-stdin"
	[ "$status" -eq 2 ]
	[[ "$output" == *"--from-stdin installs one key"* ]]
	[ "$(applies)" -eq 0 ]
}

# The expiry travels with the value in the issuer Secret (signal-ingest reads <name>.expires and
# refuses anything more than 90 days out), so minting writes both and a rotation renews both.
@test "minting writes the expiry, 90 days out, beside the value in the issuer Secret only" {
	run "$SCRIPT" --context kind-osramp --key stun-sentinel
	[ "$status" -eq 0 ]
	[ "$(expiry kind-osramp "$ISSUER_NS" "$ISSUER")" = "2026-12-31" ]
	[ -z "$(expiry kind-osramp "$CONSUMER_NS" "$CONSUMER")" ]
}

@test "an issuer Secret with a value but no expiry converges: the expiry is added, the value kept" {
	seed kind-osramp "$ISSUER_NS" "$ISSUER" "$GOOD_TOKEN"
	seed kind-osramp "$CONSUMER_NS" "$CONSUMER" "$GOOD_TOKEN"
	run "$SCRIPT" --context kind-osramp --key stun-sentinel
	[ "$status" -eq 0 ]
	[ "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" = "$GOOD_TOKEN" ]
	[ "$(expiry kind-osramp "$ISSUER_NS" "$ISSUER")" = "2026-12-31" ]
}

@test "--rotate renews the expiry with the value" {
	"$SCRIPT" --context kind-osramp --key stun-sentinel 2>/dev/null
	SLDC_INGEST_TODAY=2026-11-20 run "$SCRIPT" --context kind-osramp --key stun-sentinel --rotate
	[ "$status" -eq 0 ]
	[ "$(expiry kind-osramp "$ISSUER_NS" "$ISSUER")" = "2027-02-18" ]
}

@test "a re-run keeps an existing expiry: converging never extends a key's life" {
	"$SCRIPT" --context kind-osramp --key stun-sentinel 2>/dev/null
	: >"$FAKE_LOG"
	SLDC_INGEST_TODAY=2026-11-20 run "$SCRIPT" --context kind-osramp --key stun-sentinel
	[ "$status" -eq 0 ]
	[ "$(expiry kind-osramp "$ISSUER_NS" "$ISSUER")" = "2026-12-31" ]
	[ "$(applies)" -eq 0 ]
}

# --- --emit-remote-secrets ----------------------------------------------------
#
# The flag writes a consumer Secret as a FILE for another cluster to apply. It
# must converge first and emit second, write nothing for a key that has no
# consumer, and leave no key value in argv or on stdout.

@test "--emit-remote-secrets without a directory is a usage error (exit 2)" {
	run "$SCRIPT" --context kind-osramp --key stun-sentinel --emit-remote-secrets
	[ "$status" -eq 2 ]
	[ "$(applies)" -eq 0 ]
}

@test "--emit-remote-secrets writes the consumer Secret, with the converged value" {
	local dir="$BATS_TEST_TMPDIR/transfer"
	run "$SCRIPT" --context kind-osramp --key stun-sentinel --emit-remote-secrets "$dir"
	[ "$status" -eq 0 ]
	[ -f "$dir/$CONSUMER.yaml" ]
	grep -q "^  name: $CONSUMER\$" "$dir/$CONSUMER.yaml"
	grep -q "^  namespace: $CONSUMER_NS\$" "$dir/$CONSUMER.yaml"
	# The value in the file is the value this run left in the issuer Secret.
	# Emitting before the last converge would write a value the cluster does
	# not hold, and the remote caller would be rejected with a valid-looking
	# key.
	local emitted
	emitted="$(awk '$1 == "token:" {print $2; exit}' "$dir/$CONSUMER.yaml" | base64 -d)"
	[ "$emitted" = "$(token kind-osramp "$ISSUER_NS" "$ISSUER")" ]
}

@test "--emit-remote-secrets emits the warden's key under the name the overlay reads" {
	# signalloom-warden is the key a remote cluster's warden holds, and
	# signalloom-warden-ingest-token is the Secret the remote-tenant overlay's
	# DaemonSet resolves SIGNAL_INGEST_TOKEN from.
	local dir="$BATS_TEST_TMPDIR/transfer"
	run "$SCRIPT" --context kind-osramp --key signalloom-warden --emit-remote-secrets "$dir"
	[ "$status" -eq 0 ]
	[ -f "$dir/signalloom-warden-ingest-token.yaml" ]
	grep -q '^  namespace: inf-signalloom-warden$' "$dir/signalloom-warden-ingest-token.yaml"
	grep -q '^  token: ' "$dir/signalloom-warden-ingest-token.yaml"
}

@test "--emit-remote-secrets writes files 0600 in a 0700 directory" {
	local dir="$BATS_TEST_TMPDIR/transfer"
	run "$SCRIPT" --context kind-osramp --key stun-sentinel --emit-remote-secrets "$dir"
	[ "$status" -eq 0 ]
	[ "$(stat -c '%a' "$dir")" = "700" ]
	[ "$(stat -c '%a' "$dir/$CONSUMER.yaml")" = "600" ]
}

@test "--emit-remote-secrets writes nothing for a key that has no consumer Secret" {
	local dir="$BATS_TEST_TMPDIR/transfer"
	run "$SCRIPT" --context kind-osramp --key sldc-live-bats --emit-remote-secrets "$dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"no consumer Secret"* ]]
	# The directory is never created for a key with nothing to emit, so an
	# empty transfer directory cannot be mistaken for a completed export.
	run ! ls "$dir"
}

@test "--emit-remote-secrets never puts a value in argv or on stdout" {
	local dir="$BATS_TEST_TMPDIR/transfer"
	printf '%s' "$GOOD_TOKEN" | "$SCRIPT" --context kind-osramp --key stun-sentinel --from-stdin 2>/dev/null
	: >"$FAKE_LOG"
	run "$SCRIPT" --context kind-osramp --key stun-sentinel --emit-remote-secrets "$dir"
	[ "$status" -eq 0 ]
	run ! grep -qF "$GOOD_TOKEN" "$FAKE_LOG"
	[[ "$output" != *"$GOOD_TOKEN"* ]]
	# The file itself does hold it. That is the whole point of the flag, and
	# the reason it is 0600.
	grep -qF "$(printf '%s' "$GOOD_TOKEN" | base64 | tr -d '\n')" "$dir/$CONSUMER.yaml"
}
