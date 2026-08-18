# Native Terraform tests for the platform root.
#
# The module tests in modules/observability/tests/ prove the module is correct in
# isolation. These prove the ROOT composes it correctly — that the channels this
# root creates actually reach the alert policies, that the audit sink is not
# pointed at the state bucket by the values this root passes down, and that the
# DNS gate is a real gate.
#
# mock_provider mandatory, command = plan only. See CONTRACT.md section 7a.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id        = "changeme-project"
  state_bucket_name = "changeme-project-tfstate"

  notification_emails = ["platform-owner@example.invalid"]

  uptime_targets = {
    "demo-1" = { hostname = "demo-1.example.invalid", app_port = 8080 }
  }

  billing_account_id = "000000-AAAAAA-BBBBBB"

  dns_zone_name = "signalloom-demo"
  dns_domain    = "demo.example.invalid."
}

# ---------------------------------------------------------------------------
# ISC-206 / ISC-207 — evaluated at the composition boundary
# ---------------------------------------------------------------------------

run "audit_sink_destination_is_not_the_state_bucket" {
  command = plan

  assert {
    condition     = output.log_bucket_name != var.state_bucket_name
    error_message = "The platform root wired the audit sink into the Terraform state bucket."
  }

  assert {
    condition     = output.log_bucket_name != ""
    error_message = "The audit bucket name evaluated empty — the assertion above would then pass vacuously against any non-empty state bucket name."
  }
}

# ---------------------------------------------------------------------------
# ISC-213 / ISC-214 — the channels this root creates reach the alert policies
# ---------------------------------------------------------------------------

run "notification_channels_are_created_and_propagated" {
  command = plan

  assert {
    condition     = length(google_monitoring_notification_channel.owners) == length(var.notification_emails)
    error_message = "one notification channel must be created per named owner"
  }

  assert {
    condition     = google_monitoring_notification_channel.owners["platform-owner@example.invalid"].type == "email"
    error_message = "owner channels must be email channels"
  }

  assert {
    condition     = google_monitoring_notification_channel.owners["platform-owner@example.invalid"].labels.email_address == "platform-owner@example.invalid"
    error_message = "the channel must carry the owner's address"
  }

  assert {
    condition     = length(output.notification_channel_ids) > 0
    error_message = "the composed channel list reaching modules/observability evaluated empty"
  }
}

run "externally_managed_channels_are_merged_in" {
  command = plan

  variables {
    notification_emails            = []
    extra_notification_channel_ids = ["projects/changeme-project/notificationChannels/2222222222"]
  }

  assert {
    condition     = length(google_monitoring_notification_channel.owners) == 0
    error_message = "no channel should be created when no owner email is supplied"
  }

  assert {
    condition     = output.notification_channel_ids == ["projects/changeme-project/notificationChannels/2222222222"]
    error_message = "a PagerDuty or Slack channel managed outside Terraform must still reach the alert policies"
  }
}

# ---------------------------------------------------------------------------
# ISC-352 — mandatory labels survive composition
# ---------------------------------------------------------------------------

run "platform_resources_carry_the_mandatory_label_set" {
  command = plan

  variables {
    labels = { owner = "controlplane" }
  }

  assert {
    condition = alltrue([
      for k in ["environment", "kind", "managed-by", "component"] :
      contains(keys(google_dns_managed_zone.demo[0].labels), k)
    ])
    error_message = "platform resources must carry environment, kind, managed-by and component labels"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].labels["managed-by"] == "terraform"
    error_message = "managed-by must evaluate to terraform"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].labels["owner"] == "controlplane"
    error_message = "caller-supplied labels must merge over the mandatory set, not replace or be replaced by it"
  }
}

# ---------------------------------------------------------------------------
# DNS gate — a real gate, in both directions
# ---------------------------------------------------------------------------

run "dns_zone_is_created_with_dnssec_when_configured" {
  command = plan

  assert {
    condition     = length(google_dns_managed_zone.demo) == 1
    error_message = "a managed zone must be created when dns_zone_name is set"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].dns_name == "demo.example.invalid."
    error_message = "the managed zone must carry the configured fully-qualified domain"
  }

  assert {
    condition     = one(google_dns_managed_zone.demo[0].dnssec_config).state == "on"
    error_message = "DNSSEC must default to on"
  }

  assert {
    condition     = output.dns_managed_zone_name == "signalloom-demo"
    error_message = "the zone name must be exported for the environments root to attach records to"
  }
}

run "dns_is_omitted_entirely_when_unconfigured" {
  command = plan

  variables {
    dns_zone_name = ""
    dns_domain    = ""
  }

  assert {
    condition     = length(google_dns_managed_zone.demo) == 0
    error_message = "no managed zone may be created when Terraform is not managing DNS"
  }

  assert {
    condition     = output.dns_managed_zone_name == ""
    error_message = "the exported zone name must be empty so the environments root creates no records"
  }

  # Everything else must still plan. Domain ownership is a prerequisite Andy
  # supplies later; not having it yet must not block the platform.
  assert {
    condition     = output.log_bucket_name != ""
    error_message = "the audit sink must plan without DNS"
  }
}

# ---------------------------------------------------------------------------
# ISC-346 — negative runs, each PAIRED with a positive above
# ---------------------------------------------------------------------------

# Paired with "notification_channels_are_created_and_propagated": identical
# except that no channel of any kind is configured.
run "alerts_enabled_with_no_channel_of_any_kind_is_rejected" {
  command = plan

  variables {
    enable_alerts                  = true
    notification_emails            = []
    extra_notification_channel_ids = []
  }

  expect_failures = [var.notification_emails]
}

# Paired with "dns_is_omitted_entirely_when_unconfigured": a domain with no zone
# is a silent no-op today, which is exactly the class of mistake that reads as
# "DNS is configured" in a review.
run "a_domain_without_a_zone_is_rejected" {
  command = plan

  variables {
    dns_zone_name = ""
    dns_domain    = "demo.example.invalid."
  }

  expect_failures = [var.dns_domain]
}

# Paired with "dns_zone_is_created_with_dnssec_when_configured".
run "a_domain_without_a_trailing_dot_is_rejected" {
  command = plan

  variables {
    dns_zone_name = "signalloom-demo"
    dns_domain    = "demo.example.invalid"
  }

  expect_failures = [var.dns_domain]
}

# ===========================================================================
# WIRING BLOCK — uncomment with modules/identity. See WIRING.md step 4.
# ===========================================================================
#
# run "wif_provider_carries_a_non_empty_attribute_condition" {
#   command = plan
#
#   variables {
#     project_number     = "000000000000"
#     environment_keys   = ["demo-1"]
#     github_owner_id    = "00000000"
#     github_repository  = "CHANGEME-owner/osramp-demo"
#     github_allowed_ref = "refs/heads/main"
#   }
#
#   assert {
#     condition     = output.workload_identity_provider_name != ""
#     error_message = "the WIF provider must be created"
#   }
# }
#
# END WIRING BLOCK
# ===========================================================================
