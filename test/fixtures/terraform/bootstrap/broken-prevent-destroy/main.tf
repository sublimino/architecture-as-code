resource "google_storage_bucket" "terraform_state" {
  name     = var.state_bucket_name
  project  = var.project_id
  location = var.location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = false
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      # This keeps at least N noncurrent generations because deletion starts only after more than N newer versions exist.
      num_newer_versions = var.noncurrent_versions_kept
      with_state         = "ARCHIVED"
    }
  }

  labels = merge(
    {
      managed-by = "terraform"
      component  = "signalloom"
      purpose    = "terraform-state"
    },
    var.labels,
  )
}

# State-bucket protection is IAM, not config.
#
# prevent_destroy and force_destroy = false live in THIS FILE. The same commit that deletes the
# bucket can delete them. They are tripwires, not enforcement.
#
# The real mechanism is IAM: no plan/apply principal holds bucket-administration rights here.
# roles/storage.objectAdmin is sufficient to read and write state objects and insufficient to
# delete the bucket or change its retention. This root deliberately declares no binding for
# roles/storage.admin — granting it is a one-line change a reviewer must be able to see, and
# test/terraform-state-protection.bats fails if that line ever appears.
resource "google_storage_bucket_iam_binding" "state_object_admins" {
  bucket  = google_storage_bucket.terraform_state.name
  role    = "roles/storage.objectAdmin"
  members = var.state_object_admins
}

# The log/audit bucket is deliberately NOT declared here. Three reasons, in ascending order of
# how much they matter:
#
#  1. Ownership. The audit bucket and the log sink belong to terraform/platform, which runs after
#     bootstrap and holds the logging-admin credential this root intentionally lacks.
#  2. Single point of change. Declaring it here would create a second place where a change to log
#     retention has to be made, and the two would drift.
#  3. Decisively: the log bucket must never BE the state bucket. Co-locating audit logs with the
#     state they describe means one deletion destroys both the record and the evidence of it.
#     That is why the separation is structural rather than stylistic.

# ── The deploy identity ─────────────────────────────────────────────────────
#
# Created here because it is what applies the platform and environment roots, so
# it cannot be created by them. One elevated human runs bootstrap once; after
# that, nobody needs elevated rights again — every subsequent apply and destroy
# runs as this account by impersonation.
#
# Gated so bootstrap still works for someone who only wants the state bucket.
module "deploy_identity" {
  count  = var.create_deploy_identity ? 1 : 0
  source = "../modules/deploy-identity"

  project_id        = var.project_id
  account_id        = var.deploy_account_id
  state_bucket_name = google_storage_bucket.terraform_state.name
  impersonators     = var.deploy_impersonators
}
