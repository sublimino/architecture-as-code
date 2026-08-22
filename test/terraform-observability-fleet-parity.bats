#!/usr/bin/env bats
#
# The two halves of "observability is not installed" must agree.
#
# ─── The invariant ──────────────────────────────────────────────────────────
#
# No Kustomization may reference a source that the current ENABLE_OBSERVABILITY
# setting never pushes. Concretely: the tenants declared in the `infra`
# ResourceSet, which is what materialises the namespace + OCIRepository +
# infra-controllers/infra-configs Kustomizations, must be exactly the set of
# `infra/<tenant>` artifacts push-local.sh publishes on the same run.
#
# Nothing checked that before 2026-08-22, which is precisely why the estate
# shipped broken. push_foundation() filtered the fleet correctly, but three
# other call paths — scripts/ci/vm-pipeline.sh:283, and `$(MAKE)
# push-local-fleet` inside both demo-agent-trust-up and demo-signalloom-up —
# reached push_fleet(), whose default argument was the raw unfiltered tree.
# Every bring-up therefore published a correct two-tenant fleet at bootstrap and
# overwrote it with a four-tenant one an hour later.
#
# Measured on sl-demo-1-vm before the fix:
#
#   cert-manager/infra-controllers   12h   True    Applied
#   ingress/infra-controllers        12h   True    Applied
#   monitoring/infra-controllers      9h   False   Source artifact not found
#   trivy-system/infra-controllers    9h   False   Source artifact not found
#
#   OCIRepository monitoring/infra -> NAME_UNKNOWN: repository name not known
#                                     to registry (acme/infra/monitoring)
#
# Those four Kustomizations retry forever, the estate never converges, and three
# of four lanes ABORT at stage [5/8] on `context deadline exceeded`.
#
# ─── Why this suite needs no cluster ────────────────────────────────────────
#
# scripts/lib/fleet-source.sh takes its source dir, destination dir and the
# observability setting as arguments rather than reading globals and calling
# mktemp internally. That injectable boundary is deliberate: the whole filter is
# exercisable against a fixture tree with no registry, no signing key and no
# Kubernetes. Same motivation as the private TF_DATA_DIR in
# test/terraform-observability-dormant.bats — isolation is what makes a guard
# trustworthy in a 26-suite run, not just standalone.
#
# That sibling suite asserts the GCP-level observability module is dormant and
# that ENABLE_OBSERVABILITY defaults to false. This one asserts the in-cluster
# consequence of that default is actually delivered. No overlap.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	lib="$repo/scripts/lib/fleet-source.sh"
	fleet="$repo/d2-osramp-fleet"
	push="$repo/scripts/push-local.sh"
	# shellcheck source=../scripts/lib/fleet-source.sh
	source "$lib"
}

# Tenants the ResourceSet declares in a given fleet tree, sorted.
tenants_of() {
	fleet_infra_tenants "$1/tenants/base/infra.yaml" | sort
}

@test "FLEETOBS the unfiltered fleet declares all four tenants" {
	# The baseline every other assertion is measured against. If this drifts,
	# the fixtures below are testing something other than what ships.
	run tenants_of "$fleet"
	[ "$status" -eq 0 ]
	[ "$output" = "cert-manager
ingress
monitoring
trivy-system" ]
}

@test "FLEETOBS observability=false strips monitoring and trivy-system" {
	run fleet_source_dir "$fleet" "$BATS_TEST_TMPDIR/off" false
	[ "$status" -eq 0 ]
	[ "$output" = "$BATS_TEST_TMPDIR/off" ]

	run tenants_of "$BATS_TEST_TMPDIR/off"
	[ "$status" -eq 0 ]
	[ "$output" = "cert-manager
ingress" ]
}

@test "FLEETOBS observability=true publishes the tree untouched" {
	# The positive control for the filter itself: proof the two tenants are
	# removed BECAUSE the flag is false, not because the helper always removes
	# them or always returns an empty list.
	run fleet_source_dir "$fleet" "$BATS_TEST_TMPDIR/on" true
	[ "$status" -eq 0 ]
	[ "$output" = "$fleet" ]

	run tenants_of "$fleet"
	[ "$output" = "cert-manager
ingress
monitoring
trivy-system" ]
}

@test "FLEETOBS an invalid observability value is refused, not defaulted" {
	run fleet_source_dir "$fleet" "$BATS_TEST_TMPDIR/bad" yes
	[ "$status" -eq 64 ]
	[[ "$output" == *"must be true or false"* ]]
}

# ─── The regression guard proper ────────────────────────────────────────────

@test "FLEETOBS every fleet publisher resolves its path through the filter" {
	# THE test. The defect was not a broken filter — it was a filter one of four
	# callers skipped. push_fleet must not be able to publish a directory it was
	# handed by nobody, so its no-argument path has to resolve through
	# resolve_fleet_path rather than falling back to a bare literal.
	#
	# The pre-fix body was:
	#     push_fleet() { push_and_sign "fleet" "${1:-d2-osramp-fleet}"; }
	# which is exactly the shape this refuses.
	run bash -c "sed -n '/^push_fleet()/,/^}/p' '$push'"
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	# It must consult the resolver...
	[[ "$output" == *"resolve_fleet_path"* ]]
	# ...and must never name the raw tree as a fallback value.
	! grep -q 'd2-osramp-fleet' <<<"$output"
}

@test "FLEETOBS no push path names the raw fleet tree as a default argument" {
	# The generalisation: any `${1:-d2-osramp-fleet}` anywhere in the script is
	# the same latent bug wearing a different function name.
	run grep -n '\${1:-d2-osramp-fleet}' "$push"
	[ "$status" -ne 0 ]
}

@test "FLEETOBS MUTATION the publisher guard can see an unfiltered fallback" {
	# Positive control for the two tests above: without this, a sed that matched
	# nothing would make both green forever. Reintroduce the historical defect in
	# a copy and prove the assertion fires.
	cp "$push" "$BATS_TEST_TMPDIR/push.sh"
	python3 - "$BATS_TEST_TMPDIR/push.sh" <<-'PY'
		import re, sys
		p = sys.argv[1]
		s = open(p).read()
		new = 'push_fleet() {\n  push_and_sign "fleet" "${1:-d2-osramp-fleet}"\n}\n'
		s2 = re.sub(r'^push_fleet\(\) \{.*?^\}\n', new, s, count=1, flags=re.S | re.M)
		assert s2 != s, "mutation did not apply; this test would prove nothing"
		open(p, 'w').write(s2)
	PY
	# The mutated copy must now trip BOTH assertions.
	run bash -c "sed -n '/^push_fleet()/,/^}/p' '$BATS_TEST_TMPDIR/push.sh' | grep -c 'd2-osramp-fleet'"
	[ "$output" = "1" ]
	run grep -c '\${1:-d2-osramp-fleet}' "$BATS_TEST_TMPDIR/push.sh"
	[ "$output" = "1" ]
}

# ─── The push/reconcile parity invariant ────────────────────────────────────

@test "FLEETOBS every declared tenant has a component dir to be pushed from" {
	# The invariant stated directly: a tenant the ResourceSet declares must have
	# an d2-infra/components/<tenant> source, or its OCIRepository can never be
	# satisfied and its two Kustomizations retry until the lane times out.
	local t
	for t in $(tenants_of "$fleet"); do
		[ -d "$repo/d2-infra/components/$t" ] \
			|| { echo "tenant '$t' has no d2-infra/components/$t"; false; }
	done
}

@test "FLEETOBS the filtered fleet's tenants are exactly what foundation pushes" {
	# push_foundation derives its artifact list from fleet_infra_tenants(), so
	# the two sides are the same list by construction. This asserts the derivation
	# is actually wired up — that the script reads the tenants rather than
	# carrying a second hardcoded copy that can drift.
	run grep -c 'fleet_infra_tenants' "$push"
	[ "$status" -eq 0 ]
	[ "$output" -ge 1 ]
	# And the hardcoded conditional artifact list is gone.
	run grep -n 'infra/monitoring|d2-infra/components/monitoring' "$push"
	[ "$status" -ne 0 ]
}

@test "FLEETOBS MUTATION the filter refuses a fleet it cannot edit" {
	# A range-delete sed that matches nothing deletes nothing and exits 0. This
	# repo has shipped that defect before, so the filter brackets each removal:
	# absent-before is as loud as present-after. Drift the indentation — the most
	# likely real-world cause — and prove the helper REFUSES rather than
	# publishing an unfiltered fleet with a success exit code.
	cp -a "$fleet" "$BATS_TEST_TMPDIR/drifted"
	sed -i 's/^    - tenant: "monitoring"$/      - tenant: "monitoring"/' \
		"$BATS_TEST_TMPDIR/drifted/tenants/base/infra.yaml"
	# The mutation must have actually landed, or this proves nothing.
	grep -q '^      - tenant: "monitoring"$' \
		"$BATS_TEST_TMPDIR/drifted/tenants/base/infra.yaml"

	run fleet_source_dir "$BATS_TEST_TMPDIR/drifted" "$BATS_TEST_TMPDIR/out" false
	[ "$status" -ne 0 ]
	[[ "$output" == *"monitoring"* ]]
	[[ "$output" == *"FATAL"* ]]
}

@test "FLEETOBS MUTATION the filter refuses a fleet with the tenant already gone" {
	# The other edge of the bracket, and the one only the absent-BEFORE check can
	# catch. The drifted-indentation case above is caught by the present-AFTER
	# check, so without this test the before-check is dead weight — removing it
	# entirely leaves the suite green, which the M3 mutation demonstrated.
	#
	# "Already removed" is not a benign no-op. It means someone edited the
	# manifests to drop the tenants instead of using the ENABLE_OBSERVABILITY
	# toggle, so `true` would no longer install them and this filter is no longer
	# describing what it publishes. Both halves have to fail loudly.
	cp -a "$fleet" "$BATS_TEST_TMPDIR/pregone"
	sed -i '/^    - tenant: "monitoring"$/,/^      artifactSubjectGitRef: /d' \
		"$BATS_TEST_TMPDIR/pregone/tenants/base/infra.yaml"
	# The mutation must have actually landed, or this proves nothing.
	! grep -q 'tenant: "monitoring"' \
		"$BATS_TEST_TMPDIR/pregone/tenants/base/infra.yaml"

	run fleet_source_dir "$BATS_TEST_TMPDIR/pregone" "$BATS_TEST_TMPDIR/pgout" false
	[ "$status" -ne 0 ]
	[[ "$output" == *"is not declared"* ]]
	[[ "$output" == *"Nothing was removed"* ]]
}

@test "FLEETOBS MUTATION the filter refuses a tenant that reappears elsewhere" {
	# The entries can be gone from spec.inputs while the tenant is still reachable
	# some other way — an overlay, a second ResourceSet, a dependsOn. That is
	# still a route back into the cluster and the range-delete would not touch it.
	cp -a "$fleet" "$BATS_TEST_TMPDIR/stray"
	printf '\n# tenant: "trivy-system"\n' \
		>>"$BATS_TEST_TMPDIR/stray/tenants/local/kustomization.yaml"

	run fleet_source_dir "$BATS_TEST_TMPDIR/stray" "$BATS_TEST_TMPDIR/strayout" false
	[ "$status" -ne 0 ]
	[[ "$output" == *"still referenced after filtering"* ]]
}

@test "FLEETOBS the observability tenant list is the single source of truth" {
	# Both halves read OBSERVABILITY_TENANTS. If someone adds a third
	# observability tenant, adding it here is the only edit required — and
	# forgetting to add its component dir trips the parity test above.
	[ "${#OBSERVABILITY_TENANTS[@]}" -eq 2 ]
	[[ " ${OBSERVABILITY_TENANTS[*]} " == *" monitoring "* ]]
	[[ " ${OBSERVABILITY_TENANTS[*]} " == *" trivy-system "* ]]
}
