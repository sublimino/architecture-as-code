# Observability, audit, and cost control for the Signal Loom GCP demo platform.
#
# This module is instantiated ONCE, by terraform/platform. It is deliberately
# project-scoped rather than environment-scoped: an audit trail that a demo
# environment's own destroy can delete is not an audit trail, and a budget that
# only exists while one demo exists cannot tell you the estate is overspending.
# The separation is structural — terraform/environments never sees these
# resources, so `make gcp-tf-destroy ENV=demo-1` physically cannot reach them.

locals {
  # Derived, not supplied. A caller cannot accidentally point the audit sink at
  # the state bucket by passing the wrong name, because it cannot pass a name
  # at all. The precondition below is the belt to this braces.
  audit_bucket_name = "${var.project_id}-signalloom-audit"

  # GCS retention policies are expressed in seconds.
  audit_retention_seconds = var.log_retention_days * 24 * 60 * 60
}

# ---------------------------------------------------------------------------
# Audit log destination — a dedicated bucket, provably not the state bucket
# ---------------------------------------------------------------------------

resource "google_storage_bucket" "audit_logs" {
  name          = local.audit_bucket_name
  project       = var.project_id
  location      = var.log_bucket_location
  storage_class = "STANDARD"
  labels        = var.labels

  # The audit trail is the evidence. It survives a demo teardown on purpose.
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # Retention policy stops early deletion; the lifecycle rule performs the
  # deletion once retention has elapsed. Both derive from the same variable, so
  # they cannot drift apart.
  retention_policy {
    retention_period = local.audit_retention_seconds
    is_locked        = false
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.log_retention_days
    }
  }

  lifecycle {
    # ISC-206: the sink destination must not be the Terraform state bucket.
    # Routing audit logs into the state bucket would put a write-heavy,
    # externally-triggered object stream into the one bucket whose integrity the
    # whole estate depends on — and would make the state bucket's own deletion
    # protection the audit trail's only retention control.
    #
    # This is a precondition, not a coalesce or a rename. It fails the plan; it
    # does not quietly pick a different name. A guard that repairs what it
    # detects can never fail, and the broken input ships green.
    precondition {
      condition     = var.state_bucket_name == "" || local.audit_bucket_name != var.state_bucket_name
      error_message = "The audit log bucket and the Terraform state bucket must be different buckets. Both resolved to the same name; change state_bucket_name or the project id."
    }
  }
}

resource "google_logging_project_sink" "admin_activity" {
  count       = var.manage_project_iam ? 1 : 0
  name        = "${var.name_prefix}-admin-activity"
  project     = var.project_id
  destination = "storage.googleapis.com/${google_storage_bucket.audit_logs.name}"

  # Admin Activity is the "who changed what" stream and cannot be disabled.
  # System Event, Policy Denied and Data Access ride the same sink so the
  # evidence lives in one place.
  filter = <<-EOT
    logName:("cloudaudit.googleapis.com%2Factivity"
      OR "cloudaudit.googleapis.com%2Fsystem_event"
      OR "cloudaudit.googleapis.com%2Fpolicy"
      OR "cloudaudit.googleapis.com%2Fdata_access")
  EOT

  # A per-sink service account rather than the shared project writer: the grant
  # below is then scoped to this bucket alone.
  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "sink_writer" {
  count  = var.manage_project_iam ? 1 : 0
  bucket = google_storage_bucket.audit_logs.name

  # objectCreator, not objectAdmin: the sink needs to write new objects and must
  # not be able to delete or overwrite the ones already there.
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.admin_activity[0].writer_identity
}

# ---------------------------------------------------------------------------
# Data-access audit logging
# ---------------------------------------------------------------------------

# DATA_READ and DATA_WRITE are OFF by default in GCP for every service except
# IAM. Without this block, "who read the demo's data" is unanswerable after the
# fact, which is precisely the question a regulated buyer asks.
resource "google_project_iam_audit_config" "data_access" {
  for_each = var.manage_project_iam ? toset(var.data_access_services) : toset([])

  project = var.project_id
  service = each.value

  audit_log_config {
    log_type = "DATA_READ"
  }

  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# ---------------------------------------------------------------------------
# Uptime checks — one per public demo hostname
# ---------------------------------------------------------------------------

resource "google_monitoring_uptime_check_config" "demo" {
  for_each = var.uptime_targets

  project      = var.project_id
  display_name = "${var.name_prefix}-uptime-${each.key}"
  timeout      = "10s"
  period       = "300s"

  http_check {
    path           = "/"
    port           = each.value.app_port
    request_method = "GET"

    # The edge terminates TLS with a Google-managed certificate; a check that
    # tolerates an invalid certificate would go green through an expiry.
    use_ssl      = true
    validate_ssl = true
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = each.value.hostname
    }
  }
}

# ---------------------------------------------------------------------------
# Alert policies
# ---------------------------------------------------------------------------

resource "google_monitoring_alert_policy" "uptime_failure" {
  for_each = var.enable_alerts ? var.uptime_targets : {}

  project      = var.project_id
  display_name = "${var.name_prefix}-uptime-failed-${each.key}"
  combiner     = "OR"
  user_labels  = var.labels

  conditions {
    display_name = "Uptime check failing for ${each.value.hostname}"

    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\"",
        "resource.type=\"uptime_url\"",
        "metric.label.check_id=\"${google_monitoring_uptime_check_config.demo[each.key].uptime_check_id}\"",
      ])

      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "1200s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }
    }
  }

  # Validated non-empty by the validation block on the variable itself.
  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }
}

resource "google_monitoring_alert_policy" "backend_unhealthy" {
  count = var.enable_alerts ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix}-lb-backend-unhealthy"
  combiner     = "OR"
  user_labels  = var.labels

  conditions {
    display_name = "HTTPS load balancer returning 5xx from its backend"

    # GCP does not export a "backend healthy" gauge for the classic external
    # HTTPS load balancer, so the honest proxy is the 5xx class on the LB's own
    # request counter: when the backend instance group has no healthy member,
    # the LB serves 502s and this fires. Documented rather than dressed up as a
    # direct health signal.
    condition_threshold {
      filter = join(" AND ", [
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "resource.type=\"https_lb_rule\"",
        "metric.label.response_code_class=\"500\"",
      ])

      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.label.url_map_name"]
      }
    }
  }

  notification_channels = var.notification_channel_ids

  alert_strategy {
    auto_close = "3600s"
  }
}

# ---------------------------------------------------------------------------
# Budget
# ---------------------------------------------------------------------------

# Gated on billing_account_id so the module plans for an engineer who has
# project access but not billing-account access. That is the common case and it
# should not block everything else in this module.
resource "google_billing_budget" "platform" {
  count = var.billing_account_id != "" ? 1 : 0

  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix}-budget"

  budget_filter {
    projects               = ["projects/${var.project_id}"]
    calendar_period        = "MONTH"
    credit_types_treatment = "INCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      currency_code = var.budget_amount_currency
      units         = tostring(var.budget_amount_units)
    }
  }

  # 50% is "the month is going faster than planned", 80% is "intervene now",
  # 100% is "this is already over". Three rules, not one, because a single
  # alarm at 100% only ever arrives too late to act on.
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.8
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = var.notification_channel_ids
    disable_default_iam_recipients   = false
  }
}
