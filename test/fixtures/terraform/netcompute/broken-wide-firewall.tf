# FIXTURE — DELIBERATELY BROKEN. NOT PART OF THE REAL TREE. NEVER APPLIED.
#
# Carries the violation `scan_wide_open_allow` exists to catch: an `allow` rule
# whose source is the entire internet. Note the contrast with the second rule
# below — the same CIDR inside a `deny` block is the posture working, not a
# violation, and the scanner must tell the two apart.

resource "google_compute_firewall" "fixture_ssh_from_anywhere" {
  name    = "sl-fixture-allow-ssh-world"
  project = "CHANGEME-project"
  network = "sl-fixture-vpc"

  direction = "INGRESS"
  priority  = 1000

  # THE VIOLATION. SSH open to the internet, and unscoped to any target, so it
  # lands on every instance in the VPC.
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# NOT a violation: 0.0.0.0/0 in a deny rule is exactly what default-deny means.
# If the scanner ever flags this one, it has become a string match rather than
# a semantic check, and the clean-control fixture will catch that.
resource "google_compute_firewall" "fixture_deny_all_ingress" {
  name    = "sl-fixture-deny-all-ingress"
  project = "CHANGEME-project"
  network = "sl-fixture-vpc"

  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}
