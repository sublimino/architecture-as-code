#!/usr/bin/env bats
#
# Adversarial inputs to the forensic evidence verifier and packager: hostile
# archive layouts, removed or forged signature material, schema violations in
# a correctly re-signed header, and secrets planted beside the evidence. Every
# refusal is asserted by exact exit code and the FAIL line on stderr.
#
# @target scripts/verify-eap-evidence.sh scripts/package-eap-evidence.sh scripts/lib/eap-evidence.sh
# @spec   schemas/eap-evidence-bundle-schema.json

bats_require_minimum_version 1.5.0

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	pack="$root/scripts/package-eap-evidence.sh"
	verify="$root/scripts/verify-eap-evidence.sh"
	ev="$BATS_TEST_TMPDIR/evidence"
	out="$BATS_TEST_TMPDIR/out"
	mkdir -p "$ev" "$out"
	cp "$root"/test/fixtures/eap-evidence/* "$ev/"

	key="$BATS_TEST_TMPDIR/signer.pem"
	pub="$BATS_TEST_TMPDIR/signer.pub.pem"
	openssl genpkey -algorithm ed25519 -out "$key" 2>/dev/null
	openssl pkey -in "$key" -pubout -out "$pub"

	export EAP_SIGNING_KEY="$key" EAP_VERIFY_PUBKEY="$pub" EAP_OUT_DIR="$out"
	export EAP_OPERATOR="bats@adversarial" EAP_CONTAINER_RUNTIME="test-runtime 0.0"
	export SOURCE_DATE_EPOCH=1790726400
	top="kusari-eap-evidence-20260930T000000Z"
	bundle="$out/$top.tar.gz"
	x="$BATS_TEST_TMPDIR/x"
}

package_ok() {
	run bash "$pack" --quiet "$ev"
	[ "$status" -eq 0 ]
	rm -rf "$x" && mkdir -p "$x" && tar -xzf "$bundle" -C "$x"
}

# pack_as ARGS...: rebuild the bundle from $x with extra tar args, then refresh
# the outer .sha256 so only the verifier's inner checks can object.
pack_as() {
	find "$x" -type f -exec chmod 0644 {} +
	tar --sort=name --owner=0 --group=0 --numeric-owner "$@" -C "$x" -czf "$bundle" "$top"
	(cd "$out" && sha256sum "$top.tar.gz" >"$top.tar.gz.sha256")
}

verify_fails_with() { # MESSAGE [verify args...]
	local msg="$1"
	shift
	run --separate-stderr bash "$verify" "$@"
	[ "$status" -eq 1 ]
	[[ "$output" == *"VERDICT: FAIL"* ]]
	[[ "$stderr" == *"$msg"* ]]
}

resign_header() { # re-sign $x/$top/bundle-header.json with the TRUSTED key
	openssl pkeyutl -sign -inkey "$key" -rawin -in "$x/$top/bundle-header.json" -out "$x/$top/bundle-header.json.sig"
}

edit_header() { # JQ-FILTER: edit the header, keep it correctly signed
	jq "$1" "$x/$top/bundle-header.json" >"$x/h" && mv "$x/h" "$x/$top/bundle-header.json"
	chmod 0644 "$x/$top/bundle-header.json"
	resign_header
	pack_as
}

# --- tampering and removal ------------------------------------------------------

@test "one flipped byte inside an artifact fails sha256sum -c, naming the file" {
	package_ok
	f="$x/$top/step2-registry-claim.json"
	# Flip one byte in place (same length, still valid JSON): '4b53ab6b' -> '4b53ab6c'.
	sed -i 's/"4b53ab6b"/"4b53ab6c"/' "$f"
	pack_as
	verify_fails_with "step2-registry-claim.json: FAILED" "$bundle"
}

@test "an artifact removed from the tarball is refused as missing" {
	package_ok
	rm "$x/$top/step1-flux-reconcile.txt"
	pack_as
	verify_fails_with "FAIL artifact step1-flux-reconcile.txt is missing" "$bundle"
}

@test "the manifest removed from the tarball is refused" {
	package_ok
	rm "$x/$top/audit-signature.sha256"
	pack_as
	verify_fails_with "FAIL audit-signature.sha256 is missing, empty, or a symlink" "$bundle"
}

@test "the detached signature removed or emptied is refused" {
	package_ok
	rm "$x/$top/bundle-header.json.sig"
	pack_as
	verify_fails_with "FAIL bundle-header.json.sig or bundle-header.json is missing" "$bundle"
	: >"$x/$top/bundle-header.json.sig"
	pack_as
	verify_fails_with "FAIL bundle-header.json.sig or bundle-header.json is missing" "$bundle"
}

@test "a garbage signature of the right length does not verify" {
	package_ok
	head -c 64 /dev/urandom >"$x/$top/bundle-header.json.sig"
	pack_as
	verify_fails_with "FAIL ed25519 signature over bundle-header.json does NOT verify" "$bundle"
}

@test "an untouched bundle checked against the wrong trusted key is refused" {
	package_ok
	openssl genpkey -algorithm ed25519 2>/dev/null | openssl pkey -pubout -out "$BATS_TEST_TMPDIR/other.pub"
	verify_fails_with "trusted key is sha256:" --pubkey "$BATS_TEST_TMPDIR/other.pub" "$bundle"
	[[ "$stderr" == *"does NOT verify"* ]]
}

@test "an unparseable trusted key is refused, not skipped" {
	package_ok
	printf 'not a key\n' >"$BATS_TEST_TMPDIR/junk.pub"
	verify_fails_with "FAIL public key $BATS_TEST_TMPDIR/junk.pub cannot be parsed" --pubkey "$BATS_TEST_TMPDIR/junk.pub" "$bundle"
}

# --- hostile archive layouts ----------------------------------------------------------

@test "a '..' entry is refused and nothing is written outside the work dir" {
	package_ok
	echo pwned >"$x/$top/escape"
	pack_as --transform "s,^$top/escape\$,$top/../escape,"
	cd "$BATS_TEST_TMPDIR"
	verify_fails_with "archive entry '$top/../escape' has an absolute or parent path" "$bundle"
	[ ! -e "$BATS_TEST_TMPDIR/escape" ]
	[ ! -e "$out/escape" ]
}

@test "an absolute-path entry is refused" {
	package_ok
	echo pwned >"$x/$top/abs"
	pack_as -P --transform "s,^$top/abs\$,/tmp/sldc-evidence-abs-$$,"
	verify_fails_with "archive entry" "$bundle"
	[[ "$stderr" == *"sldc-evidence-abs-$$"* ]]
	[ ! -e "/tmp/sldc-evidence-abs-$$" ]
}

@test "a symlink entry pointing outside the bundle is refused" {
	package_ok
	rm "$x/$top/step1-flux-reconcile.txt"
	ln -s /etc/passwd "$x/$top/step1-flux-reconcile.txt"
	pack_as
	verify_fails_with "archive entries with non-standard type/permissions: lrwxrwxrwx" "$bundle"
}

@test "a hard-link entry is refused" {
	package_ok
	ln -f "$x/$top/step3-provocation-act.log" "$x/$top/step1-flux-reconcile.txt"
	pack_as
	verify_fails_with "non-standard type/permissions" "$bundle"
}

@test "a duplicate entry is refused even when both copies are identical" {
	package_ok
	pack_as
	gunzip -c "$bundle" >"$BATS_TEST_TMPDIR/b.tar"
	tar --owner=0 --group=0 --numeric-owner -rf "$BATS_TEST_TMPDIR/b.tar" -C "$x" "$top/step1-flux-reconcile.txt"
	gzip -n -c "$BATS_TEST_TMPDIR/b.tar" >"$bundle"
	(cd "$out" && sha256sum "$top.tar.gz" >"$top.tar.gz.sha256")
	verify_fails_with "archive entry '$top/step1-flux-reconcile.txt' appears more than once" "$bundle"
}

@test "a truncated tarball is refused as unreadable" {
	package_ok
	head -c "$(($(stat -c %s "$bundle") / 2))" "$bundle" >"$BATS_TEST_TMPDIR/t" && mv "$BATS_TEST_TMPDIR/t" "$bundle"
	rm -f "$bundle.sha256"
	verify_fails_with "FAIL cannot read $bundle as a gzip tar archive" "$bundle"
}

@test "a zero-byte bundle file is refused" {
	: >"$bundle"
	verify_fails_with "FAIL cannot read $bundle as a gzip tar archive" "$bundle"
}

@test "a valid but empty archive is refused" {
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	tar -C "$BATS_TEST_TMPDIR/empty" -czf "$bundle" --files-from /dev/null
	verify_fails_with "FAIL archive top-level entry '' is not kusari-eap-evidence-<UTC timestamp>" "$bundle"
}

@test "directory mode: a symlinked signature or public key is refused" {
	package_ok
	mv "$ev/bundle-header.json.sig" "$BATS_TEST_TMPDIR/real.sig"
	ln -s "$BATS_TEST_TMPDIR/real.sig" "$ev/bundle-header.json.sig"
	verify_fails_with "FAIL bundle-header.json.sig is a symlink" "$ev"
	rm "$ev/bundle-header.json.sig" && mv "$BATS_TEST_TMPDIR/real.sig" "$ev/bundle-header.json.sig"
	mv "$ev/signing-key.pub.pem" "$BATS_TEST_TMPDIR/real.pub"
	ln -s "$BATS_TEST_TMPDIR/real.pub" "$ev/signing-key.pub.pem"
	verify_fails_with "FAIL signing-key.pub.pem is a symlink" "$ev"
}

# --- schema violations in a header the attacker could not have signed ------------
# Each edit is re-signed with the trusted key, so the signature passes and only
# the schema check can catch it.

@test "header: a correctly signed header passes (control for the schema cases)" {
	package_ok
	edit_header '.'
	run bash "$verify" "$bundle"
	[ "$status" -eq 0 ]
}

@test "header: a missing required field is refused" {
	package_ok
	edit_header 'del(.signed_at)'
	verify_fails_with 'bundle-header.json violates the schema: $: missing required property signed_at' "$bundle"
}

@test "header: a field of the wrong type is refused" {
	package_ok
	edit_header '.artifacts[0].bytes |= tostring'
	verify_fails_with 'violates the schema: $.artifacts[0].bytes: expected type integer, got string' "$bundle"
}

@test "header: an extra field is refused (additionalProperties false)" {
	package_ok
	edit_header '.note = "trust me"'
	verify_fails_with 'violates the schema: $: unexpected property note' "$bundle"
}

@test "header: an artifact name outside the enum is refused" {
	package_ok
	edit_header '.artifacts[0].name = "../../etc/passwd"'
	verify_fails_with 'violates the schema: $.artifacts[0].name: must be one of' "$bundle"
}

@test "header: a malformed digest is refused by pattern" {
	package_ok
	edit_header '.manifest.sha256 |= ascii_upcase'
	verify_fails_with 'violates the schema: $.manifest.sha256:' "$bundle"
}

@test "an artifact carrying a second JSON document is refused by the packager" {
	echo '{"tenant":"kurasl"}' >>"$ev/step2-registry-claim.json"
	run --separate-stderr bash "$pack" "$ev"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"step2-registry-claim.json violates schema"*"exactly one JSON document"* ]]
	[ ! -e "$bundle" ]
}

# --- secrets never leave the host ------------------------------------------------------

@test "packager never packages planted keys, tokens or dotfiles beside the evidence" {
	mkdir -p "$ev/.keys"
	cp "$key" "$ev/.keys/witness.pem"
	cp "$key" "$ev/witness.pem"
	echo 'ghp_000000000000000000000000000000000000' >"$ev/token"
	echo 'secret' >"$ev/.env"
	run bash "$pack" --quiet "$ev"
	[ "$status" -eq 0 ]
	run tar -tzf "$bundle"
	[ "$status" -eq 0 ]
	[ "$(wc -l <<<"$output")" -eq 12 ] # directory + 11 bundle files
	[[ "$output" != *"witness.pem"* ]]
	[[ "$output" != *".keys"* ]]
	[[ "$output" != *"token"* ]]
	[[ "$output" != *".env"* ]]
	# No private key material in any packaged byte.
	! tar -xzOf "$bundle" | grep -q 'PRIVATE KEY'
	for f in "$out"/*; do ! grep -q 'PRIVATE KEY' "$f"; done
}

@test "packager output is byte-identical across runs from pristine copies" {
	cp -r "$ev" "$BATS_TEST_TMPDIR/ev2"
	run bash "$pack" --quiet "$ev"
	[ "$status" -eq 0 ]
	first="$(sha256sum "$bundle" | cut -d' ' -f1)"
	mv "$out" "$BATS_TEST_TMPDIR/out1"
	run bash "$pack" --quiet --out "$out" "$BATS_TEST_TMPDIR/ev2"
	[ "$status" -eq 0 ]
	[ "$(sha256sum "$bundle" | cut -d' ' -f1)" = "$first" ]
}

@test "packager: a bundle that fails self-verification leaves no bundle copy behind" {
	# A schema only the verifier sees makes self-verification fail after packing.
	jq '.required += ["never_present"]' "$root/schemas/eap-evidence-bundle-schema.json" >"$BATS_TEST_TMPDIR/strict.json"
	EAP_SCHEMA="$BATS_TEST_TMPDIR/strict.json" run --separate-stderr bash "$pack" --quiet "$ev"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"self-verification of $bundle failed; bundle deleted"* ]]
	[ ! -e "$bundle" ]
	[ ! -e "$out/eap-kusari-containment.tar.gz" ]
	[ ! -e "$out/eap-kusari-containment.tar.gz.sha256" ]
}

@test "packager refuses missing evidence directory with exit 1" {
	run --separate-stderr bash "$pack" "$BATS_TEST_TMPDIR/absent"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"evidence directory $BATS_TEST_TMPDIR/absent does not exist"* ]]
}

@test "verifier: a target that is neither file nor directory is a usage error (exit 2)" {
	run --separate-stderr bash "$verify" "$BATS_TEST_TMPDIR/absent"
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"is neither a file nor a directory"* ]]
}
