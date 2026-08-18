# Providers are configured in roots only; modules declare `required_providers`
# and never a `provider` block (CONTRACT.md §2). Configuring a provider inside a
# module makes the module impossible to for_each over and pins its credentials
# to its own file rather than to the root that owns the blast radius.

provider "google" {
  project = var.project_id
  region  = var.default_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.default_region
}
