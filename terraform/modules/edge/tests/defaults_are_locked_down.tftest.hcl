# ---------------------------------------------------------------------------
# The all-defaults accident.
#
# Terraform treats a tfvars value for an UNDECLARED variable as a WARNING, not
# an error, and discards the value. So a calling root that forgets to declare an
# input does not fail: the operator's setting silently evaporates and THIS
# MODULE'S DEFAULTS are what actually take effect. That makes the defaults a
# security control in their own right, not a convenience.
#
# This file supplies only the mandatory inputs -- the ones with no default at
# all -- plus iap_members, which the default posture requires. Everything else
# is genuinely omitted, so every assertion below reads a real default.
#
# WHY THIS IS ITS OWN FILE: run-level `variables` blocks MERGE with the
# file-level block rather than replacing it. Written as a `run` inside a file
# whose header sets hostname, allowed_ipv4 and friends, the "omitted" inputs are
# still supplied by that header and the test measures nothing. It has to be a
# file whose header is minimal. (Found the hard way: as a run in
# iap_access.tftest.hcl this failed against a module that was behaving
# correctly.)
#
# THE LIMIT OF THE GUARANTEE, which matters to any calling root: a module
# default only applies while the caller passes NO value. Once a root wires
# `access_mode = var.access_mode`, the ROOT's default governs and this one is
# dead. A calling root must therefore default access_mode to "iap" as well, or
# declare it required with no default.
# ---------------------------------------------------------------------------

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  # Mandatory inputs only. Adding anything else here defeats the file's purpose.
  project_id             = "CHANGEME-project"
  environment_key        = "demo-1"
  name_prefix            = "sl-demo-1"
  labels                 = { environment = "demo-1", kind = "demo" }
  backend_instance_group = "projects/CHANGEME-project/zones/europe-west2-a/instanceGroups/sl-demo-1-ig"
  app_port               = 8080
  iap_members            = ["user:someone@example.invalid"]
}

run "the_default_posture_is_iap" {
  command = plan

  assert {
    condition     = var.access_mode == "iap"
    error_message = "With access_mode omitted the module did not default to \"iap\". A root that forgets to declare the variable produces exactly this state, so the default is what stands between a discarded setting and a public edge."
  }

  assert {
    condition     = google_compute_backend_service.app.iap[0].enabled == true
    error_message = "IAP is not enabled under the all-defaults configuration."
  }
}

run "an_omitted_hostname_builds_no_public_frontend" {
  command = plan

  # Fail closed, not half-created.
  assert {
    condition = alltrue([
      length(google_compute_global_forwarding_rule.https) == 0,
      length(google_compute_managed_ssl_certificate.edge) == 0,
      length(google_dns_record_set.edge) == 0,
      length(google_compute_target_https_proxy.edge) == 0,
      length(google_compute_global_address.edge) == 0,
    ])
    error_message = "A discarded hostname produced part of a public frontend. The empty default must disable the whole chain rather than leave a fragment of it."
  }
}

run "omitted_optional_inputs_all_fail_closed" {
  command = plan

  # A discarded allowlist must mean "nothing extra is admitted", never "admit
  # everything".
  assert {
    condition     = length(var.allowed_ipv4) == 0 && length(var.allowed_ipv6) == 0
    error_message = "The allowlist defaults are not empty. A discarded allowlist must fail closed."
  }

  # A cache in front of an IAP-authenticated app would serve one principal's
  # response to another.
  assert {
    condition     = google_compute_backend_service.app.enable_cdn == false
    error_message = "enable_cdn defaulted to true. A CDN in front of an authenticated edge is a cross-principal disclosure risk."
  }

  # Omitting the OAuth client selects the IAP-managed one rather than sending
  # empty strings, which the API would reject.
  assert {
    condition = alltrue([
      google_compute_backend_service.app.iap[0].oauth2_client_id == null,
      google_compute_backend_service.app.iap[0].oauth2_client_secret == null,
    ])
    error_message = "An omitted OAuth client did not resolve to the IAP-managed form."
  }

  # And the floor is still there.
  assert {
    condition = one([
      for r in google_compute_security_policy.edge.rule : r.action
      if r.priority == 2147483647
    ]) == "deny(403)"
    error_message = "The Cloud Armor default deny is absent under the all-defaults configuration."
  }
}

run "omitting_iap_members_as_well_fails_loudly_rather_than_opening_up" {
  command = plan

  # The one optional input whose default is NOT independently safe, and is
  # therefore made unrepresentable instead. If a root discards iap_members too,
  # the plan must abort -- never quietly fall back to a mode that needs no
  # principals.
  variables {
    iap_members = []
  }

  expect_failures = [var.iap_members]
}
