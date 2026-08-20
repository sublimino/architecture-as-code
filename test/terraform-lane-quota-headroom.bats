#!/usr/bin/env bats
#
# The estate has NO CPU headroom, and that is now a design property.
#
# ─── Why this suite exists ──────────────────────────────────────────────────
#
# Four lanes at n2-standard-8 is exactly 32 vCPU against a CPUS_ALL_REGIONS
# quota of 32. Measured 2026-08-20: a cold `demo-2` apply failed with
#
#     Error: Quota 'CPUS_ALL_REGIONS' exceeded. Limit: 32.0 globally.
#
# at 32/32 with the lanes then sized 16+8+8. Note the regional N2_CPUS quota in
# us-east4 is 200 with usage 32 — the regional headroom is enormous and
# irrelevant. It is the GLOBAL all-regions cap that binds, which is why this
# reads as a capacity problem in a region that plainly has capacity.
#
# Sized at exactly the cap, any operation that briefly runs N+1 instances
# fails. Today none does, and the reason is worth stating because it is an
# ABSENCE rather than a decision:
#
#   * `machine_type` is not ForceNew in the Google provider and
#     `allow_stopping_for_update = true`, so a resize stops and starts the SAME
#     instance. No second instance exists at any point.
#   * `boot_disk.initialize_params` IS ForceNew, so changing `boot_disk_gb`
#     replaces the instance — but Terraform's DEFAULT is destroy-then-create.
#     The estate goes N-1, then N. It never goes N+1.
#
# That second one holds only while no `create_before_destroy` exists. Adding it
# is an ordinary, well-intentioned change — it is the standard way to cut
# replacement downtime, and on any estate with headroom it is strictly better.
# Here it would make every disk-triggered replacement fail at the quota, and it
# would fail with the same `CPUS_ALL_REGIONS exceeded` message, which reads as
# "we need more quota" rather than "we asked for one more VM than we can hold".
#
# So the absence is load-bearing and undefended, which is what this suite fixes.
# It is not a style rule. Delete it the day the quota is raised, and say so in
# the deletion.

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	COMPUTE_MAIN="${REPO_ROOT}/terraform/modules/compute/main.tf"

	# Presence before behaviour. A suite asserting "the string does not appear"
	# passes perfectly against a file that is missing, empty, or renamed — the
	# absence of bad is trivially satisfied by the absence of everything.
	[ -f "${COMPUTE_MAIN}" ] || {
		echo "terraform/modules/compute/main.tf is missing — every assertion below would be vacuous"
		return 1
	}
	grep -q 'resource "google_compute_instance"' "${COMPUTE_MAIN}" || {
		echo "no google_compute_instance in ${COMPUTE_MAIN} — this suite is measuring nothing"
		return 1
	}
}

@test "QUOTA no create_before_destroy on any lane resource" {
	# Scoped to the whole terraform tree rather than one file: the constraint is
	# about the estate's instance count, and a lifecycle block added to the
	# environments root or a wrapper module would breach it just as effectively.
	local hits
	hits="$(grep -rn 'create_before_destroy' "${REPO_ROOT}/terraform" --include='*.tf' 2>/dev/null | grep -v '/\.terraform' || true)"
	[ -z "${hits}" ] || {
		echo "create_before_destroy is present, which makes a replacement run N+1 instances:"
		echo "${hits}"
		echo
		echo "The estate is sized at exactly its CPUS_ALL_REGIONS quota (32/32), so the"
		echo "extra instance cannot be created and the apply fails mid-replacement,"
		echo "leaving a half-built lane. If the quota has since been raised, delete this"
		echo "test in the same commit and say so."
		return 1
	}
}

@test "QUOTA machine_type changes in place rather than by replacement" {
	# The property that makes a RESIZE safe at 32/32. If allow_stopping_for_update
	# were dropped, a resize would either fail outright or become a replacement,
	# and a replacement is the case the test above is about.
	grep -q 'allow_stopping_for_update = true' "${COMPUTE_MAIN}" || {
		echo "allow_stopping_for_update is not set, so a machine_type change cannot"
		echo "apply in place. At 32/32 the estate cannot afford the alternative."
		return 1
	}
}

@test "QUOTA MUTATION create_before_destroy is actually detected" {
	# The assertion above is a NEGATIVE — "this string does not appear" — which
	# is the shape that passes hardest when the thing it guards has been deleted
	# or renamed. So the detector is exercised against a tree that really does
	# contain the string, in a scratch copy rather than the real one.
	local scratch="${BATS_TEST_TMPDIR}/terraform"
	mkdir -p "${scratch}/modules/compute"
	cat >"${scratch}/modules/compute/main.tf" <<'TF'
resource "google_compute_instance" "this" {
  lifecycle {
    create_before_destroy = true
  }
}
TF

	local hits
	hits="$(grep -rn 'create_before_destroy' "${scratch}" --include='*.tf' 2>/dev/null | grep -v '/\.terraform' || true)"
	[ -n "${hits}" ] || {
		echo "the detector found nothing in a tree that certainly contains it —"
		echo "the real assertion above is therefore not measuring anything"
		return 1
	}
}
