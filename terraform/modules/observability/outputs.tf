# Outputs.
#
# The first two are the frozen interface from terraform/CONTRACT.md section 4.
# The rest are additive — a consumer that reads only the contract's two outputs
# is unaffected by them.

output "log_bucket_name" {
  description = "Name of the dedicated audit log bucket. Never the Terraform state bucket; see the precondition in main.tf."
  value       = google_storage_bucket.audit_logs.name
}

output "log_sink_writer_identity" {
  description = "Service account identity the log sink writes as. Granted objectCreator on the audit bucket only."
  value       = try(google_logging_project_sink.admin_activity[0].writer_identity, "")
}

output "log_bucket_self_link" {
  description = "Self link of the audit log bucket."
  value       = google_storage_bucket.audit_logs.self_link
}

output "uptime_check_ids" {
  description = "Monitoring uptime check ids, keyed by environment key."
  value       = { for k, v in google_monitoring_uptime_check_config.demo : k => v.uptime_check_id }
}

output "alert_policy_names" {
  description = "Names of every alert policy this module created, for runbook cross-reference."
  value = concat(
    [for k, v in google_monitoring_alert_policy.uptime_failure : v.name],
    [for v in google_monitoring_alert_policy.backend_unhealthy : v.name],
  )
}

output "budget_enabled" {
  description = "Whether the billing budget was created. False means billing_account_id was empty, not that the budget failed."
  value       = length(google_billing_budget.platform) > 0
}
