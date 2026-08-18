# ---------------------------------------------------------------------------
# Allowlist chunking and input validation.
#
# Cloud Armor caps a single rule's src_ip_ranges at 10 CIDRs. The module chunks
# the allowlist rather than truncating it. Truncation is the dangerous failure
# because it is silent and asymmetric: the 11th CIDR simply stops working, the
# operator sees a 403, and the obvious diagnosis -- "the allowlist is wrong" --
# is exactly the wrong one.
#
# The only assertion that catches truncation is a COUNT. "Some allow rules were
# planned" is true whether 25 CIDRs or 10 survived.
# ---------------------------------------------------------------------------

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  # Chunking only happens when the allowlist is an authorisation control, so
  # this file is pinned to allowlist mode. Under the "iap" default the allow
  # band is a single wildcard chunk and there is nothing to chunk.
  access_mode            = "allowlist"
  project_id             = "CHANGEME-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1", kind = "demo" }
  hostname               = "demo-1.example.invalid"
  dns_managed_zone       = "signalloom-demo"
  backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080

  # 25 distinct CIDRs carved out of the two RFC5737 documentation ranges:
  # 16 /28s from 192.0.2.0/24 plus 9 from 198.51.100.0/24.
  allowed_ipv4 = concat(
    [for i in range(16) : cidrsubnet("192.0.2.0/24", 4, i)],
    [for i in range(9) : cidrsubnet("198.51.100.0/24", 4, i)],
  )
  allowed_ipv6 = []
}

run "twenty_five_cidrs_survive_chunking_intact" {
  command = plan

  # Existence first. If no allow rule was planned at all, every assertion below
  # about "no rule exceeds 10" would pass vacuously.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow"
    ]) == 3
    error_message = "Expected exactly 3 plain-allow rules for 25 IPv4 CIDRs (ceil(25/10) = 3). A different count means the chunking arithmetic changed."
  }

  # The count that catches truncation. distinct() guards against a chunking bug
  # that duplicates entries across rules to reach the right total.
  assert {
    condition = length(distinct(flatten([
      for r in google_compute_security_policy.edge.rule :
      try(r.match[0].config[0].src_ip_ranges, [])
      if r.action == "allow"
    ]))) == 25
    error_message = "The union of src_ip_ranges across the evaluated allow rules is not 25 distinct CIDRs. Entries were dropped (silent truncation) or duplicated to pad the count."
  }

  # Set equality with the input, not just cardinality: 25 of the wrong CIDRs
  # would satisfy the count assertion above.
  assert {
    condition = setunion(distinct(flatten([
      for r in google_compute_security_policy.edge.rule :
      try(r.match[0].config[0].src_ip_ranges, [])
      if r.action == "allow"
    ])), toset(var.allowed_ipv4)) == toset(var.allowed_ipv4)
    error_message = "The evaluated allow rules cover a set of CIDRs that is not exactly var.allowed_ipv4. Something was added, dropped, or rewritten in transit."
  }

  # The constraint that forced chunking in the first place.
  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      length(try(r.match[0].config[0].src_ip_ranges, [])) <= 10
      if r.action == "allow" || r.action == "rate_based_ban"
    ])
    error_message = "An evaluated rule carries more than 10 src_ip_ranges. Cloud Armor rejects such a rule at apply time, which would turn a plan that looks correct into a failed deployment."
  }

  # Every chunk must also be rate-limited, or a chunk boundary becomes a hole
  # in the throttling that nothing else reports.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "rate_based_ban"
    ]) == 3
    error_message = "The rate-limited rule count does not match the allow rule count, so at least one allowlist chunk is admitted without a rate limit."
  }

  # Generated priorities must not collide. A collision is rejected by the API,
  # not by the plan, so this is only visible as an arithmetic property here.
  assert {
    condition = length(distinct([
      for r in google_compute_security_policy.edge.rule : r.priority
    ])) == length(google_compute_security_policy.edge.rule)
    error_message = "Two evaluated Cloud Armor rules share a priority. Generated priorities from the chunk index have collided with each other or crossed into another band."
  }

  # Chunked allow rules must still be evaluated after the default deny's
  # priority band, i.e. numerically well below 2147483647.
  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      r.priority < 2147483647
      if r.action == "allow" || r.action == "rate_based_ban"
    ])
    error_message = "An allow rule has a priority at or above the default deny's, so it would never be reached -- or worse, would displace the default rule."
  }
}

run "ipv4_and_ipv6_chunks_coexist_without_colliding" {
  command = plan

  variables {
    allowed_ipv4 = [for i in range(12) : cidrsubnet("192.0.2.0/24", 4, i)]
    allowed_ipv6 = [for i in range(11) : cidrsubnet("2001:db8::/32", 8, i)]
  }

  # 12 IPv4 -> 2 chunks, 11 IPv6 -> 2 chunks. Both lists cross the boundary, so
  # a chunker that indexed the two families independently would collide here.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow"
    ]) == 4
    error_message = "Expected 4 allow rules for 12 IPv4 + 11 IPv6 CIDRs (2 chunks each)."
  }

  assert {
    condition = length(distinct(flatten([
      for r in google_compute_security_policy.edge.rule :
      try(r.match[0].config[0].src_ip_ranges, [])
      if r.action == "allow"
    ]))) == 23
    error_message = "The union of allow-rule CIDRs is not 23. IPv4 and IPv6 chunks are overwriting one another or one family was dropped."
  }

  assert {
    condition = length(distinct([
      for r in google_compute_security_policy.edge.rule : r.priority
    ])) == length(google_compute_security_policy.edge.rule)
    error_message = "IPv4 and IPv6 chunk priorities collided."
  }
}

run "an_empty_allowlist_leaves_only_the_default_deny" {
  command = plan

  variables {
    allowed_ipv4 = []
    allowed_ipv6 = []
  }

  # The safe state. Supplying no allowlist must not fall back to allowing
  # everything -- the classic empty-list-means-any inversion.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow" || r.action == "rate_based_ban"
    ]) == 0
    error_message = "An empty allowlist produced allow rules. An empty list must mean \"nothing is allowed\", never \"everything is allowed\"."
  }

  assert {
    condition = one([
      for r in google_compute_security_policy.edge.rule : r.action
      if r.priority == 2147483647
    ]) == "deny(403)"
    error_message = "The default deny must still be present when the allowlist is empty."
  }
}

# ---------------------------------------------------------------------------
# Input validation. Each expect_failures run is paired with a positive run
# proving the same configuration plans cleanly once the offending input is
# corrected -- otherwise a syntax error would be indistinguishable from the
# validation rule firing.
# ---------------------------------------------------------------------------

run "rejects_ipv4_default_route_in_the_allowlist" {
  command = plan

  variables {
    allowed_ipv4 = ["192.0.2.0/24", "0.0.0.0/0"]
  }

  expect_failures = [var.allowed_ipv4]
}

run "accepts_the_same_ipv4_allowlist_without_the_default_route" {
  command = plan

  variables {
    allowed_ipv4 = ["192.0.2.0/24"]
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow"
    ]) == 1
    error_message = "The corrected allowlist must plan one allow rule. Without this, the rejection above proves nothing about the 0.0.0.0/0 rule specifically."
  }
}

run "rejects_ipv6_default_route_in_the_allowlist" {
  command = plan

  variables {
    allowed_ipv6 = ["2001:db8::/32", "::/0"]
  }

  expect_failures = [var.allowed_ipv6]
}

run "accepts_the_same_ipv6_allowlist_without_the_default_route" {
  command = plan

  variables {
    allowed_ipv4 = []
    allowed_ipv6 = ["2001:db8::/32"]
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "allow"
    ]) == 1
    error_message = "The corrected IPv6 allowlist must plan one allow rule."
  }
}

run "rejects_a_zero_rate_limit_threshold" {
  command = plan

  variables {
    rate_limit_threshold_per_minute = 0
  }

  expect_failures = [var.rate_limit_threshold_per_minute]
}

run "accepts_an_explicit_finite_rate_limit_threshold" {
  command = plan

  variables {
    rate_limit_threshold_per_minute = 120
  }

  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      r.rate_limit_options[0].rate_limit_threshold[0].count == 120
      if r.action == "rate_based_ban"
    ])
    error_message = "An explicitly supplied threshold of 120 did not reach the evaluated rate_based_ban rules."
  }
}

run "rejects_an_environment_key_outside_the_demo_ci_namespace" {
  command = plan

  variables {
    environment_key = "prod-1"
  }

  expect_failures = [var.environment_key]
}

run "accepts_a_valid_ci_environment_key" {
  command = plan

  variables {
    environment_key = "ci-2"
    name_prefix     = "sl-ci-2"
    hostname        = "ci-2.example.invalid"
  }

  assert {
    condition     = can(regex("ci-2", google_compute_security_policy.edge.name))
    error_message = "A valid ci- environment key must plan cleanly and embed itself in the policy name."
  }
}
