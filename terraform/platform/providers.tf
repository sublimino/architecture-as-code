# Provider configuration lives in roots only — never in modules. See
# terraform/CONTRACT.md section 2.
#
# No credentials are configured here on purpose. The provider resolves
# Application Default Credentials at runtime, which means this root can be
# `init -backend=false`'d, `validate`'d and `terraform test`'d on a machine with
# no GCP access at all. A `credentials = file(...)` argument would make every
# offline check depend on a key file, and a key file is the thing this platform
# exists to avoid (CONTRACT section 6: no google_service_account_key).

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
