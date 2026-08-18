# ---------------------------------------------------------------------------
# TLS termination, the redirect-only port 80 listener, and the fail-closed
# behaviour of hostname = "".
#
# The property that matters here is structural: the port 80 listener must be
# incapable of reaching a backend, not merely configured not to. A url_map with
# no default_service and no path_matcher cannot serve content even if someone
# later points a forwarding rule at it by mistake.
# ---------------------------------------------------------------------------

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id             = "CHANGEME-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1", kind = "demo" }
  hostname               = "demo-1.example.invalid"
  dns_managed_zone       = "signalloom-demo"
  backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080
  allowed_ipv4           = ["192.0.2.0/24"]
  allowed_ipv6           = ["2001:db8::/32"]
}

run "ssl_policy_pins_tls_1_2_and_a_modern_profile" {
  command = plan

  assert {
    condition     = google_compute_ssl_policy.edge[0].min_tls_version == "TLS_1_2"
    error_message = "The evaluated SSL policy must pin min_tls_version to TLS_1_2. TLS 1.0 and 1.1 are not negotiable at a regulated-industry demo edge."
  }

  assert {
    condition     = google_compute_ssl_policy.edge[0].profile == "MODERN" || google_compute_ssl_policy.edge[0].profile == "RESTRICTED"
    error_message = "The SSL policy profile must evaluate to MODERN or RESTRICTED. COMPATIBLE re-admits the cipher suites the TLS floor was raised to exclude."
  }

  # The policy's id is computed and therefore unknown at plan under a mock, so
  # pin it and assert the proxy resolves to exactly that. This catches an
  # ssl_policy that was removed, hardcoded, or pointed at a different policy --
  # any of which would leave the TLS floor above configured but unenforced.
  override_resource {
    target          = google_compute_ssl_policy.edge[0]
    override_during = plan
    values = {
      id = "projects/CHANGEME-project/global/sslPolicies/sl-demo-1-ssl-policy"
    }
  }

  assert {
    condition     = google_compute_target_https_proxy.edge[0].ssl_policy == "projects/CHANGEME-project/global/sslPolicies/sl-demo-1-ssl-policy"
    error_message = "The HTTPS proxy's evaluated ssl_policy is not the id of google_compute_ssl_policy.edge, so the TLS floor above is configured but not enforced on any listener."
  }
}

run "https_listens_on_443_and_a_managed_certificate_exists" {
  command = plan

  assert {
    condition     = google_compute_global_forwarding_rule.https[0].port_range == "443"
    error_message = "The HTTPS global forwarding rule must evaluate to port_range 443."
  }

  assert {
    condition     = length(google_compute_managed_ssl_certificate.edge) == 1
    error_message = "Exactly one Google-managed SSL certificate must be planned when a hostname is supplied."
  }

  assert {
    condition     = contains(google_compute_managed_ssl_certificate.edge[0].managed[0].domains, var.hostname)
    error_message = "The managed certificate's evaluated domain list does not contain var.hostname, so TLS would be terminated for the wrong name."
  }
}

run "port_80_is_structurally_incapable_of_serving_content" {
  command = plan

  # A url_map with a default_url_redirect and nothing else has no backend to
  # reach. This is the assertion that ISC-126 asks for, expressed as a property
  # of the evaluated map rather than as the absence of a string in the source.
  assert {
    condition     = length(google_compute_url_map.http_redirect) == 1
    error_message = "The redirect-only url_map was not planned. The assertions below would then be measuring nothing."
  }

  assert {
    condition     = google_compute_url_map.http_redirect[0].default_url_redirect[0].https_redirect == true
    error_message = "The port 80 url_map must evaluate to https_redirect = true."
  }

  assert {
    condition     = google_compute_url_map.http_redirect[0].default_url_redirect[0].redirect_response_code == "MOVED_PERMANENTLY_DEFAULT"
    error_message = "The port 80 listener must issue a permanent (301) redirect."
  }

  assert {
    condition     = length(google_compute_url_map.http_redirect[0].path_matcher) == 0 && length(google_compute_url_map.http_redirect[0].host_rule) == 0
    error_message = "The redirect-only url_map has a path_matcher or host_rule. Any routing rule is a path by which port 80 could serve content instead of redirecting."
  }

  assert {
    condition     = google_compute_global_forwarding_rule.http_redirect[0].port_range == "80"
    error_message = "The redirect forwarding rule must evaluate to port_range 80."
  }

  # Prove the port-80 forwarding rule points at the redirect proxy and not at
  # the HTTPS proxy or anything else. The proxy id is computed, so pin it.
  override_resource {
    target          = google_compute_target_http_proxy.redirect[0]
    override_during = plan
    values = {
      id = "projects/CHANGEME-project/global/targetHttpProxies/sl-demo-1-http-proxy"
    }
  }

  assert {
    condition     = google_compute_global_forwarding_rule.http_redirect[0].target == "projects/CHANGEME-project/global/targetHttpProxies/sl-demo-1-http-proxy"
    error_message = "The port 80 forwarding rule does not target the redirect-only HTTP proxy."
  }
}

run "url_map_strips_client_supplied_identity_headers" {
  command = plan

  # The backend performs its own OIDC verification. Stripping these at the edge
  # removes the possibility of a forged client header being mistaken for an
  # assertion made by an authenticating proxy.
  assert {
    condition     = length(google_compute_url_map.https[0].path_matcher[0].header_action[0].request_headers_to_remove) > 0
    error_message = "The HTTPS url_map removes no request headers. A client-supplied identity header would reach the backend verbatim."
  }

  assert {
    condition = alltrue([
      for h in ["X-Goog-Authenticated-User-Email", "X-Forwarded-User", "X-Remote-User", "X-Signalloom-Tenant"] :
      contains(google_compute_url_map.https[0].path_matcher[0].header_action[0].request_headers_to_remove, h)
    ])
    error_message = "The evaluated header strip list is missing at least one identity header the application or its proxies could be induced to trust."
  }

  # X-Forwarded-For must NOT be stripped: the load balancer owns it and Cloud
  # Armor's source matching and logging depend on it.
  assert {
    condition = !contains(
      google_compute_url_map.https[0].path_matcher[0].header_action[0].request_headers_to_remove,
      "X-Forwarded-For"
    )
    error_message = "X-Forwarded-For is being stripped. That header is set by the load balancer, not the client, and removing it blinds Cloud Armor logging."
  }
}

run "dns_record_is_created_when_hostname_and_zone_are_both_present" {
  command = plan

  assert {
    condition     = length(google_dns_record_set.edge) == 1
    error_message = "A DNS A record must be planned when both hostname and dns_managed_zone are non-empty."
  }

  assert {
    condition     = google_dns_record_set.edge[0].type == "A"
    error_message = "The DNS record must evaluate to an A record."
  }

  assert {
    condition     = can(regex(var.environment_key, google_dns_record_set.edge[0].name))
    error_message = "The evaluated DNS record name does not embed the environment key."
  }
}

run "no_dns_record_without_a_managed_zone" {
  command = plan

  variables {
    dns_managed_zone = ""
  }

  assert {
    condition     = length(google_dns_record_set.edge) == 0
    error_message = "A DNS record was planned with no managed zone supplied."
  }

  # The load balancer itself must survive: only the DNS record is conditional
  # on the zone. Half-disabling the edge here would be the wrong failure mode.
  assert {
    condition     = length(google_compute_global_forwarding_rule.https) == 1 && length(google_compute_managed_ssl_certificate.edge) == 1
    error_message = "Removing dns_managed_zone also removed the load balancer. Only the DNS record depends on the zone."
  }
}

run "empty_hostname_plans_no_public_frontend_at_all" {
  command = plan

  variables {
    hostname         = ""
    dns_managed_zone = ""
  }

  # Fail closed, not half-created. Every public-facing resource disappears
  # together; there is no state in which a forwarding rule exists without the
  # certificate that terminates its TLS.
  assert {
    condition = alltrue([
      length(google_compute_managed_ssl_certificate.edge) == 0,
      length(google_dns_record_set.edge) == 0,
      length(google_compute_global_forwarding_rule.https) == 0,
      length(google_compute_global_forwarding_rule.http_redirect) == 0,
      length(google_compute_target_https_proxy.edge) == 0,
      length(google_compute_target_http_proxy.redirect) == 0,
      length(google_compute_global_address.edge) == 0,
      length(google_compute_url_map.https) == 0,
      length(google_compute_url_map.http_redirect) == 0,
      length(google_compute_ssl_policy.edge) == 0,
    ])
    error_message = "With hostname = \"\" at least one public frontend resource is still planned. The disable path must remove the whole chain, not part of it."
  }

  # The Cloud Armor policy and the backend service remain by design: the default
  # deny is the control that must exist even when nothing is exposed.
  assert {
    condition     = length(google_compute_security_policy.edge.rule) > 0
    error_message = "The Cloud Armor policy vanished along with the frontend. The default deny must survive so that attaching a frontend later cannot expose an unprotected backend."
  }
}

run "certificate_cannot_be_issued_for_another_environments_hostname" {
  command = plan

  variables {
    hostname = "demo-9.example.invalid"
  }

  # environment_key is still demo-1, so the certificate's precondition must fire.
  expect_failures = [google_compute_managed_ssl_certificate.edge]
}

# Paired positive for the negative run above. Without this, a precondition that
# fired for an unrelated reason -- a typo, a missing variable -- would be
# indistinguishable from the guard working correctly.
run "certificate_is_issued_when_hostname_matches_the_environment" {
  command = plan

  variables {
    hostname = "demo-1.example.invalid"
  }

  assert {
    condition     = length(google_compute_managed_ssl_certificate.edge) == 1
    error_message = "The corrected hostname must plan exactly one certificate. If this fails, the negative run above proves nothing about the precondition."
  }
}
