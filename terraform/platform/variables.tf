# Inputs to the platform root.
#
# Everything here is a PROJECT-LEVEL singleton — a thing that exists once no
# matter how many demo environments run. Anything scoped to one environment
# belongs in terraform/environments and must not appear in this file
# (CONTRACT.md section 5b).

variable "project_id" {
  description = "Target GCP project id that owns the platform singletons."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project id (6-30 chars, lowercase letters, digits and hyphens, starting with a letter)."
  }
}

variable "region" {
  description = "Default region for the providers and for regional platform resources."
  type        = string
  default     = "europe-west2"
}

variable "name_prefix" {
  description = "Deterministic resource-name prefix for platform-scoped resources. Environment-scoped resources use the per-environment prefix instead."
  type        = string
  default     = "sl-platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,40}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with hyphens and start with a letter."
  }
}

variable "labels" {
  description = "Extra labels merged over the mandatory platform label set."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# State bucket — named, not created
# ---------------------------------------------------------------------------

variable "state_bucket_name" {
  description = <<-EOT
    Name of the Terraform state bucket created by terraform/bootstrap. This root
    does NOT create it — a root cannot own the bucket holding its own state. The
    name is supplied so the observability module can prove its audit bucket is a
    different bucket (CONTRACT section 5c, ISC-206/ISC-207). Empty string skips
    that proof, which is why the tftest suite always supplies it.
  EOT
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

# variable "log_retention_days" {
#   description = "Audit log retention in the dedicated audit bucket."
#   type        = number
#   default     = 400
#
#   validation {
#     condition     = var.log_retention_days >= 30 && var.log_retention_days <= 3650
#     error_message = "log_retention_days must be between 30 and 3650."
#   }
# }

# variable "log_bucket_location" {
#   description = "Location for the dedicated audit log bucket."
#   type        = string
#   default     = "europe-west2"
# }

# variable "uptime_targets" {
#   description = "Public endpoints to uptime-check, keyed by environment key. Populated from the environment map's demo-N hostnames."
#   type = map(object({
#     hostname = string
#     app_port = number
#   }))
#   default = {}
# }

variable "enable_alerts" {
  description = "Whether alert policies are created. False omits them; it never creates a policy with no channel."
  type        = bool
  default     = true
}

variable "notification_emails" {
  description = <<-EOT
    Named human owners who receive every alert. One monitoring notification
    channel is created per address. This is the list that makes an alert
    reach a person — see the validation on the observability module's
    notification_channel_ids.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.notification_emails : can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", e))])
    error_message = "Every notification_emails entry must look like an email address."
  }

  validation {
    condition     = !var.enable_alerts || length(var.notification_emails) > 0 || length(var.extra_notification_channel_ids) > 0
    error_message = "enable_alerts is true but no notification channel is configured. Supply notification_emails, or extra_notification_channel_ids for channels managed outside Terraform, or set enable_alerts = false. An alert with no channel is an alert nobody receives."
  }
}

variable "extra_notification_channel_ids" {
  description = "Pre-existing monitoring notification channel ids (PagerDuty, Slack, a shared inbox) managed outside Terraform."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Billing budget
# ---------------------------------------------------------------------------

# variable "billing_account_id" {
#   description = "Billing account id that owns the budget. Empty string disables the budget so this root is usable by an engineer without billing-account access."
#   type        = string
#   default     = ""
# }

# variable "budget_amount_currency" {
#   description = "ISO 4217 currency for the budget amount."
#   type        = string
#   default     = "GBP"
# }

# variable "budget_amount_units" {
#   description = "Whole-currency-unit monthly budget for the whole estate."
#   type        = number
#   default     = 500
# }

# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------

variable "dns_zone_name" {
  description = "Cloud DNS managed zone resource name. Empty string means Terraform does not manage the zone at all and the environments root creates no DNS records."
  type        = string
  default     = ""

  validation {
    condition     = var.dns_zone_name == "" || can(regex("^[a-z][a-z0-9-]{0,62}$", var.dns_zone_name))
    error_message = "dns_zone_name must be a valid Cloud DNS zone name (lowercase, digits, hyphens) or an empty string."
  }
}

variable "dns_domain" {
  description = "Fully-qualified DNS domain for the managed zone, with a trailing dot. Required when dns_zone_name is set."
  type        = string
  default     = ""

  validation {
    condition     = var.dns_domain == "" || endswith(var.dns_domain, ".")
    error_message = "dns_domain must be fully qualified and end with a trailing dot, e.g. \"demo.example.invalid.\"."
  }

  validation {
    condition     = (var.dns_zone_name == "") == (var.dns_domain == "")
    error_message = "dns_zone_name and dns_domain must be set together or left empty together. A zone without a domain is unplannable; a domain without a zone is a silent no-op."
  }
}

# ---------------------------------------------------------------------------
# Operator identity
# ---------------------------------------------------------------------------
#
# See modules/operator-identity/README.md. The account exists so that reaching a
# VM does not depend on an organisation-level IAM grant nobody in this project
# can make.

variable "operator_account_id" {
  description = "Account id for the operator service account that reaches demo VMs over IAP. Validation lives on the module's own variable; this passes it through so a caller can rename the account without editing the module."
  type        = string
  default     = "sl-operator"
}

variable "operator_impersonators" {
  description = "IAM principals permitted to become the operator identity, e.g. [\"user:someone@example.invalid\"]. Empty is legal and means nobody can log into a VM yet — the estate still builds. Impersonation only; no key is ever created."
  type        = list(string)
  default     = []
}

variable "manage_operator_lifecycle_role" {
  description = "Whether to create the custom role that lets the operator suspend, resume and start demo VMs. Creating a custom role needs iam.roles.create, which is in roles/iam.roleAdmin and NOT in the roles/resourcemanager.projectIamAdmin the deploy identity holds — so a platform apply running as the deploy service account cannot create it. True is correct when applying as an identity holding roleAdmin or owner. False deploys everything else cleanly and leaves the role as a documented follow-up; the operator can still tunnel and log in, and still cannot stop the billing."
  type        = bool
  default     = true
}

variable "dnssec_state" {
  description = "DNSSEC state for the managed zone."
  type        = string
  default     = "on"

  validation {
    condition     = contains(["on", "off"], var.dnssec_state)
    error_message = "dnssec_state must be \"on\" or \"off\"."
  }
}
