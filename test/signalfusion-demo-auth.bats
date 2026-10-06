#!/usr/bin/env bats
# @id test/signalfusion-demo-auth.bats
# @target scripts/signalfusion-demo.sh
#
# signal-ingest authenticates every route, so the Signal Fusion demo presents its own named static
# key (signalfusion-demo). The key comes from a mounted Secret file (in-cluster runner,
# SIGNAL_INGEST_KEY_FILE) or, on an operator's machine, from the issuer Secret through kubectl. It
# reaches curl only as a header FILE (-H @file): never argv, never printed.
#
# These run the real script's Act 1 against a fake curl that records each argv and the header file
# it was handed, and answers the four Act 1 routes.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/signalfusion-demo.sh"
KEY="sfDemoKey7x2Lq9pN4cR8tY1kD6hF3jS5aZ0mE7uB2oG"

setup() {
	export KUBECONFIG=/dev/null
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
	export CALLS="$BATS_TEST_TMPDIR/curl.log" HEADERS="$BATS_TEST_TMPDIR/headers.log"
	: >"$CALLS"
	: >"$HEADERS"
	cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
prev=""
url=""
for a in "$@"; do
	if [[ "$prev" == "-H" && "$a" == @* ]]; then cat "${a#@}" >>"$HEADERS"; fi
	[[ "$a" == http* ]] && url="$a"
	prev="$a"
done
case "$url" in
*/healthz) echo '{"status":"ok"}' ;;
*/api/v1/collectors/seed) echo '{"seeded":5}' ;;
*/api/v1/correlate) echo '{"actors_discovered":0,"actors":[]}' ;;
*/api/v1/actors) echo '[]' ;;
*) echo '{}' ;;
esac
STUB
	cat >"$BIN/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >>"$CALLS"
# Act 1's preflight (cluster-info, get ns) succeeds; the key Secret exists only when a test says so.
if [[ "$*" == *"get secret signal-ingest-key-signalfusion-demo"* ]]; then
	[[ -n "${FAKE_SECRET_B64:-}" ]] || exit 1
	printf '%s' "$FAKE_SECRET_B64"
fi
exit 0
STUB
	chmod +x "$BIN/curl" "$BIN/kubectl"
	export PATH="$BIN:$PATH"
	export SIGNAL_INGEST_URL="http://signal-ingest:8082"
}

@test "every request carries the demo key as a header file, never in argv" {
	printf '%s\n' "$KEY" >"$BATS_TEST_TMPDIR/token"
	SIGNAL_INGEST_KEY_FILE="$BATS_TEST_TMPDIR/token" run "$SCRIPT" 1
	[ "$(wc -l <"$CALLS")" -ge 4 ]
	! rg -qF "$KEY" "$CALLS"
	[[ "$output" != *"$KEY"* ]]
	# One header line per request, each exactly the key.
	[ "$(rg -c '' "$HEADERS")" -eq "$(rg -c '^-' "$CALLS")" ]
	! rg -v -x -F "Authorization: Bearer $KEY" "$HEADERS"
	rg -q -e '-H @' "$CALLS"
}

@test "the header file does not outlive the run" {
	printf '%s' "$KEY" >"$BATS_TEST_TMPDIR/token"
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	SIGNAL_INGEST_KEY_FILE="$BATS_TEST_TMPDIR/token" run "$SCRIPT" 1
	[ -z "$(ls -A "$TMPDIR")" ]
}

@test "with no key file, the key is read from the issuer Secret" {
	export FAKE_SECRET_B64="$(printf '%s' "$KEY" | base64 | tr -d '\n')"
	run "$SCRIPT" 1
	# Without this, a run that crashed before ever calling curl would still
	# leave $CALLS/$HEADERS exactly as unpopulated by the real script, and the
	# rg checks below would need the fallback path to have actually executed
	# to mean anything.
	[ "$status" -eq 0 ]
	rg -q 'kubectl -n fe-signalloom get secret signal-ingest-key-signalfusion-demo' "$CALLS"
	rg -q -x -F "Authorization: Bearer $KEY" "$HEADERS"
	! rg -qF "$KEY" "$CALLS"
}

@test "no key anywhere fails before any request, naming how to mint one" {
	run "$SCRIPT" 1
	[ "$status" -eq 1 ]
	[[ "$output" == *"no signal-ingest key"* ]]
	[[ "$output" == *"sldc-ingest-bearer.sh --key signalfusion-demo"* ]]
	! rg -q '^-sS' "$CALLS"
}

@test "an unreadable key file fails loudly rather than falling back" {
	SIGNAL_INGEST_KEY_FILE="$BATS_TEST_TMPDIR/absent" run "$SCRIPT" 1
	[ "$status" -eq 1 ]
	[[ "$output" == *"SIGNAL_INGEST_KEY_FILE"* ]]
	! rg -q '^-sS' "$CALLS"
}
