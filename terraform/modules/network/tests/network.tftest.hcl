# Native Terraform tests for modules/network.
#
# These assert on the EVALUATED configuration — the attribute values Terraform
# actually computed after variables, locals and conditionals resolved. That is
# the thing a grep over HCL text cannot see. `test/terraform-network-security.bats`
# keeps the whole-tree absence properties (no `access_config` anywhere), which
# is the thing `terraform test` cannot see.
#
# Offline by construction: both providers are mocked, so no credentials, no
# network, and no real API is ever reached. `command = plan` throughout.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id                    = "CHANGEME-project"
  environment_key               = "demo-1"
  name_prefix                   = "sl-demo-1"
  region                        = "europe-west2"
  subnet_cidr                   = "10.20.30.0/24"
  app_port                      = 8080
  runtime_service_account_email = "sl-demo-1-runtime@CHANGEME-project.iam.gserviceaccount.com"

  labels = {
    environment = "demo-1"
    kind        = "demo"
    managed-by  = "terraform"
    component   = "signalloom"
  }
}

# ---------------------------------------------------------------------------
# Baseline. Everything below is a variation on this, so if this run ever goes
# red the negative tests further down prove nothing.
# ---------------------------------------------------------------------------

run "defaults_produce_a_private_vpc" {
  command = plan

  assert {
    condition     = google_compute_network.this.auto_create_subnetworks == false
    error_message = "VPC must be custom-mode; auto mode creates a subnet in every region"
  }

  assert {
    condition     = google_compute_subnetwork.this.private_ip_google_access == true
    error_message = "subnet must reach Google APIs privately; the instances have no external IP"
  }

  assert {
    condition     = google_compute_subnetwork.this.ip_cidr_range == var.subnet_cidr
    error_message = "subnet CIDR must be the one the environment map supplied"
  }

  # ISC-80/96: flow logs on, and actually sampling something.
  assert {
    condition     = length(google_compute_subnetwork.this.log_config) == 1
    error_message = "subnet must enable VPC flow logs"
  }

  assert {
    condition     = one(google_compute_subnetwork.this.log_config).flow_sampling > 0
    error_message = "a flow sampling rate of 0 is flow logs that record nothing"
  }

  # ISC-83: NAT logging on, filter from the variable.
  assert {
    condition     = one(google_compute_router_nat.this.log_config).enable == true
    error_message = "Cloud NAT logging must be enabled"
  }

  assert {
    condition     = one(google_compute_router_nat.this.log_config).filter == "ERRORS_ONLY"
    error_message = "NAT log filter must resolve from var.nat_log_filter"
  }

  # NAT scoped to this subnet, not to every subnet the VPC ever gains.
  assert {
    condition     = google_compute_router_nat.this.source_subnetwork_ip_ranges_to_nat == "LIST_OF_SUBNETWORKS"
    error_message = "NAT must be scoped to the named subnet, not ALL_SUBNETWORKS_ALL_IP_RANGES"
  }
}

# ---------------------------------------------------------------------------
# ISC-351: evaluated resource names embed the environment key.
#
# Asserted on the computed name, not on the HCL that builds it — a name
# assembled from a local, a variable, or a literal is indistinguishable in the
# plan, which is the point.
# ---------------------------------------------------------------------------

run "evaluated_names_embed_the_environment_key" {
  command = plan

  assert {
    condition     = can(regex("demo-1", google_compute_network.this.name))
    error_message = "VPC name must embed the environment key"
  }

  assert {
    condition     = can(regex("demo-1", google_compute_subnetwork.this.name))
    error_message = "subnet name must embed the environment key"
  }

  assert {
    condition     = can(regex("demo-1", google_compute_router.this.name))
    error_message = "router name must embed the environment key"
  }

  assert {
    condition     = can(regex("demo-1", google_compute_router_nat.this.name))
    error_message = "NAT name must embed the environment key"
  }

  assert {
    condition     = can(regex("demo-1", google_compute_firewall.allow_iap_ssh.name))
    error_message = "firewall rule names must embed the environment key"
  }

  # ISC-112: the network tag the compute module consumes.
  assert {
    condition     = output.network_tag == "sl-demo-1-node"
    error_message = "network tag must derive from the environment key"
  }
}

# ---------------------------------------------------------------------------
# ISC-349: the SSH rule's evaluated source is exactly the IAP range.
# ---------------------------------------------------------------------------

run "ssh_is_reachable_only_from_the_iap_range" {
  command = plan

  assert {
    condition     = length(google_compute_firewall.allow_iap_ssh.source_ranges) == 1
    error_message = "the SSH rule must have exactly one source range"
  }

  assert {
    condition     = contains(google_compute_firewall.allow_iap_ssh.source_ranges, "35.235.240.0/20")
    error_message = "the SSH rule's only source must be the IAP TCP-forwarding range"
  }

  # ISC-85: scoped to the runtime SA, never to every instance in the VPC.
  assert {
    condition     = google_compute_firewall.allow_iap_ssh.target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "the SSH rule must be scoped to the runtime service account"
  }

  assert {
    condition     = one(google_compute_firewall.allow_iap_ssh.allow).protocol == "tcp"
    error_message = "the SSH rule must allow tcp only"
  }

  assert {
    condition     = one(google_compute_firewall.allow_iap_ssh.allow).ports == tolist(["22"])
    error_message = "the SSH rule must open port 22 and nothing else"
  }
}

# ---------------------------------------------------------------------------
# The app-port tunnel. A SEPARATE rule from allow_iap_ssh, so that the SSH rule
# above still opens 22 and nothing else — a rule named "allow-iap-ssh" that
# also opened the application would be a rule whose name lies.
#
# Run at 30754, the real value, because that number is load-bearing rather than
# arbitrary: Dex pins its OIDC issuer and callback client to it
# (`setup_gateway_forward`, scripts/acceptance-test.sh), so a tunnel on any
# other port reaches the Envoy Gateway and then fails the login redirect. It is
# passed as a variable here so a hardcoded literal in the module would fail.
# ---------------------------------------------------------------------------

run "the_app_port_is_reachable_over_iap_and_only_over_iap" {
  command = plan

  variables {
    app_port = 30754
  }

  assert {
    condition     = one(google_compute_firewall.allow_iap_app_port.allow).ports == tolist(["30754"])
    error_message = "the IAP app rule must open exactly the configured app port; 30754 is what Dex's callback is pinned to"
  }

  assert {
    condition     = length(google_compute_firewall.allow_iap_app_port.source_ranges) == 1
    error_message = "the IAP app rule must have exactly one source range"
  }

  assert {
    condition     = google_compute_firewall.allow_iap_app_port.source_ranges == toset(["35.235.240.0/20"])
    error_message = "the IAP app rule's only source must be Google's IAP TCP-forwarding range"
  }

  assert {
    condition     = google_compute_firewall.allow_iap_app_port.target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "the IAP app rule must be scoped to the runtime service account, not to every instance in the VPC"
  }

  assert {
    condition     = one(google_compute_firewall.allow_iap_app_port.allow).protocol == "tcp"
    error_message = "the IAP app rule must allow tcp only"
  }

  assert {
    condition     = google_compute_firewall.allow_iap_app_port.direction == "INGRESS"
    error_message = "the IAP app rule must be an ingress rule"
  }

  # Both paths from the IAP range, asserted together — this is the pair the
  # demo actually depends on, and asserting them in one run is what proves they
  # share a source range rather than merely each having a plausible one.
  assert {
    condition     = google_compute_firewall.allow_iap_ssh.source_ranges == google_compute_firewall.allow_iap_app_port.source_ranges
    error_message = "SSH and the app port must be reachable from the same, single IAP range"
  }

  # And 22 is untouched by the addition. A change that opened the app port by
  # widening the SSH rule would pass every assertion above except this one.
  assert {
    condition     = one(google_compute_firewall.allow_iap_ssh.allow).ports == tolist(["22"])
    error_message = "adding the app-port rule must not add a port to the SSH rule; they are separate exposures"
  }

  # The deny still sits behind both.
  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority > google_compute_firewall.allow_iap_app_port.priority
    error_message = "the ingress deny must still sit below the app-port allow"
  }
}

# ---------------------------------------------------------------------------
# The regression this environment actually hit.
#
# Before allow_iap_app_port existed, app_port was opened ONLY to Google's
# load-balancer health-check ranges. demo-1 has no load balancer at all —
# hostname and dns_managed_zone are both "" by design, so no forwarding rule is
# created — which means those ranges reach this environment NEVER. An IAP tunnel
# to the app port therefore matched no allow rule and was dropped by
# deny_all_ingress. Reproduced live against 8080:
#
#     ERROR: ... [4003: 'failed to connect to backend']
#
# and misread as "nothing is listening yet". It was BOTH, and fixing only the
# listener would have left an identical error message. That is the expensive way
# to be wrong, and it is why this run asserts reachability rather than the
# presence of a rule.
#
# Stated as a POSITIVE requirement: some ingress allow rule must grant app_port
# from the IAP range. Deleting allow_iap_app_port does not satisfy it — it
# breaks the reference and the run errors. An "app_port is not open to the
# world" assertion would have passed cheerfully throughout the outage.
# ---------------------------------------------------------------------------

run "app_port_is_reachable_from_iap_and_not_only_from_health_checkers" {
  command = plan

  variables {
    app_port = 30754
  }

  # The requirement itself. Both halves in one condition on purpose: a rule
  # that opens the port from the wrong source, and a rule with the right source
  # that opens the wrong port, are the same outage.
  assert {
    condition = (
      contains(google_compute_firewall.allow_iap_app_port.source_ranges, "35.235.240.0/20")
      && contains(one(google_compute_firewall.allow_iap_app_port.allow).ports, "30754")
    )
    error_message = "no ingress rule grants the app port from the IAP range. With no load balancer in this environment the health-check ranges reach it never, so an IAP tunnel to the app port is dropped by deny_all_ingress and fails as 4003 'failed to connect to backend' — which reads as a dead application."
  }

  # And the app port is reachable from NOWHERE else. Enumerated over every
  # ingress allow rule in the module rather than asserted about one of them,
  # because the question is what the environment permits, not what one resource
  # says.
  assert {
    condition = alltrue([
      for src in setunion(
        google_compute_firewall.allow_iap_app_port.source_ranges,
        google_compute_firewall.allow_health_checks.source_ranges,
      ) :
      contains(["35.235.240.0/20", "130.211.0.0/22", "35.191.0.0/16"], src)
    ])
    error_message = "the app port is reachable from a source that is neither the IAP range nor a Google health-check range"
  }

  assert {
    condition = length(setintersection(
      setunion(
        google_compute_firewall.allow_iap_app_port.source_ranges,
        google_compute_firewall.allow_health_checks.source_ranges,
      ),
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the app port must never be reachable from the whole internet"
  }

  # The SSH rule does not open the app port. If it did, the split would be
  # undone and the rule listing would misdescribe the exposure.
  assert {
    condition     = !contains(one(google_compute_firewall.allow_iap_ssh.allow).ports, "30754")
    error_message = "the SSH rule must not open the app port; that is allow_iap_app_port's job and the two are separate exposures"
  }

  # The health-check rule is unchanged by any of this: same two Google ranges,
  # still tracking app_port, still scoped to the runtime SA.
  assert {
    condition = google_compute_firewall.allow_health_checks.source_ranges == toset([
      "130.211.0.0/22", "35.191.0.0/16",
    ])
    error_message = "the health-check rule's sources must remain exactly the two GCP probe ranges"
  }

  assert {
    condition     = one(google_compute_firewall.allow_health_checks.allow).ports == tolist(["30754"])
    error_message = "the health-check rule must still track app_port"
  }

  assert {
    condition     = google_compute_firewall.allow_health_checks.target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "the health-check rule must remain scoped to the runtime service account"
  }
}

# ---------------------------------------------------------------------------
# ISC-86/87: health checks from exactly the two GCP ranges, on exactly the app
# port. Run with a non-default app_port so a hardcoded 8080 fails here.
# ---------------------------------------------------------------------------

run "health_checks_reach_only_the_app_port_from_only_google" {
  command = plan

  variables {
    app_port = 9443
  }

  assert {
    condition     = length(google_compute_firewall.allow_health_checks.source_ranges) == 2
    error_message = "the health-check rule must have exactly two source ranges"
  }

  assert {
    condition = google_compute_firewall.allow_health_checks.source_ranges == toset([
      "130.211.0.0/22", "35.191.0.0/16",
    ])
    error_message = "the health-check rule's sources must be exactly the two GCP probe ranges"
  }

  assert {
    condition     = one(google_compute_firewall.allow_health_checks.allow).ports == tolist(["9443"])
    error_message = "the health-check rule must open only the app port, and must track it"
  }

  assert {
    condition     = google_compute_firewall.allow_health_checks.target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "the health-check rule must be scoped to the runtime service account"
  }
}

# ---------------------------------------------------------------------------
# Egress. The proposal's named threat is "NAT is not egress control", so the
# evaluated default must be a deny that exists, and the public allowlist must
# evaluate to no rule at all.
# ---------------------------------------------------------------------------

run "egress_defaults_closed" {
  command = plan

  assert {
    condition     = length(google_compute_firewall.deny_all_egress) == 1
    error_message = "the default-deny egress rule must exist by default, not opt-in"
  }

  assert {
    condition     = google_compute_firewall.deny_all_egress[0].direction == "EGRESS"
    error_message = "the default-deny egress rule must be an egress rule"
  }

  assert {
    condition     = one(google_compute_firewall.deny_all_egress[0].deny).protocol == "all"
    error_message = "the default-deny egress rule must deny every protocol"
  }

  # No public HTTPS rule at all, rather than a rule with an empty destination
  # list — an empty list on a firewall is a shape the provider may widen.
  assert {
    condition     = length(google_compute_firewall.allow_egress_public_https) == 0
    error_message = "public HTTPS egress must produce no rule until an operator names destinations"
  }

  # And the deny sits below every allow, or the allows never apply.
  assert {
    condition     = google_compute_firewall.deny_all_egress[0].priority > google_compute_firewall.allow_egress_dns.priority
    error_message = "the egress deny must have a lower precedence than the egress allows"
  }

  assert {
    condition     = google_compute_firewall.deny_all_ingress.priority > google_compute_firewall.allow_iap_ssh.priority
    error_message = "the ingress deny must have a lower precedence than the ingress allows"
  }
}

# ---------------------------------------------------------------------------
# EGRESS-RULE-01/02: the public egress ports.
#
# The default is the security-relevant half. A module that defaults to
# ["80","443"] opens plaintext egress for every environment that never asked,
# and no functional test anywhere notices — the estate builds fine, which is
# exactly the problem. So the first assertion is on the DEFAULT, stated as an
# exact-set equality rather than as "443 is present".
# ---------------------------------------------------------------------------

run "public_egress_defaults_to_443_and_only_443" {
  command = plan

  variables {
    egress_public_https_destinations = ["192.0.2.0/24"]
    # egress_public_ports deliberately NOT set: this run is about the default.
  }

  assert {
    condition     = one(google_compute_firewall.allow_egress_public_https[0].allow).ports == tolist(["443"])
    error_message = "the public egress default must be exactly [\"443\"]; adding 80 to the module default opens plaintext egress for every environment silently"
  }

  # Belt and braces on the specific value that matters. The equality above
  # already covers it, but this one names the failure in the message, so a
  # future reader of a red run learns what was added rather than only that a
  # list differed.
  assert {
    condition     = !contains(one(google_compute_firewall.allow_egress_public_https[0].allow).ports, "80")
    error_message = "port 80 must never be in the module default; opening plaintext egress is a per-environment decision made in a reviewed tfvars file"
  }
}

run "a_configured_port_list_reaches_the_firewall_rule" {
  command = plan

  variables {
    egress_public_https_destinations = ["192.0.2.0/24"]
    egress_public_ports              = ["80", "443"]
  }

  assert {
    condition     = one(google_compute_firewall.allow_egress_public_https[0].allow).ports == tolist(["80", "443"])
    error_message = "egress_public_ports must reach the rule; a hardcoded list ignores the environment and the image build fails on http://deb.debian.org"
  }

  # The scoping is asserted POSITIVELY — the rule must name this SA — rather
  # than as "no wildcard target". An absence assertion is satisfied hardest by
  # a rule that does not exist at all, which is the inversion this repo has
  # been bitten by before.
  assert {
    condition     = google_compute_firewall.allow_egress_public_https[0].target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "the public egress rule must be scoped to the runtime service account; unscoped, it grants plaintext egress to every instance in the VPC"
  }

  assert {
    condition     = length(google_compute_firewall.allow_egress_public_https[0].target_service_accounts) == 1
    error_message = "the public egress rule must target exactly one service account"
  }

  # Widening egress must not disturb ingress. Asserted here rather than assumed,
  # because "I only opened an outbound port" is exactly the change someone makes
  # without re-reading the ingress rules.
  assert {
    condition     = one(google_compute_firewall.allow_iap_ssh.allow).ports == tolist(["22"])
    error_message = "an egress change must not alter the SSH ingress rule"
  }

  assert {
    condition     = google_compute_firewall.allow_iap_ssh.source_ranges == toset(["35.235.240.0/20"])
    error_message = "an egress change must not alter the IAP ingress source range"
  }

  assert {
    condition = google_compute_firewall.allow_health_checks.source_ranges == toset([
      "130.211.0.0/22", "35.191.0.0/16",
    ])
    error_message = "an egress change must not alter the health-check ingress sources"
  }

  assert {
    condition     = google_compute_firewall.deny_all_ingress.direction == "INGRESS"
    error_message = "the default-deny ingress rule must survive an egress change"
  }

  assert {
    condition     = one(google_compute_firewall.deny_all_ingress.deny).protocol == "all"
    error_message = "the default-deny ingress rule must still deny every protocol"
  }
}

run "rejects_an_empty_public_egress_port_list" {
  command = plan

  variables {
    # A rule with no ports is a shape the provider may widen to ALL ports,
    # which is the opposite of what an empty list looks like it means.
    egress_public_ports = []
  }

  expect_failures = [var.egress_public_ports]
}

run "rejects_a_port_range_in_the_public_egress_ports" {
  command = plan

  variables {
    # "80-443" is 364 ports wearing the appearance of two.
    egress_public_ports = ["80-443"]
  }

  expect_failures = [var.egress_public_ports]
}

run "rejects_an_out_of_range_public_egress_port" {
  command = plan

  variables {
    egress_public_ports = ["443", "70000"]
  }

  expect_failures = [var.egress_public_ports]
}

run "naming_a_public_destination_creates_exactly_one_scoped_rule" {
  command = plan

  variables {
    # RFC5737 documentation ranges. Never a real registry range in a test.
    egress_public_https_destinations = ["192.0.2.0/24", "198.51.100.0/24"]
  }

  assert {
    condition     = length(google_compute_firewall.allow_egress_public_https) == 1
    error_message = "naming destinations must create the public HTTPS egress rule"
  }

  assert {
    condition     = one(google_compute_firewall.allow_egress_public_https[0].allow).ports == tolist(["443"])
    error_message = "the public egress rule must open 443 only"
  }

  assert {
    condition     = google_compute_firewall.allow_egress_public_https[0].target_service_accounts == toset([var.runtime_service_account_email])
    error_message = "even the opt-in public egress rule must be scoped to the runtime SA"
  }

  # The deny is still there. Opening a destination must not disable the policy.
  assert {
    condition     = length(google_compute_firewall.deny_all_egress) == 1
    error_message = "naming a public destination must not remove the default-deny egress rule"
  }
}

# ---------------------------------------------------------------------------
# ISC-89/92: no ALLOW rule anywhere in this module is sourced from, or
# destined for, the whole internet. Evaluated, so a variable that resolves to
# 0.0.0.0/0 is caught where a grep over the source would miss it.
#
# The deny rules legitimately name 0.0.0.0/0 and are excluded by construction:
# this expression only walks the allow rules.
# ---------------------------------------------------------------------------

run "no_allow_rule_is_open_to_the_world" {
  command = plan

  variables {
    # The hostile case: an operator "temporarily" allowlisting everything.
    egress_public_https_destinations = ["0.0.0.0/0"]
  }

  assert {
    condition = length(setintersection(
      google_compute_firewall.allow_iap_ssh.source_ranges,
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the SSH allow rule must never be sourced from the whole internet"
  }

  assert {
    condition = length(setintersection(
      google_compute_firewall.allow_health_checks.source_ranges,
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the health-check allow rule must never be sourced from the whole internet"
  }

  assert {
    condition = length(setintersection(
      google_compute_firewall.allow_iap_app_port.source_ranges,
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the IAP app-port allow rule must never be sourced from the whole internet"
  }

  assert {
    condition = length(setintersection(
      google_compute_firewall.allow_egress_dns.destination_ranges,
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the DNS egress allow must be pinned to the metadata server"
  }

  assert {
    condition = length(setintersection(
      google_compute_firewall.allow_egress_google_apis.destination_ranges,
      toset(["0.0.0.0/0", "::/0"]),
    )) == 0
    error_message = "the Google APIs egress allow must be pinned to the Private Google Access VIPs"
  }
}

# ---------------------------------------------------------------------------
# Negative tests. Each is paired with the baseline run above, which proves the
# same configuration plans cleanly once the offending input is corrected — a
# `run` that fails for an unrelated reason is indistinguishable from a
# validation firing correctly.
# ---------------------------------------------------------------------------

run "rejects_an_out_of_range_app_port" {
  command = plan

  variables {
    app_port = 70000
  }

  expect_failures = [var.app_port]
}

# ---------------------------------------------------------------------------
# NET-RULE-01: the IAP ingress source is immovable.
#
# The two halves are different claims and both are needed. The runs above
# assert the CURRENT value is Google's range — true of any correct config, and
# equally true of one that happens to be right today. This asserts that a wrong
# value is REFUSED, which is the property that survives the next edit.
#
# The rejected values below are the three plausible ones, in ascending order of
# how reasonable they look: an office CIDR, a broader Google-owned range that
# contains the right one, and the whole internet.
# ---------------------------------------------------------------------------

run "rejects_a_non_iap_ssh_source" {
  command = plan

  variables {
    # RFC5737 documentation range standing in for "my office".
    iap_source_range = "192.0.2.0/24"
  }

  expect_failures = [var.iap_source_range]
}

run "rejects_a_supernet_of_the_iap_range" {
  command = plan

  variables {
    # The subtle one. 35.235.0.0/16 CONTAINS 35.235.240.0/20, so SSH from IAP
    # keeps working and the widening is invisible in every functional test.
    iap_source_range = "35.235.0.0/16"
  }

  expect_failures = [var.iap_source_range]
}

run "rejects_the_whole_internet_as_an_iap_source" {
  command = plan

  variables {
    iap_source_range = "0.0.0.0/0"
  }

  expect_failures = [var.iap_source_range]
}

# The positive half. Passing the correct value EXPLICITLY, rather than relying
# on the default, is what proves the rule accepts it rather than that nothing
# evaluated it.
run "accepts_the_iap_range_when_stated_explicitly" {
  command = plan

  variables {
    iap_source_range = "35.235.240.0/20"
    app_port         = 30754
  }

  assert {
    condition     = google_compute_firewall.allow_iap_ssh.source_ranges == toset(["35.235.240.0/20"])
    error_message = "the explicitly-stated IAP range must reach the SSH rule"
  }

  assert {
    condition     = google_compute_firewall.allow_iap_app_port.source_ranges == toset(["35.235.240.0/20"])
    error_message = "the explicitly-stated IAP range must reach the app-port rule"
  }
}

run "rejects_an_empty_runtime_service_account" {
  command = plan

  variables {
    # An empty target scopes every firewall rule to the entire VPC.
    runtime_service_account_email = "   "
  }

  expect_failures = [var.runtime_service_account_email]
}

run "rejects_an_unknown_nat_log_filter" {
  command = plan

  variables {
    nat_log_filter = "SOMETIMES"
  }

  expect_failures = [var.nat_log_filter]
}

run "rejects_a_zero_flow_sampling_rate" {
  command = plan

  variables {
    # The subtle one: flow logs "enabled" while recording nothing.
    flow_log_sampling_rate = 0
  }

  expect_failures = [var.flow_log_sampling_rate]
}

run "rejects_an_invalid_flow_log_aggregation_interval" {
  command = plan

  variables {
    flow_log_aggregation_interval = "INTERVAL_3_SEC"
  }

  expect_failures = [var.flow_log_aggregation_interval]
}

# The positive half of the pairing, stated explicitly rather than left implicit
# in the baseline: every value rejected above has a neighbouring value that is
# accepted, so the validations are narrow rather than merely present.
run "accepts_the_corrected_inputs" {
  command = plan

  variables {
    app_port                      = 65535
    runtime_service_account_email = "sl-demo-1-runtime@CHANGEME-project.iam.gserviceaccount.com"
    nat_log_filter                = "ALL"
    flow_log_sampling_rate        = 1
    flow_log_aggregation_interval = "INTERVAL_30_SEC"
  }

  assert {
    condition     = one(google_compute_router_nat.this.log_config).filter == "ALL"
    error_message = "ALL is a valid NAT log filter and must be accepted"
  }

  assert {
    condition     = one(google_compute_subnetwork.this.log_config).flow_sampling == 1
    error_message = "a sampling rate of 1 is valid and must be accepted"
  }

  assert {
    condition     = one(google_compute_firewall.allow_health_checks.allow).ports == tolist(["65535"])
    error_message = "65535 is a valid app port and must be accepted"
  }
}
