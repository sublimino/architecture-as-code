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

@test "TFOP deploy/gcp/README.md documents the operator identity and all three roles" {
	local doc="$repo/deploy/gcp/README.md"
	[ -f "$doc" ]
	grep -qi 'operator' "$doc"
	grep -q 'roles/iap.tunnelResourceAccessor' "$doc"
	grep -q 'roles/compute.osAdminLogin' "$doc"
	grep -q 'roles/iam.serviceAccountUser' "$doc"
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
