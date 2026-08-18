# This suite proves evaluated bootstrap plan values and variable validation behavior using mocked providers.
# It does not prove a real GCP bucket matches these values; only a real plan against real state can show that.

mock_provider "google" {}

mock_provider "google-beta" {}

variables {
  project_id               = "changeme-bootstrap-12345"
  state_bucket_name        = "changeme-tfstate-12345"
  location                 = "europe-west2"
  state_object_admins      = ["serviceAccount:tf-bootstrap@example.invalid", "group:platform-admins@example.invalid"]
  noncurrent_versions_kept = 10
  labels                   = {}
}

run "state_bucket_is_hardened" {
  command = plan

  assert {
    condition     = google_storage_bucket.terraform_state.public_access_prevention == "enforced"
    error_message = "Expected evaluated public_access_prevention to be enforced."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.force_destroy == false
    error_message = "Expected evaluated force_destroy to remain false."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.uniform_bucket_level_access == true
    error_message = "Expected evaluated uniform_bucket_level_access to remain enabled."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.versioning[0].enabled == true
    error_message = "Expected evaluated versioning to be enabled."
  }

  assert {
    condition     = one(google_storage_bucket.terraform_state.lifecycle_rule[0].condition).num_newer_versions == var.noncurrent_versions_kept
    error_message = "Expected lifecycle rule to retain the configured number of noncurrent versions."
  }

  assert {
    condition     = one(google_storage_bucket.terraform_state.lifecycle_rule[0].condition).with_state == "ARCHIVED"
    error_message = "Expected lifecycle rule to target archived object generations."
  }

  assert {
    condition     = one(google_storage_bucket.terraform_state.lifecycle_rule[0].action).type == "Delete"
    error_message = "Expected lifecycle rule action to delete archived generations."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["managed-by"] == "terraform"
    error_message = "Expected evaluated labels to include managed-by=terraform."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["component"] == "signalloom"
    error_message = "Expected evaluated labels to include component=signalloom."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["purpose"] == "terraform-state"
    error_message = "Expected evaluated labels to include purpose=terraform-state."
  }
}

run "state_bucket_iam_is_least_privilege" {
  command = plan

  assert {
    condition     = google_storage_bucket_iam_binding.state_object_admins.role == "roles/storage.objectAdmin"
    error_message = "Expected the evaluated IAM binding role to be roles/storage.objectAdmin."
  }

  assert {
    # members is a set in the provider schema, so it never compares equal to the list the
    # variable supplies. Terraform has no setequal(), so sort both sides and compare: that
    # tests membership, which is the property that matters, without depending on ordering.
    condition     = sort(tolist(google_storage_bucket_iam_binding.state_object_admins.members)) == sort(var.state_object_admins)
    error_message = "Expected the evaluated IAM binding members to match the supplied principals."
  }

  assert {
    condition = alltrue([
      for principal in google_storage_bucket_iam_binding.state_object_admins.members :
      !contains(["allUsers", "allAuthenticatedUsers", "user:allUsers", "user:allAuthenticatedUsers"], principal)
    ])
    error_message = "Expected the evaluated IAM binding members to exclude public principals."
  }
}

run "user_labels_merge_over_mandatory_labels" {
  command = plan

  variables {
    labels = {
      environment = "test"
    }
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["environment"] == "test"
    error_message = "Expected evaluated labels to include user-supplied keys."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["managed-by"] == "terraform"
    error_message = "Expected mandatory labels to remain present after merge."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["component"] == "signalloom"
    error_message = "Expected component label to survive label merge."
  }

  assert {
    condition     = google_storage_bucket.terraform_state.labels["purpose"] == "terraform-state"
    error_message = "Expected purpose label to survive label merge."
  }
}

# Baseline: if this ever fails, every expect_failures run below becomes meaningless because the failure may be unrelated.
run "baseline_valid_inputs_plan_cleanly" {
  command = plan
}

# expect_failures cannot say WHICH validation fired — only that one did. Where an input violates
# two rules at once, the run therefore cannot attribute the rejection, and a test named after the
# rule it does not isolate is a claim of coverage that does not exist.
#
# Verified by falsification: with the public-principal validation deleted from a scratch copy of
# variables.tf, the two bare-form runs below still PASSED (the principal-prefix rule rejects them
# on its own) while the prefixed-form runs went red. Only the prefixed forms isolate the rule.
#
# Both kinds are kept. The bare forms are the input a hurried operator actually types; the
# prefixed forms are what proves the public-principal rule exists.

# Bare public principals. These are rejected by the principal-prefix rule, not necessarily by the
# public-principal rule — the name says what is proven, not what we wish were proven.
run "rejects_bare_all_users_as_unprefixed_principal" {
  command = plan

  variables {
    state_object_admins = ["allUsers"]
  }

  expect_failures = [var.state_object_admins]
}

run "rejects_bare_all_authenticated_users_as_unprefixed_principal" {
  command = plan

  variables {
    state_object_admins = ["allAuthenticatedUsers"]
  }

  expect_failures = [var.state_object_admins]
}

# These two carry a valid principal prefix, so the prefix rule passes them and ONLY the
# public-principal rule can reject them. These are the runs that actually guard the state bucket
# against a world-readable IAM binding.
run "rejects_prefixed_all_users_via_public_principal_rule" {
  command = plan

  variables {
    state_object_admins = ["user:allUsers"]
  }

  expect_failures = [var.state_object_admins]
}

run "rejects_prefixed_all_authenticated_users_via_public_principal_rule" {
  command = plan

  variables {
    state_object_admins = ["principalSet:allAuthenticatedUsers"]
  }

  expect_failures = [var.state_object_admins]
}

run "rejects_empty_state_object_admins" {
  command = plan

  variables {
    state_object_admins = []
  }

  expect_failures = [var.state_object_admins]
}

run "rejects_untyped_state_object_admin" {
  command = plan

  variables {
    state_object_admins = ["tf@example.invalid"]
  }

  expect_failures = [var.state_object_admins]
}

run "rejects_noncurrent_versions_below_floor" {
  command = plan

  variables {
    noncurrent_versions_kept = 5
  }

  expect_failures = [var.noncurrent_versions_kept]
}

run "rejects_fractional_noncurrent_versions" {
  command = plan

  variables {
    noncurrent_versions_kept = 10.5
  }

  expect_failures = [var.noncurrent_versions_kept]
}

run "rejects_bucket_name_containing_google" {
  command = plan

  variables {
    state_bucket_name = "google-tfstate"
  }

  expect_failures = [var.state_bucket_name]
}

run "rejects_bucket_name_starting_with_goog" {
  command = plan

  variables {
    state_bucket_name = "goog-tfstate"
  }

  expect_failures = [var.state_bucket_name]
}

run "rejects_invalid_project_id" {
  command = plan

  variables {
    project_id = "X"
  }

  expect_failures = [var.project_id]
}

run "rejects_empty_location" {
  command = plan

  variables {
    location = ""
  }

  expect_failures = [var.location]
}
