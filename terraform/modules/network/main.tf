# ---------------------------------------------------------------------------
# Signal Loom network — one custom-mode VPC per environment, private by
# construction.
#
# The imperative estate this replaces (scripts/ci/gcp-ci.sh) builds the same
# shape by hand: custom-mode VPC, one /24 subnet in europe-west2, Cloud Router
# + Cloud NAT for outbound, and IAP-only SSH. Two things it does not do, which
# this module does: it scopes no firewall rule to a service account, and it
# relies on GCP's implied allow-all egress. Both are fixed below.
# ---------------------------------------------------------------------------

locals {
  # Networking primitives (network, subnetwork, router, NAT, firewall) accept
  # no `labels` argument in the Google provider. The contract still requires
  # the mandatory label set to travel with every module, so it is folded into
  # each resource description — greppable from `gcloud compute ... list`
  # without inventing a second naming or tagging scheme.
  label_note = join(",", [for k, v in var.labels : "${k}=${v}"])

  # Derived from the environment key, not from the prefix, so the tag survives
  # a prefix change and stays one-to-one with the environment.
  network_tag = "sl-${var.environment_key}-node"

  # Identity-Aware Proxy's TCP forwarding range. This is a fixed, Google-owned
  # range; SSH arrives from here and nowhere else.
  iap_range = "35.235.240.0/20"

  # Google's two health-check / load-balancer proxy ranges. Traffic to the
  # backend arrives from exactly these; any other source is not a health check.
  health_check_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  # Private Google Access VIPs. private.googleapis.com serves most Google APIs;
  # restricted.googleapis.com serves the VPC-SC-constrained subset. Both are
  # reached without traversing the internet, which is why the subnet sets
  # private_ip_google_access = true.
  google_api_ranges = ["199.36.153.4/30", "199.36.153.8/30"]

  # The link-local metadata server, which is also the VM's DNS resolver.
  metadata_server = "169.254.169.254/32"
}

# ---------------------------------------------------------------------------
# VPC and subnet
# ---------------------------------------------------------------------------

resource "google_compute_network" "this" {
  name    = "${var.name_prefix}-vpc"
  project = var.project_id

  # Custom mode. Auto mode would create a subnet in every region with a
  # predictable RFC1918 range, which is exactly the surface this estate is
  # trying not to have.
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  description = "Signal Loom ${var.environment_key} VPC (${local.label_note})"
}

resource "google_compute_subnetwork" "this" {
  name          = "${var.name_prefix}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # Instances have no external IP, so Google API traffic must egress via the
  # Private Google Access VIPs rather than via NAT.
  private_ip_google_access = true

  description = "Signal Loom ${var.environment_key} subnet (${local.label_note})"

  log_config {
    aggregation_interval = var.flow_log_aggregation_interval
    flow_sampling        = var.flow_log_sampling_rate
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Cloud Router + Cloud NAT
#
# NAT gives the private instances outbound reachability. It is emphatically
# NOT egress control — every destination is reachable through it unless a
# firewall rule says otherwise. The egress rules further down are what makes
# this an egress policy rather than a plumbing arrangement.
# ---------------------------------------------------------------------------

resource "google_compute_router" "this" {
  name    = "${var.name_prefix}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.this.id

  description = "Signal Loom ${var.environment_key} Cloud Router (${local.label_note})"
}

resource "google_compute_router_nat" "this" {
  name    = "${var.name_prefix}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.this.name

  nat_ip_allocate_option = "AUTO_ONLY"

  # Scoped to this environment's single subnet rather than every subnet in the
  # VPC, so a subnet added later does not silently inherit outbound reach.
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.this.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }

  log_config {
    enable = true
    filter = var.nat_log_filter
  }
}

# ---------------------------------------------------------------------------
# Ingress firewall
#
# Every allow rule below is scoped by target_service_accounts to the runtime
# service account for this environment. A rule with no target applies to every
# instance in the VPC, which turns "SSH is open to the demo VM" into "SSH is
# open to anything anyone ever launches in this network".
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.name_prefix}-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "INGRESS"
  priority  = 1000

  # IAP TCP forwarding only. No bastion, no public SSH, no operator IP
  # allowlist that goes stale the moment someone changes coffee shop.
  source_ranges           = [local.iap_range]
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  description = "SSH from the IAP TCP-forwarding range only (${local.label_note})"
}

resource "google_compute_firewall" "allow_health_checks" {
  name    = "${var.name_prefix}-allow-health-checks"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "INGRESS"
  priority  = 1000

  # These two ranges carry both the health probes and the load balancer's
  # proxied data path, so one rule covers both — on the app port alone.
  source_ranges           = local.health_check_ranges
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "tcp"
    ports    = [tostring(var.app_port)]
  }

  description = "GCP health-check and LB proxy ranges to the app port only (${local.label_note})"
}

# Explicit default-deny ingress. GCP already implies a deny-all at priority
# 65535 that cannot be removed, so this rule adds no enforcement — it makes the
# posture visible in `gcloud compute firewall-rules list` and in the plan, and
# it gives the deny a log_config so a blocked probe leaves a record. The
# 0.0.0.0/0 below is the source of a DENY, never of an allow; the bats guard
# distinguishes the two.
resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${var.name_prefix}-deny-all-ingress"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  description = "Default-deny ingress, logged (${local.label_note})"
}

# ---------------------------------------------------------------------------
# Egress firewall
#
# GCP implies an allow-all egress at priority 65535. Left alone, a compromised
# demo VM can reach any host on the internet through Cloud NAT.
# "NAT is not egress control" is a named threat in the proposal, so this module
# replaces the implied allow with an explicit deny plus a named dependency list.
# (That phrase is kept on one line on purpose: the bats guard greps for it, and
# a line-wrapped slogan is a documented decision that silently stops being one.)
#
# The demo genuinely needs, and only needs:
#
#   1. DNS — UDP/TCP 53 to the metadata server at 169.254.169.254. The VM
#      resolves everything through it; without this nothing else resolves.
#   2. Google APIs — TCP 443 to 199.36.153.4/30 (private.googleapis.com) and
#      199.36.153.8/30 (restricted.googleapis.com). Carries Cloud Logging,
#      Cloud Monitoring, OS Login account lookup, and Artifact Registry pulls
#      via Private Google Access. Reached without touching the internet.
#   3. Intra-subnet — the Kind control plane and node containers talk to each
#      other and to the host on the subnet CIDR.
#   4. Public HTTPS — TCP 443 to whatever var.egress_public_https_destinations
#      names. This is the container registries and OS package mirrors that
#      publish no stable address range: docker.io, ghcr.io, quay.io,
#      deb.debian.org, download.docker.com. THE DEFAULT IS THE EMPTY LIST, so
#      by default no such rule is created and public egress stays denied.
#
# Consequence, stated plainly: with the defaults, a freshly applied environment
# CANNOT pull public container images. That is the correct default for a
# security demo whose subject is egress control. Opening it is one line in a
# per-environment tfvars file, and that line is then reviewable, diffable, and
# attributable — which a module default is not.
# ---------------------------------------------------------------------------

resource "google_compute_firewall" "allow_egress_dns" {
  name    = "${var.name_prefix}-allow-egress-dns"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "EGRESS"
  priority  = 1000

  destination_ranges      = [local.metadata_server]
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "udp"
    ports    = ["53"]
  }

  allow {
    protocol = "tcp"
    ports    = ["53"]
  }

  description = "DNS to the metadata server (${local.label_note})"
}

resource "google_compute_firewall" "allow_egress_google_apis" {
  name    = "${var.name_prefix}-allow-egress-google-apis"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "EGRESS"
  priority  = 1000

  destination_ranges      = local.google_api_ranges
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  description = "Google APIs via Private Google Access (${local.label_note})"
}

resource "google_compute_firewall" "allow_egress_intra_subnet" {
  name    = "${var.name_prefix}-allow-egress-intra-subnet"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "EGRESS"
  priority  = 1000

  destination_ranges      = [var.subnet_cidr]
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  description = "Intra-subnet traffic for the Kind cluster (${local.label_note})"
}

# Created only when an operator has named destinations. count = 0 by default,
# so the module ships with public egress denied rather than with a rule whose
# destination list happens to be empty.
resource "google_compute_firewall" "allow_egress_public_https" {
  count = length(var.egress_public_https_destinations) > 0 ? 1 : 0

  name    = "${var.name_prefix}-allow-egress-public-https"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "EGRESS"
  priority  = 1100

  destination_ranges      = var.egress_public_https_destinations
  target_service_accounts = [var.runtime_service_account_email]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  description = "Operator-named public HTTPS destinations, e.g. container registries (${local.label_note})"
}

# The rule that makes the four allows above meaningful. Priority 65534 sits
# below every allow and above GCP's implied allow-all at 65535, so anything not
# named above is dropped and logged.
resource "google_compute_firewall" "deny_all_egress" {
  count = var.enable_default_deny_egress ? 1 : 0

  name    = "${var.name_prefix}-deny-all-egress"
  project = var.project_id
  network = google_compute_network.this.id

  direction = "EGRESS"
  priority  = 65534

  destination_ranges      = ["0.0.0.0/0"]
  target_service_accounts = [var.runtime_service_account_email]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  description = "Default-deny egress, logged — replaces GCP's implied allow-all (${local.label_note})"
}
