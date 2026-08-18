# This root declares NO backend block of any kind, and that omission is the design.
#
# The root that creates the state bucket cannot depend on the state bucket already existing, so
# bootstrap keeps local state. Because there is no backend block to complete, this root is
# structurally incapable of consuming what it produces — the failure cannot be reintroduced by
# someone filling in a placeholder.
terraform {
  required_version = ">= 1.9"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.8"
    }
  }
}

provider "google" {
  project = var.project_id
}
