# terraform/platform — the shared-foundation root.
#
# This root exists for CREDENTIAL SEPARATION, not naming tidiness
# (CONTRACT.md section 5b). bootstrap needs roles/storage.admin; platform needs
# IAM, logging, monitoring and DNS admin; environments needs none of those. Three
# roots means the principal that spins up a demo environment cannot touch the
# audit sink, the WIF pool, or the DNS zone even by accident.
#
# It owns exactly the project-level singletons that N environments would
# otherwise each claim to own:
#
#   - the Workload Identity Federation pool and provider   (modules/identity)
#   - the CI plan/apply service accounts                   (modules/identity)
#   - the log sink, audit bucket, data-access audit config  (modules/observability)
#   - the billing budget                                    (modules/observability)
#   - the monitoring notification channels                  (here)
#   - the Cloud DNS managed zone                            (here)
#
# Anything scoped to one environment belongs in terraform/environments.

locals {
  mandatory_labels = merge(
    {
      environment = "platform"
      kind        = "platform"
      managed-by  = "terraform"
      component   = "signalloom"
    },
    var.labels,
  )

  # Channels created here, plus any managed outside Terraform. The observability
  # module validates that this list is non-empty whenever alerts are enabled, so
  # a misconfiguration fails the plan rather than producing alert policies that
  # fire into nowhere.
  notification_channel_ids = concat(
    [for c in google_monitoring_notification_channel.owners : c.id],
    var.extra_notification_channel_ids,
  )
}

# ---------------------------------------------------------------------------
# Notification channels — the named humans an alert actually reaches
# ---------------------------------------------------------------------------

resource "google_monitoring_notification_channel" "owners" {
  for_each = toset(var.notification_emails)

  project      = var.project_id
  display_name = "${var.name_prefix}-owner-${replace(each.value, "/[^a-zA-Z0-9]/", "-")}"
  type         = "email"
  user_labels  = local.mandatory_labels

  labels = {
    email_address = each.value
  }
}

# ---------------------------------------------------------------------------
# DNS managed zone
# ---------------------------------------------------------------------------

# Gated, because domain ownership is a prerequisite Andy has to supply and may
# not have delegated yet (see terraform/RUNBOOK.md). With dns_zone_name empty
# the whole estate still plans and applies; the environments root simply creates
# no records and the demo is reached by IP over the load balancer's certificate.
resource "google_dns_managed_zone" "demo" {
  count = var.dns_zone_name != "" ? 1 : 0

  project     = var.project_id
  name        = var.dns_zone_name
  dns_name    = var.dns_domain
  description = "Signal Loom demo environments — managed by terraform/platform."
  labels      = local.mandatory_labels

  visibility = "public"

  dnssec_config {
    state = var.dnssec_state
  }
}

# ---------------------------------------------------------------------------
# Observability — audit sink, uptime checks, alerts, budget
# ---------------------------------------------------------------------------

variable "manage_project_iam" {
  description = "Whether the platform root manages project-level IAM. Requires resourcemanager.projects.setIamPolicy, which roles/editor does not grant. False deploys everything else cleanly and leaves the bindings as a documented follow-up."
  type        = bool
  default     = true
}

variable "create_log_bucket" {
  description = "Whether the platform root creates the audit log bucket. False when bootstrap owns it, which removes the deploy identity's need for project-scope storage rights."
  type        = bool
  default     = true
}

variable "log_bucket_name" {
  description = "Audit log bucket name. Required when create_log_bucket is false."
  type        = string
  default     = ""
}

module "observability" {
  create_log_bucket  = var.create_log_bucket
  log_bucket_name    = var.log_bucket_name
  manage_project_iam = var.manage_project_iam
  source             = "../modules/observability"

  project_id               = var.project_id
  labels                   = local.mandatory_labels
  log_retention_days       = var.log_retention_days
  uptime_targets           = var.uptime_targets
  notification_channel_ids = local.notification_channel_ids
  billing_account_id       = var.billing_account_id
  budget_amount_currency   = var.budget_amount_currency
  budget_amount_units      = var.budget_amount_units

  # Additive, F6-owned inputs (all defaulted; see modules/observability/README.md).
  name_prefix         = var.name_prefix
  log_bucket_location = var.log_bucket_location
  state_bucket_name   = var.state_bucket_name
  enable_alerts       = var.enable_alerts
}

# ===========================================================================
# WIRING BLOCK — uncomment at integration. See terraform/platform/WIRING.md.
# ===========================================================================
#
# terraform/modules/identity is built by chunk F5 on branch
# feat/gcp-tf-identity-ci and does not exist in this worktree. A `module` block
# pointing at a missing directory fails `terraform init`, so the call below is
# commented out and this root validates cleanly as it stands. The input names
# are copied verbatim from CONTRACT.md section 4 and must not be renamed when
# uncommenting — if they no longer match F5's module, that is a contract
# violation to reconcile, not a rename to make locally.
#
# Uncomment the variables AND the module block AND the outputs together, in the
# order given in WIRING.md.
#
# ---------------------------------------------------------------------------
variable "project_number" {
  description = "Numeric project number, required by the Workload Identity Federation provider resource name."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.project_number))
    error_message = "project_number must be the numeric project number, not the project id."
  }
}

variable "environment_keys" {
  description = "Every environment key that needs a runtime service account. Must equal keys(var.environments) in the environments root."
  type        = list(string)
  default     = []
}

variable "github_owner_id" {
  description = "Numeric GitHub owner id. Numeric and not the login, because a login can be released and re-registered by someone else; the numeric id cannot."
  type        = string
  default     = ""
}

variable "github_repository" {
  description = "GitHub repository in owner/repo form, used in the WIF attribute condition."
  type        = string
  default     = ""
}

variable "github_allowed_ref" {
  description = "The single git ref permitted to assume the CI identity, e.g. refs/heads/main."
  type        = string
  default     = ""
}

module "identity" {
  source = "../modules/identity"

  project_id         = var.project_id
  project_number     = var.project_number
  environment_keys   = var.environment_keys
  github_owner_id    = var.github_owner_id
  github_repository  = var.github_repository
  github_allowed_ref = var.github_allowed_ref

  # Required since the plan/apply privilege split: the apply identity is scoped
  # to one workflow file rather than to the repository, so that any other
  # workflow in the same repo cannot assume it.
  github_apply_workflow_ref = var.github_apply_workflow_ref

  state_bucket_name  = var.state_bucket_name
  manage_project_iam = var.manage_project_iam
}

variable "github_apply_workflow_ref" {
  description = "Fully-qualified job_workflow_ref of the one workflow permitted to assume the apply service account."
  type        = string
}
#
# ---------------------------------------------------------------------------
# END WIRING BLOCK
# ===========================================================================
