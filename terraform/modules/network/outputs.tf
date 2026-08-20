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

# ─── Why a firewall rule is published as an output ──────────────────────────
#
# So that a CALLER can assert on it. The health-check ingress is created only
# when var.edge_enabled is true, and the root's own test suite could not see
# that: a root-level `terraform test` cannot reach a private resource inside a
# module, so it was reduced to asserting the INPUT it passes down and trusting
# that the module did the right thing with it.
#
# That is the shape of an untested claim. This output closes it — the root now
# observes the rule itself, and an empty list is the unambiguous, greppable
# statement that this lane admits nothing from Google's load-balancer probe
# ranges.
#
# A list rather than a bool because it is derived from the resource, not from
# the variable that gated it. A bool would let the module report "false" while
# a rule existed; a projection over the resource cannot.
output "health_check_firewall_names" {
  description = "Names of the GCP health-check / load-balancer proxy ingress rules this environment created. EMPTY when the lane has no edge, which is the state the whole estate is in today. Derived from the resource rather than from var.edge_enabled so it cannot disagree with what was actually planned."
  value       = [for r in google_compute_firewall.allow_health_checks : r.name]
}
