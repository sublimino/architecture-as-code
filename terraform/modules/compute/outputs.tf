output "instance_self_link" {
  description = "Self-link of the demo VM."
  value       = google_compute_instance.this.self_link
}

output "instance_name" {
  description = "Name of the demo VM, for gcloud and IAP invocations."
  value       = google_compute_instance.this.name
}

output "internal_ip" {
  description = "Private RFC1918 address of the demo VM. There is no external address to output."
  value       = google_compute_instance.this.network_interface[0].network_ip
}

output "instance_group_self_link" {
  description = "Self-link of the unmanaged instance group wrapping the VM. The edge module's backend service consumes this."
  value       = google_compute_instance_group.this.self_link
}
