# Outputs consumed by terraform/environments (via `terraform_remote_state` or,
# more simply, by copying the values into the environment tfvars) and by the
# runbook.

output "log_bucket_name" {
  description = "Dedicated audit log bucket. Provably not the Terraform state bucket — see the precondition in modules/observability/main.tf."
  value       = module.observability.log_bucket_name
}

output "log_sink_writer_identity" {
  description = "Identity the admin-activity log sink writes as."
  value       = module.observability.log_sink_writer_identity
}

output "notification_channel_ids" {
  description = "Every monitoring notification channel an alert policy can route to, created here plus supplied externally."
  value       = local.notification_channel_ids
}

output "budget_enabled" {
  description = "False means billing_account_id was empty, not that the budget failed to create."
  value       = module.observability.budget_enabled
}

output "dns_managed_zone_name" {
  description = "Name of the managed zone, or empty string when Terraform does not manage DNS. Feed this to the environments root's dns_managed_zone input."
  value       = var.dns_zone_name != "" ? google_dns_managed_zone.demo[0].name : ""
}

output "dns_name_servers" {
  description = "Name servers to delegate the domain to at the registrar. Empty when Terraform does not manage DNS."
  value       = var.dns_zone_name != "" ? google_dns_managed_zone.demo[0].name_servers : []
}

# ===========================================================================
# WIRING BLOCK — uncomment with modules/identity. See WIRING.md.
# ===========================================================================
#
# output "workload_identity_provider_name" {
#   description = "Full resource name of the WIF provider, for the GitHub Actions google-github-actions/auth step."
#   value       = module.identity.workload_identity_provider_name
# }
#
# output "ci_plan_service_account_email" {
#   description = "Read-only CI identity used for plan."
#   value       = module.identity.ci_plan_service_account_email
# }
#
# output "ci_apply_service_account_email" {
#   description = "Privileged CI identity used for apply."
#   value       = module.identity.ci_apply_service_account_email
# }
#
# output "runtime_service_account_emails" {
#   description = "Per-environment runtime service account emails, keyed by environment key."
#   value       = module.identity.runtime_service_account_emails
# }
#
# END WIRING BLOCK
# ===========================================================================

# ── Identity, re-exported for the environments root ─────────────────────────
#
# The environments root consumes these via terraform_remote_state rather than
# instantiating modules/identity itself. That is deliberate (CONTRACT §5b): a
# project-level singleton declared in an environment's state is destroyed by
# `make gcp-tf-destroy ENV=<that environment>`, which would take CI's ability to
# authenticate with it. Re-exporting here is what makes the read-only path work.

output "runtime_service_account_emails" {
  description = "Runtime service account email per environment key. Consumed by the environments root for the VM's identity and for firewall target scoping."
  value       = module.identity.runtime_service_account_emails
}

output "ci_plan_service_account_email" {
  description = "Read-only CI principal."
  value       = module.identity.ci_plan_service_account_email
}

output "ci_apply_service_account_email" {
  description = "Write-capable CI principal, scoped to one workflow file."
  value       = module.identity.ci_apply_service_account_email
}
