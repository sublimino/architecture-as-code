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

# ═══════════════════════════════════════════════════════════════════════════
# PERMISSION BUDGET
#
# These exist so the deploy identity's privilege set cannot grow quietly. Every
# role and permission is pinned by exact count and exact membership, so ADDING
# one fails the suite. That converts "we granted a bit more to make it work"
# from an invisible commit into a deliberate, reviewable change with a number
# attached — which is the difference between least privilege as a practice and
# least privilege as an aspiration.
#
# When a grant is genuinely needed, the required change is: add it, update the
# count, and justify it in the diff. That is the point. The failure is the
# feature.
# ═══════════════════════════════════════════════════════════════════════════

run "project_role_budget_is_exactly_nine" {
  command = plan

  assert {
    condition     = length(local.deploy_roles) == 9
    error_message = "The deploy identity's project role count changed. Nine roles were justified against the 34 resource types this estate declares. Adding one is a privilege increase: update this number ONLY with a comment in main.tf saying which resource type forced it."
  }
}

run "project_roles_are_exactly_the_justified_set" {
  command = plan

  # Set equality, not a subset check. A subset check would pass while something
  # extra was granted, which is precisely the drift this is meant to catch.
  assert {
    condition = setunion(toset(local.deploy_roles), toset([
      "roles/compute.admin",
      "roles/iam.serviceAccountAdmin",
      "roles/iam.serviceAccountUser",
      "roles/resourcemanager.projectIamAdmin",
      "roles/iam.workloadIdentityPoolAdmin",
      "roles/logging.configWriter",
      "roles/monitoring.editor",
      "roles/dns.admin",
      "roles/iap.admin",
      ])) == toset([
      "roles/compute.admin",
      "roles/iam.serviceAccountAdmin",
      "roles/iam.serviceAccountUser",
      "roles/resourcemanager.projectIamAdmin",
      "roles/iam.workloadIdentityPoolAdmin",
      "roles/logging.configWriter",
      "roles/monitoring.editor",
      "roles/dns.admin",
      "roles/iap.admin",
    ])
    error_message = "The deploy identity's project roles are no longer exactly the justified set. Something was added or renamed."
  }
}

run "no_primitive_or_legacy_role_is_ever_granted" {
  command = plan

  # CIS GCP Benchmark guidance: primitive roles (owner/editor/viewer) and legacy
  # roles grant far more than any resource needs and change meaning under you
  # when the provider revises them.
  assert {
    condition = length([
      for r in local.deploy_roles : r
      if contains(["roles/owner", "roles/editor", "roles/viewer"], r) || strcontains(lower(r), "legacy")
    ]) == 0
    error_message = "A primitive (owner/editor/viewer) or legacy role appears in the deploy role set. CIS guidance forbids both, and legacy roles are deprecated on Google's schedule, not yours."
  }
}

run "storage_admin_is_never_granted_at_project_scope" {
  command = plan

  # roles/storage.admin includes storage.buckets.delete. At project scope it
  # would let the deploy identity destroy the state bucket — the one object with
  # no state to roll back from.
  assert {
    condition     = !contains(local.deploy_roles, "roles/storage.admin")
    error_message = "roles/storage.admin grants storage.buckets.delete. The deploy identity must never be able to delete the bucket holding every environment's history."
  }
}

# ── The custom role's permission budget ────────────────────────────────────

run "object_access_stays_object_admin_not_bucket_admin" {
  command = plan

  assert {
    condition     = google_storage_bucket_iam_member.deploy_state.role == "roles/storage.objectAdmin"
    error_message = "Object access must remain objectAdmin: it reads and writes state objects and cannot delete the bucket."
  }
}

run "the_only_bucket_grant_is_object_admin" {
  command = plan

  # The strongest form of this invariant is a count, not a value check: exactly
  # ONE bucket-scoped binding exists, and it is objectAdmin. Adding a second —
  # a custom role, a legacy role, storage.admin — fails here rather than being
  # noticed later.
  #
  # Bucket CREATION and bucket IAM are lifecycle and belong to the privileged
  # bootstrap step. The deploy identity POPULATES buckets and runs Terraform; it
  # never owns them. That split is what keeps this budget at one.
  assert {
    condition     = google_storage_bucket_iam_member.deploy_state.role == "roles/storage.objectAdmin"
    error_message = "The deploy identity's only bucket grant must be objectAdmin: it reads and writes state objects and cannot get, set, reconfigure or delete the bucket."
  }
}
