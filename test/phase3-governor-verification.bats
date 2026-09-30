#!/usr/bin/env bats
# ==============================================================================
# SLDC-P3-GOV: the Phase 3 governor certificate must reflect what actually ran.
#
# Drives scripts/test-phase3-governor.sh --hermetic with stubbed sub-suite
# runners (go, bun, bats, the mutation proof) so each gate can be forced green
# or red, while the ingress gates run the real verify script (HTTPRoute + real
# Lua) and Gate 8 runs the real preflight legacy-gate. Asserts exit code, the
# certificate JSON and per-gate status. The sub-suites themselves are covered
# by their own files; this suite never re-runs them.
#
# @id     phase3-governor-verification-bats
# @target scripts/test-phase3-governor.sh
# @task   SLDC-P3-GOV
# ==============================================================================

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	GOV="$REPO_ROOT/scripts/test-phase3-governor.sh"
	export KUBECONFIG=/dev/null
	stub="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$stub"
	for tool in go bun bats; do stub_tool "$tool" 0; done
	# No live traffic can leave this suite: a non-hermetic probe gets "refused".
	stub_tool curl 7
	stub_tool mutation-proof 0
	export PATH="$stub:$PATH"
	export PHASE3_MUTATION_PROOF="$stub/mutation-proof"
	CERT="$BATS_TEST_TMPDIR/cert.json"
	TRACE="$BATS_TEST_TMPDIR/trace.txt"
}

stub_tool() { # name exit-code
	printf '#!/usr/bin/env bash\nexit %s\n' "$2" >"$stub/$1"
	chmod +x "$stub/$1"
}

run_gov() {
	run "$GOV" --hermetic --out "$CERT" --trace-out "$TRACE"
}

gate() { # id -> status
	jq -r --arg g "$1" '.gates[] | select(.gate == $g) | .status' "$CERT"
}

@test "all gates green: exit 0 and a PASS certificate with 8/8 gates and 12/12 probes" {
	run_gov
	[ "$status" -eq 0 ]
	[ "$(jq -r '.governor_status' "$CERT")" = "PASS" ]
	[ "$(jq -r '.metrics | "\(.gates_total) \(.gates_passed) \(.gates_failed) \(.probes_total) \(.probes_passed)"' "$CERT")" = "8 8 0 12 12" ]
	[ "$(jq -r '.signoff.authorized_for_phase4' "$CERT")" = "true" ]
}

@test "a failing gate still writes a FAIL certificate that names it, and exits 1" {
	stub_tool mutation-proof 1
	run_gov
	[ "$status" -eq 1 ]
	[ -s "$CERT" ]
	[ "$(jq -r '.governor_status' "$CERT")" = "FAIL" ]
	[ "$(gate G7_MUTATION_TESTING)" = "FAIL" ]
	[ "$(jq -r '.metrics.gates_failed' "$CERT")" = "1" ]
	[ "$(jq -r '.signoff.authorized_for_phase4' "$CERT")" = "false" ]
}

@test "Gate 2 fails and names the Go suite when go test fails; the trace does not claim PASS" {
	stub_tool go 1
	run_gov
	[ "$status" -eq 1 ]
	[ "$(gate G2_CRYPTO_VECTORS)" = "FAIL" ]
	[[ "$(jq -r '.gates[] | select(.gate == "G2_CRYPTO_VECTORS") | .details' "$CERT")" == *"Go"* ]]
	! grep -q 'Go=PASS' "$TRACE"
}

@test "ingress gates come from the real Lua: a filter admitting kurasi fails Gate 6 only" {
	policy="$REPO_ROOT/d2-infra/components/ingress/tenant-filter-policy.yaml"
	sed 's/clean_tenant == "kurasi" or //; s/clean_tenant ~= "kusari" and/clean_tenant ~= "kusari" and clean_tenant ~= "kurasi" and/' "$policy" >"$BATS_TEST_TMPDIR/policy.yaml"
	SLDC_TENANT_POLICY_MANIFEST="$BATS_TEST_TMPDIR/policy.yaml" run_gov
	[ "$status" -eq 1 ]
	[ "$(gate G5_POSITIVE_ROUTING)" = "PASS" ]
	[ "$(gate G6_NEGATIVE_ISOLATION)" = "FAIL" ]
	[ "$(jq -r '.metrics.probes_passed' "$CERT")" = "10" ]
}

@test "Gate 8 fails when an active file names the legacy typo without an allowlist entry" {
	: >"$BATS_TEST_TMPDIR/empty-allowlist.txt"
	P3_LEGACY_ALLOWLIST="$BATS_TEST_TMPDIR/empty-allowlist.txt" run_gov
	[ "$status" -eq 1 ]
	[ "$(gate G8_ZERO_TOLERANCE_SCAN)" = "FAIL" ]
	[[ "$(jq -r '.gates[] | select(.gate == "G8_ZERO_TOLERANCE_SCAN") | .details' "$CERT")" == *"unexcused"* ]]
}

@test "the certificate is valid JSON and records the HEAD it certified" {
	run_gov
	[ "$(jq -r '.commit_sha' "$CERT")" = "$(git -C "$REPO_ROOT" rev-parse HEAD)" ]
	[ "$(jq -r '.canonical_vector | "\(.tenant_name) \(.tenant_hash) \(.canonical_fqdn)"' "$CERT")" = "kusari 4b53ab6b sl-eap-4b53ab6b.ts.net" ]
}

@test "an unknown option is a usage error (exit 2) that writes nothing" {
	run "$GOV" --bogus --out "$CERT"
	[ "$status" -eq 2 ]
	[ ! -e "$CERT" ]
}
