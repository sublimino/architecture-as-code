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

	# ─── A PRIVATE TF_DATA_DIR, because this root is shared ─────────────────
	#
	# `terraform providers` needs an initialised root, and this suite used to
	# init into the default `terraform/platform/.terraform`. That directory is
	# shared: `make gcp-tf-validate` also runs `terraform test` in this root,
	# which initialises it too. Standalone this suite passed; in the full
	# 26-suite run it failed — `providers` exited non-zero, the graph came back
	# empty, and BOTH tests fell over. The dormancy assertion appeared to fail
	# as if observability had come back, and its own positive control failed as
	# if identity had vanished.
	#
	# That is the worst presentation available: a shared-state collision wearing
	# the costume of the regression the guard exists to catch. Measured
	# 2026-08-21 — 0 failures standalone, 2 in the combined run, deterministic.
	#
	# TF_DATA_DIR is per-invocation, so pointing it at the test's own tmpdir
	# gives this suite a private initialisation that no sibling can disturb.
	# It is the same mechanism the Makefile uses to keep four lanes apart
	# (GCP_TF_DATA_DIR = .terraform-$(ENV)); the lesson had simply not been
	# carried into the test layer.
	# BATS_FILE_TMPDIR, not BATS_TEST_TMPDIR: setup() runs before EVERY test, and
	# a per-test data dir would re-download the providers once per test. One
	# private directory for the whole file is both isolated and paid for once.
	export TF_DATA_DIR="${BATS_FILE_TMPDIR}/tfdata"
}

# Initialise ONCE for the file. -backend=false so this needs no bucket and no
# credentials.
#
# Deliberately not `|| true`, which is what the previous version did: an init
# that failed then left `terraform providers` to fail later, where it read as
# "the module graph is empty" — indistinguishable from the regression these
# tests exist to catch. Failing here names the cause instead.
setup_file() {
	export TF_DATA_DIR="${BATS_FILE_TMPDIR}/tfdata"
	local root
	root="$(cd "$BATS_TEST_DIRNAME/../terraform/platform" && pwd)"
	terraform -chdir="$root" init -backend=false -no-color >/dev/null 2>&1 || {
		echo "terraform init failed in ${root}; every assertion in this file would" >&2
		echo "measure an uninitialised root rather than the module graph" >&2
		return 1
	}
}

# The gate: the module manifest terraform writes at init.
#
# `terraform init -backend=false` resolves every instantiated module and records
# it in ${TF_DATA_DIR}/modules/modules.json. A module that is genuinely
# instantiated appears there; one that is commented out does not. Reading the
# file is deterministic in a way the command output is not.
#
# ─── Two obvious choices that are both wrong, and why ──────────────────────
#
# `terraform providers` requires BACKEND initialisation, and this suite inits
# with -backend=false, so it exits 1 with "Backend initialization required". It
# appeared to work only because a developer checkout's shared
# terraform/platform/.terraform already carried a real backend init from other
# work — green standalone there, red with a private TF_DATA_DIR, on a clean
# machine, or in CI.
#
# Parsing init's STDOUT is wrong for a subtler reason: terraform prints
# "Initializing modules..." only on a COLD data dir. The second call in the same
# file prints nothing, so the positive control failed while the dormancy check
# passed — the exact asymmetry that would let this suite go green while
# measuring nothing.
#
# Both failure modes yield an EMPTY graph, and an empty graph is
# indistinguishable from the regression these tests exist to catch. I diagnosed
# this three times by reasoning — shared-state contention, setup ordering, then
# a warm-vs-cold init — and was wrong each time before reading the actual
# stderr and then the actual file. Recorded because every wrong answer was
# plausible and the right one took one command.
graph() {
	jq -r '.Modules[]? | "\(.Key) \(.Source)"' "${TF_DATA_DIR}/modules/modules.json" 2>/dev/null
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
	# identity and operator_identity are uncommented in this root today, and the
	# manifest renders one "<key> <source>" line per instantiated module.
	grep -qx "identity ../modules/identity" <<<"$output"
	grep -qx "operator_identity ../modules/operator-identity" <<<"$output"
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
