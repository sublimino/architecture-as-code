#!/usr/bin/env bats
#
# Whole-tree absence properties for the operator access path.
#
# ─── The invariant, and why it is an anti-criterion rather than a preference ─
#
# The operator reaches a demo VM through an IAP tunnel and OS Login. OS Login
# refuses to configure POSIX data for a Google identity that is EXTERNAL to the
# organisation owning the project unless that identity holds
# roles/compute.osLoginExternalUser — a role grantable ONLY at organisation
# scope. The operator of this estate holds a personal Google account,
# `gcloud organizations list` returns nothing for him, and the wait for an
# organisation administrator has already cost a day.
#
# terraform/modules/operator-identity removes that dependency by putting the
# login identity INSIDE the project, where the external-user rule does not
# apply. The removal only holds while nothing in the estate reintroduces an
# organisation-scoped grant. The moment a `google_organization_iam_*` resource
# appears, `terraform apply` requires organisation-level rights that nobody
# working on this project has, and the estate becomes unappliable by the person
# who owns it. That is the failure this file exists to prevent, and it is an
# anti-criterion: the correct number of organisation-scoped IAM resources is
# zero, not "few".
#
# ─── Why `terraform test` cannot do this ────────────────────────────────────
#
# CONTRACT §7a: a plan can only tell you about the configuration it evaluated,
# never about the configuration nobody wrote. Absence-across-the-whole-tree is
# the case native tests genuinely cannot reach, so it lives here.
#
# ─── Why the guards look narrow ─────────────────────────────────────────────
#
# `grep -r google_organization_iam_member terraform/` fires on the comment in
# operator-identity/main.tf that names the resource precisely in order to
# forbid it, and on the error messages that explain it. A guard that cannot
# tell "declares" from "forbids" gets disabled the first time it cries wolf. So
# comment lines are stripped first and the patterns match DECLARATION SITES.
#
# Every guard is paired with a mutation check that proves it fails on a
# deliberately-broken fixture under test/fixtures/terraform/operator/. A guard
# nobody has watched fail is not a guard.
#
# Offline. No network, no credentials, no cloud.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	tf="$repo/terraform"
	op_mod="$tf/modules/operator-identity"
	platform="$tf/platform"
	fixtures="$repo/test/fixtures/terraform/operator"
}

# Every non-comment line of the HCL under $1. $2 is a filename suffix so the same
# function reads the real tree (suffix "") and the fixtures (".fixture").
hcl_lines() {
	local dir="$1" sfx="${2:-}"
	find "$dir" -type f \( -name "*.tf${sfx}" -o -name "*.tftest.hcl${sfx}" \) \
		-not -path '*/.terraform/*' -print0 2>/dev/null |
		xargs -0 -r grep -hv -e '^[[:space:]]*#' -e '^[[:space:]]*//' || true
}

# Non-comment lines of the CONFIGURATION only — *.tf, never *.tftest.hcl.
#
# The forbidden-role guards below match a role literal anywhere in the text, and
# a test file legitimately names roles/owner and roles/compute.admin in order to
# assert their absence. Scanning tests with those guards is the "a guard can
# match its own source" failure: it fires on the assertion that proves the
# invariant holds. A role can only be GRANTED in a .tf file, so that is the only
# surface those guards have any business reading.
tf_only_lines() {
	local dir="$1" sfx="${2:-}"
	find "$dir" -type f -name "*.tf${sfx}" -not -path '*/.terraform/*' -print0 2>/dev/null |
		xargs -0 -r grep -hv -e '^[[:space:]]*#' -e '^[[:space:]]*//' || true
}

# How many HCL files the scan can see. Every absence assertion below is trivially
# satisfied by an empty corpus, so this is what stops the whole file passing
# because a path moved.
hcl_file_count() {
	local dir="$1" sfx="${2:-}"
	find "$dir" -type f \( -name "*.tf${sfx}" -o -name "*.tftest.hcl${sfx}" \) \
		-not -path '*/.terraform/*' 2>/dev/null | wc -l
}

# Emits every organisation-scoped IAM declaration it finds, and nothing when the
# tree is clean. Emitting rather than returning a status is deliberate: the
# caller asserts on the captured text, so a guard that silently found nothing
# because the scan was misdirected is distinguishable from one that found
# nothing because the tree is clean (the file-count assertions do that half).
org_iam_declarations() {
	local dir="$1" sfx="${2:-}"
	hcl_lines "$dir" "$sfx" |
		grep -E 'resource[[:space:]]+"google_organization_iam_(member|binding|policy|audit_config)"' || true
}

# Any google_service_account_key declaration. A downloaded key is a bearer
# credential with no expiry; the estate has never needed one.
sa_key_declarations() {
	local dir="$1" sfx="${2:-}"
	hcl_lines "$dir" "$sfx" |
		grep -E 'resource[[:space:]]+"google_service_account_key"' || true
}

# roles/iam.serviceAccountUser appearing inside a google_project_iam_member
# block. At project scope that role covers EVERY service account in the project,
# including the deploy identity, which holds projectIamAdmin — so a
# project-scoped actAs hands the operator the keys to the estate. Brace depth is
# tracked so the role is attributed to the block that declares it and not to the
# file.
project_scoped_act_as() {
	local dir="$1" sfx="${2:-}"
	find "$dir" -type f \( -name "*.tf${sfx}" -o -name "*.tftest.hcl${sfx}" \) \
		-not -path '*/.terraform/*' -print0 2>/dev/null |
		xargs -0 -r awk '
      function flush() {
        if (inblock && has_act_as)
          printf "  %s: %s\n", FILENAME, name
        inblock = 0; has_act_as = 0; depth = 0; name = ""
      }
      { line = $0; sub(/#.*$/, "", line); sub(/\/\/.*$/, "", line) }
      !inblock && line ~ /resource[[:space:]]+"google_project_iam_member"/ {
        flush(); inblock = 1
        n = split(line, parts, "\"")
        name = parts[4]
      }
      inblock {
        if (line ~ /roles\/iam\.serviceAccountUser/) has_act_as = 1
        depth += gsub(/\{/, "{", line)
        depth -= gsub(/\}/, "}", line)
        if (depth <= 0) flush()
      }
      END { flush() }
    '
}

# Emits every estate-mutating permission found inside a
# google_project_iam_custom_role block, and nothing when the role is clean.
#
# The custom role is the operator's only unbounded surface: the role BUDGET in
# tests/operator_identity.tftest.hcl counts roles, and one role can hold any
# number of permissions, so `permissions = [... , "compute.instances.delete"]`
# is a privilege increase that moves no number the budget test reads. The tftest
# pins the evaluated list; this is the text-level companion, and it reaches a
# custom role declared in ANY file rather than only the one that feeds
# local.operator_lifecycle_permissions.
#
# Brace depth is tracked so a permission is attributed to the block that
# declares it and not to the file. Matched on the VERB suffix, so the guard also
# bites on compute.disks.delete or compute.snapshots.create — resource types
# nobody thought to enumerate.
#
# TWO REGIONS, because the permission list has two legitimate homes. The real
# module names it in `locals` as operator_lifecycle_permissions and the resource
# references it (`permissions = local.operator_lifecycle_permissions`), so a
# scanner that only reads inside the resource block finds NOTHING in the shipped
# code — which is how the first version of this guard failed: it went red on the
# real module while passing every fixture, because the fixtures inline the list.
# The fixtures were changed to keep the inline shape on purpose, so both are
# covered and neither can rot unnoticed.
#
# $1 is an awk regex selecting which permission lines to emit.
lifecycle_role_scan() {
	local dir="$1" want="$2" sfx="${3:-}"
	find "$dir" -type f -name "*.tf${sfx}" -not -path '*/.terraform/*' -print0 2>/dev/null |
		xargs -0 -r awk -v want="$want" '
      function flush() { inres = 0; inlist = 0; depth = 0; name = "" }
      { line = $0; sub(/#.*$/, "", line); sub(/\/\/.*$/, "", line) }

      !inres && !inlist && line ~ /resource[[:space:]]+"google_project_iam_custom_role"/ {
        inres = 1; depth = 0
        split(line, parts, "\""); name = parts[4]
        depth += gsub(/\{/, "{", line); depth -= gsub(/\}/, "}", line)
        next
      }

      !inres && !inlist && line ~ /operator_lifecycle_permissions[[:space:]]*=[[:space:]]*\[/ {
        inlist = 1; depth = 0; name = "operator_lifecycle_permissions"
        depth += gsub(/\[/, "[", line); depth -= gsub(/\]/, "]", line)
        if (depth <= 0) flush()
        next
      }

      (inres || inlist) {
        if (line ~ want) {
          perm = line
          gsub(/^[[:space:]]*"/, "", perm)
          gsub(/",?[[:space:]]*$/, "", perm)
          printf "%s\t%s\t%s\n", FILENAME, name, perm
        }
        if (inres) { depth += gsub(/\{/, "{", line); depth -= gsub(/\}/, "}", line) }
        else       { depth += gsub(/\[/, "[", line); depth -= gsub(/\]/, "]", line) }
        if (depth <= 0) flush()
      }
    '
}

# Estate-mutating permissions inside a lifecycle permission list. Matched on the
# VERB suffix, so the guard also bites on compute.disks.delete or
# compute.snapshots.create — resource types nobody thought to enumerate.
lifecycle_role_mutating_permissions() {
	lifecycle_role_scan "$1" \
		'"[a-zA-Z0-9]+\.[a-zA-Z0-9]+\.(create|insert|delete|update|setMetadata|setIamPolicy|setServiceAccount|attachDisk|detachDisk|setTags|setLabels|addAccessConfig|reset|setMachineType|setDiskAutoDelete)",?[[:space:]]*$' \
		"${2:-}"
}

# Every permission literal in a lifecycle permission list, one per line, bare.
# Used for the PAIRED POSITIVE: an absence guard over a corpus with no
# permission list in it is satisfied by nothing being there.
lifecycle_role_permissions() {
	lifecycle_role_scan "$1" \
		'^[[:space:]]*"[a-zA-Z0-9]+\.[a-zA-Z0-9]+\.[a-zA-Z0-9]+",?[[:space:]]*$' \
		"${2:-}" | cut -f3
}

# ---------------------------------------------------------------------------
# Presence. Nothing below means anything if the module is not there.
# ---------------------------------------------------------------------------

@test "TFOP the operator identity module exists and ships every required file" {
	[ -d "$op_mod" ]
	[ -f "$op_mod/main.tf" ]
	[ -f "$op_mod/variables.tf" ]
	[ -f "$op_mod/outputs.tf" ]
	[ -f "$op_mod/versions.tf" ]
	[ -f "$op_mod/README.md" ]
	[ -f "$op_mod/tests/operator_identity.tftest.hcl" ]
}

@test "TFOP the operator module is instantiated by a root, not left as dead code" {
	# An unreferenced module still passes `terraform validate` and still runs its
	# own tftest suite green. The suite would then be proving the correctness of
	# something no apply ever creates.
	local hits
	hits="$(grep -rlE 'source[[:space:]]*=[[:space:]]*"\.\./modules/operator-identity"' \
		"$tf"/*/*.tf 2>/dev/null || true)"
	if [ -z "$hits" ]; then
		echo "no terraform root instantiates modules/operator-identity" >&2
		return 1
	fi
	# CONTRACT §5b: project-level singletons belong to terraform/platform. A
	# singleton declared in terraform/environments is deleted by
	# `make gcp-tf-destroy ENV=<one environment>`, which would take away the only
	# way to log into every other environment.
	echo "$hits" | grep -q "^$platform/"
}

@test "TFOP the scan is not vacuous — it can see the terraform tree and the fixtures" {
	local real fixture lines
	real="$(hcl_file_count "$tf")"
	fixture="$(hcl_file_count "$fixtures" ".fixture")"
	[ "$real" -gt 20 ]
	[ "$fixture" -ge 5 ]

	lines="$(hcl_lines "$tf" | wc -l)"
	[ "$lines" -gt 500 ]
}

# ---------------------------------------------------------------------------
# The anti-criterion: no organisation-scoped IAM, anywhere
# ---------------------------------------------------------------------------

@test "TFOP no organisation-scoped IAM resource is declared anywhere in the estate" {
	local hits
	hits="$(org_iam_declarations "$tf")"
	if [ -n "$hits" ]; then
		echo "organisation-scoped IAM declared in the terraform tree:" >&2
		echo "$hits" >&2
		echo "The primary access path must never depend on an organisation grant." >&2
		echo "See terraform/modules/operator-identity/README.md." >&2
		return 1
	fi
}

@test "TFOP MUTATION an org-scoped IAM fixture trips the org guard" {
	[ -f "$fixtures/org-iam-member/main.tf.fixture" ]
	local hits
	hits="$(org_iam_declarations "$fixtures/org-iam-member" ".fixture")"
	[ -n "$hits" ]
}

@test "TFOP MUTATION the org guard stays silent on the clean fixture" {
	# The paired positive. Without it, a guard whose pattern matched everything
	# would satisfy the mutation check above while being useless on the real tree.
	[ -f "$fixtures/clean/main.tf.fixture" ]
	local hits
	hits="$(org_iam_declarations "$fixtures/clean" ".fixture")"
	[ -z "$hits" ]
}

@test "TFOP MUTATION the org guard ignores a commented-out org resource" {
	# The specific false positive that would get this guard deleted: the real
	# module's comment names google_organization_iam_member in order to forbid it.
	[ -f "$fixtures/org-iam-commented/main.tf.fixture" ]
	local hits
	hits="$(org_iam_declarations "$fixtures/org-iam-commented" ".fixture")"
	[ -z "$hits" ]
}

# ---------------------------------------------------------------------------
# No key, ever
# ---------------------------------------------------------------------------

@test "TFOP no google_service_account_key is declared anywhere in the estate" {
	local hits
	hits="$(sa_key_declarations "$tf")"
	if [ -n "$hits" ]; then
		echo "a service account key resource was declared:" >&2
		echo "$hits" >&2
		return 1
	fi
}

@test "TFOP MUTATION a service account key fixture trips the key guard" {
	[ -f "$fixtures/service-account-key/main.tf.fixture" ]
	local hits
	hits="$(sa_key_declarations "$fixtures/service-account-key" ".fixture")"
	[ -n "$hits" ]
}

# ---------------------------------------------------------------------------
# actAs stays at resource scope
# ---------------------------------------------------------------------------

@test "TFOP the operator module never grants serviceAccountUser at project scope" {
	local hits
	hits="$(project_scoped_act_as "$op_mod")"
	if [ -n "$hits" ]; then
		echo "roles/iam.serviceAccountUser granted via google_project_iam_member:" >&2
		echo "$hits" >&2
		echo "At project scope that covers every service account in the project," >&2
		echo "including the deploy identity, which holds projectIamAdmin." >&2
		return 1
	fi
}

@test "TFOP the operator module does grant serviceAccountUser at resource scope" {
	# The paired positive for the guard above. "No project-scoped actAs" is
	# trivially satisfied by granting no actAs at all, which would leave the
	# operator unable to log into a VM with a runtime service account attached —
	# the exact thing this module was written to fix.
	local resource_scoped
	resource_scoped="$(hcl_lines "$op_mod" |
		grep -c 'resource[[:space:]]*"google_service_account_iam_member"[[:space:]]*"act_as_runtime"' || true)"
	[ "$resource_scoped" -eq 1 ]

	hcl_lines "$op_mod" | grep -q 'roles/iam\.serviceAccountUser'
}

@test "TFOP MUTATION a project-scoped actAs fixture trips the scope guard" {
	[ -f "$fixtures/project-scoped-act-as/main.tf.fixture" ]
	local hits
	hits="$(project_scoped_act_as "$fixtures/project-scoped-act-as" ".fixture")"
	[ -n "$hits" ]
}

@test "TFOP MUTATION the scope guard stays silent on the clean fixture" {
	[ -f "$fixtures/clean/main.tf.fixture" ]
	local hits
	hits="$(project_scoped_act_as "$fixtures/clean" ".fixture")"
	[ -z "$hits" ]
}

# ---------------------------------------------------------------------------
# The operator is not the deploy identity
# ---------------------------------------------------------------------------

@test "TFOP the operator module declares no estate-management or primitive role" {
	# The tftest budget pins the evaluated role list. This is the text-level
	# companion: it would catch a role added in a second file, or in a resource
	# that never reaches local.operator_all_roles.
	local role hits
	for role in \
		"roles/owner" "roles/editor" "roles/viewer" \
		"roles/compute.admin" "roles/resourcemanager.projectIamAdmin" \
		"roles/storage.admin" "roles/iam.serviceAccountAdmin"; do
		hits="$(tf_only_lines "$op_mod" | grep -F "\"${role}\"" || true)"
		if [ -n "$hits" ]; then
			echo "forbidden role ${role} appears in the operator module:" >&2
			echo "$hits" >&2
			return 1
		fi
	done
}

@test "TFOP MUTATION an estate-admin role fixture trips the forbidden-role guard" {
	[ -f "$fixtures/estate-admin-role/main.tf.fixture" ]
	local hits
	hits="$(tf_only_lines "$fixtures/estate-admin-role" ".fixture" | grep -F '"roles/compute.admin"' || true)"
	[ -n "$hits" ]
}

# ---------------------------------------------------------------------------
# The instance-lifecycle custom role holds only what was justified
#
# CONTRACT §7b. The tftest suite pins the EVALUATED permission list and is the
# primary surface; these are the text-level companions, and they reach a custom
# role declared in any file rather than only the one feeding
# local.operator_lifecycle_permissions. Both are mutation-proved against the
# REAL module by test/operator-suspend-mutation-proof.sh.
# ---------------------------------------------------------------------------

@test "TFOP the operator module declares the instance-lifecycle custom role" {
	# The paired positive, and it comes first deliberately: every "no forbidden
	# permission" assertion below is trivially satisfied by a module that declares
	# no custom role at all — which is also the state in which the operator still
	# cannot suspend a VM. Asserting the mechanism is PRESENT before asserting
	# anything about its contents is what stops this whole section passing over
	# nothing.
	local declared
	declared="$(tf_only_lines "$op_mod" |
		grep -c 'resource[[:space:]]*"google_project_iam_custom_role"[[:space:]]*"instance_lifecycle"' || true)"
	[ "$declared" -eq 1 ]

	# Complete-line matches, not substrings. CONTRACT §7b shape 1: a substring
	# search for compute.instances.suspend also matches the prose in main.tf that
	# explains why it is there, so the guard would stay green with the permission
	# deleted and only the comment left behind. A permission is a whole list
	# element on its own line; a comment can never be one.
	local perms
	perms="$(lifecycle_role_permissions "$op_mod")"
	echo "$perms" | grep -qxF 'compute.instances.suspend'
	echo "$perms" | grep -qxF 'compute.instances.resume'
	echo "$perms" | grep -qxF 'compute.instances.start'
	echo "$perms" | grep -qxF 'compute.zoneOperations.get'

	# Exactly four. A count, not a floor: shape 2 in CONTRACT §7b is an assertion
	# that stays green while something extra is present, and `grep -q` for four
	# specific strings is satisfied by a role holding forty.
	[ "$(echo "$perms" | grep -c .)" -eq 4 ]
}

@test "TFOP the lifecycle custom role grants no estate-mutating permission" {
	local hits
	hits="$(lifecycle_role_mutating_permissions "$op_mod")"
	if [ -n "$hits" ]; then
		echo "an estate-mutating permission is declared in a custom role:" >&2
		echo "$hits" >&2
		echo "This role parks and unparks machines. Creating, deleting or" >&2
		echo "reconfiguring them belongs to modules/deploy-identity, and a custom" >&2
		echo "role is the one place a permission can be added without moving any" >&2
		echo "number the role budget in tests/ reads." >&2
		return 1
	fi
}

@test "TFOP MUTATION an overreaching custom role fixture trips the permission guard" {
	[ -f "$fixtures/overreaching-custom-role/main.tf.fixture" ]
	local hits
	hits="$(lifecycle_role_mutating_permissions "$fixtures/overreaching-custom-role" ".fixture")"
	[ -n "$hits" ]
}

@test "TFOP MUTATION the permission guard stays silent on the clean fixture" {
	# The paired positive. clean/ carries a well-formed custom role, so this also
	# proves the guard can tell a legitimate suspend/resume role from an
	# overreaching one — a guard that fired on every custom role would satisfy the
	# mutation check above while being useless on the real module.
	[ -f "$fixtures/clean/main.tf.fixture" ]
	local hits
	hits="$(lifecycle_role_mutating_permissions "$fixtures/clean" ".fixture")"
	[ -z "$hits" ]

	# And the scan is not silent because it found no custom role to look in.
	local perms
	perms="$(lifecycle_role_permissions "$fixtures/clean" ".fixture")"
	[ "$(echo "$perms" | grep -c .)" -ge 2 ]
}

@test "TFOP the operator module grants no predefined instance-admin role" {
	# roles/compute.instanceAdmin.v1 is the ONLY predefined role carrying
	# compute.instances.suspend, and it carries 529 permissions to deliver it —
	# including create, delete, setMetadata, setServiceAccount and attachDisk.
	# It is the shortcut the custom role exists to avoid, so it is named here
	# rather than left to the budget count: a reviewer who saw the budget move
	# from two to three would have no way to tell which of the two changes landed.
	local role hits
	for role in \
		"roles/compute.instanceAdmin" "roles/compute.instanceAdmin.v1"; do
		hits="$(tf_only_lines "$op_mod" | grep -F "\"${role}\"" || true)"
		if [ -n "$hits" ]; then
			echo "forbidden role ${role} appears in the operator module:" >&2
			echo "$hits" >&2
			echo "It grants 529 permissions to deliver compute.instances.suspend." >&2
			echo "google_project_iam_custom_role.instance_lifecycle grants four." >&2
			return 1
		fi
	done
}

@test "TFOP MUTATION an instance-admin role fixture trips the instance-admin guard" {
	[ -f "$fixtures/instance-admin-role/main.tf.fixture" ]
	local hits
	hits="$(tf_only_lines "$fixtures/instance-admin-role" ".fixture" | grep -F '"roles/compute.instanceAdmin.v1"' || true)"
	[ -n "$hits" ]
}

@test "TFOP no legacy role is named anywhere in the operator module" {
	# CIS GCP Benchmark guidance, and the same reasoning as deploy-identity:
	# legacy roles are deprecated on Google's schedule, not yours.
	local hits
	hits="$(tf_only_lines "$op_mod" | grep -iE '"roles/[^"]*legacy[^"]*"' || true)"
	if [ -n "$hits" ]; then
		echo "a legacy role is named in the operator module:" >&2
		echo "$hits" >&2
		return 1
	fi
}

@test "TFOP MUTATION a legacy role fixture trips the legacy-role guard" {
	[ -f "$fixtures/legacy-role/main.tf.fixture" ]
	local hits
	hits="$(tf_only_lines "$fixtures/legacy-role" ".fixture" | grep -iE '"roles/[^"]*legacy[^"]*"' || true)"
	[ -n "$hits" ]
}

# ---------------------------------------------------------------------------
# Documentation — the operator SA must be the documented primary path
# ---------------------------------------------------------------------------

@test "TFOP the access request no longer puts the org-level role on the critical path" {
	local doc="$repo/deploy/gcp/ACCESS-REQUEST.md"
	[ -f "$doc" ]

	# It must still be MENTIONED — it remains a genuine convenience for direct
	# human SSH, and deleting it would mislead the reader in the other direction.
	grep -q 'roles/compute.osLoginExternalUser' "$doc"

	# And it must be described as optional. The exact wording is not pinned;
	# what is pinned is that the words "no longer" and "optional" appear in the
	# section that names the role, so a future edit that quietly reinstates it as
	# a blocker has to remove a sentence rather than just add one.
	grep -qi 'no longer' "$doc"
	grep -qi 'optional' "$doc"

	# The replacement path must be named, or the reader is told what NOT to do
	# with no instruction on what to do instead.
	grep -q 'operator' "$doc"
	grep -q 'roles/iap.tunnelResourceAccessor' "$doc"
}

@test "TFOP deploy/gcp/README.md documents the operator identity and all four roles" {
	local doc="$repo/deploy/gcp/README.md"
	[ -f "$doc" ]
	grep -qi 'operator' "$doc"
	grep -q 'roles/iap.tunnelResourceAccessor' "$doc"
	grep -q 'roles/compute.osAdminLogin' "$doc"
	grep -q 'roles/iam.serviceAccountUser' "$doc"

	# The custom role, and the two facts an operator cannot work without: the
	# permission that actually stops the billing, and the reason the grant may be
	# absent. A runbook that lists three roles when four are granted sends someone
	# to the console to work out why suspend still fails.
	grep -q 'slOperatorInstanceLifecycle' "$doc"
	grep -q 'compute.instances.suspend' "$doc"
	grep -q 'iam.roles.create' "$doc"
}

@test "TFOP the module README states the budget and names the deliberately-absent roles" {
	local doc="$op_mod/README.md"
	[ -f "$doc" ]
	grep -q 'roles/iap.tunnelResourceAccessor' "$doc"
	grep -q 'roles/compute.osAdminLogin' "$doc"
	grep -q 'roles/iam.serviceAccountUser' "$doc"
	grep -q 'roles/compute.osLoginExternalUser' "$doc"
	grep -qi 'never a key\|no key\|not a key' "$doc"
}
