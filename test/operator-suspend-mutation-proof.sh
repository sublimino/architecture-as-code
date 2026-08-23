#!/usr/bin/env bash
#
# operator-suspend-mutation-proof.sh — prove the operator-identity permission
# guards can fail, by breaking the REAL module.
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# CONTRACT §7b. A fixture mutation asks "does my scanner detect this string in a
# file I just wrote it into?" It cannot ask "does the thing I am guarding
# actually exist in the shipped code?" This repo produced several assertions
# that passed against broken code while their fixture mutations passed too.
#
# The operator identity is the sharpest case available. Its whole value is that
# it holds four roles instead of compute.admin, and the newest of those four is
# a CUSTOM role — the one place where a permission can be added without moving
# any role count a reviewer is likely to check. So every guard over that
# permission list is broken here, against the real file, and the named test that
# must go red is stated up front.
#
# ─── Restoration, and the failure mode it protects against ──────────────────
#
# Restore is from a byte-for-byte backup in mktemp -d OUTSIDE the repository,
# never `git checkout` — a checkout of a directory silently reverts uncommitted
# work elsewhere in the same tree, and the resulting "the guard did not fire"
# reads exactly like a real finding.
#
# The EXIT trap runs on a normal exit and on SIGTERM. It does NOT run on
# SIGKILL, which is what a tool timeout escalates to. A hard kill therefore
# leaves the real module mutated in the checkout, and the next run reads a
# deliberately-broken file as a genuine regression. A functional line replaced
# by a no-op is the signature of a leaked mutation, not of a bad merge.
#
# So a sentinel is written before the first mutation and removed after the last
# restore. If a later run finds it, that run REFUSES TO START and says what to
# do. It deliberately does NOT auto-restore: silently repairing the tree would
# hide that a destructive run was interrupted, which is the same
# mitigation-masks-the-alarm defect this repo has spent a night removing.
#
# Offline. No network, no credentials, no cloud.
#
# Run: test/operator-suspend-mutation-proof.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MAIN="terraform/modules/operator-identity/main.tf"
TFTEST="terraform/modules/operator-identity/tests/operator_identity.tftest.hcl"
BATS_SUITE="test/terraform-operator-access.bats"
MODULE_DIR="terraform/modules/operator-identity"

# ── The shared safety rail ──────────────────────────────────────────────────
#
# This harness already had a correct, uniquely-named sentinel; it is now the
# shared rail so all eight proofs behave identically instead of three of them
# doing so. The name is unchanged. What the rail adds here:
#
#   * The old trap did `rm -f "$SENTINEL"` unconditionally, so a FAILED restore
#     removed the very marker that a failed restore exists to leave behind.
#     The rail clears it only after verification passes.
#   * Restore is verified on MODE as well as content. `cp` onto an existing
#     file keeps the destination's mode.
#   * A live pid now reads as "a run is in progress" rather than as a leak.
#   * The refusal prints a `git show <commit>:<path> | diff` that actually runs
#     from any directory, instead of a `git checkout` hedged with a warning.
# shellcheck source=helpers/mutation-sentinel.bash
source "${REPO_ROOT}/test/helpers/mutation-sentinel.bash"

ms_guard_init operator-suspend "$MAIN" "$TFTEST"
ms_guard_arm "operator-identity permission guards"
trap ms_guard_on_exit EXIT

restore_all() { ms_guard_restore; }

PASS=0
FAIL=0

# A sed that cannot silently do nothing — and that separates a sed SYNTAX ERROR
# from a pattern that no longer matches. This version conflated the two into one
# ABORT, and an unescaped `|` inside s|…|…| reads exactly like a dead guard.
mutate() { ms_sed "$1" "$2"; }

# Names of failing bats tests, not `not ok <n>` numbers. Inserting a test in the
# middle renumbers everything below it, which silently repoints every
# expectation — a harness reporting NOT PROVEN for a guard that fired perfectly
# well is worse than no harness, because the natural response is to go and "fix"
# working code.
failing_bats() {
	bats "$BATS_SUITE" 2>&1 | sed -n 's/^not ok [0-9]* //p' || true
}

# Names of failing terraform test run blocks.
failing_tftest() {
	terraform -chdir="$MODULE_DIR" test -no-color 2>&1 |
		sed -n 's/^ *run "\([^"]*\)"\.\.\. fail.*/\1/p' || true
}

check() {
	local label="$1" want="$2" got="$3"
	if grep -qxF "$want" <<<"$got"; then
		printf '  RED as expected — "%s"  [%s]\n' "$want" "$label"
		PASS=$((PASS + 1))
	else
		printf '  *** NOT PROVEN: expected "%s" to fail. Failures were:\n' "$want" >&2
		printf '%s\n' "${got:-<none — the suite was GREEN with the mutation applied>}" >&2
		FAIL=$((FAIL + 1))
	fi
}

echo "=== operator-identity permission guards: mutating the REAL module ==="
echo

# ---------------------------------------------------------------------------
# 1. Add a forbidden permission to the custom role.
#
# The headline case. compute.instances.delete lets the operator destroy the
# estate it was only supposed to park. The ROLE count does not move — still one
# custom role, still three project roles, still four in total — so this is
# exactly the widening a role budget alone cannot see.
# ---------------------------------------------------------------------------
echo "[1] custom role gains compute.instances.delete"
mutate "$MAIN" 's|^    "compute.zoneOperations.get",$|    "compute.zoneOperations.get",\n    "compute.instances.delete",|'
out="$(failing_tftest)"
check "extra permission" "lifecycle_permission_budget_is_exactly_four" "$out"
check "extra permission" "lifecycle_permissions_are_exactly_the_justified_set" "$out"
check "extra permission" "the_lifecycle_role_grants_no_estate_mutating_verb" "$out"
out="$(failing_bats)"
check "extra permission" "TFOP the lifecycle custom role grants no estate-mutating permission" "$out"
check "extra permission" "TFOP the operator module declares the instance-lifecycle custom role" "$out"
restore_all

# ---------------------------------------------------------------------------
# 2. Delete a justified permission.
#
# The opposite direction, and the one an "adding a role must fail" budget is
# blind to by construction. Without compute.instances.start the lane lifecycle
# breaks on TERMINATED — the state Compute Engine itself produces after 60 days
# suspended — and nothing about the estate looks wrong until a parked lane will
# not come back.
# ---------------------------------------------------------------------------
echo
echo "[2] compute.instances.start is dropped"
mutate "$MAIN" '/^    "compute.instances.start",$/d'
out="$(failing_tftest)"
check "missing permission" "lifecycle_permission_budget_is_exactly_four" "$out"
check "missing permission" "lifecycle_permissions_are_exactly_the_justified_set" "$out"
out="$(failing_bats)"
check "missing permission" "TFOP the operator module declares the instance-lifecycle custom role" "$out"
restore_all

# ---------------------------------------------------------------------------
# 3. Replace the whole permission list with a comment.
#
# CONTRACT §7b shape 1: prose satisfying the assertion. main.tf names every one
# of these permissions in its justification comments, so a substring search
# would stay green with the list gone and only the explanation left behind. The
# guards match complete list-element lines precisely so this cannot happen; this
# is the check that proves it.
# ---------------------------------------------------------------------------
echo
echo "[3] permission list emptied, justification comments left in place"
mutate "$MAIN" 's|^    "compute.instances.suspend",$|    # "compute.instances.suspend",|'
mutate "$MAIN" 's|^    "compute.instances.resume",$|    # "compute.instances.resume",|'
mutate "$MAIN" 's|^    "compute.instances.start",$|    # "compute.instances.start",|'
mutate "$MAIN" 's|^    "compute.zoneOperations.get",$|    # "compute.zoneOperations.get",|'
out="$(failing_bats)"
check "prose only" "TFOP the operator module declares the instance-lifecycle custom role" "$out"
restore_all

# ---------------------------------------------------------------------------
# 4. Swap the custom role for roles/compute.instanceAdmin.v1.
#
# The shortcut this module exists to refuse: 529 permissions to deliver
# compute.instances.suspend. Note the shape — it is SMALLER in the diff than
# what it replaces, one line in a role list with no permission block to review.
# ---------------------------------------------------------------------------
echo
echo "[4] custom role swapped for the predefined roles/compute.instanceAdmin.v1"
mutate "$MAIN" 's|^    local.operator_lifecycle_role_name,$|    "roles/compute.instanceAdmin.v1",|'
out="$(failing_bats)"
check "predefined shortcut" "TFOP the operator module grants no predefined instance-admin role" "$out"
out="$(failing_tftest)"
check "predefined shortcut" "roles_are_exactly_the_justified_set" "$out"
check "predefined shortcut" "no_admin_or_owner_shaped_role_slips_in_under_another_name" "$out"
restore_all

# ---------------------------------------------------------------------------
# 5. Add a fourth project role.
#
# The property the budget test existed for before this change, re-proved after
# it. Updating a count from two to three must not have turned the assertion into
# decoration.
# ---------------------------------------------------------------------------
echo
echo "[5] a fourth project role is added"
mutate "$MAIN" 's|^    local.operator_lifecycle_role_name,$|    local.operator_lifecycle_role_name,\n    "roles/monitoring.viewer",|'
out="$(failing_tftest)"
check "fourth role" "project_role_budget_is_exactly_three" "$out"
check "fourth role" "total_role_budget_at_any_scope_is_exactly_four" "$out"
check "fourth role" "roles_are_exactly_the_justified_set" "$out"
restore_all

# ---------------------------------------------------------------------------
# 6. Drop the count assertion itself.
#
# A guard can be deleted as easily as the thing it guards. If removing the exact
# count leaves the suite green, the membership assertions were carrying it alone
# and the count was decoration — which is worth knowing before relying on it.
# ---------------------------------------------------------------------------
echo
echo "[6] the exact-count assertion is loosened to a floor"
mutate "$TFTEST" 's|^    condition     = length(local.operator_lifecycle_permissions) == 4$|    condition     = length(local.operator_lifecycle_permissions) >= 1|'
mutate "$MAIN" 's|^    "compute.zoneOperations.get",$|    "compute.zoneOperations.get",\n    "compute.instances.delete",|'
out="$(failing_tftest)"
check "loosened count" "lifecycle_permissions_are_exactly_the_justified_set" "$out"
check "loosened count" "the_lifecycle_role_grants_no_estate_mutating_verb" "$out"
restore_all

# ---------------------------------------------------------------------------
# 7. Bind the custom role but never create it.
#
# A binding to a role Terraform did not create fails at apply with "role not
# found" — after the rest of the estate has been touched. The flag exists to
# make that case apply cleanly, so the flag itself needs a guard.
# ---------------------------------------------------------------------------
echo
echo "[7] the custom role is bound even when it is not created"
mutate "$MAIN" 's|^    if var.manage_lifecycle_custom_role \|\| r != local.operator_lifecycle_role_name$|    if true \|\| r != local.operator_lifecycle_role_name|'
out="$(failing_tftest)"
check "unmanaged binding" "the_custom_role_can_be_left_to_a_manual_follow_up" "$out"
restore_all

# ---------------------------------------------------------------------------
# 8. Remove a justified role entirely.
#
# The direction the budget was blind to until 2026-08-20. Both "exactly the
# justified set" assertions were written as
# `setunion(toset(actual), toset(expected)) == toset(expected)`, which is
# containment, not equality: it fires on an added role and passes on a removed
# one, while the comment above it said "set equality, not a subset check". Case
# [2] found it on the permission list; this is the same proof for the role list,
# so the fix cannot silently regress on one side.
# ---------------------------------------------------------------------------
echo
echo "[8] the IAP tunnel role is removed from the justified set"
mutate "$MAIN" '/^    "roles\/iap.tunnelResourceAccessor",$/d'
out="$(failing_tftest)"
check "removed role" "roles_are_exactly_the_justified_set" "$out"
check "removed role" "project_role_budget_is_exactly_three" "$out"
check "removed role" "the_tunnel_and_login_roles_are_granted_at_project_scope" "$out"
restore_all

# ── Restoration, verified ───────────────────────────────────────────────────
#
# Content AND mode. The hash-only version could not see a mode-only diff, which
# is what a mutation applied through a tempfile leaves behind.
echo
if ! ms_guard_verify; then
	printf '*** RESTORATION FAILED — the working tree is NOT as it was found.\n' >&2
	exit 2
fi
printf 'restored:\n'
ms_guard_report

echo
echo "proven: ${PASS}   NOT proven: ${FAIL}"
[[ "$FAIL" -eq 0 ]]
