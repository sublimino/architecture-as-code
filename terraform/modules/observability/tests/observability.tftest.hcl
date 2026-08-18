# Native Terraform tests for modules/observability.
#
# These assert on the EVALUATED configuration — the attribute values Terraform
# actually computed after variables, locals, for_each and conditionals resolved.
# A grep over the HCL proves the source says the right thing; this proves the
# plan came out the right way. See CONTRACT.md section 7a.
#
# mock_provider is mandatory: no test here reaches a real provider, requires
# credentials, or touches the network. command = plan only.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id         = "changeme-project"
  labels             = { environment = "platform", managed-by = "terraform", component = "signalloom" }
  log_retention_days = 400
  state_bucket_name  = "changeme-project-tfstate"

  notification_channel_ids = ["projects/changeme-project/notificationChannels/1111111111"]

  uptime_targets = {
    "demo-1" = { hostname = "demo-1.example.invalid", app_port = 8080 }
    "demo-2" = { hostname = "demo-2.example.invalid", app_port = 8080 }
  }

  billing_account_id  = "000000-AAAAAA-BBBBBB"
  budget_amount_units = 500
}

# ---------------------------------------------------------------------------
# ISC-206 / ISC-207 — the audit sink must not write into the state bucket
# ---------------------------------------------------------------------------

run "audit_sink_destination_is_not_the_state_bucket" {
  command = plan

  assert {
    condition     = google_storage_bucket.audit_logs.name != var.state_bucket_name
    error_message = "The audit log bucket resolved to the same name as the Terraform state bucket."
  }

  # The stronger form: assert on the sink's own destination string, not just on
  # the bucket resource. A future refactor could point the sink somewhere else
  # entirely and the bucket-name check above would still pass.
  assert {
    condition     = google_logging_project_sink.admin_activity.destination != "storage.googleapis.com/${var.state_bucket_name}"
    error_message = "The log sink destination is the Terraform state bucket."
  }

  assert {
    condition     = google_logging_project_sink.admin_activity.destination == "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"
    error_message = "The log sink does not point at the dedicated audit bucket this module creates."
  }
}

# ---------------------------------------------------------------------------
# ISC-205 / ISC-208 / ISC-209 — sink shape, retention, data-access audit config
# ---------------------------------------------------------------------------

run "audit_bucket_is_hardened_and_retains_from_the_variable" {
  command = plan

  assert {
    condition     = google_storage_bucket.audit_logs.public_access_prevention == "enforced"
    error_message = "audit bucket must enforce public access prevention"
  }

  assert {
    condition     = google_storage_bucket.audit_logs.force_destroy == false
    error_message = "audit bucket must not allow force_destroy — the audit trail outlives the demo"
  }

  assert {
    condition     = google_storage_bucket.audit_logs.uniform_bucket_level_access == true
    error_message = "audit bucket must use uniform bucket-level access"
  }

  # 400 days supplied above, expressed in seconds by the module. Asserting the
  # arithmetic rather than the literal is what makes this test track the
  # variable instead of a hardcoded number.
  assert {
    condition     = tonumber(one(google_storage_bucket.audit_logs.retention_policy).retention_period) == var.log_retention_days * 86400
    error_message = "audit bucket retention period does not derive from log_retention_days"
  }

  assert {
    condition     = google_logging_project_sink.admin_activity.unique_writer_identity == true
    error_message = "the sink must use a unique writer identity so its grant can be scoped to the audit bucket alone"
  }

  assert {
    condition     = google_storage_bucket_iam_member.sink_writer.role == "roles/storage.objectCreator"
    error_message = "the sink writer must be objectCreator, not objectAdmin — it writes new evidence and must not delete existing evidence"
  }

  # ISC-209: DATA_READ and DATA_WRITE are OFF by default in GCP for every
  # service except IAM.
  assert {
    condition     = length(google_project_iam_audit_config.data_access) == length(var.data_access_services)
    error_message = "one data-access audit config must exist per configured service"
  }

  assert {
    condition     = contains([for c in google_project_iam_audit_config.data_access["storage.googleapis.com"].audit_log_config : c.log_type], "DATA_READ")
    error_message = "storage data-access audit config must enable DATA_READ"
  }
}

# ---------------------------------------------------------------------------
# ISC-210 — one uptime check per target
# ---------------------------------------------------------------------------

run "one_uptime_check_per_target_over_validated_tls" {
  command = plan

  assert {
    condition     = length(google_monitoring_uptime_check_config.demo) == length(var.uptime_targets)
    error_message = "an uptime check must exist for every entry in uptime_targets"
  }

  assert {
    condition     = one(google_monitoring_uptime_check_config.demo["demo-1"].http_check).port == 8080
    error_message = "the uptime check must probe the environment's app_port"
  }

  assert {
    condition     = one(google_monitoring_uptime_check_config.demo["demo-1"].http_check).validate_ssl == true
    error_message = "an uptime check that tolerates an invalid certificate goes green straight through an expiry"
  }

  assert {
    condition     = google_monitoring_uptime_check_config.demo["demo-2"].monitored_resource[0].labels.host == "demo-2.example.invalid"
    error_message = "the uptime check must target the environment's hostname"
  }
}

# ---------------------------------------------------------------------------
# ISC-211 / ISC-212 / ISC-213 / ISC-214 — alerts reach a person
# ---------------------------------------------------------------------------

run "every_alert_policy_has_at_least_one_notification_channel" {
  command = plan

  assert {
    condition     = length(google_monitoring_alert_policy.uptime_failure) == length(var.uptime_targets)
    error_message = "an uptime-failure alert policy must exist for every uptime target"
  }

  assert {
    condition     = length(google_monitoring_alert_policy.backend_unhealthy) == 1
    error_message = "the LB backend-unhealthy alert policy must exist when alerts are enabled"
  }

  # The whole point of ISC-214. Evaluated, across every policy the plan
  # produced — not "the source references the variable somewhere".
  assert {
    condition = alltrue(concat(
      [for p in google_monitoring_alert_policy.uptime_failure : length(p.notification_channels) > 0],
      [for p in google_monitoring_alert_policy.backend_unhealthy : length(p.notification_channels) > 0],
    ))
    error_message = "an alert policy evaluated with zero notification channels — that is an alert nobody receives"
  }
}

# ---------------------------------------------------------------------------
# ISC-215 / ISC-216 — budget thresholds
# ---------------------------------------------------------------------------

run "budget_has_thresholds_at_50_80_and_100_percent" {
  command = plan

  assert {
    condition     = length(google_billing_budget.platform) == 1
    error_message = "a budget must exist when billing_account_id is supplied"
  }

  assert {
    condition     = tolist([for r in google_billing_budget.platform[0].threshold_rules : r.threshold_percent]) == tolist([0.5, 0.8, 1.0])
    error_message = "budget thresholds must evaluate to exactly 0.5, 0.8 and 1.0 — one alarm at 100% only ever arrives too late to act on"
  }

  assert {
    condition     = one(google_billing_budget.platform[0].amount).specified_amount[0].currency_code == "GBP"
    error_message = "budget currency must default to GBP"
  }
}

# ---------------------------------------------------------------------------
# ISC-217 — the budget is skippable without billing-account access
# ---------------------------------------------------------------------------

run "budget_is_omitted_without_a_billing_account" {
  command = plan

  variables {
    billing_account_id = ""
  }

  assert {
    condition     = length(google_billing_budget.platform) == 0
    error_message = "an empty billing_account_id must omit the budget entirely, so the module plans for an engineer without billing-account access"
  }

  # Everything else must still be there — "skippable" must not mean "degraded".
  assert {
    condition     = length(google_monitoring_alert_policy.uptime_failure) == length(var.uptime_targets)
    error_message = "omitting the budget must not omit the alert policies"
  }
}

# ---------------------------------------------------------------------------
# ISC-346 — negative test PAIRED with the positive that proves it is the rule
#           firing, not an unrelated error
# ---------------------------------------------------------------------------

# Positive half. Same configuration as the negative below in every respect
# except the offending input. If this fails, the negative proves nothing.
run "populated_channel_list_passes_with_alerts_enabled" {
  command = plan

  variables {
    enable_alerts            = true
    notification_channel_ids = ["projects/changeme-project/notificationChannels/1111111111"]
  }

  assert {
    condition     = length(google_monitoring_alert_policy.uptime_failure) > 0
    error_message = "the corrected configuration must produce alert policies"
  }
}

# Negative half. Empty channel list with alerts on must be rejected by the
# variable's own validation block.
run "empty_channel_list_is_rejected_when_alerts_are_enabled" {
  command = plan

  variables {
    enable_alerts            = true
    notification_channel_ids = []
  }

  expect_failures = [var.notification_channel_ids]
}

# The third leg: alerts explicitly disabled is the sanctioned way to have no
# channels. Without this, "reject empty channels" would be indistinguishable
# from "channels are always mandatory".
run "empty_channel_list_is_allowed_when_alerts_are_disabled" {
  command = plan

  variables {
    enable_alerts            = false
    notification_channel_ids = []
  }

  assert {
    condition     = length(google_monitoring_alert_policy.uptime_failure) == 0
    error_message = "disabling alerts must omit the policies rather than create channel-less ones"
  }

  assert {
    condition     = length(google_monitoring_alert_policy.backend_unhealthy) == 0
    error_message = "disabling alerts must omit the backend-unhealthy policy too"
  }
}
