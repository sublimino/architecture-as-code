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

# ─── Why this is an explicit root signal, not `hostname != ""` ─────────────
#
# The edge module does NOT treat hostname as "edge on/off". It uses
# `local.tls_enabled = var.hostname != ""` to gate the TLS FRONTEND only:
# global address, managed certificate, SSL policy, URL maps, proxies, and
# forwarding rules. The backend half is different. The health check, backend
# service, IAP backend-service IAM binding, and Cloud Armor policy are created
# whenever modules/edge is instantiated, hostname or not.
#
# That distinction matters here because Google's two load-balancer
# health-check / proxy ranges hit the VM whenever the edge module exists, even
# on a lane with hostname = "". Deriving this firewall rule from hostname would
# therefore delete real probe ingress for a backend that still exists, and the
# symptom would be a backend that never turns healthy — an outage that reads as
# a broken application rather than as a broken network policy.
#
# So this module takes an explicit boolean from the root instead. The root can
# drive it from the SAME expression that decides whether module "edge" exists,
# which makes disagreement between "the edge was instantiated" and "the health
# check ranges are admitted" unrepresentable. The default stays false for the
# opposite case: a caller who does not think about the question gets no dead
# ingress surface by accident.
variable "edge_enabled" {
  description = "Create the GCP health-check / load-balancer proxy ingress rule. Defaults false so a caller that does not think about the question gets no dead ingress surface by accident; set true only where the root is also instantiating the edge module."
  type        = bool
  default     = false
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

# ---------------------------------------------------------------------------
# UDP egress. A SEPARATE pair of variables from egress_public_ports, not a
# protocol field bolted onto it.
#
# egress_public_ports is consumed inside `allow { protocol = "tcp" }`. Adding
# "41641" to it would open TCP/41641, which Tailscale does not listen on, while
# leaving UDP as closed as it was — a change that reads as "I opened the port"
# and grants nothing. Protocol and port are one decision and they belong in one
# variable pair, or the rule listing and the tfvars disagree about what was
# actually permitted.
# ---------------------------------------------------------------------------

variable "egress_public_udp_ports" {
  description = <<-EOT
    UDP ports the runtime service account may reach on the destinations named in
    egress_public_udp_destinations. Defaults to the EMPTY list, which creates no
    rule at all and leaves UDP egress denied exactly as it is today.

    41641 is Tailscale's direct listener and 3478 is STUN, which is how two
    nodes behind NAT discover a path to each other. Opening both is what buys a
    DIRECT WireGuard tunnel; leaving them closed does not break Tailscale, it
    makes every packet relay through Tailscale's DERP servers over TCP 443,
    which the existing public-egress rule already permits. So this variable buys
    latency and throughput, not connectivity — which is precisely why it should
    be an explicit per-environment decision rather than a module default.
  EOT
  type        = list(string)
  default     = []

  # ─── Why the default is empty and not ["41641", "3478"] ──────────────────
  #
  # UDP egress is the widest thing this module can open. TCP egress to a named
  # CIDR is at least a connection the flow logs record as established or not;
  # UDP is connectionless, so an allowed UDP port to a wide destination is a
  # one-way channel out of the estate that looks identical whether anything is
  # listening or not. It is a better exfiltration path than anything else in
  # this policy, and it is the one an auditor asks about.
  #
  # That does not make it wrong to open — Andy has chosen direct connections
  # over DERP relaying deliberately — it makes it wrong to INHERIT. An
  # environment that never asked for Tailscale must not acquire UDP egress
  # because a module default said so, and the empty default is what guarantees
  # the grant appears in a reviewed tfvars diff with a name attached.
  #
  # The conditions below are character-identical to EGRESS-RULE-01/02 above,
  # deliberately: the same class of input is wrong for the same reasons whether
  # the protocol is TCP or UDP, and two rules that disagree about what a port
  # looks like is how one of them ends up weaker than the other.
  validation {
    condition = alltrue([
      for p in var.egress_public_udp_ports :
      can(regex("^[0-9]+$", p)) && tonumber(p) >= 1 && tonumber(p) <= 65535
    ])
    error_message = "EGRESS-RULE-03-UDP-PORTS-RANGE: every entry in egress_public_udp_ports must be a bare port number between 1 and 65535, as a string. Ranges (\"3478-3479\") and protocol names (\"stun\") are not accepted: a range is a much larger grant than it looks, and this list is meant to be countable at a glance."
  }
}

variable "egress_public_udp_destinations" {
  description = <<-EOT
    Public CIDRs the runtime service account may reach on egress_public_udp_ports.
    Defaults to the empty list. Required to be non-empty whenever
    egress_public_udp_ports names a port — a firewall rule with ports and no
    destinations is a shape the provider may widen, and the widening is invisible
    in the tfvars that caused it.

    Kept SEPARATE from egress_public_https_destinations because they are
    different destination sets with different justifications: that one names
    container registries and package mirrors, this one names Tailscale's DERP
    and STUN infrastructure, or the peer addresses a direct tunnel needs. Sharing
    one list would grant UDP to the registries and TCP to the tailnet, neither of
    which anyone asked for.
  EOT
  type        = list(string)
  default     = []

  # ─── The pairing rule, and why it is here rather than in the resource ─────
  #
  # Ports without destinations is the failure that matters. The rule's `count`
  # keys off the PORT list, so a tfvars naming ports and forgetting destinations
  # would produce a real firewall rule whose destination_ranges is empty — and
  # the Google provider does not treat an empty destination list as "nothing".
  #
  # Stated as a validation on the DESTINATIONS variable rather than on the ports
  # one so that the error names the field the operator must actually fill in.
  # Cross-variable references in validation conditions are a Terraform 1.9
  # feature and this tree pins `>= 1.9`.
  validation {
    condition     = length(var.egress_public_udp_ports) == 0 || length(var.egress_public_udp_destinations) > 0
    error_message = "EGRESS-RULE-04-UDP-DESTINATIONS: egress_public_udp_ports names at least one port, so egress_public_udp_destinations must name at least one CIDR. A UDP egress rule with ports and no destinations is not \"no destinations\" — the provider may render it as every destination, which is the opposite of what an empty list looks like it means. To close UDP egress entirely, empty egress_public_udp_ports instead; that creates no rule at all."
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
