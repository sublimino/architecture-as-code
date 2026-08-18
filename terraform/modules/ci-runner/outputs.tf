output "instance_name" {
  description = "Name of the CI lane instance."
  value       = google_compute_instance.runner.name
}

output "instance_self_link" {
  description = "Self link of the CI lane instance."
  value       = google_compute_instance.runner.self_link
}

output "ci_lane_label" {
  description = "The ci-lane label value. Exposed so callers and tests can assert the reaper's selector matches."
  value       = local.labels["ci-lane"]
}
