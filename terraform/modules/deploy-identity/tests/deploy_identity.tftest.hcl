# The deploy identity is the most powerful principal in the estate: it holds
# projectIamAdmin, so it can grant itself anything. These assertions are the
# difference between "powerful because it must be" and "powerful by accident".

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id        = "changeme-project"
  state_bucket_name = "changeme-tfstate"
  impersonators     = ["user:someone@example.invalid"]
}

run "state_bucket_access_is_object_admin_not_bucket_admin" {
  command = plan

  # The asymmetry that actually protects the state bucket. objectAdmin reads and
  # writes state objects and cannot delete the bucket; storage.admin can. This
  # binding is the part an attacker editing the config cannot remove.
  assert {
    condition     = google_storage_bucket_iam_member.deploy_state.role == "roles/storage.objectAdmin"
    error_message = "The deploy identity must get objectAdmin on the state bucket, never storage.admin."
  }
}

run "no_owner_or_editor_is_ever_granted" {
  command = plan

  assert {
    condition     = !contains(local.deploy_roles, "roles/owner")
    error_message = "The deploy identity must never hold roles/owner."
  }

  assert {
    condition     = !contains(local.deploy_roles, "roles/editor")
    error_message = "The deploy identity must never hold roles/editor — it is both too broad and, as this deploy proved, too narrow for the IAM-shaped resources."
  }
}

run "impersonation_is_token_creator_not_a_key" {
  command = plan

  assert {
    condition = alltrue([
      for m in values(google_service_account_iam_member.impersonators) :
      m.role == "roles/iam.serviceAccountTokenCreator"
    ])
    error_message = "Access to the deploy identity must be impersonation, not a downloaded key."
  }
}

# ── Negatives, each paired with a positive ──────────────────────────────────

run "rejects_an_empty_impersonator_list" {
  command = plan
  variables { impersonators = [] }

  expect_failures = [var.impersonators]
}

run "rejects_allauthenticatedusers_as_an_impersonator" {
  command = plan
  variables { impersonators = ["allAuthenticatedUsers"] }

  expect_failures = [var.impersonators]
}

run "rejects_a_wildcard_impersonator" {
  command = plan
  variables { impersonators = ["principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/*"] }

  expect_failures = [var.impersonators]
}

run "rejects_a_bare_email_with_no_type_prefix" {
  command = plan
  variables { impersonators = ["someone@example.invalid"] }

  expect_failures = [var.impersonators]
}

run "accepts_a_correctly_prefixed_principal" {
  # The paired positive. Without it, a validation that rejected everything would
  # satisfy all four negatives above while making the module unusable.
  command = plan
  variables { impersonators = ["user:someone@example.invalid", "group:sre@example.invalid"] }

  assert {
    condition     = length(google_service_account_iam_member.impersonators) == 2
    error_message = "A correctly-prefixed principal list must plan cleanly, or the negatives prove nothing."
  }
}
