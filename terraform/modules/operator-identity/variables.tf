variable "project_id" {
  description = "GCP project the operator identity is created in and granted over. The account must live INSIDE this project: an account created here is internal to the owning organisation, which is what sidesteps OS Login's external-user rule."
  type        = string

  validation {
    condition     = length(trimspace(var.project_id)) > 0
    error_message = "project_id must be a non-empty project ID."
  }
}

variable "account_id" {
  description = "Account id for the operator service account, e.g. \"sl-operator\"."
  type        = string
  default     = "sl-operator"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{4,28})[a-z0-9]$", var.account_id))
    error_message = "account_id must be 6-30 characters, lowercase, and match GCP's service account id rules."
  }
}

variable "manage_lifecycle_custom_role" {
  description = <<-EOT
    Whether this module creates the instance-lifecycle custom role that lets the
    operator suspend, resume and start a demo VM.

    Creating a custom role requires iam.roles.create, which lives in
    roles/iam.roleAdmin. roles/resourcemanager.projectIamAdmin — the IAM role the
    deploy identity actually holds — does NOT include it: verified against the
    live role definition, projectIamAdmin is nine permissions and every one of
    them is resourcemanager.projects.* or iam.policybindings.*. So a platform
    apply running as the deploy service account cannot create this role.

    True (the default) is correct when the platform root is applied by an
    identity holding roleAdmin or owner. Set it false to deploy everything else
    cleanly and create the role once by hand — the same trade modules/identity
    makes with manage_project_iam, and for the same reason: an apply that dies
    part-way on a permission error leaves a half-built estate and invites the
    wrong fix, which here would be granting roleAdmin to an identity that already
    holds compute.admin and projectIamAdmin and could then mint itself anything.

    When false, the operator keeps the tunnel and the login and still cannot
    suspend. The role is a documented follow-up, not a silent downgrade:
    outputs.lifecycle_role_is_managed reports which case is in force.
  EOT
  type        = bool
  default     = true
}

variable "runtime_service_account_emails" {
  description = <<-EOT
    Runtime service account email per environment key, from
    modules/identity.runtime_service_account_emails. The operator gets
    roles/iam.serviceAccountUser on each of these SERVICE ACCOUNT RESOURCES —
    never at project scope — because OS Login to an instance carrying a
    non-default service account requires actAs on that account.

    Empty map is legal and means the operator can tunnel and log in to VMs with
    no attached service account only. It is the honest default for a caller that
    has not created runtime accounts yet.
  EOT
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for e in values(var.runtime_service_account_emails) :
      can(regex("^[a-z][-a-z0-9]{4,28}[a-z0-9]@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", trimspace(e)))
    ])
    error_message = "Every runtime_service_account_emails value must be a service account email of the form <account-id>@<project>.iam.gserviceaccount.com. A bare account id or a user email here would silently produce a binding on a resource that does not exist."
  }
}

variable "impersonators" {
  description = <<-EOT
    IAM principals permitted to impersonate the operator identity, e.g.
    ["user:someone@example.invalid"]. Impersonation only — no key is ever
    created.

    Defaults to empty, unlike modules/deploy-identity which rejects an empty
    list. The deploy identity with no impersonators makes the estate
    undeployable, so an empty list there is a configuration error. An operator
    identity with no impersonators is simply inert: the estate still builds and
    runs, nobody can log into a VM, and the fix is one tfvars line rather than a
    re-bootstrap.
  EOT
  type        = list(string)
  default     = []

  # allUsers and allAuthenticatedUsers on a token-creator binding would let
  # anyone with a Google account open an authenticated tunnel to every VM in the
  # project and log in with sudo. IAP would faithfully authenticate them. This is
  # rejected structurally rather than left to review.
  validation {
    condition = alltrue([
      for m in var.impersonators :
      !contains(["allusers", "allauthenticatedusers"], lower(trimspace(m))) && !strcontains(m, "*")
    ])
    error_message = "impersonators must not contain allUsers, allAuthenticatedUsers, or a wildcard: this account has sudo on every demo VM, so a wildcard here is an open root shell behind an authenticated tunnel."
  }

  validation {
    condition = alltrue([
      for m in var.impersonators :
      can(regex("^(user|group|serviceAccount|domain):[^[:space:]]+$", trimspace(m)))
    ])
    error_message = "Every impersonators entry must be a prefixed IAM principal such as \"user:...\" or \"group:...\"."
  }
}
