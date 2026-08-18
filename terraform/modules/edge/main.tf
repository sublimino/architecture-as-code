# ---------------------------------------------------------------------------
# Signal Loom secure HTTPS edge.
#
# Replaces the ngrok tunnel with a global external Application Load Balancer
# fronted by a Cloud Armor policy whose DEFAULT ACTION IS DENY. Every allow is
# explicit, logged, rate-limited, and generated from data.
#
# Read modules/edge/README.md before changing anything in this file. In
# particular: the IP allowlist is exposure control, NOT authentication.
# ---------------------------------------------------------------------------

locals {
  # The public frontend exists only when a hostname was supplied. Without one
  # there is no certificate to terminate TLS with, so we create no proxy and no
  # forwarding rule at all rather than leaving a half-built plaintext edge.
  tls_enabled = var.hostname != ""
  dns_enabled = var.hostname != "" && var.dns_managed_zone != ""

  # Cloud Armor caps a single rule's src_ip_ranges at 10 CIDRs. Chunk rather
  # than truncate: silently dropping the 11th CIDR would lock a legitimate
  # operator out and look like a network fault.
  armor_max_cidrs_per_rule = 10

  # Priority bands. Lower number is evaluated first.
  #   500-599   preconfigured WAF denies (apply to allowlisted traffic too)
  #   800-899   rate-limited allow, matched on the allowlist itself
  #   1000-1099 plain allow fail-safe, matched on the same allowlist
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

  allow_chunks = [
    for i, c in local.raw_chunks : {
      key            = c.key
      ranges         = c.ranges
      rate_priority  = local.rate_limit_priority_base + i
      allow_priority = local.allow_priority_base + i
    }
  ]

  # Client-supplied identity headers stripped at the edge. The backend must not
  # trust any of these; they are removed so that a header injected by a client
  # can never be mistaken for one asserted by an authenticating proxy.
  # X-Forwarded-For is deliberately NOT in this list: the load balancer owns it
  # and Cloud Armor logging depends on it.
  untrusted_identity_headers = [
    "X-Auth-Request-Email",
    "X-Auth-Request-Groups",
    "X-Auth-Request-User",
    "X-Forwarded-Client-Cert",
    "X-Forwarded-Email",
    "X-Forwarded-User",
    "X-Goog-Authenticated-User-Email",
    "X-Goog-Authenticated-User-Id",
    "X-Goog-Iap-Jwt-Assertion",
    "X-Remote-Groups",
    "X-Remote-User",
    "X-Signalloom-Role",
    "X-Signalloom-Tenant",
  ]

  backend_timeout_sec = 30
}

# ---------------------------------------------------------------------------
# Cloud Armor -- the load-bearing control
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Backend service and health check
# ---------------------------------------------------------------------------

resource "google_compute_health_check" "app" {
  name                = "${var.name_prefix}-hc"
  project             = var.project_id
  description         = "Health check for ${var.environment_key} on app port ${var.app_port}."
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = var.app_port
    request_path = var.health_check_path
  }

  log_config {
    enable = true
  }
}

resource "google_compute_backend_service" "app" {
  name                  = "${var.name_prefix}-backend"
  project               = var.project_id
  description           = "Signal Loom application backend for ${var.environment_key}."
  protocol              = "HTTP"
  port_name             = var.backend_port_name
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = local.backend_timeout_sec
  enable_cdn            = var.enable_cdn
  health_checks         = [google_compute_health_check.app.id]
  security_policy       = google_compute_security_policy.edge.id

  backend {
    group           = var.backend_instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }

  dynamic "cdn_policy" {
    for_each = var.enable_cdn ? [1] : []

    content {
      cache_mode        = "CACHE_ALL_STATIC"
      client_ttl        = 300
      default_ttl       = 300
      max_ttl           = 3600
      negative_caching  = false
      serve_while_stale = 0
    }
  }
}

# ---------------------------------------------------------------------------
# HTTPS frontend -- created only when a hostname exists
# ---------------------------------------------------------------------------

resource "google_compute_global_address" "edge" {
  count = local.tls_enabled ? 1 : 0

  name         = "${var.name_prefix}-lb-ip"
  project      = var.project_id
  description  = "Global anycast address for the ${var.environment_key} edge."
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

resource "google_compute_managed_ssl_certificate" "edge" {
  count = local.tls_enabled ? 1 : 0

  name        = "${var.name_prefix}-cert"
  project     = var.project_id
  description = "Google-managed certificate for ${var.hostname}."
  type        = "MANAGED"

  managed {
    domains = [var.hostname]
  }

  lifecycle {
    precondition {
      condition     = can(regex(var.environment_key, var.hostname))
      error_message = "hostname (\"${var.hostname}\") must embed environment_key (\"${var.environment_key}\") so a certificate can never be issued for the wrong environment's name."
    }
  }
}

resource "google_compute_ssl_policy" "edge" {
  count = local.tls_enabled ? 1 : 0

  name            = "${var.name_prefix}-ssl-policy"
  project         = var.project_id
  description     = "Modern profile, TLS 1.2 floor. TLS 1.0 and 1.1 are not negotiable."
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_url_map" "https" {
  count = local.tls_enabled ? 1 : 0

  name            = "${var.name_prefix}-urlmap"
  project         = var.project_id
  description     = "Routes all hosts to the Signal Loom backend, stripping client-supplied identity headers."
  default_service = google_compute_backend_service.app.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "all"
  }

  path_matcher {
    name            = "all"
    default_service = google_compute_backend_service.app.id

    # Remove any identity header a client may have forged. The backend still
    # performs its own OIDC verification; this only removes the possibility of
    # confusing a client header with a proxy assertion.
    header_action {
      request_headers_to_remove = local.untrusted_identity_headers
    }
  }
}

resource "google_compute_target_https_proxy" "edge" {
  count = local.tls_enabled ? 1 : 0

  name             = "${var.name_prefix}-https-proxy"
  project          = var.project_id
  description      = "HTTPS termination for ${var.hostname}."
  url_map          = google_compute_url_map.https[0].id
  ssl_certificates = [google_compute_managed_ssl_certificate.edge[0].id]
  ssl_policy       = google_compute_ssl_policy.edge[0].id
}

resource "google_compute_global_forwarding_rule" "https" {
  count = local.tls_enabled ? 1 : 0

  name                  = "${var.name_prefix}-https-fr"
  project               = var.project_id
  description           = "Public HTTPS entry point for ${var.environment_key}."
  target                = google_compute_target_https_proxy.edge[0].id
  port_range            = "443"
  ip_address            = google_compute_global_address.edge[0].id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  labels                = var.labels
}

# ---------------------------------------------------------------------------
# Port 80 -- redirect only, never content
#
# This URL map has no default_service and no path_matcher. It is structurally
# incapable of reaching a backend: every request it receives becomes a 301.
# ---------------------------------------------------------------------------

resource "google_compute_url_map" "http_redirect" {
  count = local.tls_enabled ? 1 : 0

  name        = "${var.name_prefix}-http-redirect"
  project     = var.project_id
  description = "Port 80 listener that only issues 301 redirects to HTTPS. It serves no content and references no backend service."

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  count = local.tls_enabled ? 1 : 0

  name        = "${var.name_prefix}-http-proxy"
  project     = var.project_id
  description = "Redirect-only HTTP proxy for ${var.environment_key}."
  url_map     = google_compute_url_map.http_redirect[0].id
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  count = local.tls_enabled ? 1 : 0

  name                  = "${var.name_prefix}-http-fr"
  project               = var.project_id
  description           = "Port 80 listener bound to the redirect-only proxy."
  target                = google_compute_target_http_proxy.redirect[0].id
  port_range            = "80"
  ip_address            = google_compute_global_address.edge[0].id
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  labels                = var.labels
}

# ---------------------------------------------------------------------------
# DNS -- only when both a hostname and a managed zone were supplied
# ---------------------------------------------------------------------------

resource "google_dns_record_set" "edge" {
  count = local.dns_enabled ? 1 : 0

  name         = endswith(var.hostname, ".") ? var.hostname : "${var.hostname}."
  project      = var.project_id
  managed_zone = var.dns_managed_zone
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.edge[0].address]
}
