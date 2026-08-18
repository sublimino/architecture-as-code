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
  # --- Access mode ---------------------------------------------------------
  # Three postures, derived once here so no resource re-interprets the string.
  #
  #   iap_enabled          IAP authenticates and authorises at the Google edge.
  #   allowlist_authorises Cloud Armor's IP allowlist is an authorisation control.
  #   admit_all_clients    Cloud Armor admits every source IP to the sign-in
  #                        boundary, because in pure "iap" mode there is no IP
  #                        restriction by design and IAP is what says no.
  #
  # Read modules/edge/README.md "Access modes" before changing any of these.
  iap_enabled          = contains(["iap", "iap_and_allowlist"], var.access_mode)
  allowlist_authorises = contains(["allowlist", "iap_and_allowlist"], var.access_mode)
  admit_all_clients    = var.access_mode == "iap"

  # Empty id selects the IAP-managed OAuth client: no brand to provision by
  # hand, and no client secret in tfvars or state.
  iap_managed_client = var.iap_oauth2_client_id == ""

  # The public frontend exists only when a hostname was supplied. Without one
  # there is no certificate to terminate TLS with, so we create no proxy and no
  # forwarding rule at all rather than leaving a half-built plaintext edge.
  tls_enabled = var.hostname != ""
  dns_enabled = var.hostname != "" && var.dns_managed_zone != ""

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

  # --- Identity-Aware Proxy ------------------------------------------------
  # This is the control that makes the edge non-public. The load balancer stays
  # externally addressable so there is a real hostname and a managed
  # certificate, but Google authenticates and authorises every request here,
  # before any byte reaches the backend. An unauthenticated visitor gets a
  # Google sign-in page, not the application.
  #
  # Omitting oauth2_client_id/secret selects the IAP-managed OAuth client. The
  # provider schema at google ~> 6.8 marks both optional, so this is supported
  # rather than assumed -- see NOTES.md for the schema check.
  dynamic "iap" {
    for_each = local.iap_enabled ? [1] : []

    content {
      enabled              = true
      oauth2_client_id     = local.iap_managed_client ? null : var.iap_oauth2_client_id
      oauth2_client_secret = local.iap_managed_client ? null : var.iap_oauth2_client_secret
    }
  }
}

# ---------------------------------------------------------------------------
# Who may pass IAP
#
# Enabling IAP without granting anyone httpsResourceAccessor produces an edge
# that authenticates every visitor and then refuses all of them. The variable
# validation makes an empty list unrepresentable under an IAP mode; this
# resource is what turns the named principals into actual access.
# ---------------------------------------------------------------------------

resource "google_iap_web_backend_service_iam_member" "accessors" {
  for_each = local.iap_enabled ? toset(var.iap_members) : toset([])

  project             = var.project_id
  web_backend_service = google_compute_backend_service.app.name
  role                = "roles/iap.httpsResourceAccessor"
  member              = each.value
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
