# ---------------------------------------------------------------------------
# Cloud Armor posture -- asserted on the EVALUATED plan, not on HCL text.
#
# A grep can tell you the file contains the string "deny(403)". It cannot tell
# you which rule got that action after locals, dynamic blocks and for_each
# resolved. These assertions read the attributes Terraform actually computed.
#
# mock_provider means no credentials, no network, no real project.
# command = plan only -- apply against a mock still writes state.
# ---------------------------------------------------------------------------

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id             = "CHANGEME-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1", kind = "demo", managed-by = "terraform" }
  hostname               = "demo-1.example.invalid"
  dns_managed_zone       = "signalloom-demo"
  backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080
  allowed_ipv4           = ["192.0.2.0/24", "198.51.100.0/24"]
  allowed_ipv6           = ["2001:db8::/32"]
}

run "default_rule_is_deny_403" {
  command = plan

  # one() returns null for an empty list, so this fails both when the default
  # rule was flipped to allow AND when it was deleted outright. A test that only
  # checked "no rule at 2147483647 is an allow" would pass vacuously if the rule
  # were removed, which is the more dangerous mutation of the two.
  assert {
    condition = one([
      for r in google_compute_security_policy.edge.rule : r.action
      if r.priority == 2147483647
    ]) == "deny(403)"
    error_message = "The Cloud Armor rule at priority 2147483647 must exist and its evaluated action must be exactly deny(403). This is the load-bearing line of the whole edge: if it is allow, or absent, the internet reaches the backend."
  }
}

run "no_rule_is_left_in_preview" {
  command = plan

  # preview = true logs a rule's verdict without enforcing it. A default deny in
  # preview is an open edge that produces reassuring logs.
  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r.priority
      if r.preview
    ]) == 0
    error_message = "At least one evaluated Cloud Armor rule has preview = true. A previewed rule is logged but not enforced, so the policy reports decisions it never made."
  }

  # Existence guard: the assertion above is trivially satisfied by a policy with
  # no rules at all. Pin the expected rule count for this input so a vanished
  # rule set cannot read as "nothing in preview".
  #   2 WAF + 2 allowlist chunks x 2 (rate-limited + fail-safe) + 1 default = 7
  assert {
    condition     = length(google_compute_security_policy.edge.rule) == 7
    error_message = "Expected exactly 7 evaluated Cloud Armor rules for this input (2 WAF, 2 chunks x 2 allow rules, 1 default deny). A different count means rules were added or lost, and the preview assertion above may be measuring an empty set."
  }
}

run "rate_limit_rule_has_a_finite_threshold_and_ban" {
  command = plan

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if r.action == "rate_based_ban"
      && try(r.rate_limit_options[0].rate_limit_threshold[0].count, 0) > 0
      && try(r.rate_limit_options[0].rate_limit_threshold[0].interval_sec, 0) > 0
      && try(r.rate_limit_options[0].ban_duration_sec, 0) > 0
    ]) > 0
    error_message = "No evaluated rule performs rate_based_ban with a positive threshold count, a positive interval, and a finite ban duration. An unbounded or absent rate limit leaves an allowlisted source free to exhaust the backend."
  }

  # The threshold must come from the variable, not from a hardcoded constant
  # that happens to look reasonable.
  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      r.rate_limit_options[0].rate_limit_threshold[0].count == var.rate_limit_threshold_per_minute
      if r.action == "rate_based_ban"
    ])
    error_message = "A rate_based_ban rule's evaluated threshold does not equal var.rate_limit_threshold_per_minute, so the input is not actually wired to the enforced value."
  }

  # A rate-limit rule whose match is "*" with conform_action = allow would admit
  # the entire internet below the threshold and silently defeat the default deny.
  assert {
    condition = alltrue([
      for r in google_compute_security_policy.edge.rule :
      !contains(try(r.match[0].config[0].src_ip_ranges, []), "*")
      if r.action == "rate_based_ban" || r.action == "allow"
    ])
    error_message = "An allow or rate_based_ban rule matches src_ip_ranges \"*\". Any allow matched on the wildcard defeats the default deny regardless of what priority 2147483647 says."
  }
}

run "logging_is_verbose_and_adaptive_protection_is_on" {
  command = plan

  assert {
    condition     = google_compute_security_policy.edge.advanced_options_config[0].log_level == "VERBOSE"
    error_message = "advanced_options_config.log_level must evaluate to VERBOSE. Without it a deny records the verdict but not the matched rule, so a denial cannot be attributed after the fact."
  }

  assert {
    condition     = google_compute_security_policy.edge.adaptive_protection_config[0].layer_7_ddos_defense_config[0].enable
    error_message = "Adaptive protection (Layer 7 DDoS defence) must evaluate to enabled."
  }
}

run "preconfigured_waf_covers_sqli_and_xss" {
  command = plan

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if can(regex("sqli-", try(r.match[0].expr[0].expression, ""))) && r.action == "deny(403)"
    ]) == 1
    error_message = "Expected exactly one enforced deny rule referencing a preconfigured SQLi expression. An allowlisted source is still not trusted to send SQL injection."
  }

  assert {
    condition = length([
      for r in google_compute_security_policy.edge.rule : r
      if can(regex("xss-", try(r.match[0].expr[0].expression, ""))) && r.action == "deny(403)"
    ]) == 1
    error_message = "Expected exactly one enforced deny rule referencing a preconfigured XSS expression."
  }

  # WAF rules must be evaluated BEFORE any allow, or an allowlisted source would
  # be admitted without ever being inspected.
  assert {
    condition = alltrue(flatten([
      for waf in google_compute_security_policy.edge.rule : [
        for allow in google_compute_security_policy.edge.rule :
        waf.priority < allow.priority
        if allow.action == "allow" || allow.action == "rate_based_ban"
      ]
      if can(regex("(sqli|xss)-", try(waf.match[0].expr[0].expression, "")))
    ]))
    error_message = "A preconfigured WAF rule has a numerically higher priority than an allow rule, so allowlisted traffic would be admitted before the WAF ever inspected it."
  }
}

run "policy_is_attached_to_the_backend_service" {
  command = plan

  # The policy's id is computed, so under a mock provider it is unknown at plan
  # time and any condition touching it errors out. Pinning it with an override
  # makes the reference observable: if security_policy were hardcoded, pointed
  # at another policy, or removed, the equality below would not hold.
  override_resource {
    target          = google_compute_security_policy.edge
    override_during = plan
    values = {
      id = "projects/CHANGEME-project/global/securityPolicies/sl-demo-1-armor"
    }
  }

  assert {
    condition     = google_compute_backend_service.app.security_policy == "projects/CHANGEME-project/global/securityPolicies/sl-demo-1-armor"
    error_message = "The backend service's evaluated security_policy is not the id of google_compute_security_policy.edge. A perfectly configured Cloud Armor policy that is not bound to a backend enforces nothing."
  }

  assert {
    condition     = google_compute_backend_service.app.log_config[0].enable && google_compute_backend_service.app.log_config[0].sample_rate == 1.0
    error_message = "Backend service logging must evaluate to enabled at sample_rate 1.0. A sampled log of a security boundary is a log you cannot answer questions with."
  }
}

run "cdn_is_off_by_default" {
  command = plan

  variables {
    # Deliberately not setting enable_cdn: this run asserts the DEFAULT.
    project_id             = "CHANGEME-project"
    environment_key        = "demo-1"
    name_prefix            = "sl-demo-1"
    labels                 = { environment = "demo-1" }
    hostname               = "demo-1.example.invalid"
    backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
    app_port               = 8080
    allowed_ipv4           = ["192.0.2.0/24"]
  }

  assert {
    condition     = google_compute_backend_service.app.enable_cdn == false
    error_message = "enable_cdn must evaluate to false when the caller does not opt in. A cache in front of an authenticated application is a cross-tenant disclosure risk."
  }

  assert {
    condition     = length(google_compute_backend_service.app.cdn_policy) == 0
    error_message = "A cdn_policy block was planned while enable_cdn is false. The CDN configuration must disappear entirely, not sit dormant."
  }
}

run "resource_names_embed_the_environment_key" {
  command = plan

  assert {
    condition = alltrue([
      can(regex("demo-1", google_compute_security_policy.edge.name)),
      can(regex("demo-1", google_compute_backend_service.app.name)),
      can(regex("demo-1", google_compute_health_check.app.name)),
    ])
    error_message = "Evaluated resource names must embed the environment key so two environments in one project can never collide or be confused during an incident."
  }

  assert {
    condition     = google_compute_health_check.app.http_health_check[0].port == var.app_port
    error_message = "The health check port does not evaluate to var.app_port, so the load balancer would health-check a port the application is not listening on."
  }
}
