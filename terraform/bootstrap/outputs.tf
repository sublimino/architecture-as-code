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
