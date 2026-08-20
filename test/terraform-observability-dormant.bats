#!/usr/bin/env bats
#
# Observability is deliberately not installed — prove it, and prove the proof works.
#
# ─── Why this is a bats suite and not a tftest ──────────────────────────────
#
# `terraform test` observes a PLAN, and a plan cannot show the absence of a
# module: with `module "observability"` commented out there is no address to
# reference, so a condition written there either fails to evaluate or is a
# tautology that passes whether or not the module is live. That is not a
# hypothetical — the run this replaced referenced `output.log_bucket_name` and
# broke the whole suite the moment the output went dormant.
#
# terraform/environments/tests/edge_dormant.tftest.hcl CAN assert dormancy, but
# only because modules/network publishes `health_check_firewall_names` for it to
# count. Nothing analogous survives once a module is uninstantiated.
#
# The resolved module graph is observable, so that is what these tests read.
#
# ─── What is being defended ─────────────────────────────────────────────────
#
# Before 2026-08-20 the ONLY thing preventing this root from creating a log
# sink, an audit bucket, a data-access audit config, uptime checks, two
# alert-policy families and a billing budget was that `TF_ROOT_PLATFORM` is
# declared in the Makefile and used by zero recipes. That is an accident of
# plumbing, not a control: one hand-run `terraform -chdir=terraform/platform
# apply` would have created the lot, and nothing would have refused it.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	root="$repo/terraform/platform"
	# -backend=false so this needs no bucket and no credentials.
	terraform -chdir="$root" init -backend=false -no-color >/dev/null 2>&1 || true
}

# The gate. `terraform providers` renders the RESOLVED module tree, so a module
# that is genuinely instantiated appears and one that is commented out does not.
graph() {
	terraform -chdir="$root" providers 2>/dev/null
}

@test "OBS the platform root instantiates no observability module" {
	run graph
	[ "$status" -eq 0 ]
	! grep -qi 'observability' <<<"$output"
}

# THE POSITIVE CONTROL, and the reason the test above is worth anything.
#
# "grep found nothing" is equally consistent with "the module is absent" and
# with "graph() returned nothing at all, or names modules in a form this grep
# cannot match". Without this, a broken graph() would make the suite green
# forever — the exact shape this repo keeps rediscovering.
@test "OBS MUTATION the graph check can see a module that IS live" {
	run graph
	[ "$status" -eq 0 ]
	# identity and operator_identity are uncommented in this root today.
	grep -q 'module\.identity' <<<"$output"
	grep -q 'module\.operator_identity' <<<"$output"
}

# Absence in the graph is the property that matters, but it is downstream of the
# source. If someone uncomments the module block, the graph check above catches
# it — this asserts the source state directly so a failure names the cause
# rather than the symptom.
@test "OBS the module block is commented in source" {
	run grep -c '^# module "observability"' "$root/main.tf"
	[ "$status" -eq 0 ]
	[ "$output" = "1" ]
}

@test "OBS MUTATION uncommenting the module block is detectable" {
	tmp="$BATS_TEST_TMPDIR/main.tf"
	sed 's/^# module "observability" {/module "observability" {/' "$root/main.tf" >"$tmp"
	# The mutation must actually change something, or this test proves nothing.
	! cmp -s "$tmp" "$root/main.tf"
	run grep -c '^# module "observability"' "$tmp"
	[ "$output" = "0" ]
}

# In-cluster observability is a separate mechanism from the GCP-level one and
# was already off. Asserted here so both halves of "no observability" live in
# one place — someone flipping this default should meet a test, not a surprise.
@test "OBS in-cluster observability is off by default" {
	run grep -E '^ENABLE_OBSERVABILITY \?= ' "$repo/Makefile"
	[ "$status" -eq 0 ]
	[[ "$output" == *"false"* ]]
}
