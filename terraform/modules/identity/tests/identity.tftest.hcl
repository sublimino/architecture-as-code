# Native terraform tests for modules/identity.
#
# These assert on the EVALUATED configuration — the attribute values Terraform
# actually computed after variables, locals, for_each and format() resolved. A
# grep over the source proves the file says the right thing; only this proves
# the plan came out the right way.
#
# Mocked providers, plan only. Nothing here reaches GCP, requires credentials,
# or touches the network.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id         = "CHANGEME-project"
  project_number     = "123456789012"
  environment_keys   = ["demo-1", "ci-1", "ci-2"]
  github_owner_id    = "123456789012"
  github_repository  = "example-org/osramp-demo"
  github_allowed_ref = "refs/heads/main"

  github_apply_workflow_ref = "example-org/osramp-demo/.github/workflows/gcp-apply.yml@refs/heads/main"
  state_bucket_name         = "changeme-tfstate"
  operator_members          = ["group:sre@example.invalid"]
}

# ── The WIF provider: the single most dangerous surface in the module ────────

run "issuer_uri_is_exactly_the_github_actions_issuer" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.github[0].oidc[0].issuer_uri == "https://token.actions.githubusercontent.com"
    error_message = "The OIDC issuer URI must be exactly https://token.actions.githubusercontent.com."
  }
}

run "attribute_condition_is_present_and_not_a_tautology" {
  command = plan

  # ISC-159, ISC-160, ISC-165, ISC-350. An absent or `true` condition lets any
  # GitHub repository on earth mint tokens for this project.
  assert {
    condition     = trimspace(google_iam_workload_identity_pool_provider.github[0].attribute_condition) != ""
    error_message = "attribute_condition must be non-empty."
  }

  assert {
    condition     = trimspace(google_iam_workload_identity_pool_provider.github[0].attribute_condition) != "true"
    error_message = "attribute_condition must not be the tautology `true`."
  }

  assert {
    condition     = length(trimspace(google_iam_workload_identity_pool_provider.github[0].attribute_condition)) > 20
    error_message = "attribute_condition is implausibly short to be pinning three claims."
  }
}

run "attribute_condition_pins_the_immutable_numeric_owner_id" {
  command = plan

  # ISC-161, ISC-162. repository_owner (the string name) is renameable and the
  # freed name is immediately re-registerable by anyone. repository_owner_id is not.
  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, "assertion.repository_owner_id")
    error_message = "attribute_condition must pin assertion.repository_owner_id, the immutable numeric id."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, var.github_owner_id)
    error_message = "attribute_condition must contain the configured numeric owner id."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, "assertion.repository ==")
    error_message = "attribute_condition must pin the repository (ISC-163)."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, "assertion.ref ==")
    error_message = "attribute_condition must pin an approved ref (ISC-164)."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, var.github_allowed_ref)
    error_message = "attribute_condition must contain the configured allowed ref."
  }
}

run "attribute_mapping_exposes_the_id_claim" {
  command = plan

  assert {
    condition     = google_iam_workload_identity_pool_provider.github[0].attribute_mapping["attribute.repository_owner_id"] == "assertion.repository_owner_id"
    error_message = "The provider must map the numeric owner id claim through."
  }
}

# ── The impersonation bindings must not be pool-wide ─────────────────────────

run "wif_member_is_attribute_scoped_not_pool_wide" {
  command = plan

  # ISC-175, ISC-176. principalSet://.../workloadIdentityPools/<pool>/* grants
  # every identity the pool can ever mint.
  assert {
    condition     = !endswith(google_service_account_iam_member.ci_apply_wif[0].member, "/*")
    error_message = "The WIF member must not be the bare pool-wide principalSet wildcard."
  }

  assert {
    condition     = !strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "workloadIdentityPools/${var.pool_id}/*")
    error_message = "The WIF member must not be scoped to the whole pool."
  }

  # This originally required the APPLY member to be repository-scoped, which is
  # the defect an adversarial review found rather than a property worth holding:
  # repository scope on apply is what made it identical to plan. Apply is now
  # workflow-scoped, so the invariant that survives is "scoped by SOME attribute,
  # never pool-wide" — asserted for each member against its own correct scope.
  assert {
    condition     = strcontains(google_service_account_iam_member.ci_plan_wif[0].member, "/attribute.repository/${var.github_repository}")
    error_message = "The plan WIF member must be scoped by the repository attribute."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "/attribute.job_workflow_ref/")
    error_message = "The apply WIF member must be scoped by job_workflow_ref, which is narrower than the repository."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "projects/${var.project_number}/")
    error_message = "The principalSet URI must carry the numeric project number, not the project id."
  }

  # This assertion used to require the two members to be EQUAL — it encoded the
  # vulnerability as an invariant, which is why twenty-four identity assertions
  # passed while the plan/apply boundary did not exist. Inverted, and the
  # positive form now lives in its own run block below.
  assert {
    condition     = google_service_account_iam_member.ci_plan_wif[0].member != google_service_account_iam_member.ci_apply_wif[0].member
    error_message = "The plan and apply principals must differ; identical members mean the read-only identity is a path to the write-capable one."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_plan_wif[0].member, "projects/${var.project_number}/")
    error_message = "The plan principalSet URI must carry the numeric project number, not the project id."
  }
}

# ── Service accounts ─────────────────────────────────────────────────────────

run "runtime_service_account_ids_embed_every_environment_key" {
  command = plan

  # ISC-168. One SA per environment, key embedded, so a compromise is scoped.
  assert {
    condition     = google_service_account.runtime["demo-1"].account_id == "sl-rt-demo-1"
    error_message = "The demo-1 runtime SA account id must embed its environment key."
  }

  assert {
    condition     = google_service_account.runtime["ci-1"].account_id == "sl-rt-ci-1"
    error_message = "The ci-1 runtime SA account id must embed its environment key."
  }

  assert {
    condition     = google_service_account.runtime["ci-2"].account_id == "sl-rt-ci-2"
    error_message = "The ci-2 runtime SA account id must embed its environment key."
  }

  assert {
    condition     = length(google_service_account.runtime) == length(var.environment_keys)
    error_message = "There must be exactly one runtime service account per environment key."
  }

  assert {
    condition     = alltrue([for k in var.environment_keys : strcontains(output.runtime_service_account_emails[k], k)])
    error_message = "Every emitted runtime SA email must embed its environment key."
  }
}

run "ci_plan_and_apply_are_distinct_principals_with_distinct_bindings" {
  command = plan

  # ISC-169.
  assert {
    condition     = google_service_account.ci_plan.account_id != google_service_account.ci_apply.account_id
    error_message = "The CI plan and apply service accounts must be distinct."
  }

  assert {
    condition     = output.ci_plan_service_account_email != output.ci_apply_service_account_email
    error_message = "The CI plan and apply emails must differ."
  }

  assert {
    condition = length(setintersection(
      toset([for k, v in google_project_iam_member.ci_plan : v.role]),
      toset([for k, v in google_project_iam_member.ci_apply : v.role]),
    )) == 0
    error_message = "The CI plan and apply principals must not share any project role — a plan identity that can apply is not a plan identity."
  }

  assert {
    condition     = !anytrue([for k, v in google_project_iam_member.ci_plan : strcontains(v.role, "admin")])
    error_message = "The CI plan principal must hold no admin role."
  }
}

# ── Least privilege ──────────────────────────────────────────────────────────

run "no_binding_grants_owner_editor_or_storage_admin" {
  command = plan

  # ISC-170, ISC-171, ISC-172 asserted on the evaluated bindings, not the source
  # text. The bats suite asserts the same properties across the whole tree.
  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.runtime :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin"], v.role)
    ])
    error_message = "A runtime binding grants owner, editor, or storage.admin."
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.ci_plan :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin"], v.role)
    ])
    error_message = "A CI plan binding grants owner, editor, or storage.admin."
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.ci_apply :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin"], v.role)
    ])
    error_message = "A CI apply binding grants owner, editor, or storage.admin."
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.operators :
      !contains(["roles/owner", "roles/editor", "roles/compute.osAdminLogin"], v.role)
    ])
    error_message = "An operator binding grants owner, editor, or osAdminLogin."
  }
}

run "state_bucket_grants_object_admin_and_never_bucket_admin" {
  command = plan

  # Contract §5c. objectAdmin can read and write state objects and cannot delete
  # the bucket. Both halves are asserted: the positive and the negative.
  assert {
    condition     = length(google_storage_bucket_iam_member.ci_state) == 2
    error_message = "Both CI principals must be bound on the state bucket."
  }

  assert {
    condition = alltrue([
      for k, v in google_storage_bucket_iam_member.ci_state :
      v.role == "roles/storage.objectAdmin"
    ])
    error_message = "State bucket bindings must be roles/storage.objectAdmin."
  }

  assert {
    condition = !anytrue([
      for k, v in google_storage_bucket_iam_member.ci_state :
      v.role == "roles/storage.admin"
    ])
    error_message = "No CI principal may hold roles/storage.admin on the state bucket — that role can delete the bucket."
  }

  assert {
    condition = alltrue([
      for k, v in google_storage_bucket_iam_member.ci_state :
      v.bucket == var.state_bucket_name
    ])
    error_message = "State bucket bindings must target the configured bucket."
  }
}

run "iap_tunnel_and_os_login_are_granted_to_named_principals" {
  command = plan

  # ISC-177, ISC-178.
  assert {
    condition = anytrue([
      for k, v in google_project_iam_member.runtime :
      v.role == "roles/iap.tunnelResourceAccessor"
    ])
    error_message = "Runtime principals must hold roles/iap.tunnelResourceAccessor."
  }

  assert {
    condition = anytrue([
      for k, v in google_project_iam_member.runtime :
      v.role == "roles/compute.osLogin"
    ])
    error_message = "Runtime principals must hold roles/compute.osLogin."
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.operators :
      startswith(v.member, "group:") || startswith(v.member, "user:") || startswith(v.member, "serviceAccount:")
    ])
    error_message = "Operator bindings must name principals — never allUsers or allAuthenticatedUsers."
  }

  assert {
    condition = length([
      for k, v in google_project_iam_member.operators :
      v.role if v.role == "roles/iap.tunnelResourceAccessor"
    ]) == length(var.operator_members)
    error_message = "Every named operator must be granted IAP tunnel access."
  }
}

# ── Negative tests, each paired with a positive (ISC-346) ───────────────────
#
# A run that fails for an unrelated reason — a typo, a missing variable — is
# indistinguishable from a validation rule firing. Every expect_failures below
# has an adjacent run proving the SAME configuration passes once the offending
# input is corrected.

run "rejects_a_non_numeric_github_owner_id" {
  command = plan

  variables {
    github_owner_id = "example-org"
  }

  expect_failures = [var.github_owner_id]
}

run "accepts_a_numeric_github_owner_id" {
  command = plan

  variables {
    github_owner_id = "987654321098"
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, "987654321098")
    error_message = "The corrected numeric owner id must be accepted and pinned."
  }
}

run "rejects_an_empty_github_owner_id" {
  command = plan

  variables {
    github_owner_id = ""
  }

  expect_failures = [var.github_owner_id]
}

run "rejects_owner_in_ci_apply_roles" {
  command = plan

  variables {
    ci_apply_roles = ["roles/owner"]
  }

  expect_failures = [var.ci_apply_roles]
}

run "accepts_a_least_privilege_ci_apply_role_set" {
  command = plan

  variables {
    ci_apply_roles = ["roles/compute.admin"]
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.ci_apply :
      v.role == "roles/compute.admin"
    ])
    error_message = "The corrected role set must be accepted."
  }
}

run "rejects_storage_admin_in_ci_plan_roles" {
  command = plan

  variables {
    ci_plan_roles = ["roles/storage.admin"]
  }

  expect_failures = [var.ci_plan_roles]
}

run "accepts_object_admin_scoped_plan_roles" {
  command = plan

  variables {
    ci_plan_roles = ["roles/compute.viewer"]
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.ci_plan :
      v.role == "roles/compute.viewer"
    ])
    error_message = "The corrected plan role set must be accepted."
  }
}

run "rejects_a_project_id_in_the_project_number_slot" {
  command = plan

  variables {
    project_number = "CHANGEME-project"
  }

  expect_failures = [var.project_number]
}

run "accepts_a_numeric_project_number" {
  command = plan

  variables {
    project_number = "210987654321"
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "projects/210987654321/")
    error_message = "The corrected numeric project number must be accepted and used in the principalSet URI."
  }
}

run "rejects_an_unqualified_ref" {
  command = plan

  variables {
    github_allowed_ref = "main"
  }

  expect_failures = [var.github_allowed_ref]
}

run "accepts_a_fully_qualified_ref" {
  command = plan

  variables {
    github_allowed_ref = "refs/heads/release"
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_condition, "refs/heads/release")
    error_message = "The corrected fully-qualified ref must be accepted and pinned."
  }
}

run "rejects_all_users_as_an_operator_principal" {
  command = plan

  variables {
    operator_members = ["allUsers"]
  }

  expect_failures = [var.operator_members]
}

run "accepts_a_named_group_as_an_operator_principal" {
  command = plan

  variables {
    operator_members = ["group:platform@example.invalid"]
  }

  assert {
    condition = alltrue([
      for k, v in google_project_iam_member.operators :
      v.member == "group:platform@example.invalid"
    ])
    error_message = "The corrected named principal must be accepted."
  }
}

# ── The disabled-binding path, so the default is not silently untested ──────

run "an_empty_state_bucket_name_creates_no_bucket_binding" {
  command = plan

  variables {
    state_bucket_name = ""
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.ci_state) == 0
    error_message = "An empty state_bucket_name must produce no bucket binding at all."
  }
}

# ── Plan/apply privilege separation ─────────────────────────────────────────
#
# Regression for an adversarial-review finding. ci_plan_wif and ci_apply_wif
# both bound the SAME repository-scoped principalSet, so the read-only
# ci_plan_roles list and the write-capable ci_apply_roles list described a
# boundary nothing enforced: any token the pool accepted could impersonate the
# apply account, which holds compute.admin, iam.serviceAccountAdmin and
# dns.admin.
#
# Both lines were individually correct. The defect was that they were the same
# line, which is exactly the shape a grep-based guard cannot see and an
# evaluated-config assertion can.

run "plan_and_apply_wif_members_are_not_the_same_principal" {
  command = plan

  assert {
    condition = (
      google_service_account_iam_member.ci_plan_wif[0].member !=
      google_service_account_iam_member.ci_apply_wif[0].member
    )
    error_message = "The plan and apply WIF bindings name the same principal, so the read-only plan identity is a path to the write-capable apply identity."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "attribute.job_workflow_ref/")
    error_message = "The apply binding must be scoped to one workflow file, not to the repository."
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_plan_wif[0].member, "attribute.repository/")
    error_message = "The plan binding stays repository-scoped; it is the weaker identity by design."
  }

  assert {
    condition     = strcontains(google_iam_workload_identity_pool_provider.github[0].attribute_mapping["attribute.job_workflow_ref"], "assertion.job_workflow_ref")
    error_message = "job_workflow_ref must be mapped on the provider, or the apply principalSet can never match anything."
  }
}

run "rejects_a_repository_shaped_apply_workflow_ref" {
  command = plan

  variables {
    github_apply_workflow_ref = "example-org/osramp-demo"
  }

  expect_failures = [var.github_apply_workflow_ref]
}

run "accepts_a_well_formed_apply_workflow_ref" {
  command = plan

  variables {
    github_apply_workflow_ref = "example-org/osramp-demo/.github/workflows/gcp-apply.yml@refs/heads/main"
  }

  assert {
    condition     = strcontains(google_service_account_iam_member.ci_apply_wif[0].member, "gcp-apply.yml@refs/heads/main")
    error_message = "the corrected baseline must plan cleanly, or the negative above proves nothing"
  }
}
