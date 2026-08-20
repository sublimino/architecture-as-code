output "instance_self_link" {
  description = "Self-link of the lane VM."
  value       = google_compute_instance.this.self_link
}

output "instance_name" {
  description = "Name of the lane VM, for gcloud and IAP invocations. One shape for both kinds: sl-<key>-vm."
  value       = google_compute_instance.this.name
}

output "internal_ip" {
  description = "Private RFC1918 address of the lane VM. There is no external address to output."
  value       = google_compute_instance.this.network_interface[0].network_ip
}

# Migrated from modules/ci-runner. Exposed so callers and tests can assert the
# reaper's selector matches from the Terraform side, rather than inferring it
# from the label map the module happened to build.
#
# EMPTY on a demo lane, and the empty string is the assertion: it is what makes
# "no demo VM carries a CI selector" checkable in a plan, which a `contains` on
# the label keys alone would leave as an inference.
output "ci_lane_label" {
  description = "The `ci-lane` label value scripts/ci/gcp-tf-reaper.sh selects on, or \"\" for a demo lane. Non-empty exactly when kind is \"ci\"."
  value       = lookup(google_compute_instance.this.labels, "ci-lane", "")
}

output "instance_group_self_link" {
  description = "Self-link of the unmanaged instance group wrapping the VM. The edge module's backend service consumes this."
  value       = google_compute_instance_group.this.self_link
}
