variable "project_id" {
  description = "GCP project that owns the WIF pool, the OIDC provider, and every service account."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "project_number" {
  description = <<-EOT
    Numeric GCP project number. The principalSet:// URI requires the NUMBER, not the id —
    a project id in that position produces a binding that silently matches nothing.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be the numeric project number (e.g. 123456789012), not the project id."
  }
}

variable "environment_keys" {
  description = "Every environment key that needs a runtime service account. This module is map-aware; the roots do NOT for_each over it."
  type        = list(string)

  validation {
    condition     = length(var.environment_keys) > 0
    error_message = "environment_keys must not be empty — a project with no runtime identity cannot run anything."
  }

  validation {
    condition     = alltrue([for k in var.environment_keys : can(regex("^(demo|ci)-[1-9][0-9]*$", k))])
    error_message = "Every environment key must match ^(demo|ci)-[1-9][0-9]*$ (contract §3)."
  }
}

variable "github_owner_id" {
  description = <<-EOT
    The IMMUTABLE numeric GitHub owner id (organisation or user), e.g. "123456789012".

    Not the org name. A string-name binding survives the org being renamed and re-registered
    by somebody else — GitHub frees the old name immediately, and the new holder's tokens then
    satisfy a condition written against the name. The numeric id is never reissued.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the immutable NUMERIC owner id, not the renameable org/user name."
  }
}

variable "github_repository" {
  description = "Repository allowed to mint tokens, in owner/repo form (e.g. example-org/osramp-demo)."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in owner/repo form."
  }
}

variable "github_allowed_ref" {
  description = "The single git ref permitted to assume the CI identities, e.g. refs/heads/main."
  type        = string

  validation {
    condition     = can(regex("^refs/(heads|tags)/[A-Za-z0-9._/-]+$", var.github_allowed_ref))
    error_message = "github_allowed_ref must be a fully-qualified ref such as refs/heads/main."
  }
}

variable "state_bucket_name" {
  description = <<-EOT
    Name of the Terraform state bucket. The CI plan and apply principals are granted
    roles/storage.objectAdmin on it and never roles/storage.admin (contract §5c): objectAdmin
    can read and write state objects and cannot delete the bucket.

    Empty string disables the binding, which is how a caller that does not (yet) own a state
    bucket instantiates this module. See NOTES.md — this input is an addition to the frozen
    §4 interface, defaulted so no existing caller breaks.
  EOT
  type        = string
  default     = ""
}

variable "runtime_roles" {
  description = "Project roles granted to every per-environment runtime service account."
  type        = list(string)
  default = [
    "roles/iap.tunnelResourceAccessor",
    "roles/compute.osLogin",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/artifactregistry.reader",
  ]

  validation {
    condition = alltrue([
      for r in var.runtime_roles :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin", "roles/compute.osAdminLogin"], r)
    ])
    error_message = "runtime_roles must not contain roles/owner, roles/editor, roles/storage.admin, or roles/compute.osAdminLogin."
  }
}

variable "ci_plan_roles" {
  description = "Project roles granted to the CI plan principal. Read-only: a plan must never be able to change anything."
  type        = list(string)
  default = [
    "roles/compute.viewer",
    "roles/iam.serviceAccountViewer",
    "roles/dns.reader",
  ]

  validation {
    condition = alltrue([
      for r in var.ci_plan_roles :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin"], r)
    ])
    error_message = "ci_plan_roles must not contain roles/owner, roles/editor, or roles/storage.admin."
  }
}

variable "ci_apply_roles" {
  description = "Project roles granted to the CI apply principal. Deliberately distinct from the plan principal's set."
  type        = list(string)
  default = [
    "roles/compute.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/dns.admin",
  ]

  validation {
    condition = alltrue([
      for r in var.ci_apply_roles :
      !contains(["roles/owner", "roles/editor", "roles/storage.admin"], r)
    ])
    error_message = "ci_apply_roles must not contain roles/owner, roles/editor, or roles/storage.admin."
  }
}

variable "operator_members" {
  description = <<-EOT
    Named human or group principals granted IAP tunnel and OS Login access, e.g.
    ["group:sre@example.invalid"]. Named principals only — never allUsers or allAuthenticatedUsers.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for m in var.operator_members :
      can(regex("^(user|group|serviceAccount):[^ ]+$", m))
    ])
    error_message = "operator_members entries must be user:, group:, or serviceAccount: principals — never allUsers or allAuthenticatedUsers."
  }
}

variable "operator_roles" {
  description = "Roles granted to operator_members. IAP tunnel + OS Login only; never an admin variant."
  type        = list(string)
  default = [
    "roles/iap.tunnelResourceAccessor",
    "roles/compute.osLogin",
  ]

  validation {
    condition = alltrue([
      for r in var.operator_roles :
      !contains(["roles/owner", "roles/editor", "roles/compute.osAdminLogin"], r)
    ])
    error_message = "operator_roles must not contain roles/owner, roles/editor, or roles/compute.osAdminLogin."
  }
}

variable "pool_id" {
  description = "Workload identity pool id. Stable across environments — the pool is a project-level singleton owned by terraform/platform."
  type        = string
  default     = "sl-github-pool"
}
