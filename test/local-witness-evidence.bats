#!/usr/bin/env bats

setup() {
	repo="$BATS_TEST_DIRNAME/.."
	tmp="$BATS_TEST_TMPDIR/local-witness"
	mkdir -p "$tmp/bin" "$tmp/keys"
	openssl genpkey -algorithm ed25519 -out "$tmp/keys/witness.pem" 2>/dev/null
	openssl pkey -in "$tmp/keys/witness.pem" -pubout -out "$tmp/keys/witness-pub.pem"
	cat > "$tmp/bin/witness" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
verb=$1
shift
working_dir=$PWD
output=""
input=""
artifact=""
attestation=""
policy=""
step=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--workingdir) working_dir=$2; shift 2 ;;
		-o) output=$2; shift 2 ;;
		-f) artifact=$2; input=$2; shift 2 ;;
		-a) attestation=$2; shift 2 ;;
		-p) policy=$2; shift 2 ;;
		--step) step=$2; shift 2 ;;
		-k) shift 2 ;;
		--) shift; break ;;
		*) shift ;;
	esac
done
printf '%s|%s|%s|%s|%s|%s|%s\n' "$verb" "$working_dir" "$artifact" "$attestation" "$policy" "$HOME" "${KUBECONFIG:-}" >> "${FAKE_WITNESS_LOG:?}"
case "$verb" in
	run)
		( cd "$working_dir" && "$@" )
		mkdir -p "$(dirname "$output")"
		printf '{"signatures":[{"keyid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' > "$output"
		;;
	sign)
		mkdir -p "$(dirname "$output")"
		cp "$input" "$output"
		;;
	verify)
		case "$artifact" in
			*modified*)
				echo "policy signature verified" >&2
				echo "Verification failed" >&2
				echo "failed to verify artifacts for step artifact-build: no passed collections present" >&2
				echo "failed to verify policy: policy verification failed" >&2
				case "${FAKE_WITNESS_VERIFY_FAILURE:-}" in
					unrelated) echo "unknown flag: --unrelated-verifier-error" >&2 ;;
					unreadable) echo "failed to read policy: permission denied" >&2 ;;
				esac
				exit 1
				;;
		esac
		case "$attestation:$policy" in
			*wrong-key.attestation.json*:*intended-policy*)
				echo "policy signature verified" >&2
				echo "collection rejected: test-evidence, Reason: no verifiers present to validate against collection verifiers" >&2
				echo "Verification failed" >&2
				echo "failed to verify artifacts for step test-evidence: no passed collections present" >&2
				echo "failed to verify policy: policy verification failed" >&2
				exit 1
				;;
		esac
		;;
	*) exit 2 ;;
esac
FAKE
	chmod +x "$tmp/bin/witness"
	export PATH="$tmp/bin:$PATH"
	export FAKE_WITNESS_LOG="$tmp/witness.log"
}

@test "owned workflow scripts contain no Archivista integration" {
	run grep -ERi 'ARCHIVISTA_URL|enable-archivista[^:]*true|enable-archivist[^:]*true|archivista-server|osramp-archivista' \
		"$repo/scripts/attested-test.sh" "$repo/scripts/promotion-demo.sh" \
		"$repo/scripts/gen-witness-policy.sh" "$repo/.github/workflows/e2e-local.yaml" \
		"$repo/.github/workflows/reusable-witness-step.yaml"
	[ "$status" -eq 1 ]
}

@test "local helper controls both Archivista aliases and isolates HOME" {
	work="$tmp/work"
	home="$tmp/home"
	run env WITNESS_LOCAL_HOME="$home" bash -c \
		'source "$1"; witness_local_prepare "$2"; witness_local_run "$2" --step test -o "$3" -k "$4" -- bash -c "printf product > product.txt"' \
		_ "$repo/scripts/lib/witness-local.sh" "$work" "$tmp/envelope.json" "$tmp/keys/witness.pem"
	[ "$status" -eq 0 ]
	run grep -F 'enable-archivista: false' "$work/.witness.yaml"
	[ "$status" -eq 0 ]
	run grep -F 'enable-archivist: false' "$work/.witness.yaml"
	[ "$status" -eq 0 ]
	run grep -F "$work" "$FAKE_WITNESS_LOG"
	[ "$status" -eq 0 ]
	run grep -F "$home" "$FAKE_WITNESS_LOG"
	[ "$status" -eq 0 ]
}

@test "local helper rejects remote publication environment" {
	run env ARCHIVISTA_URL=http://127.0.0.1:1 bash -c \
		'source "$1"; witness_local_prepare "$2"' _ \
		"$repo/scripts/lib/witness-local.sh" "$tmp/rejected"
	[ "$status" -ne 0 ]
	[[ "$output" == *"forbidden for local evidence"* ]]
}

@test "local helper rejects stale audit anchor requirement environment" {
	run env AUDIT_ANCHOR_REQUIRE_LOG=1 bash -c \
		'source "$1"; witness_local_prepare "$2"' _ \
		"$repo/scripts/lib/witness-local.sh" "$tmp/rejected"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AUDIT_ANCHOR_REQUIRE_LOG"* ]]
}

@test "witness subprocess preserves caller HOME and KUBECONFIG" {
	work="$tmp/work-preserve"
	caller_home="$tmp/caller-home"
	isolated_home="$tmp/witness-home"
	kubeconfig="$tmp/original-kubeconfig"
	mkdir -p "$caller_home"
	: > "$kubeconfig"
	run env HOME="$caller_home" KUBECONFIG="$kubeconfig" WITNESS_LOCAL_HOME="$isolated_home" \
		bash -c 'source "$1"; witness_local_prepare "$2"; witness_local_run "$2" --step test -o "$3" -k "$4" -- true; printf "after|%s|%s\n" "$HOME" "$KUBECONFIG"' \
		_ "$repo/scripts/lib/witness-local.sh" "$work" "$tmp/envelope.json" "$tmp/keys/witness.pem"
	[ "$status" -eq 0 ]
	[[ "$output" == *"after|$caller_home|$kubeconfig"* ]]
	run grep -F "$isolated_home|$kubeconfig" "$FAKE_WITNESS_LOG"
	[ "$status" -eq 0 ]
}

@test "promotion demo retains replayable artifacts and public trust only" {
	out="$tmp/evidence"
	run env KEYS_DIR="$tmp/keys" PROMOTION_OUT_DIR="$out" \
		bash "$repo/scripts/promotion-demo.sh"
	[ "$status" -eq 0 ]
	[ -s "$out/artifact-build/generic-artifact.txt" ]
	[ -s "$out/artifact-build.attestation.json" ]
	[ -s "$out/promotion-decision/promotion-decision.txt" ]
	[ -s "$out/promotion-decision.attestation.json" ]
	[ -s "$out/modified-artifact.rejection.txt" ]
	[ -s "$out/trust/public-key-fingerprints.sha256" ]
	run find "$out" -type f \( -name '*.key' -o -name '*.pem' \) ! -name '*-pub.pem'
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	run grep -F 'verify|' "$FAKE_WITNESS_LOG"
	[ "$status" -eq 0 ]
	[[ "$output" == *"promotion-decision.txt"* ]]
}

@test "promotion demo rejects unrelated verifier failure as unsigned failure" {
	for failure in unrelated unreadable; do
		out="$tmp/$failure-failure-evidence"
		run env KEYS_DIR="$tmp/keys" PROMOTION_OUT_DIR="$out" \
			FAKE_WITNESS_VERIFY_FAILURE="$failure" \
			bash "$repo/scripts/promotion-demo.sh"
		[ "$status" -ne 0 ]
		[[ "$output" == *"unexpected Witness verification failure"* ]]
	done
}

@test "stale environment refuses before key creation or directory clearing" {
	out="$tmp/stale-environment-evidence"
	keys="$tmp/stale-keys"
	mkdir -p "$out/artifact-build" "$keys"
	printf 'preserve\n' > "$out/artifact-build/sentinel.txt"
	run env AUDIT_ANCHOR_REQUIRE_LOG=1 KEYS_DIR="$keys" PROMOTION_OUT_DIR="$out" \
		bash "$repo/scripts/promotion-demo.sh"
	[ "$status" -ne 0 ]
	[[ "$output" == *"AUDIT_ANCHOR_REQUIRE_LOG"* ]]
	[ -f "$out/artifact-build/sentinel.txt" ]
	[ ! -e "$keys/policy.pem" ]
}

@test "rejection evidence matches pinned Witness diagnostics" {
	out="$tmp/pinned-diagnostics"
	run env KEYS_DIR="$tmp/keys" PROMOTION_OUT_DIR="$out" \
		bash "$repo/scripts/promotion-demo.sh"
	[ "$status" -eq 0 ]
	run grep -F 'policy signature verified' "$out/modified-artifact.rejection.txt"
	[ "$status" -eq 0 ]
	run grep -F 'Verification failed' "$out/modified-artifact.rejection.txt"
	[ "$status" -eq 0 ]
	run grep -F 'failed to verify artifacts for step artifact-build: no passed collections present' "$out/modified-artifact.rejection.txt"
	[ "$status" -eq 0 ]
	run grep -F 'failed to verify policy: policy verification failed' "$out/modified-artifact.rejection.txt"
	[ "$status" -eq 0 ]
}

@test "wrong-key flow proves fresh evidence before intended rejection" {
	run grep -F 'fresh wrong signer product' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
	run grep -F 'wrong-signer-policy/promotion-policy.signed.json' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
	run grep -F 'wrong-key-intended-policy.rejection.txt' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
}

@test "CI retains evidence even when a prior step fails" {
	run grep -A 8 'name: Retain local Witness evidence' "$repo/.github/workflows/e2e-local.yaml"
	[ "$status" -eq 0 ]
	[[ "$output" == *"if: always()"* ]]
	[[ "$output" == *"if-no-files-found: warn"* ]]
	[[ "$output" == *"docs/records/ci-evidence/local-witness/"* ]]
}

@test "local Witness defaults use repository CI evidence records" {
	run grep -F 'docs/records/ci-evidence/local-witness/attested-test' "$repo/scripts/attested-test.sh"
	[ "$status" -eq 0 ]
	run grep -F 'docs/records/ci-evidence/local-witness/promotion-demo' "$repo/scripts/promotion-demo.sh"
	[ "$status" -eq 0 ]
	run grep -F 'docs/records/ci-evidence/local-witness/' "$repo/.gitignore"
	[ "$status" -eq 0 ]
	run grep -F 'docs/records/ci-evidence/local-witness/' "$repo/README.md" "$repo/HUMAN_VALIDATION.md"
	[ "$status" -eq 0 ]
}

@test "Python and shell reject both stale remote configuration variables" {
	run grep -F 'for name in ("ARCHIVISTA_URL", "AUDIT_ANCHOR_REQUIRE_LOG")' \
		"$repo/d2-signalloom/apps/fe-signalloom/src/audit_anchor/anchor.py"
	[ "$status" -eq 0 ]
	run grep -F "AUDIT_ANCHOR_REQUIRE_LOG" "$repo/scripts/lib/witness-local.sh"
	[ "$status" -eq 0 ]
}

@test "repository setup pins Witness 0.9.1" {
	run grep -F 'WITNESS_VERSION="0.9.1"' "$repo/scripts/setup.sh"
	[ "$status" -eq 0 ]
	run grep -F './scripts/setup.sh --tools-only' "$repo/.github/workflows/reusable-witness-step.yaml"
	[ "$status" -eq 0 ]
}

@test "each owned shell script parses independently" {
	for script in \
		"$repo/scripts/lib/witness-local.sh" \
		"$repo/scripts/attested-test.sh" \
		"$repo/scripts/promotion-demo.sh" \
		"$repo/scripts/gen-witness-policy.sh"; do
		run bash -n "$script"
		[ "$status" -eq 0 ]
	done
}

# The retained-evidence private-key guard, lifted out of promotion-demo.sh and
# run under the script's own `set -euo pipefail`. A `find | grep -q .` here was
# VAC008: grep exits on the first path, find is still writing, takes EPIPE or
# SIGPIPE, and pipefail turns a FOUND key into "no key found", so the refusal
# was skipped exactly when it mattered. Thousands of keys keep find writing
# past the pipe buffer, so that race is lost every run rather than sometimes.
run_retained_key_guard() {
	local block
	block="$(awk '/find "\$\{OUT_DIR\}" -type f/ { on = 1 } on { print } on && /^fi$/ { exit }' \
		"$repo/scripts/promotion-demo.sh")"
	[ -n "$block" ]
	run bash -c "set -euo pipefail; OUT_DIR='$1'; $block"
}

@test "promotion demo refuses when retained evidence holds a private key" {
	local out="$BATS_TEST_TMPDIR/evidence"
	mkdir -p "$out/keys"
	(cd "$out/keys" && seq -f 'leaked-private-key-%06g.pem' 1 6000 | xargs touch)
	run_retained_key_guard "$out"
	[ "$status" -eq 1 ]
	[[ "$output" == *"private key found in retained evidence"* ]]
}

@test "promotion demo accepts retained evidence holding only public keys" {
	local out="$BATS_TEST_TMPDIR/evidence"
	mkdir -p "$out/keys"
	(cd "$out/keys" && seq -f 'trusted-%06g-pub.pem' 1 6000 | xargs touch)
	run_retained_key_guard "$out"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
