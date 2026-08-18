output "lb_ip_address" {
  description = "Anycast IPv4 address of the public load balancer. Empty string when hostname is \"\" and no public frontend was created."
  value       = local.tls_enabled ? google_compute_global_address.edge[0].address : ""
}

output "certificate_name" {
  description = "Name of the Google-managed SSL certificate. Empty string when no public frontend was created."
  value       = local.tls_enabled ? google_compute_managed_ssl_certificate.edge[0].name : ""
}

output "security_policy_name" {
  description = "Name of the Cloud Armor security policy attached to the backend service. Always created, because the default deny is the control that must exist even when nothing is exposed."
  value       = google_compute_security_policy.edge.name
}

output "backend_service_name" {
  description = "Name of the backend service fronting the application instance group."
  value       = google_compute_backend_service.app.name
}
