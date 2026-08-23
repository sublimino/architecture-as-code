variable "project_id" {
  description = "GCP project ID that will own the Terraform state bucket."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id validation failed: value must be non-empty."
  }

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id validation failed: value must match ^[a-z][a-z0-9-]{4,28}[a-z0-9]$."
  }
}

variable "state_bucket_name" {
  description = "Name to assign to the GCS bucket that stores Terraform state."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name validation failed: value must be 3-63 characters and match ^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$."
  }

  validation {
    condition     = !startswith(var.state_bucket_name, "goog")
    error_message = "state_bucket_name validation failed: value must not begin with \"goog\"."
  }

  validation {
    condition     = !strcontains(var.state_bucket_name, "google")
    error_message = "state_bucket_name validation failed: value must not contain \"google\"."
  }
}

variable "location" {
  description = "Bucket location, provided explicitly so no copied configuration can inherit a real-project default."
  type        = string

  validation {
    condition     = length(trimspace(var.location)) > 0
    error_message = "location validation failed: value must be non-empty."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.location))
    error_message = "location validation failed: value must match ^[A-Za-z0-9-]+$."
  }
}

variable "state_object_admins" {
  description = "IAM principals that may read and write Terraform state objects without gaining bucket-administration privileges."
  type        = list(string)

  validation {
    condition     = length(var.state_object_admins) > 0
    error_message = "state_object_admins validation failed: list must be non-empty."
  }

  validation {
    condition = alltrue([
      for principal in var.state_object_admins :
      can(regex("^(user|group|serviceAccount|principal|principalSet):.+$", principal))
    ])
    error_message = "state_object_admins validation failed: every entry must start with one of user:, group:, serviceAccount:, principal:, or principalSet:."
  }

  validation {
    condition = alltrue([
      for principal in var.state_object_admins :
      !can(regex("^(?:[^:]+:)?(?:allUsers|allAuthenticatedUsers)$", principal))
    ])
    error_message = "state_object_admins validation failed: entries must not be allUsers or allAuthenticatedUsers, whether bare or prefixed."
  }
}

variable "noncurrent_versions_kept" {
  description = "Minimum number of noncurrent object generations to retain before archived versions become eligible for deletion."
  type        = number
  default     = 10

  validation {
    condition     = var.noncurrent_versions_kept >= 10
    error_message = "noncurrent_versions_kept validation failed: value must be greater than or equal to 10."
  }

  validation {
    condition     = var.noncurrent_versions_kept == floor(var.noncurrent_versions_kept)
    error_message = "noncurrent_versions_kept validation failed: value must be a whole number."
  }
}

variable "labels" {
  description = "Additional labels merged over the mandatory bootstrap labels."
  type        = map(string)
  default     = {}
}

variable "create_deploy_identity" {
  description = <<-EOT
    Create the Terraform deploy service account alongside the state bucket.

    Opt-in rather than default-on, and the reason is the interaction with
    deploy_impersonators: the deploy identity rejects an empty impersonator list,
    because an account nobody can assume is inert while still holding
    projectIamAdmin. Defaulting this to true with an empty impersonator list
    therefore made a bare `terraform plan` fail on a contradiction between two
    defaults, which is a bad first experience and teaches nothing.

    Set true AND name deploy_impersonators together. They are one decision.
  EOT
  type        = bool
  default     = false
}

variable "deploy_account_id" {
  description = "Account id for the deploy service account."
  type        = string
  default     = "sl-tf-deploy"
}

variable "deploy_impersonators" {
  description = "IAM principals permitted to impersonate the deploy identity. Impersonation only; no key is ever created."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Tailscale certificate store
# ---------------------------------------------------------------------------
#
# See the long comment above google_storage_bucket.tailnet_certs in main.tf for
# why this bucket is created by THIS root and not beside the VM that uses it.

variable "tailnet_cert_bucket_name" {
  description = "Globally-unique name of the bucket holding each lane's Tailscale TLS certificate across VM rebuilds. Defaults to the empty string, which creates NO bucket and NO grant and leaves the startup script's restore step disabled. Set it and every rebuild reuses the existing certificate instead of spending one of Let's Encrypt's five-per-168h issuances for the node's exact DNS name."
  type        = string
  default     = ""

  validation {
    # Checked here rather than at the API: otherwise a typo surfaces during
    # apply, after the plan has been reviewed and approved, which is the worst
    # moment to discover it.
    condition     = var.tailnet_cert_bucket_name == "" || can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.tailnet_cert_bucket_name))
    error_message = "tailnet_cert_bucket_name validation failed: must be a valid GCS bucket name (3-63 chars, lowercase letters, digits, dots, hyphens and underscores, starting and ending alphanumeric), or \"\" to disable certificate persistence."
  }

  validation {
    # A name suggesting it holds the tailnet auth key would invite someone to
    # drop that key here later "since the bucket is already there". This
    # bucket's IAM grants every lane write access to its own prefix, which is
    # right for a TLS certificate and wrong for the credential that joins the
    # tailnet — that one lives in Secret Manager, read at boot by
    # fetch_tailscale_authkey, and is never written by a VM.
    condition     = !can(regex("authkey|auth-key|tskey", var.tailnet_cert_bucket_name))
    error_message = "tailnet_cert_bucket_name validation failed: the name must not suggest it holds a Tailscale auth key. This bucket is writable by every lane's runtime account within its own prefix, which is not an appropriate home for the credential that joins the tailnet."
  }

  validation {
    # Co-locating certificates with Terraform state repeats the mistake the
    # audit-bucket comment above already refuses: one deletion would take both
    # the state and the certificates it provisioned.
    condition     = var.tailnet_cert_bucket_name == "" || var.tailnet_cert_bucket_name != var.state_bucket_name
    error_message = "tailnet_cert_bucket_name validation failed: it must not be the Terraform state bucket. One deletion would destroy both the state and the certificates, and the state bucket's IAM is written for state objects, not for per-lane TLS private keys."
  }
}

variable "tailnet_cert_bucket_location" {
  description = "Location for the Tailscale certificate bucket. Regional by default rather than multi-region: the payload is a few kilobytes read once per boot, so replication buys nothing and a single region keeps the key in one stated jurisdiction."
  type        = string
  default     = "us-east4"
}

variable "tailnet_cert_writers" {
  description = "Lane key to IAM principal, e.g. { demo-1 = \"serviceAccount:sl-rt-demo-1@<project>.iam.gserviceaccount.com\" }. Each entry receives roles/storage.objectAdmin CONDITIONED on that lane's own object prefix. The KEY must equal the environment key the VM is given as its cert prefix, or the condition denies every read and write. Supplied explicitly rather than read from the platform root's state because bootstrap runs FIRST — the runtime accounts do not exist yet when this applies, and a binding may legally name a principal that does not exist."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for principal in values(var.tailnet_cert_writers) :
      can(regex("^(user|group|serviceAccount|principal|principalSet):.+$", principal))
    ])
    error_message = "tailnet_cert_writers validation failed: every value must start with one of user:, group:, serviceAccount:, principal:, or principalSet:."
  }

  validation {
    condition = alltrue([
      for principal in values(var.tailnet_cert_writers) :
      !can(regex("^(?:[^:]+:)?(?:allUsers|allAuthenticatedUsers)$", principal))
    ])
    error_message = "tailnet_cert_writers validation failed: entries must not be allUsers or allAuthenticatedUsers. This bucket holds TLS private keys."
  }

  validation {
    # The key is interpolated into the IAM condition's startsWith anchor. A key
    # containing a slash, a quote or ".." changes what that anchor matches,
    # which is a change to a security boundary rather than a formatting
    # preference.
    condition = alltrue([
      for lane in keys(var.tailnet_cert_writers) :
      can(regex("^[a-z0-9][a-z0-9-]*$", lane))
    ])
    error_message = "tailnet_cert_writers validation failed: every KEY must be lowercase alphanumeric with hyphens and no slashes, dots or quotes. The key is interpolated into the IAM condition that confines a lane to its own object prefix."
  }
}
