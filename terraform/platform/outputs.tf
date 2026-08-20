# Outputs consumed by terraform/environments (via `terraform_remote_state` or,
# more simply, by copying the values into the environment tfvars) and by the
# runbook.

# ─── Dormant with module "observability" ────────────────────────────────────
#
# These three outputs read module.observability directly, so they must go
# dormant with it or `terraform validate` fails on a reference to an
# uninstantiated module. Commented rather than deleted, for the same reason the
# module block is: restoring observability should be uncommenting, not
# reconstructing.
#
# NOT dormant, and deliberately so: `notification_channel_ids` below reads
# `local.notification_channel_ids`, not the module, so it stays live. Anything
# consuming it keeps working while observability is off.
#
# output "log_bucket_name" {
#   description = "Dedicated audit log bucket. Provably not the Terraform state bucket — see the precondition in modules/observability/main.tf."
#   value       = module.observability.log_bucket_name
# }
#
# output "log_sink_writer_identity" {
#   description = "Identity the admin-activity log sink writes as."
#   value       = module.observability.log_sink_writer_identity
# }

output "notification_channel_ids" {
  description = "Every monitoring notification channel an alert policy can route to, created here plus supplied externally."
  value       = local.notification_channel_ids
}

# Dormant with module "observability" — see the note above.
#
# output "budget_enabled" {
#   description = "False means billing_account_id was empty, not that the budget failed to create."
#   value       = module.observability.budget_enabled
# }

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

# ── Operator identity ───────────────────────────────────────────────────────
#
# Exported for the runbook and for scripts/ci/gcp-ci.sh, which needs the email
# to pass to --impersonate-service-account. Nobody should be retyping it.

output "operator_service_account_email" {
  description = "The identity a human impersonates to open an IAP tunnel and log into a demo VM. In-project, and therefore internal to the owning organisation, which is what removes the roles/compute.osLoginExternalUser dependency."
  value       = module.operator_identity.operator_service_account_email
}

output "operator_granted_roles" {
  description = "Every role the operator identity holds, at any scope. Four, and a reviewer should be able to check that without reading the module."
  value       = module.operator_identity.granted_roles
}

output "operator_lifecycle_role_permissions" {
  description = "The four permissions in the operator's instance-lifecycle custom role. Exposed beside operator_granted_roles because one of those roles is custom, and a role name alone does not tell a reviewer what it grants — which is the entire reason a custom role was preferred to roles/compute.instanceAdmin.v1 and its 529 permissions."
  value       = module.operator_identity.lifecycle_role_permissions
}

output "operator_can_suspend" {
  description = "Whether the operator identity can actually park the estate. False means the custom role was left to a manual follow-up because the applying identity lacked iam.roles.create, and suspending a demo VM still needs project owner — which is the cost this role was added to remove. Surfaced as an output so the answer is visible in `make gcp-tf-status` rather than discovered at teardown."
  value       = module.operator_identity.lifecycle_role_is_managed
}

output "operator_ssh_command" {
  description = "The exact gcloud invocation that reaches a demo VM as the operator identity. INSTANCE and ZONE are placeholders; everything else is resolved."
  value       = module.operator_identity.ssh_command
}
