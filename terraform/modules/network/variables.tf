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

variable "iap_source_range" {
  description = "Source range for every IAP ingress rule. Google's IAP TCP-forwarding range is 35.235.240.0/20 and there is no second legal value; this is a variable so that an attempt to point IAP ingress somewhere else fails at plan with a named rule."
  type        = string
  default     = "35.235.240.0/20"

  # ─── Why a variable that accepts exactly one value is not ceremony ────────
  #
  # This range was a `local`. A local can be widened by a one-character edit —
  # to an office CIDR, to a VPN range, to 0.0.0.0/0 — and the edit reads as
  # configuration rather than as a change of posture. Nothing named the rule it
  # was breaking, so nothing could report it as broken.
  #
  # As a variable with an equality validation, the same edit fails at plan and
  # says what it violated. The rule is also now reachable from a test:
  # `rejects_a_non_iap_ssh_source` in tests/network.tftest.hcl proves it fires,
  # which an assertion on the evaluated source range cannot do — that only
  # proves the current value is right, not that a wrong one is refused.
  #
  # The value is Google-owned infrastructure, not a customer network. Traffic
  # arriving from it has already been authorised by IAP against
  # roles/iap.tunnelResourceAccessor; the firewall rule is the second gate, not
  # the first.
  validation {
    condition     = var.iap_source_range == "35.235.240.0/20"
    error_message = "NET-RULE-01-IAP-RANGE: iap_source_range must be exactly \"35.235.240.0/20\", Google's IAP TCP-forwarding range. Any other value is by definition not IAP: it converts an identity-gated tunnel into a network allowlist, and the resulting rule still carries the name \"allow-iap-ssh\". If you need a different source, add a separate, differently-named rule and justify it — do not repoint this one."
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

variable "egress_public_ports" {
  description = <<-EOT
    TCP ports the runtime service account may reach on the destinations named in
    egress_public_https_destinations. Defaults to ["443"] alone, so plaintext
    egress stays closed unless an environment opens it explicitly in tfvars.

    Opening 80 is what makes container image BUILDS work. It also weakens the
    posture this environment exists to demonstrate. Read EGRESS-RULE-01 below
    before setting it.
  EOT
  type        = list(string)
  default     = ["443"]

  # ─── The measured failure that made a hardcoded ["443"] untenable ─────────
  #
  # `make demo-signalloom-up` failed RC=2 on the running VM, in the image build:
  #
  #     W: Failed to fetch http://deb.debian.org/debian/dists/trixie/InRelease
  #        Unable to connect to deb.debian.org:http
  #     E: Unable to locate package wget
  #
  # And directly, from the VM: `port80 deb.debian.org: BLOCKED`,
  # `port443 deb.debian.org: 200`.
  #
  # The distinction is the whole point and it is easy to miss. The VM's OWN apt
  # is fine on 443-only, because every source on the GCE Debian image is HTTPS.
  # A container build does not use the VM's sources — it uses the BASE IMAGE's,
  # and debian:trixie defaults to http://deb.debian.org. So a 443-only policy
  # passes every check you can run from the host and fails the moment anything
  # builds an image. That is why this was found by running the estate rather
  # than by reading the module.
  #
  # ─── Why "just use HTTPS in the Dockerfiles" is not the fix ───────────────
  #
  # Debian serves identical content on 443, but debian:trixie-slim ships
  # without ca-certificates, so apt cannot verify a TLS mirror until it has
  # installed a package it can only fetch over TLS. Chicken and egg. This was
  # checked on the VM before the widening was proposed; do not "improve" it
  # back into a Dockerfile change without re-testing that specific point.
  #
  # ─── What opening 80 costs, stated plainly ───────────────────────────────
  #
  # It is a real weakening of the story this environment tells, and the comment
  # should not pretend otherwise. What bounds it:
  #
  #   * EGRESS ONLY. Ingress is entirely unaffected — default-deny ingress
  #     stands, there is no external IP, and the only paths in are IAP on 22
  #     and on app_port.
  #   * Scoped by target_service_accounts to this environment's runtime SA. A
  #     VM running as any other identity in this VPC still cannot reach the
  #     internet at all.
  #   * Bounded by egress_public_https_destinations, which is a CIDR list, not
  #     "the internet" — unless someone makes it so.
  #
  # Before showing this to a customer, narrow the destinations to the mirrors
  # and registries actually used. An 80-open rule pointed at 0.0.0.0/0 is a
  # plaintext channel to anywhere, and it is the first thing a hostile reviewer
  # will find.
  #
  # The default stays ["443"] so that this decision is made per environment, in
  # a file someone reviewed, rather than inherited from a module nobody reread.
  validation {
    condition     = length(var.egress_public_ports) > 0
    error_message = "EGRESS-RULE-01-PORTS-NON-EMPTY: egress_public_ports must name at least one port. An empty list produces a firewall rule with no ports, which the provider may widen to every port rather than none — the opposite of the intent. To close public egress entirely, leave egress_public_https_destinations empty; that creates no rule at all."
  }

  validation {
    condition = alltrue([
      for p in var.egress_public_ports :
      can(regex("^[0-9]+$", p)) && tonumber(p) >= 1 && tonumber(p) <= 65535
    ])
    error_message = "EGRESS-RULE-02-PORTS-RANGE: every entry in egress_public_ports must be a bare port number between 1 and 65535, as a string. Ranges (\"80-443\") and protocol names (\"http\") are not accepted here: a range is a much larger grant than it looks, and this list is meant to be countable at a glance."
  }
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
