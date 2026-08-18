output "operator_service_account_email" {
  description = "Email of the operator identity. Use with --impersonate-service-account; never with a downloaded key."
  value       = local.operator_email

  # Derived rather than read off google_service_account.operator.email, which is
  # computed and therefore unknown until apply. The tftest suite asserts the
  # derivation matches the resource's own account_id and project, so the two
  # cannot drift.
  depends_on = [google_service_account.operator]
}

output "granted_roles" {
  description = "Every role granted to the operator identity at any scope, so a reviewer can diff intent against reality. Three: two project-scoped, one scoped to the runtime service account resources."
  value       = sort(local.operator_all_roles)
}

output "project_roles" {
  description = "The project-scoped subset of granted_roles. Exposed separately because the project-scoped set is the one with a blast radius beyond a single VM, and a caller asserting on it should not have to filter the combined list."
  value       = sort(local.operator_project_roles)
}

output "act_as_service_account_names" {
  description = "Fully-qualified names of the service account resources the operator may act as. Empty when no runtime accounts were supplied. A caller can assert every entry contains \"/serviceAccounts/\" to prove the actAs grant never became project-wide."
  value       = sort(values(local.runtime_account_names))
}

output "ssh_command" {
  description = "The exact gcloud invocation that reaches a demo VM as this identity. Impersonation is what makes it work: the operator's own Google account is external to the owning organisation and cannot configure OS Login POSIX data, while this in-project account can."
  value       = "gcloud compute ssh INSTANCE --zone ZONE --project ${var.project_id} --tunnel-through-iap --impersonate-service-account=${local.operator_email}"

  depends_on = [google_service_account.operator]
}
