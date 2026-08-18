# Native Terraform tests for the state-bootstrap root.
#
# These assert on the EVALUATED configuration — the attribute values Terraform actually
# computed — rather than on the HCL text that produced them. test/terraform-state-protection.bats
# greps the source and proves it says the right thing; this file proves the bucket Terraform
# would create IS the right thing, after variables and locals resolved. Both matter, and CONTRACT
# §7a makes this one primary.
#
# mock_provider means no credentials, no network, no project. command = plan means nothing is
# ever created. Verified offline at Terraform 1.15.8.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id          = "changeme-project"
  state_bucket_name   = "changeme-project-tfstate"
  location            = "EU"
  state_object_admins = ["serviceAccount:tf-ci-apply@changeme-project.iam.gserviceaccount.com"]
}

run "state_bucket_is_hardened" {
  command = plan

  assert {
    condition     = google_storage_bucket.terraform_state.public_access_prevention == "enforced"
    error_message = "state bucket must enforce public access prevention; a state file is the keys to the estate"
  }

  assert {
    condition     = google_storage_bucket.terraform_state.uniform_bucket_level_access == true
    error_message = "state bucket must use uniform bucket-level access so per-object ACLs cannot reopen it"
  }

  assert {
    condition     = google_storage_bucket.terraform_state.force_destroy == false
    error_message = "state bucket must refuse force_destroy; a non-empty bucket must survive a careless destroy"
  }

  assert {
    condition     = one(google_storage_bucket.terraform_state.versioning).enabled == true
    error_message = "state bucket must keep object versions; without them a corrupted state is unrecoverable"
  }
}

run "state_bucket_retains_noncurrent_versions" {
  command = plan

  variables {
    noncurrent_versions_kept = 10
  }

  assert {
    condition = anytrue([
      for r in google_storage_bucket.terraform_state.lifecycle_rule :
      one(r.condition).num_newer_versions == 10 && one(r.condition).with_state == "ARCHIVED"
    ])
    error_message = "state bucket must retain at least the configured number of noncurrent generations"
  }
}

run "state_bucket_is_labelled_for_ownership" {
  command = plan

  assert {
    condition     = google_storage_bucket.terraform_state.labels["managed-by"] == "terraform"
    error_message = "every managed resource carries managed-by=terraform so drift has an owner"
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["component"] == "signalloom"
    error_message = "every managed resource carries component=signalloom"
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["purpose"] == "terraform-state"
    error_message = "the state bucket is labelled by purpose so a cost view can separate it"
  }
}

# CONTRACT §5c. prevent_destroy and force_destroy live in the config and the same commit that
# deletes the bucket can delete them. IAM is the actual mechanism: objectAdmin can read and write
# state objects and cannot delete the bucket or change its retention.
run "state_bucket_iam_grants_object_admin_not_bucket_admin" {
  command = plan

  assert {
    condition     = google_storage_bucket_iam_binding.state_object_admins.role == "roles/storage.objectAdmin"
    error_message = "state bucket IAM must grant objectAdmin, never storage.admin — objectAdmin cannot delete the bucket"
  }

  assert {
    condition = length([
      for m in google_storage_bucket_iam_binding.state_object_admins.members :
      m if m == "allUsers" || m == "allAuthenticatedUsers"
    ]) == 0
    error_message = "state bucket IAM must never name allUsers or allAuthenticatedUsers"
  }
}

# ── Negative cases ──────────────────────────────────────────────────────────
#
# CONTRACT §7a: every expect_failures run is paired with a positive run proving the same
# configuration passes once the offending input is corrected. Without the pair, a run that fails
# for an unrelated reason — a typo, a missing variable — is indistinguishable from the validation
# rule firing correctly, and the suite silently measures nothing.

run "rejects_a_bucket_name_google_reserves" {
  command = plan

  variables {
    state_bucket_name = "google-changeme-tfstate"
  }

  expect_failures = [var.state_bucket_name]
}

run "rejects_a_bucket_name_with_the_goog_prefix" {
  command = plan

  variables {
    state_bucket_name = "googchangeme-tfstate"
  }

  expect_failures = [var.state_bucket_name]
}

run "rejects_an_empty_location" {
  command = plan

  variables {
    location = "   "
  }

  expect_failures = [var.location]
}

run "rejects_an_empty_state_object_admin_list" {
  command = plan

  variables {
    state_object_admins = []
  }

  expect_failures = [var.state_object_admins]
}

run "accepts_the_corrected_inputs" {
  command = plan

  variables {
    state_bucket_name   = "changeme-project-tfstate"
    location            = "EU"
    state_object_admins = ["serviceAccount:tf-ci-apply@changeme-project.iam.gserviceaccount.com"]
  }

  assert {
    condition     = google_storage_bucket.terraform_state.name == "changeme-project-tfstate"
    error_message = "the corrected baseline must plan cleanly, otherwise the negative runs above prove nothing"
  }
}
