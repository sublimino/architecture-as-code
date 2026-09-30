#!/usr/bin/env bats
#
# SLDC-P3-1: CLI contract of scripts/derive_tenant_hash.py. The canonical
# kusari vector is 4b53ab6b; the retired kurasi typo and a missing salt fail
# closed with exit 1; usage errors exit 2. Hermetic: no OpenBao, no cluster.
#
# @id     tenant-hash-vectors-bats
# @target scripts/derive_tenant_hash.py
# @doc    docs/eap/SLDC-P3-TENANT-INVENTORY.md
# @task   SLDC-P3-1

setup() {
	root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	script="$root/scripts/derive_tenant_hash.py"
	unset BAO_ADDR VAULT_ADDR OPENBAO_ADDR BAO_TOKEN VAULT_TOKEN
	export SIGNAL_LOOM_EAP_SALT="signalloom-eap-salt-2026-q3"
}

@test "kusari derives the canonical 4b53ab6b" {
	run python3 "$script" kusari
	[ "$status" -eq 0 ]
	[ "$output" = "Tenant: kusari -> Hash: 4b53ab6b" ]
}

@test "--quiet prints exactly the 8-char hash" {
	run python3 "$script" --quiet kusari
	[ "$status" -eq 0 ]
	[ "$output" = "4b53ab6b" ]
}

@test "matches the shell implementation in tailscale-eap-env.sh" {
	for t in kusari acme tenant-01; do
		py="$(python3 "$script" --quiet "$t")"
		sh="$(bash "$root/scripts/eap/tailscale-eap-env.sh" hash "$t")"
		[ "$py" = "$sh" ]
	done
}

@test "custom tenant equals sha256(salt:tenant)[:8]" {
	want="$(printf '%s' "$SIGNAL_LOOM_EAP_SALT:acme" | sha256sum | cut -c1-8)"
	run python3 "$script" --quiet acme
	[ "$status" -eq 0 ]
	[ "$output" = "$want" ]
}

@test "case and whitespace normalise to the canonical vector" {
	run python3 "$script" --quiet "  KUSARI "
	[ "$status" -eq 0 ]
	[ "$output" = "4b53ab6b" ]
}

@test "kurasi fails closed with exit 1 and names the retired typo" {
	run python3 "$script" kurasi
	[ "$status" -eq 1 ]
	[[ "$output" == *"kurasi"*"retired legacy typo"* ]]
	[[ "$output" != *"6f82ad81"* ]]
}

@test "uppercase KURASI is also rejected" {
	run python3 "$script" KURASI
	[ "$status" -eq 1 ]
}

@test "empty tenant is rejected" {
	run python3 "$script" "   "
	[ "$status" -eq 1 ]
	[[ "$output" == *"cannot be empty"* ]]
}

@test "missing salt fails closed with exit 1" {
	unset SIGNAL_LOOM_EAP_SALT
	run python3 "$script" kusari
	[ "$status" -eq 1 ]
	[[ "$output" == *"salt unavailable"* ]]
	[[ "$output" != *"4b53ab6b"* ]]
}

@test "unreachable OpenBao with a bogus token falls back to the env salt" {
	export BAO_ADDR="http://127.0.0.1:9" BAO_TOKEN="invalid"
	run python3 "$script" --quiet kusari
	[ "$status" -eq 0 ]
	[ "${lines[-1]}" = "4b53ab6b" ]
}

@test "no arguments runs the known-answer self-test" {
	unset SIGNAL_LOOM_EAP_SALT
	run python3 "$script"
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok: kusari -> 4b53ab6b"* ]]
	[[ "$output" == *"ok: kurasi fails closed"* ]]
}

@test "extra arguments are a usage error (exit 2)" {
	run python3 "$script" kusari extra
	[ "$status" -eq 2 ]
}
