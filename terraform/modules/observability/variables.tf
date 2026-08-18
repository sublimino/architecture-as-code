# Inputs.
#
# The first eight variables are the frozen interface from terraform/CONTRACT.md
# section 4. The remaining five are additive and every one of them carries a
# default, so a caller that passes exactly the contract's eight inputs still
# plans. That property is deliberate: it is what lets this module be wired into
# the platform root before the other chunks merge, without forcing a contract
# amendment. The additions are recorded in NOTES.md.

# ---------------------------------------------------------------------------
# Contract inputs (CONTRACT.md section 4, modules/observability)
# ---------------------------------------------------------------------------

variable "project_id" {
  description = "Target GCP project id that owns the audit sink, uptime checks, and alert policies."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project id (6-30 chars, lowercase letters, digits and hyphens, starting with a letter)."
  }
}

variable "labels" {
  description = "Mandatory label set from the environment contract, merged onto every labellable resource."
  type        = map(string)
}

variable "log_retention_days" {
  description = "How long audit log objects are retained in the dedicated audit bucket before lifecycle deletion."
  type        = number

  validation {
    # 30 days is the floor a regulated demo can defend; 3650 is GCS's practical
    # ceiling for a retention policy expressed in days.
    condition     = var.log_retention_days >= 30 && var.log_retention_days <= 3650
    error_message = "log_retention_days must be between 30 and 3650."
  }
}

variable "uptime_targets" {
  description = "Public endpoints to uptime-check, keyed by environment key. An entry per demo-N hostname."
  type = map(object({
    hostname = string
    app_port = number
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.uptime_targets : v.hostname != ""])
    error_message = "Every uptime target must carry a non-empty hostname; drop the entry instead of passing an empty string."
  }

  validation {
    condition     = alltrue([for k, v in var.uptime_targets : v.app_port > 0 && v.app_port < 65536])
    error_message = "Every uptime target's app_port must be between 1 and 65535."
  }
}

variable "notification_channel_ids" {
  description = "Monitoring notification channel ids (named owners) that every alert policy routes to."
  type        = list(string)
  default     = []

  # An alert policy with no notification channel is an alert nobody receives:
  # it fires, it is recorded, and the first human to learn of the outage is the
  # person who tried to use the demo. Terraform accepts an empty channel list
  # happily, so this is the only place the mistake can be caught. Cross-variable
  # references in a validation block require Terraform >= 1.9, which is the
  # pinned floor in versions.tf.
  validation {
    condition     = !var.enable_alerts || length(var.notification_channel_ids) > 0
    error_message = "notification_channel_ids must name at least one channel when enable_alerts is true. An alert with no channel is an alert nobody receives; pass enable_alerts = false if you genuinely want the policies omitted."
  }
}

variable "billing_account_id" {
  description = "Billing account id that owns the budget. Empty string disables the budget entirely, so the module is usable without billing-account access."
  type        = string
  default     = ""
}

variable "budget_amount_currency" {
  description = "ISO 4217 currency for the budget amount."
  type        = string
  default     = "GBP"

  validation {
    condition     = can(regex("^[A-Z]{3}$", var.budget_amount_currency))
    error_message = "budget_amount_currency must be a three-letter uppercase ISO 4217 code."
  }
}

variable "budget_amount_units" {
  description = "Whole-currency-unit budget amount for the platform and all demo environments combined."
  type        = number
  default     = 500

  validation {
    condition     = var.budget_amount_units > 0
    error_message = "budget_amount_units must be greater than zero."
  }
}

# ---------------------------------------------------------------------------
# Additive inputs (F6-owned, all defaulted — see NOTES.md)
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Deterministic resource-name prefix. Platform-scoped rather than environment-scoped, because this module is instantiated once per project."
  type        = string
  default     = "sl-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,40}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens and start with a letter."
  }
}

variable "log_bucket_location" {
  description = "Location for the dedicated audit log bucket."
  type        = string
  default     = "europe-west2"
}

variable "state_bucket_name" {
  description = <<-EOT
    Name of the Terraform state bucket, supplied so this module can PROVE its
    audit bucket is a different bucket rather than merely asserting it in a
    comment. Empty string skips the check. See the precondition in main.tf.
  EOT
  type        = string
  default     = ""
}

variable "enable_alerts" {
  description = "Whether to create alert policies. False omits them entirely; it does not create channel-less policies."
  type        = bool
  default     = true
}

variable "data_access_services" {
  description = <<-EOT
    Services whose DATA_READ/DATA_WRITE audit logs are enabled. Data-access
    logging is off by default in GCP for everything except IAM, and the services
    that matter for this platform are the ones holding demo state and secrets.
  EOT
  type        = list(string)
  default = [
    "storage.googleapis.com",
    "iam.googleapis.com",
    # iamcredentials.googleapis.com is DELIBERATELY ABSENT. It does not support
    # service-level audit configuration, and GCP rejects the whole IAM policy
    # write with a 400 rather than ignoring the unsupported entry — so one bad
    # name in this list fails the entire platform apply, including every service
    # that would have worked. Verified against sl-port-over-sandbox on
    # 2026-08-18. Add a service here only after confirming it accepts an audit
    # config; the failure is all-or-nothing, not per-service.
    "secretmanager.googleapis.com",
    "compute.googleapis.com",
  ]

  validation {
    condition     = length(var.data_access_services) > 0
    error_message = "data_access_services must name at least one service; pass the default rather than an empty list."
  }
}

variable "manage_project_iam" {
  description = <<-EOT
    Whether this module manages PROJECT-LEVEL IAM bindings.

    Setting project IAM requires resourcemanager.projects.setIamPolicy, which
    roles/editor does NOT grant. A deployer with editor can create every other
    resource here — service accounts, networks, instances, buckets — and then
    fails partway through the apply on the first binding, leaving the estate
    half-built. A half-applied estate is worse than either outcome: it looks
    deployed and is not, and the error names IAM rather than the permission the
    caller is actually missing.

    Set false to deploy everything except project IAM. The bindings are then a
    documented follow-up for someone holding projectIamAdmin or owner, and the
    apply completes cleanly instead of aborting.

    Default true: the safe posture is the complete one, and a deployer who does
    hold the permission should not have to ask for it.
  EOT
  type        = bool
  default     = true
}

variable "create_log_bucket" {
  description = <<-EOT
    Whether this module CREATES the audit log bucket.

    False when the bucket is provisioned by the separately-authorised bootstrap
    step instead. That is the preferred layering, and it exists to shrink the
    deploy identity's permission set rather than for tidiness: a module that
    creates a bucket forces its caller to hold project-scope storage rights,
    and project-scope storage rights include the ability to delete the Terraform
    state bucket. Moving bucket creation to bootstrap removes that requirement
    entirely — the best permission is the one you do not need.

    The sink still writes to the bucket either way; only ownership moves.
  EOT
  type        = bool
  default     = true
}

variable "log_bucket_name" {
  description = "Name of the audit log bucket. Required when create_log_bucket is false, because the module must still name the bucket the sink writes to even though it does not own it."
  type        = string
  default     = ""
}
