output "runtime_service_account_emails" {
  description = "Runtime service account email per environment key."
  value       = local.runtime_emails
}

output "workload_identity_provider_name" {
  description = "Full resource name of the OIDC provider, for google-github-actions/auth."
  value       = try(google_iam_workload_identity_pool_provider.github[0].name, "")
}

output "ci_plan_service_account_email" {
  description = "Read-only CI principal, assumed by pull-request plans."
  value       = local.ci_plan_email
}

output "ci_apply_service_account_email" {
  description = "Write-capable CI principal, assumed only by the pinned ref."
  value       = local.ci_apply_email
}

output "workload_identity_plan_principal" {
  description = "The repository-scoped principalSet:// member that may assume the read-only plan service account. Exposed so callers can assert it is not pool-wide."
  value       = local.wif_plan_principal
}

output "workload_identity_apply_principal" {
  description = "The workflow-scoped principalSet:// member that may assume the write-capable apply service account. Deliberately narrower than the plan principal; a caller asserting these two are equal has found a regression."
  value       = local.wif_apply_principal
}

output "attribute_condition" {
  description = "The CEL condition GCP evaluates before exchanging a GitHub token."
  value       = local.attribute_condition
}
