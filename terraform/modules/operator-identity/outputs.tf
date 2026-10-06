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
  description = "The role BUDGET at any scope — what this identity is entitled to hold, not what the current configuration bound. Four: two predefined project-scoped roles, one project-scoped custom role holding four permissions, and one scoped to the runtime service account resources. Built from operator_project_roles, which is deliberately constant, so when manage_lifecycle_custom_role is false this still lists the custom role and nothing was bound to it. Read lifecycle_role_is_managed alongside it; that output, not this one, is the one that tells you what exists."
  value       = sort(local.operator_all_roles)
}

output "lifecycle_role_permissions" {
  description = "The exact permission set of the instance-lifecycle custom role, sorted. Four: suspend, resume, start, and the zoneOperations.get that gcloud's synchronous poll depends on. Exposed so a caller can diff the granted verbs without reading the module, and so the difference between this role and roles/compute.instanceAdmin.v1 (529 permissions) is a number a reviewer can see."
  value       = sort(local.operator_lifecycle_permissions)
}

output "lifecycle_role_is_managed" {
  description = "Whether Terraform created the instance-lifecycle custom role. False means the caller could not supply iam.roles.create and the role is a documented manual follow-up — the operator can still tunnel and log in, and still cannot suspend. Reported rather than inferred, because a silently-absent grant is indistinguishable from a working one until the estate needs turning off."
  value       = var.manage_lifecycle_custom_role
}

output "project_roles" {
  description = "The project-scoped subset of the granted_roles BUDGET — three, constant. Exposed separately because the project-scoped set is the one with a blast radius beyond a single VM, and a caller asserting on it should not have to filter the combined list. Like granted_roles this states entitlement rather than bindings: a budget that shrank when a feature flag was flipped would let a future role be added under cover of \"we are back to three\"."
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
