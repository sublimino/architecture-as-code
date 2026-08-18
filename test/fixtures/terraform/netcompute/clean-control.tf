# FIXTURE — DELIBERATELY CLEAN. NOT PART OF THE REAL TREE. NEVER APPLIED.
#
# The negative control for `scan_access_config` and `scan_wide_open_allow`. Its
# whole job is to be the shape those two scanners must NOT flag:
#
#   * an instance with a network_interface and no access_config;
#   * a scoped `allow` rule with a narrow source;
#   * a `deny` rule that legitimately names 0.0.0.0/0.
#
# A guard that always fires is exactly as useless as one that never does, and a
# red run tells you nothing about which of the two you have. Without this file,
# `scan_wide_open_allow() { return 1; }` would pass every mutation test in the
# suite.
#
# Keep the deny rule below. It is the reason the scanner has to be semantic —
# a guard that banned the string "0.0.0.0/0" outright would flag this file, and
# would force the real module's default-deny rules out of the tree.

resource "google_compute_firewall" "fixture_clean_scoped_allow" {
  name    = "sl-fixture-allow-health-checks"
  project = "CHANGEME-project"
  network = "sl-fixture-vpc"

  direction = "INGRESS"
  priority  = 1000

  source_ranges           = ["130.211.0.0/22", "35.191.0.0/16"]
  target_service_accounts = ["sl-fixture-runtime@CHANGEME-project.iam.gserviceaccount.com"]

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }
}

resource "google_compute_firewall" "fixture_clean_deny_all_ingress" {
  name    = "sl-fixture-deny-all-ingress"
  project = "CHANGEME-project"
  network = "sl-fixture-vpc"

  direction = "INGRESS"
  priority  = 65534

  # Legitimate. This is the one place the whole-internet CIDR belongs.
  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}

resource "google_compute_instance" "fixture_clean_private_vm" {
  name         = "sl-fixture-vm"
  project      = "CHANGEME-project"
  zone         = "europe-west2-a"
  machine_type = "n2-standard-2"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 50
      type  = "pd-balanced"
    }
  }

  # No access_config. This is what private looks like.
  network_interface {
    subnetwork = "sl-fixture-subnet"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = "sl-fixture-runtime@CHANGEME-project.iam.gserviceaccount.com"
    scopes = ["cloud-platform"]
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }
}
