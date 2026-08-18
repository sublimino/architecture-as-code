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
  description = ""
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
