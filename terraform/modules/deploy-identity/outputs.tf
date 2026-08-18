output "deploy_service_account_email" {
  description = "Email of the deploy identity. Use with --impersonate-service-account; never with a downloaded key."
  value       = google_service_account.deploy.email
}

output "impersonation_command" {
  description = "The exact gcloud invocation that authenticates Terraform as this identity."
  value       = "gcloud auth application-default login --impersonate-service-account=${google_service_account.deploy.email}"
}

output "granted_roles" {
  description = "Every project role granted to the deploy identity, so a reviewer can diff intent against reality."
  value       = sort(local.deploy_roles)
}
