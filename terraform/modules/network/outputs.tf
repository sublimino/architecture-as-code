output "network_self_link" {
  description = "Self-link of this environment's VPC."
  value       = google_compute_network.this.self_link
}

output "subnet_self_link" {
  description = "Self-link of this environment's single subnet."
  value       = google_compute_subnetwork.this.self_link
}

output "network_tag" {
  description = "Network tag derived from the environment key, carried by every instance in this environment."
  value       = local.network_tag
}

output "subnet_cidr" {
  description = "CIDR of this environment's subnet, echoed back so callers do not re-derive it."
  value       = google_compute_subnetwork.this.ip_cidr_range
}
