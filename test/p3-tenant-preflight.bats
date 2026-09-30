#!/usr/bin/env bats
#
# SLDC-P3-PRE: the tenant preflight oracle must accept only the canonical
# kusari vector (4b53ab6b), fail closed on the retired kurasi typo (6f82ad81)
# and the unsalted digest (d9d69501), and inventory legacy strings without
# counting the wrong things. Tier 1: no cluster, fake kubectl, fixture repos.

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/p3-tenant-preflight.sh"
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	export P3_SKIP_CLUSTER=1
}

make_fixture_repo() {
	fixture="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$fixture/src" "$fixture/docs" "$fixture/pkg"
	git -C "$fixture" init -q
	printf 'tenant = "kusari"\n' >"$fixture/src/ok.py"
	[[ "${1:-}" == "clean" ]] || {
		printf 'if tenant == "kurasi" {}\n' >"$fixture/src/router.go"
		printf 'host: sl-eap-6f82ad81.ts.net\n' >"$fixture/src/route.yaml"
		printf 'old run used kurasi\n' >"$fixture/docs/report.md"
		printf 'func TestKurasi() {}\n' >"$fixture/pkg/x_test.go"
	}
	git -C "$fixture" add -A
	git -C "$fixture" -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -qm fixture
	export P3_REPO="$fixture"
}

fake_kubectl() {
	# $1 = JSON body the fake bao returns, $2 = exit code
	cat >"$bin/kubectl" <<FAKE
#!/usr/bin/env bash
printf '%s\n' '$1'
exit $2
FAKE
	chmod +x "$bin/kubectl"
	export KUBECTL="$bin/kubectl" P3_SKIP_CLUSTER=0
}

@test "the implemented salted formula reproduces the canonical kusari hash 4b53ab6b" {
	run "$script" vectors
	[ "$status" -eq 0 ]
	[ "$(jq -r '.canonical.computed' <<<"$output")" = "4b53ab6b" ]
	[ "$(jq -r '.canonical.match' <<<"$output")" = "true" ]
}

@test "the retired and unsalted vectors are recomputed from their definitions, not trusted" {
	run "$script" vectors
	[ "$(jq -r '.retired.computed' <<<"$output")" = "6f82ad81" ]
	[ "$(jq -r '.retired.status' <<<"$output")" = "retired-fail-closed" ]
	[ "$(jq -r '.unsalted.computed' <<<"$output")" = "d9d69501" ]
	[ "$(jq -r '.unsalted.status' <<<"$output")" = "rejected" ]
}

@test "the card's HMAC-SHA256 wording does not yield 4b53ab6b (spec discrepancy stays visible)" {
	run "$script" vectors
	[ "$(jq -r '.card_formula_check.yields_canonical_hash' <<<"$output")" = "false" ]
	[ "$(jq -r '.card_formula_check.kusari' <<<"$output")" != "4b53ab6b" ]
}

@test "the oracle agrees with the production shell derivation" {
	SIGNAL_LOOM_EAP_SALT=signalloom-eap-salt-2026-q3 run bash "$root/scripts/eap/tailscale-eap-env.sh" hash kusari
	[ "$status" -eq 0 ]
	[ "$output" = "$("$script" vectors | jq -r '.canonical.computed')" ]
}

@test "classify accepts kusari in every accepted spelling" {
	for v in kusari "  KuSaRi " 4b53ab6b sl-eap-4b53ab6b; do
		run "$script" classify "$v"
		[ "$status" -eq 0 ] || { echo "rejected: $v"; return 1; }
		[ "$output" = "canonical" ]
	done
}

@test "classify fails closed on the retired kurasi vector and the unsalted digest" {
	for v in kurasi KURASI 6f82ad81 sl-eap-6f82ad81 eap-6f82ad81 d9d69501; do
		run "$script" classify "$v"
		[ "$status" -eq 3 ] || { echo "not rejected: $v (status $status)"; return 1; }
	done
}

@test "classify refuses unknown tenants and an empty argument" {
	run "$script" classify acme
	[ "$status" -eq 4 ]
	run "$script" classify ""
	[ "$status" -eq 2 ]
}

@test "scan buckets planted legacy strings by where they live" {
	make_fixture_repo
	run "$script" scan
	[ "$status" -eq 0 ]
	legacy="$(jq -c '.legacy_typo' <<<"$output")"
	[ "$(jq -r '.files' <<<"$legacy")" = "4" ]
	[ "$(jq -r '.by_category.active_code' <<<"$legacy")" = "2" ]
	[ "$(jq -r '.by_category.historical_record' <<<"$legacy")" = "1" ]
	[ "$(jq -r '.by_category.test_fixture' <<<"$legacy")" = "1" ]
	jq -e '.active_files == ["src/route.yaml", "src/router.go"]' <<<"$legacy"
	# historical records are listed by file but their lines are not carried
	jq -e '[.occurrences[].category] | index("historical_record") == null' <<<"$legacy"
}

@test "scan of a clean repo reports zero and still exits 0" {
	make_fixture_repo clean
	run "$script" scan
	[ "$status" -eq 0 ]
	[ "$(jq -r '.legacy_typo.total' <<<"$output")" = "0" ]
	[ "$(jq -r '.unsalted_digest.total' <<<"$output")" = "0" ]
}

@test "bao reports a provisioned pilot salt without printing it" {
	fake_kubectl '{"data":{"data":{"salt":"signalloom-eap-salt-2026-q3"}}}' 0
	run "$script" bao
	[ "$status" -eq 0 ]
	[ "$(jq -r '.status' <<<"$output")" = "provisioned" ]
	[ "$(jq -r '.equals_pilot_salt' <<<"$output")" = "true" ]
	[[ "$output" != *"signalloom-eap-salt-2026-q3"* ]]
}

@test "bao distinguishes a non-pilot salt from the pilot salt" {
	fake_kubectl '{"data":{"data":{"salt":"0123456789abcdef0123456789abcdef"}}}' 0
	run "$script" bao
	[ "$(jq -r '.equals_pilot_salt' <<<"$output")" = "false" ]
	[ "$(jq -r '.salt_length' <<<"$output")" = "32" ]
}

@test "bao reports an unprovisioned path instead of failing silently" {
	fake_kubectl 'No value found at secret/data/signalloom/eap' 2
	run "$script" bao
	[ "$status" -eq 0 ]
	[ "$(jq -r '.status' <<<"$output")" = "unprovisioned" ]
	[ "$(jq -r '.exit_code' <<<"$output")" = "2" ]
}

@test "audit --out writes one report whose verdict reflects the fixture" {
	make_fixture_repo
	run "$script" audit --out "$BATS_TEST_TMPDIR/audit.json"
	[ "$status" -eq 0 ]
	v="$(jq -c '.verdict' "$BATS_TEST_TMPDIR/audit.json")"
	[ "$(jq -r '.canonical_vector_holds' <<<"$v")" = "true" ]
	[ "$(jq -r '.active_legacy_files' <<<"$v")" = "2" ]
	[ "$(jq -r '.salt_provisioned' <<<"$v")" = "false" ]
	[ "$(jq -r '.openbao.status' "$BATS_TEST_TMPDIR/audit.json")" = "skipped" ]
}

@test "the committed audit evidence is well formed and records the canonical vector" {
	evidence="$root/ci-evidence/p3-preflight-audit.json"
	[ -f "$evidence" ]
	[ "$(jq -r '.card' "$evidence")" = "SLDC-P3-PRE" ]
	[ "$(jq -r '.verdict.canonical_vector_holds' "$evidence")" = "true" ]
	[ "$(jq -r '.verdict.unsalted_digest_occurrences' "$evidence")" = "0" ]
}
