# ---------------------------------------------------------------------------
# Cloud Armor -- the load-bearing control.
#
# This resource lives alone in its own file on purpose. The mutation fixtures
# under test/fixtures/terraform/edge/ are drop-in replacements for THIS FILE,
# which is what lets the mutation checks swap in a broken policy and run the
# real tftest suite against it. Splitting a resource out of main.tf by line
# number in a test would be brittle; giving it a file makes the swap exact.
#
# The priority bands and the allowlist chunking arithmetic live here too, not in
# main.tf, so that a fixture can mutate the chunker itself. Silent truncation of
# the allowlist is the failure mode this module most needs to be able to fail on
# in a test, and a guard that cannot be shown to fail is not a guard.
# ---------------------------------------------------------------------------

locals {
  # Cloud Armor caps a single rule's src_ip_ranges at 10 CIDRs. Chunk rather
  # than truncate: silently dropping the 11th CIDR would lock a legitimate
  # operator out and look like a network fault, not a configuration error.
  armor_max_cidrs_per_rule = 10

  # Priority bands. Lower number is evaluated first.
  #   500-599    preconfigured WAF denies (apply to allowlisted traffic too)
  #   800-899    rate-limited allow, matched on the allowlist itself
  #   1000-1099  plain allow fail-safe, matched on the same allowlist
  #   2147483647 default deny(403)
  # The 500-entry cap on each allowlist keeps chunk indices below 100, so a
  # generated priority can never cross into the next band.
  waf_sqli_priority        = 500
  waf_xss_priority         = 510
  rate_limit_priority_base = 800
  allow_priority_base      = 1000
  default_rule_priority    = 2147483647

  raw_chunks = concat(
    [for i, c in chunklist(var.allowed_ipv4, local.armor_max_cidrs_per_rule) :
      { key = format("ipv4-%02d", i), ranges = c }
    ],
    [for i, c in chunklist(var.allowed_ipv6, local.armor_max_cidrs_per_rule) :
      { key = format("ipv6-%02d", i), ranges = c }
    ],
  )

  # One shared index across both address families. Indexing each family
  # separately would give an IPv4 chunk and an IPv6 chunk the same priority.
  allow_chunks = [
    for i, c in local.raw_chunks : {
      key            = c.key
      ranges         = c.ranges
      rate_priority  = local.rate_limit_priority_base + i
      allow_priority = local.allow_priority_base + i
    }
  ]
}

resource "google_compute_security_policy" "edge" {
  name        = "${var.name_prefix}-armor"
  project     = var.project_id
  type        = "CLOUD_ARMOR"
  description = "Default-deny edge policy for ${var.environment_key}. Allow rules are generated from the environment allowlist; the default action is deny(403)."

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  advanced_options_config {
    log_level    = "VERBOSE"
    json_parsing = "STANDARD"
  }

  # --- Preconfigured WAF, evaluated before any allow ---------------------
  # An allowlisted source is still not trusted to send SQLi or XSS.

  rule {
    action      = "deny(403)"
    priority    = local.waf_sqli_priority
    preview     = false
    description = "Preconfigured WAF: SQL injection."

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = local.waf_xss_priority
    preview     = false
    description = "Preconfigured WAF: cross-site scripting."

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }
  }

  # --- Rate-limited allow -------------------------------------------------
  # Matched on the allowlist, NOT on "*". A rate-limit rule whose match is "*"
  # with conform_action = "allow" would allow the entire internet under the
  # threshold and silently defeat the default deny below.

  dynamic "rule" {
    for_each = local.allow_chunks

    content {
      action      = "rate_based_ban"
      priority    = rule.value.rate_priority
      preview     = false
      description = "Rate-limited allow for allowlist chunk ${rule.value.key} (${length(rule.value.ranges)} CIDRs)."

      match {
        versioned_expr = "SRC_IPS_V1"

        config {
          src_ip_ranges = rule.value.ranges
        }
      }

      rate_limit_options {
        conform_action   = "allow"
        exceed_action    = "deny(429)"
        enforce_on_key   = "IP"
        ban_duration_sec = var.rate_limit_ban_duration_sec

        rate_limit_threshold {
          count        = var.rate_limit_threshold_per_minute
          interval_sec = 60
        }

        ban_threshold {
          count        = var.rate_limit_threshold_per_minute
          interval_sec = 60
        }
      }
    }
  }

  # --- Plain allow fail-safe ---------------------------------------------
  # Unreachable while the rate-limited rules above exist, and deliberately so:
  # the source ranges are identical, so deleting a rate-limit rule degrades to
  # "allowed but unthrottled" instead of "denied". It can never widen exposure.

  dynamic "rule" {
    for_each = local.allow_chunks

    content {
      action      = "allow"
      priority    = rule.value.allow_priority
      preview     = false
      description = "Allowlist fail-safe for chunk ${rule.value.key}; identical ranges to priority ${rule.value.rate_priority}."

      match {
        versioned_expr = "SRC_IPS_V1"

        config {
          src_ip_ranges = rule.value.ranges
        }
      }
    }
  }

  # --- Default deny -------------------------------------------------------
  # This is the load-bearing line. Everything above is an explicit exception
  # to it. If this rule's action ever becomes "allow", the edge is open.

  rule {
    action      = "deny(403)"
    priority    = local.default_rule_priority
    preview     = false
    description = "Default deny. Anything not explicitly allowlisted above is rejected."

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}
