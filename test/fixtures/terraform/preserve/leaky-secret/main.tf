resource "google_secret_manager_secret" "oops" {
  secret_id = "CHANGEME-authkey"

  replication {
    auto {}
  }
}

# Destroying a version leaves the secret in place and unusable, which is the
# same outage as deleting it. The scanner reports this type too.
resource "google_secret_manager_secret_version" "oops" {
  secret      = google_secret_manager_secret.oops.id
  secret_data = var.placeholder
}

# The decoy that matters most: this is the resource type modules/compute really
# uses. It binds a role on a secret owned elsewhere and must never be flagged,
# or the guard would forbid the correct pattern.
resource "google_secret_manager_secret_iam_member" "accessor" {
  secret_id = "CHANGEME-authkey"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:CHANGEME@CHANGEME-project.iam.gserviceaccount.com"
}

variable "placeholder" {
  type      = string
  sensitive = true
}
