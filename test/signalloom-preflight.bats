#!/usr/bin/env bats

setup() {
	tmp_root="$BATS_TEST_TMPDIR/signalloom"
	mkdir -p "$tmp_root"

	platform_root="$tmp_root/platform"
	osramp_root="$tmp_root/osramp"
	demo_root="$tmp_root/osramp-demo"
	d2_bao_root="$tmp_root/d2-bao-apps"

	for root in "$platform_root" "$osramp_root" "$demo_root" "$d2_bao_root"; do
		mkdir -p "$root"
		git -C "$root" init -q
	done
	mkdir -p \
		"$platform_root/services/discovery-portal" \
		"$platform_root/infrastructure/terraform" \
		"$demo_root/d2-osramp-apps" \
		"$demo_root/d2-osramp-fleet" \
		"$demo_root/d2-infra" \
		"$d2_bao_root/d2-bao-infra"
}

@test "valid roots pass the preflight" {
	run "$BATS_TEST_DIRNAME/../scripts/signalloom-preflight.sh" check \
		"$platform_root" "$osramp_root" "$demo_root" "$d2_bao_root"

	[ "$status" -eq 0 ]
	[[ "$output" == *"preflight passed"* ]]
}

@test "an overridden missing root fails precisely" {
	run "$BATS_TEST_DIRNAME/../scripts/signalloom-preflight.sh" check \
		"$platform_root/missing" "$osramp_root" "$demo_root" "$d2_bao_root"

	[ "$status" -ne 0 ]
	[[ "$output" == *"missing git root: SIGNALLOOM_PLATFORM_ROOT="* ]]
}

@test "make help exposes both targets and signalloom help lists four roots" {
	run make help
	[ "$status" -eq 0 ]
	[[ "$output" == *"signalloom-check"* ]]
	[[ "$output" == *"signalloom-help"* ]]

	run make signalloom-help \
		SIGNALLOOM_PLATFORM_ROOT="$platform_root" \
		OSRAMP_PRODUCT_ROOT="$osramp_root" \
		OSRAMP_DEMO_ROOT="$demo_root" \
		D2_BAO_ROOT="$d2_bao_root"
	[ "$status" -eq 0 ]
	[[ "$output" == *"SIGNALLOOM_PLATFORM_ROOT=$platform_root"* ]]
	[[ "$output" == *"OSRAMP_PRODUCT_ROOT=$osramp_root"* ]]
	[[ "$output" == *"OSRAMP_DEMO_ROOT=$demo_root"* ]]
	[[ "$output" == *"D2_BAO_ROOT=$d2_bao_root"* ]]
}
