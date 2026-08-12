#!/usr/bin/env bats
# The KubeSec-AFM slice backs Signal Loom's RBAC Explorer: rbac_correlation.py
# reads /api/rbac/* from afm-platform.fe-k8s-afm. The slice was complete in the
# repo but deployed by nothing in the Signal Loom bring-up path, so the page
# failed with a DNS error against a Service that had never existed.
#
# These cover the two halves of that gap without needing a cluster: the deploy
# script says which external checkout is missing, and the Signal Loom lifecycle
# actually invokes the deploy.

repo_root="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
	afm_source="$BATS_TEST_TMPDIR/kubesec-afm"
	mkdir -p "$afm_source/AFM/docker"
	touch "$afm_source/AFM/docker/backend.Dockerfile"

	missing_source="$BATS_TEST_TMPDIR/absent"
}

@test "preflight passes when the AFM source checkout is present" {
	run env KUBESEC_AFM_ROOT="$afm_source" "$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 0 ]
	[[ "$output" == *"$afm_source"* ]]
}

@test "preflight names the missing checkout and the variable that relocates it" {
	run env KUBESEC_AFM_ROOT="$missing_source" "$repo_root/scripts/k8s-afm.sh" preflight

	[ "$status" -eq 1 ]
	[[ "$output" == *"$missing_source"* ]]
	[[ "$output" == *"KUBESEC_AFM_ROOT"* ]]
	# The consequence, so the failure is traceable back to the broken page.
	[[ "$output" == *"RBAC Explorer"* ]]
}

@test "up refuses before spending anything on a docker build" {
	run env KUBESEC_AFM_ROOT="$missing_source" "$repo_root/scripts/k8s-afm.sh" up

	[ "$status" -eq 1 ]
	[[ "$output" == *"source repo not found"* ]]
	# Guard is a preflight, not a post-mortem: the build never started.
	[[ "$output" != *"Building kubesec-afm image"* ]]
}

@test "the Signal Loom lifecycle deploys the AFM slice its RBAC page reads from" {
	# Recipe body of demo-signalloom-up, up to the next target definition.
	run awk '/^demo-signalloom-up:/{f=1;next} f&&/^[a-zA-Z0-9_.-]+:/{exit} f' "$repo_root/Makefile"

	[ "$status" -eq 0 ]
	[[ "$output" == *"demo-signalloom-afm-up"* ]]
}

@test "the AFM deploy step warns rather than failing the whole bring-up" {
	run awk '/^demo-signalloom-afm-up:/{f=1;next} f&&/^[a-zA-Z0-9_.-]+:/{exit} f' "$repo_root/Makefile"

	[ "$status" -eq 0 ]
	# An absent external checkout must not take down a Signal Loom bring-up
	# that is otherwise fine -- but it must say what will be broken.
	[[ "$output" == *"preflight"* ]]
	[[ "$output" == *"WARNING"* ]]
	[[ "$output" == *"not deployed"* ]]
}
