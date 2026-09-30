#!/usr/bin/env bats
#
# SLDC-P5-2: the forensic evidence bundle must be tamper-evident. Tier 1: the
# committed fixture (evidence_origin=fixture), an ephemeral Ed25519 key, no
# cluster, no .keys/. Every "passes" test has mutation siblings that break
# exactly one fact and must fail (Shared Pattern 6: no vacuous greens).
#
# @target scripts/package-eap-evidence.sh scripts/verify-eap-evidence.sh
# @doc    docs/eap/FORENSIC-BUNDLE-SPECIFICATION.md
# @spec   schemas/eap-evidence-bundle-schema.json

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

	export EAP_SIGNING_KEY="$key"
	export EAP_VERIFY_PUBKEY="$pub"
	export EAP_OUT_DIR="$out"
	export EAP_OPERATOR="bats@sldc-p5-2"
	export EAP_CONTAINER_RUNTIME="test-runtime 0.0"
	export SOURCE_DATE_EPOCH=1790726400
	bundle="$out/kusari-eap-evidence-20260930T000000Z.tar.gz"
}

package() { run bash "$pack" "$@" "$ev"; }

# Rebuild the tarball from an extracted, edited copy, the way an attacker who
# can write the archive would, and refresh its .sha256 so only the inner
# integrity chain can catch the edit.
repack() {
	local x="$BATS_TEST_TMPDIR/x" top
	rm -rf "$x" && mkdir -p "$x"
	tar -xzf "$bundle" -C "$x"
	top="$(ls "$x")"
	"$@" "$x/$top"
	tar --sort=name --owner=0 --group=0 --numeric-owner -C "$x" -czf "$bundle" "$top"
	(cd "$out" && sha256sum "$(basename "$bundle")" >"$(basename "$bundle").sha256")
}

@test "packager signs the fixture: 8 artifacts, no empty files, exit 0" {
	package
	[ "$status" -eq 0 ]
	[[ "$output" == *"bundle: $bundle"* ]]
	[ -f "$bundle" ] && [ -f "$bundle.sha256" ]
	n="$(ls -1 "$ev" | grep -cE '^(preflight-manifest\.json|step1-flux-reconcile\.txt|step2-registry-claim\.json|step3-provocation-act\.log|step4-ebpf-observation\.json|step5-cgroup-freeze\.txt|step5-cadvisor-metrics\.prom|audit-signature\.sha256)$')"
	[ "$n" -eq 8 ]
	[ "$(find "$ev" -type f -size 0c | wc -l)" -eq 0 ]
	[ "$(wc -l <"$ev/audit-signature.sha256")" -eq 7 ]
	! grep -Evq '^[0-9a-f]{64}  ' "$ev/audit-signature.sha256"
}

@test "sha256sum -c on the evidence directory reports 7 OK" {
	package
	[ "$status" -eq 0 ]
	run bash -c "cd '$ev' && sha256sum -c audit-signature.sha256"
	[ "$status" -eq 0 ]
	[ "$(grep -c ': OK$' <<<"$output")" -eq 7 ]
}

@test "verifier accepts the untouched tarball and directory" {
	package
	[ "$status" -eq 0 ]
	run bash "$verify" "$bundle"
	[ "$status" -eq 0 ]
	[[ "$output" == *"VERDICT: PASS"* ]]
	[[ "$output" == *"sha256sum -c audit-signature.sha256: 7 OK, 0 mismatches"* ]]
	[[ "$output" == *"ed25519 signature over bundle-header.json verifies"* ]]
	run bash "$verify" "$ev"
	[ "$status" -eq 0 ]
}

@test "tarball is reproducible: same inputs and SOURCE_DATE_EPOCH give the same digest" {
	package
	[ "$status" -eq 0 ]
	first="$(cut -d' ' -f1 "$bundle.sha256")"
	rm -f "$bundle" "$bundle.sha256"
	package
	[ "$status" -eq 0 ]
	[ "$(cut -d' ' -f1 "$bundle.sha256")" = "$first" ]
}

@test "tarball entries are root-owned, files 0644, directory 0755" {
	package
	[ "$status" -eq 0 ]
	run tar -tvzf "$bundle"
	[ "$status" -eq 0 ]
	[ "$(awk '$2 != "0/0"' <<<"$output" | wc -l)" -eq 0 ]
	[ "$(awk '$1 == "drwxr-xr-x"' <<<"$output" | wc -l)" -eq 1 ]
	[ "$(awk '$1 == "-rw-r--r--"' <<<"$output" | wc -l)" -eq 11 ]
}

@test "header records signing time, commit, operator, kernel, runtime and arch" {
	package
	[ "$status" -eq 0 ]
	h="$ev/bundle-header.json"
	[ "$(jq -r .signed_at "$h")" = "2026-09-30T00:00:00Z" ]
	[ "$(jq -r .git.commit "$h")" = "$(git -C "$root" rev-parse HEAD)" ]
	[ "$(jq -r .operator.identity "$h")" = "bats@sldc-p5-2" ]
	[ "$(jq -r .host.kernel_release "$h")" = "$(uname -r)" ]
	[ "$(jq -r .host.architecture "$h")" = "$(uname -m)" ]
	[ "$(jq -r .host.container_runtime "$h")" = "test-runtime 0.0" ]
	[ "$(jq -r .evidence_origin "$h")" = "fixture" ]
}

# --- tamper detection -----------------------------------------------------------

@test "mutation: one space appended to step4-ebpf-observation.json fails sha256sum -c" {
	package
	[ "$status" -eq 0 ]
	printf ' ' >>"$ev/step4-ebpf-observation.json"
	run bash -c "cd '$ev' && sha256sum -c audit-signature.sha256"
	[ "$status" -eq 1 ]
	[[ "$output" == *"step4-ebpf-observation.json: FAILED"* ]]
	run bash "$verify" "$ev"
	[ "$status" -eq 1 ]
	[[ "$output" == *"VERDICT: FAIL"* ]]
}

@test "mutation: artifact edited inside the tarball (outer .sha256 refreshed) is caught" {
	package
	[ "$status" -eq 0 ]
	edit() { sed -i 's/frozen 1/frozen 1 /' "$1/step5-cgroup-freeze.txt"; }
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"step5-cgroup-freeze.txt: FAILED"* ]]
}

@test "mutation: attacker also re-hashes the manifest; the signed header catches it" {
	package
	[ "$status" -eq 0 ]
	edit() { printf ' ' >>"$1/step3-provocation-act.log"; (cd "$1" && sha256sum preflight-manifest.json step1-flux-reconcile.txt step2-registry-claim.json step3-provocation-act.log step4-ebpf-observation.json step5-cgroup-freeze.txt step5-cadvisor-metrics.prom >audit-signature.sha256); }
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"bundle-header.json does not match the files"* ]]
}

@test "mutation: attacker rewrites manifest and header; the signature catches it" {
	package
	[ "$status" -eq 0 ]
	edit() {
		local d="$1" m s
		printf ' ' >>"$d/step3-provocation-act.log"
		(cd "$d" && sha256sum preflight-manifest.json step1-flux-reconcile.txt step2-registry-claim.json step3-provocation-act.log step4-ebpf-observation.json step5-cgroup-freeze.txt step5-cadvisor-metrics.prom >audit-signature.sha256)
		m="$(sha256sum "$d/audit-signature.sha256" | cut -d' ' -f1)"
		s="$(sha256sum "$d/step3-provocation-act.log" | cut -d' ' -f1)"
		jq --arg m "$m" --arg s "$s" --argjson b "$(stat -c %s "$d/step3-provocation-act.log")" \
			'.manifest.sha256 = $m | (.artifacts[] | select(.name == "step3-provocation-act.log")) |= (.sha256 = $s | .bytes = $b)' \
			"$d/bundle-header.json" >"$d/h" && mv "$d/h" "$d/bundle-header.json"
		# A careful attacker restores the standard mode so only the signature is left.
		chmod 0644 "$d/bundle-header.json"
	}
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"signature over bundle-header.json does NOT verify"* ]]
}

@test "mutation: bundle re-signed with an attacker key fails against the trusted key" {
	package
	[ "$status" -eq 0 ]
	evil="$BATS_TEST_TMPDIR/evil.pem"
	openssl genpkey -algorithm ed25519 -out "$evil" 2>/dev/null
	# The attacker's packager self-verifies against the attacker's own key...
	EAP_SIGNING_KEY="$evil" package
	[ "$status" -eq 0 ]
	# ...but an auditor holding the published key rejects both copies.
	run bash "$verify" --pubkey "$pub" "$ev"
	[ "$status" -eq 1 ]
	[[ "$output" == *"trusted key is sha256:"* ]]
	[[ "$output" == *"does NOT verify"* ]]
	run bash "$verify" --pubkey "$pub" "$bundle"
	[ "$status" -eq 1 ]
}

@test "mutation: an extra file injected into the tarball is rejected" {
	package
	[ "$status" -eq 0 ]
	edit() { echo 'forged' >"$1/step6-extra.txt"; }
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"step6-extra.txt' is not part of the bundle contract"* ]]
}

@test "mutation: world-writable entry permissions are rejected" {
	package
	[ "$status" -eq 0 ]
	edit() { chmod 0666 "$1/step1-flux-reconcile.txt"; }
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"non-standard type/permissions"* ]]
}

@test "mutation: outer tarball checksum mismatch is reported" {
	package
	[ "$status" -eq 0 ]
	# Rotate the first hex digit: always a change (a fixed replacement is a no-op
	# 1 time in 16, because the ephemeral key makes the digest random).
	sum="$(cat "$bundle.sha256")"
	first="$(printf '%s' "${sum:0:1}" | tr '0-9a-f' '1-9a-f0')"
	printf '%s%s\n' "$first" "${sum:1}" >"$bundle.sha256"
	[ "$(cat "$bundle.sha256")" != "$sum" ]
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"bundle checksum mismatch"* ]]
}

# --- packager refusals -----------------------------------------------------------

@test "packager refuses a missing artifact, naming it, exit 1" {
	rm "$ev/step5-cadvisor-metrics.prom"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"artifact step5-cadvisor-metrics.prom is missing"* ]]
	[ ! -e "$ev/audit-signature.sha256" ]
	[ ! -e "$bundle" ]
}

@test "packager refuses a zero-byte artifact, exit 1" {
	: >"$ev/step3-provocation-act.log"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"artifact step3-provocation-act.log is empty (0 bytes)"* ]]
}

@test "packager refuses a symlinked artifact, exit 1" {
	mv "$ev/step1-flux-reconcile.txt" "$BATS_TEST_TMPDIR/real.txt"
	ln -s "$BATS_TEST_TMPDIR/real.txt" "$ev/step1-flux-reconcile.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"step1-flux-reconcile.txt is a symlink"* ]]
}

@test "hard blocker: 'frozen 0' voids the primary forensic proof (packager and verifier)" {
	package
	[ "$status" -eq 0 ]
	edit() { sed -i 's/^frozen 1$/frozen 0/' "$1/step5-cgroup-freeze.txt"; }
	repack edit
	run bash "$verify" "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"PRIMARY FORENSIC PROOF INVALID"* ]]
	rm -f "$ev/audit-signature.sha256"
	sed -i 's/^frozen 1$/frozen 0/' "$ev/step5-cgroup-freeze.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"PRIMARY FORENSIC PROOF INVALID: step5-cgroup-freeze.txt reports 'frozen 0'"* ]]
}

@test "mutation: no 'frozen 1' line at all is not proof of freeze" {
	sed -i '/^frozen /d' "$ev/step5-cgroup-freeze.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"has no 'frozen 1' line"* ]]
}

@test "mutation: restartCount 1 breaks forensic preservation" {
	sed -i 's/^restartCount: 0$/restartCount: 1/' "$ev/step5-cgroup-freeze.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"restartCount is not 0"* ]]
}

@test "mutation: a moving CPU counter is not a 0 mCPU flatline" {
	sed -i '$ s/0\.18422 /0.19000 /' "$ev/step5-cadvisor-metrics.prom"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"0 mCPU not proven"* ]]
}

@test "mutation: legacy tenant kurasi fails closed, even in an unschematised text artifact" {
	# step3 is a free-text log with no schema: only the tenant sweep can catch it.
	echo 'X-Tenant-ID: kurasi' >>"$ev/step3-provocation-act.log"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL legacy tenant 'kurasi' / '6f82ad81' found in evidence"* ]]
	[ ! -e "$bundle" ]
}

@test "mutation: legacy tenant hash in the registry claim violates the schema" {
	sed -i 's/"tenant_hash": "4b53ab6b"/"tenant_hash": "6f82ad81"/' "$ev/step2-registry-claim.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"step2-registry-claim.json violates schema"*'$.tenant_hash: must equal "4b53ab6b"'* ]]
}

@test "mutation: eBPF observation with an unnormalised syscall violates the schema" {
	sed -i 's/"sys_enter_openat"/"openat"/' "$ev/step4-ebpf-observation.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"step4-ebpf-observation.json violates schema"* ]]
}

@test "mutation: malformed JSON artifact is refused" {
	printf '{' >"$ev/preflight-manifest.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"preflight-manifest.json is not valid JSON"* ]]
}

@test "packager refuses to re-sign evidence changed since its manifest was written" {
	package
	[ "$status" -eq 0 ]
	printf ' ' >>"$ev/step4-ebpf-observation.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"refusing to re-sign tampered evidence"* ]]
}

@test "hard blocker: missing signing key, exit 1" {
	EAP_SIGNING_KEY="$BATS_TEST_TMPDIR/absent.pem" package
	[ "$status" -eq 1 ]
	[[ "$output" == *"is missing"* ]]
	[ ! -e "$ev/audit-signature.sha256" ]
}

@test "hard blocker: corrupted signing key, exit 1" {
	printf -- '-----BEGIN PRIVATE KEY-----\nnot-a-key\n-----END PRIVATE KEY-----\n' >"$BATS_TEST_TMPDIR/bad.pem"
	EAP_SIGNING_KEY="$BATS_TEST_TMPDIR/bad.pem" package
	[ "$status" -eq 1 ]
	[[ "$output" == *"corrupted"* ]]
}

@test "hard blocker: a non-Ed25519 signing key is refused" {
	openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$BATS_TEST_TMPDIR/ec.pem" 2>/dev/null
	EAP_SIGNING_KEY="$BATS_TEST_TMPDIR/ec.pem" package
	[ "$status" -eq 1 ]
	[[ "$output" == *"not an Ed25519 private key"* ]]
}

# --- origin, defaults, usage ------------------------------------------------------

@test "--require-live rejects fixture evidence; live-origin evidence passes it" {
	package
	[ "$status" -eq 0 ]
	run bash "$verify" --require-live "$bundle"
	[ "$status" -eq 1 ]
	[[ "$output" == *"evidence_origin is 'fixture' and --require-live was given"* ]]
	rm -f "$ev/audit-signature.sha256" "$bundle" "$bundle.sha256"
	jq '.evidence_origin = "live"' "$ev/preflight-manifest.json" >"$ev/p" && mv "$ev/p" "$ev/preflight-manifest.json"
	package
	[ "$status" -eq 0 ]
	run bash "$verify" --require-live "$bundle"
	[ "$status" -eq 0 ]
}

@test "no argument: packages the latest run under EAP_EVIDENCE_ROOT" {
	export EAP_EVIDENCE_ROOT="$BATS_TEST_TMPDIR/runs"
	mkdir -p "$EAP_EVIDENCE_ROOT/20260929T100000" "$EAP_EVIDENCE_ROOT/20260930T100000"
	cp "$ev"/* "$EAP_EVIDENCE_ROOT/20260930T100000/"
	run bash "$pack"
	[ "$status" -eq 0 ]
	[[ "$output" == *"evidence: $EAP_EVIDENCE_ROOT/20260930T100000"* ]]
	[ -s "$EAP_EVIDENCE_ROOT/20260930T100000/audit-signature.sha256" ]
	[ ! -e "$EAP_EVIDENCE_ROOT/20260929T100000/audit-signature.sha256" ]
}

@test "usage errors exit 2" {
	run bash "$pack" --bogus
	[ "$status" -eq 2 ]
	run bash "$verify"
	[ "$status" -eq 2 ]
}

# --- the shapes SLDC-P5-1 actually writes (test/e2e-dual-cluster-containment.bats) ---

p5_1_shapes() {
	cat >"$ev/step2-registry-claim.json" <<'JSON'
{"query":"SELECT name, tenant_id, model_name FROM public.agent_registry WHERE name='kusari-agent';","row":"kusari-agent|kusari|deterministic","tenant":"kusari","tenant_hash":"4b53ab6b","model_name":"deterministic"}
JSON
	cat >"$ev/step4-ebpf-observation.json" <<'JSON'
{"actor_id":"kusari-agent","pod_name":"agent-kusari-7c9f8d6b5-x2x4q","syscall":"sys_enter_openat","target":"/etc/passwd","tenant_id":"kusari","timestamp":"2026-09-30T00:00:11.120Z","labels":{"cgroup_path":"/kubepods.slice/pod0000"}}
JSON
	sed -i '/^## cpu.stat/i cadvisor_cpu_seconds: 0.18422 -> 0.18422\ndelta_mcpu: 0.000' "$ev/step5-cgroup-freeze.txt"
	sed -i '$d' "$ev/step5-cadvisor-metrics.prom"
}

@test "P5-1 wire shapes (claim row, bare event, text flatline, single scrape) package and verify" {
	p5_1_shapes
	package
	[ "$status" -eq 0 ]
	[[ "$output" == *"records an unchanged cAdvisor CPU counter (0 mCPU)"* ]]
	run bash "$verify" "$bundle"
	[ "$status" -eq 0 ]
}

@test "mutation: a moving cadvisor_cpu_seconds record fails even with a flat scrape" {
	sed -i '/^## cpu.stat/i cadvisor_cpu_seconds: 0.18422 -> 0.20100' "$ev/step5-cgroup-freeze.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"records a moving cAdvisor CPU counter"* ]]
}

@test "mutation: an eBPF observation without any cgroup_path is refused" {
	p5_1_shapes
	jq 'del(.labels)' "$ev/step4-ebpf-observation.json" >"$ev/o" && mv "$ev/o" "$ev/step4-ebpf-observation.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"observation without cgroup_path"* ]]
}

@test "mutation: a claim naming neither tenant nor tenant_id violates the schema" {
	p5_1_shapes
	jq 'del(.tenant)' "$ev/step2-registry-claim.json" >"$ev/o" && mv "$ev/o" "$ev/step2-registry-claim.json"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"step2-registry-claim.json violates schema"*"anyOf"* ]]
}

@test "a key:value preflight-manifest.json.txt is not the F.2 preflight-manifest.json" {
	mv "$ev/preflight-manifest.json" "$ev/preflight-manifest.json.txt"
	package
	[ "$status" -eq 1 ]
	[[ "$output" == *"artifact preflight-manifest.json is missing"* ]]
}
