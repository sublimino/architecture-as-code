variable "project_id" {
  description = "GCP project that owns every resource in this module."
  type        = string
}

variable "environment_key" {
  description = "Stable environment key, e.g. \"demo-1\" or \"ci-1\". Embedded in the network tag."
  type        = string
}

variable "name_prefix" {
  description = "Deterministic resource-name prefix supplied by the env-contract module, e.g. \"sl-demo-1\"."
  type        = string
}

variable "labels" {
  description = "Mandatory label set merged by the env-contract module. Networking primitives do not accept labels, so these are folded into resource descriptions instead."
  type        = map(string)
}

variable "region" {
  description = "Region for the subnet, Cloud Router, and Cloud NAT."
  type        = string
}

variable "subnet_cidr" {
  description = "RFC1918 CIDR for this environment's single subnet."
  type        = string
}

variable "app_port" {
  description = "Backend port the load balancer health-checks and forwards to. The only port the health-check firewall rule opens."
  type        = number

  validation {
    condition     = var.app_port >= 1 && var.app_port <= 65535
    error_message = "app_port must be between 1 and 65535."
  }
}

variable "runtime_service_account_email" {
  description = "Per-environment runtime service account attached to this environment's instances. Every firewall rule in this module is scoped to it, so no rule is ever applied network-wide."
  type        = string

  validation {
    condition     = length(trimspace(var.runtime_service_account_email)) > 0
    error_message = "runtime_service_account_email must be set; an empty value would scope firewall rules to every instance in the VPC."
  }
}

variable "nat_log_filter" {
  description = "Cloud NAT log filter. One of ERRORS_ONLY, TRANSLATIONS_ONLY, ALL."
  type        = string
  default     = "ERRORS_ONLY"

  validation {
    condition     = contains(["ERRORS_ONLY", "TRANSLATIONS_ONLY", "ALL"], var.nat_log_filter)
    error_message = "nat_log_filter must be one of ERRORS_ONLY, TRANSLATIONS_ONLY, ALL."
  }
}

# ---------------------------------------------------------------------------
# Flow-log shape. Defaults are the cost/signal balance the demo wants: a 0.5
# sampling rate over 5-second intervals keeps the record volume affordable
# while still catching a sustained exfiltration pattern.
# ---------------------------------------------------------------------------

variable "flow_log_aggregation_interval" {
  description = "VPC flow-log aggregation interval."
  type        = string
  default     = "INTERVAL_5_SEC"

  validation {
    condition = contains([
      "INTERVAL_5_SEC", "INTERVAL_30_SEC", "INTERVAL_1_MIN",
      "INTERVAL_5_MIN", "INTERVAL_10_MIN", "INTERVAL_15_MIN",
    ], var.flow_log_aggregation_interval)
    error_message = "flow_log_aggregation_interval must be a valid GCP aggregation interval."
  }
}

variable "flow_log_sampling_rate" {
  description = "Fraction of flows sampled into the flow logs, 0.0 to 1.0. Must be greater than zero or flow logs record nothing."
  type        = number
  default     = 0.5

  validation {
    condition     = var.flow_log_sampling_rate > 0 && var.flow_log_sampling_rate <= 1
    error_message = "flow_log_sampling_rate must be greater than 0 and at most 1; a rate of 0 enables flow logs that capture nothing."
  }
}

# ---------------------------------------------------------------------------
# Egress policy. See the comment block above the egress rules in main.tf for
# the full dependency list and the reasoning. Read the README before changing
# either of these two.
# ---------------------------------------------------------------------------

variable "enable_default_deny_egress" {
  description = "Create the low-priority deny-all egress rule. Defaults true: without it the VPC inherits GCP's implied allow-all egress, which is the \"NAT is not egress control\" threat the proposal names. Setting this false is an explicit, auditable decision to run without egress control."
  type        = bool
  default     = true
}

variable "egress_public_https_destinations" {
  description = "Public CIDRs the runtime service account may reach on TCP 443, for container registries and OS package mirrors that publish no stable address range (docker.io, ghcr.io, quay.io, deb.debian.org). Defaults to the empty list, which creates NO rule at all and therefore leaves public egress denied. The demo cannot pull images until an operator sets this per environment. That is deliberate: the loosening belongs in a reviewed tfvars file, not in a module default."
  type        = list(string)
  default     = []
}

variable "enable_private_google_access_dns" {
  description = <<-EOT
    Create the private DNS zone that points googleapis.com at the restricted
    Private Google Access VIP.

    Defaults TRUE, and the default matters. Private Google Access is two
    mechanisms: a route to the VIPs (the firewall rule) and a DNS redirect onto
    them (these zones). With only the first, a guest resolves googleapis.com
    publicly, the deny-all egress rule correctly refuses the public address, and
    the environment is broken in a way that reads as an over-strict firewall.

    Set false only when an organisation-wide DNS policy already provides the
    redirect, and say so in the environment's tfvars — otherwise the next person
    to read the plan will assume it was an oversight.
  EOT
  type        = bool
  default     = true
}
