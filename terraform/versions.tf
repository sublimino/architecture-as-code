# Canonical version-pin block. Every root (bootstrap, platform, environments) and every module
# carries an identical copy in its own versions.tf; this file is the reference they are checked
# against. terraform/ is itself NOT a Terraform root — nothing is ever applied from this level.
terraform {
  required_version = ">= 1.9"

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
