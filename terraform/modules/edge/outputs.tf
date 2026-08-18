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

output "access_mode" {
  description = "The access mode this edge was built in: \"iap\", \"allowlist\", or \"iap_and_allowlist\". Surfaced so a caller, a runbook, or an acceptance test can assert the posture it thinks it deployed."
  value       = var.access_mode
}

output "iap_enabled" {
  description = "True when Identity-Aware Proxy authenticates every request at the edge. False means the IP allowlist is the only control, and the allowlist is exposure control, not authentication."
  value       = local.iap_enabled
}

output "iap_authorised_member_count" {
  description = "Number of principals granted roles/iap.httpsResourceAccessor. Zero while iap_enabled is true would be an edge nobody can open; the iap_members validation makes that unrepresentable."
  value       = length(google_iap_web_backend_service_iam_member.accessors)
}
