output "state_bucket_name" {
  description = "Name of the GCS bucket created for Terraform state."
  value       = google_storage_bucket.terraform_state.name
}

output "state_bucket_url" {
  description = "gs:// URL of the GCS bucket created for Terraform state."
  value       = format("gs://%s", google_storage_bucket.terraform_state.name)
}

output "backend_config" {
  description = "Copyable partial backend configuration for Terraform roots that consume this state bucket."
  value       = <<-EOT
    bucket = "${google_storage_bucket.terraform_state.name}"
    prefix = "osramp/platform"
    # The environments root uses prefix = "osramp/environments/<key>" instead.
  EOT
}

output "deploy_service_account_email" {
  description = "The identity every subsequent apply and destroy should run as."
  value       = try(module.deploy_identity[0].deploy_service_account_email, "")
}

output "deploy_impersonation_command" {
  description = "The exact gcloud invocation that authenticates Terraform as the deploy identity."
  value       = try(module.deploy_identity[0].impersonation_command, "")
}

output "tailnet_cert_bucket_name" {
  description = "Bucket holding each lane's Tailscale TLS certificate across rebuilds, or \"\" when certificate persistence is disabled. Copy into the environments root's tailnet_cert_bucket_name, the same way state_bucket_name is carried."
  value       = var.tailnet_cert_bucket_name == "" ? "" : google_storage_bucket.tailnet_certs[0].name
}
