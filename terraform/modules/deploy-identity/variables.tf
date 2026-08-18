variable "project_id" {
  description = "GCP project the deploy identity is created in and granted over."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must be a non-empty project ID."
  }
}

variable "account_id" {
  description = "Account id for the deploy service account, e.g. \"sl-tf-deploy\"."
  type        = string
  default     = "sl-tf-deploy"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28})[a-z0-9]$", var.account_id))
    error_message = "account_id must be 6-30 characters, lowercase, and match GCP's service account id rules."
  }
}

variable "state_bucket_name" {
  description = "Terraform state bucket. The deploy identity gets objectAdmin on it — never storage.admin, so it cannot delete the bucket it stores history in."
  type        = string

  validation {
    condition     = length(trimspace(var.state_bucket_name)) > 0
    error_message = "state_bucket_name must be a non-empty bucket name."
  }
}

variable "impersonators" {
  description = "IAM principals permitted to impersonate the deploy identity, e.g. [\"user:someone@example.invalid\"]. Impersonation only — no key is ever created."
  type        = list(string)

  validation {
    condition     = length(var.impersonators) > 0
    error_message = "impersonators must name at least one principal, or nobody can run a deploy and the account is inert."
  }

  # allUsers and allAuthenticatedUsers on a token-creator binding would let
  # anyone with a Google account become an identity holding projectIamAdmin.
  # That is total project compromise from a single line, so it is rejected
  # structurally rather than left to review.
  validation {
    condition = alltrue([
      for m in var.impersonators :
      !contains(["allusers", "allauthenticatedusers"], lower(trimspace(m))) && !strcontains(m, "*")
    ])
    error_message = "impersonators must not contain allUsers, allAuthenticatedUsers, or a wildcard: this account holds projectIamAdmin, so a wildcard here is total project compromise."
  }

  validation {
    condition = alltrue([
      for m in var.impersonators :
      can(regex("^(user|group|serviceAccount|domain):[^[:space:]]+$", trimspace(m)))
    ])
    error_message = "Every impersonators entry must be a prefixed IAM principal such as \"user:...\" or \"group:...\"."
  }
}
