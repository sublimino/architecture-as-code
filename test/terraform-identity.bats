#!/usr/bin/env bats
#
# Whole-tree absence properties for the identity boundary.
#
# `terraform test` asserts on the evaluated plan and is the primary correctness
# surface (CONTRACT §7a). It cannot do the assertions in this file, because they
# are about what appears NOWHERE: a plan can only tell you about the
# configuration it evaluated, never about the configuration nobody wrote.
#
# ─── Why every guard here is deliberately narrow ────────────────────────────
#
# The obvious implementation — `grep -r 'roles/owner' terraform/` — is wrong in
# both directions. It fires on this module's own validation blocks, which list
# roles/owner precisely in order to reject it, and on the error messages that
# name it. A guard that cannot distinguish "grants owner" from "forbids owner"
# gets disabled the first time it cries wolf.
#
# So the patterns match BINDING SITES: an assignment `role = "roles/owner"` or a
# bare list element. Comment lines are stripped first, because a comment cannot
# grant anything. Each guard is proven to still bite by running it against a
# deliberately-broken fixture under test/fixtures/terraform/identity/.
#
# Offline. No network, no credentials, no cloud.

setup() {
	repo="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	tf="$repo/terraform"
	id_mod="$tf/modules/identity"
	ci_mod="$tf/modules/ci-runner"
	fixtures="$repo/test/fixtures/terraform/identity"
}

# Every non-comment line of the HCL under $1. $2 is a filename suffix so the
# same function reads the real tree (suffix "") and the fixtures (".fixture").
hcl_lines() {
	local dir="$1" sfx="${2:-}"
	find "$dir" -type f \( -name "*.tf${sfx}" -o -name "*.tftest.hcl${sfx}" \) -print0 2>/dev/null |
		xargs -0 -r grep -hv -e '^[[:space:]]*#' -e '^[[:space:]]*//' || true
}

# 0 when the pattern is ABSENT from the corpus, 1 when present.
guard_absent() {
	local dir="$1" pattern="$2" sfx="${3:-}"
	! hcl_lines "$dir" "$sfx" | grep -Eq "$pattern"
}

# Binding-site patterns. Kept in one place so the real-tree assertion and the
# mutation assertion can never drift apart.
PAT_SA_KEY='resource[[:space:]]+"google_service_account_key"'
PAT_IAM_POLICY='resource[[:space:]]+"google_project_iam_policy"'
PAT_OWNER='(^[[:space:]]*roles?[[:space:]]*=.*"roles/owner"|^[[:space:]]*"roles/owner",?[[:space:]]*$)'
PAT_EDITOR='(^[[:space:]]*roles?[[:space:]]*=.*"roles/editor"|^[[:space:]]*"roles/editor",?[[:space:]]*$)'
PAT_STORAGE_ADMIN='(^[[:space:]]*roles?[[:space:]]*=.*"roles/storage\.admin"|^[[:space:]]*"roles/storage\.admin",?[[:space:]]*$)'
PAT_APPLY='^[[:space:]]*command[[:space:]]*=[[:space:]]*apply[[:space:]]*$'
PAT_TAUTOLOGY='^[[:space:]]*attribute_condition[[:space:]]*=[[:space:]]*"?true"?[[:space:]]*$'
PAT_ACCESS_CONFIG='^[[:space:]]*access_config[[:space:]]*(\{|=)'

# ─── Presence, before any behavioural assertion ─────────────────────────────
#
# A grep-based guard passes vacuously when the file it greps was never created.

@test "TFID the identity module exists with its required files" {
	[ -d "$id_mod" ]
	[ -f "$id_mod/main.tf" ]
	[ -f "$id_mod/variables.tf" ]
	[ -f "$id_mod/outputs.tf" ]
	[ -f "$id_mod/versions.tf" ]
	[ -f "$id_mod/README.md" ]
}

@test "TFID the ci-runner module exists with its required files" {
	[ -d "$ci_mod" ]
	[ -f "$ci_mod/main.tf" ]
	[ -f "$ci_mod/variables.tf" ]
	[ -f "$ci_mod/outputs.tf" ]
	[ -f "$ci_mod/versions.tf" ]
}

@test "TFID both modules ship a native terraform test" {
	# ISC-329, ISC-330.
	[ -d "$id_mod/tests" ]
	[ -d "$ci_mod/tests" ]
	local n
	n="$(find "$id_mod/tests" -name '*.tftest.hcl' | wc -l)"
	[ "$n" -ge 1 ]
	n="$(find "$ci_mod/tests" -name '*.tftest.hcl' | wc -l)"
	[ "$n" -ge 1 ]
}

@test "TFID the scanned corpus is real, not an empty find" {
	# The positive control for every absence assertion below. If this test ever
	# fails, the guards are measuring nothing and their green is meaningless.
	local lines members conditions
	lines="$(hcl_lines "$tf" "" | wc -l)"
	[ "$lines" -gt 200 ]

	members="$(hcl_lines "$tf" "" | grep -c 'google_project_iam_member')"
	[ "$members" -ge 4 ]

	conditions="$(hcl_lines "$tf" "" | grep -c 'attribute_condition')"
	[ "$conditions" -ge 1 ]
}

# ─── The absence properties ────────────────────────────────────────────────

@test "TFID no google_service_account_key resource exists anywhere" {
	# ISC-166, ISC-167. A JSON key is a bearer credential with no expiry that
	# lives wherever it was pasted. WIF exists so this resource never has to.
	guard_absent "$tf" "$PAT_SA_KEY"
}

@test "TFID no google_project_iam_policy resource exists anywhere" {
	# ISC-173, ISC-174. Authoritative: it replaces the project's entire policy,
	# silently deleting every binding Terraform does not know about, including
	# the ones that let humans back in.
	guard_absent "$tf" "$PAT_IAM_POLICY"
}

@test "TFID no binding grants roles/owner" {
	# ISC-170, ISC-172.
	guard_absent "$tf" "$PAT_OWNER"
}

@test "TFID no binding grants roles/editor" {
	# ISC-171, ISC-172.
	guard_absent "$tf" "$PAT_EDITOR"
}

@test "TFID no binding grants roles/storage.admin on the state bucket" {
	# CONTRACT §5c. objectAdmin reads and writes state objects and cannot delete
	# the bucket; storage.admin can. Asserting the negative is the whole point —
	# the positive alone would pass with both roles granted.
	guard_absent "$tf" "$PAT_STORAGE_ADMIN"

	# And the positive, so this is not an assertion about an empty tree.
	local object_admin
	object_admin="$(hcl_lines "$tf" "" | grep -c 'roles/storage\.objectAdmin')"
	[ "$object_admin" -ge 1 ]
}

@test "TFID no tftest uses command = apply" {
	# ISC-334. Apply against a mocked provider still writes state, and the habit
	# is the thing being avoided.
	guard_absent "$tf" "$PAT_APPLY"

	local plans
	plans="$(hcl_lines "$tf" "" | grep -cE 'command[[:space:]]*=[[:space:]]*plan')"
	[ "$plans" -ge 20 ]
}

@test "TFID every tftest declares both mock providers" {
	# ISC-332. A test file without mock_provider reaches a real provider.
	local f found=0
	while IFS= read -r f; do
		found=$((found + 1))
		grep -q 'mock_provider "google" {}' "$f" || {
			echo "missing mock_provider google: $f"
			return 1
		}
		grep -q 'mock_provider "google-beta" {}' "$f" || {
			echo "missing mock_provider google-beta: $f"
			return 1
		}
	done < <(find "$tf" -type f -name '*.tftest.hcl')
	[ "$found" -ge 2 ]
}

@test "TFID the attribute condition is not the tautology true" {
	# ISC-165. `true` and absent are the same thing: any GitHub repository on
	# earth can mint tokens for this project.
	guard_absent "$tf" "$PAT_TAUTOLOGY"
}

@test "TFID the attribute condition pins the immutable numeric owner id" {
	# ISC-159, ISC-161, ISC-163, ISC-164 at the source level; the tftest asserts
	# the same properties on the evaluated plan.
	grep -q 'assertion.repository_owner_id' "$id_mod/main.tf"
	grep -q 'assertion.repository ==' "$id_mod/main.tf"
	grep -q 'assertion.ref ==' "$id_mod/main.tf"

	# repository_owner (the renameable string name) must not be pinned instead.
	run grep -E 'format\("assertion\.repository_owner ==' "$id_mod/main.tf"
	[ "$status" -ne 0 ]
}

@test "TFID no access_config block exists anywhere" {
	# No external IPs. The pattern matches a block declaration, not the tftest
	# assertion that reads the attribute back.
	guard_absent "$tf" "$PAT_ACCESS_CONFIG"
}

@test "TFID no open CIDR appears in the modules" {
	local open_cidrs
	open_cidrs="$(hcl_lines "$tf" "" | grep -cE '0\.0\.0\.0/0|::/0' || true)"
	[ "$open_cidrs" -eq 0 ]
}

@test "TFID no real project id, domain, or local path is committed" {
	# Two things this guard learned the hard way.
	#
	# The forbidden path is assembled from two literals, so this file cannot
	# match itself. Written as one literal, the guard fired on its own source —
	# which reads exactly like a real finding and is not one.
	#
	# And the generic form is narrowed to exclude /home/ci/, which is the CI
	# VM's own service account and the remote-side convention
	# scripts/ci/gcp-ci.sh already uses. The prohibition is on a developer's
	# machine leaking into a committed file, not on the remote work directory.
	local forbidden="/home/""andy"
	local f scanned=0
	while IFS= read -r f; do
		scanned=$((scanned + 1))
		grep -qF "$forbidden" "$f" && {
			echo "committed developer home path in $f"
			return 1
		}
		grep -oE '/home/[a-z][a-z0-9_-]*/' "$f" | grep -qxv '/home/ci/' && {
			echo "committed absolute home path in $f"
			return 1
		}
	done < <(git -C "$repo" ls-files 'terraform/modules/identity' 'terraform/modules/ci-runner' 'scripts/ci/gcp-tf-*.sh' 'test/terraform-identity.bats' 'test/terraform-ci-lifecycle.bats' 'test/fixtures/terraform' 'test/fixtures/gcp-tf-ci' | sed "s|^|$repo/|")

	# Presence before behaviour: an empty file list would pass the loop above
	# without reading a single byte.
	[ "$scanned" -ge 20 ]

	# The placeholders the contract mandates are actually in use.
	grep -q 'CHANGEME-project' "$id_mod/tests/identity.tftest.hcl"
	grep -q '123456789012' "$id_mod/tests/identity.tftest.hcl"
	grep -q 'example.invalid' "$id_mod/tests/identity.tftest.hcl"
}

@test "TFID MUTATION the home-path guard fires on a file that has one" {
	# The guard is self-immune by construction, so it needs an independent
	# demonstration that it still bites — and that its /home/ci/ carve-out has
	# not quietly widened into "any home path is fine".
	local probe="$BATS_TEST_TMPDIR/has-home-path.tf.fixture"
	printf 'startup_script_path = "%s/src/osramp-demo/scripts/boot.sh"\n' "/home/someuser" >"$probe"
	run bash -c "grep -oE '/home/[a-z][a-z0-9_-]*/' '$probe' | grep -qxv '/home/ci/'"
	[ "$status" -eq 0 ]

	# The carve-out: a remote path under the CI account is allowed.
	local remote="$BATS_TEST_TMPDIR/remote-path.tf.fixture"
	printf 'remote_dir = "/home/ci/osramp-demo"\n' >"$remote"
	run bash -c "grep -oE '/home/[a-z][a-z0-9_-]*/' '$remote' | grep -qxv '/home/ci/'"
	[ "$status" -ne 0 ]

	local clean="$BATS_TEST_TMPDIR/no-home-path.tf.fixture"
	printf 'startup_script_path = "${path.module}/scripts/boot.sh"\n' >"$clean"
	run bash -c "grep -oE '/home/[a-z][a-z0-9_-]*/' '$clean' | grep -qxv '/home/ci/'"
	[ "$status" -ne 0 ]
}

@test "TFID the WIF principal is attribute-scoped, never pool-wide" {
	# ISC-175, ISC-176 at the source level.
	grep -q 'attribute.repository/' "$id_mod/main.tf"
	run grep -E 'workloadIdentityPools/\$\{var\.pool_id\}/\*' "$id_mod/main.tf"
	[ "$status" -ne 0 ]
}

@test "TFID the README documents the WIF claim-negative test" {
	# ISC-179. The property the module exists to provide is the one no plan can
	# demonstrate, so the steps that DO demonstrate it must be written down.
	local r="$id_mod/README.md"
	[ -f "$r" ]
	grep -qi 'claim-negative' "$r"
	grep -qi 'wrong repository' "$r"
	# All three outcomes: wrong repo denied, wrong ref denied, right ref allowed.
	# Without the third, "rejects everything" would read as a pass.
	grep -q 'It must succeed' "$r"
	grep -qi 'attribute condition' "$r"
	grep -qi 'immutable' "$r"
}

@test "TFID the identity module is terraform fmt clean" {
	command -v terraform >/dev/null || skip "terraform not installed"
	run terraform fmt -recursive -check "$id_mod"
	[ "$status" -eq 0 ]
	run terraform fmt -recursive -check "$ci_mod"
	[ "$status" -eq 0 ]
}

@test "TFID the pre-existing CI scripts are byte-identical to their recorded state" {
	# ISC-203. This chunk is a sibling of gcp-ci.sh, not a replacement, and
	# nothing here may edit it, ci-lock.sh, or vm-pipeline.sh.
	local digests="$repo/test/fixtures/gcp-tf-ci/untouched-scripts.sha256"
	[ -f "$digests" ]
	run bash -c "cd '$repo' && sha256sum -c '$digests'"
	[ "$status" -eq 0 ]
}

# ─── Mutation checks: every guard above is proven able to fail ─────────────
#
# Fixture copies only. The real tree is never mutated.

@test "TFID MUTATION the fixture corpus is readable" {
	[ -d "$fixtures" ]
	local lines
	lines="$(hcl_lines "$fixtures" ".fixture" | wc -l)"
	[ "$lines" -gt 20 ]
}

@test "TFID MUTATION a service account key fixture trips the key guard" {
	[ -f "$fixtures/service-account-key/main.tf.fixture" ]
	run guard_absent "$fixtures/service-account-key" "$PAT_SA_KEY" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION an authoritative iam_policy fixture trips the policy guard" {
	[ -f "$fixtures/project-iam-policy/main.tf.fixture" ]
	run guard_absent "$fixtures/project-iam-policy" "$PAT_IAM_POLICY" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION an owner binding fixture trips the owner guard" {
	[ -f "$fixtures/owner-binding/main.tf.fixture" ]
	run guard_absent "$fixtures/owner-binding" "$PAT_OWNER" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION an editor binding fixture trips the editor guard" {
	[ -f "$fixtures/editor-binding/main.tf.fixture" ]
	run guard_absent "$fixtures/editor-binding" "$PAT_EDITOR" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION a storage.admin fixture trips the state bucket guard" {
	[ -f "$fixtures/storage-admin/main.tf.fixture" ]
	run guard_absent "$fixtures/storage-admin" "$PAT_STORAGE_ADMIN" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION a tautological condition fixture trips the tautology guard" {
	[ -f "$fixtures/tautological-condition/main.tf.fixture" ]
	run guard_absent "$fixtures/tautological-condition" "$PAT_TAUTOLOGY" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION an access_config fixture trips the external IP guard" {
	[ -f "$fixtures/external-ip/main.tf.fixture" ]
	run guard_absent "$fixtures/external-ip" "$PAT_ACCESS_CONFIG" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION a command = apply fixture trips the apply guard" {
	[ -f "$fixtures/apply-command/negative.tftest.hcl.fixture" ]
	run guard_absent "$fixtures/apply-command" "$PAT_APPLY" ".fixture"
	[ "$status" -ne 0 ]
}

@test "TFID MUTATION the clean fixture trips no guard" {
	# The control. Without it, a guard_absent that always returned non-zero —
	# a broken find, a bad suffix — would make every mutation test above pass
	# while measuring nothing.
	[ -f "$fixtures/clean/main.tf.fixture" ]
	[ -f "$fixtures/clean/positive.tftest.hcl.fixture" ]

	local lines
	lines="$(hcl_lines "$fixtures/clean" ".fixture" | wc -l)"
	[ "$lines" -gt 5 ]

	guard_absent "$fixtures/clean" "$PAT_SA_KEY" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_IAM_POLICY" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_OWNER" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_EDITOR" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_STORAGE_ADMIN" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_TAUTOLOGY" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_ACCESS_CONFIG" ".fixture"
	guard_absent "$fixtures/clean" "$PAT_APPLY" ".fixture"
}
