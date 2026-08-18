# FIXTURE — DELIBERATELY BROKEN. NOT PART OF THE REAL TREE. NEVER APPLIED.
#
# Carries the violation `scan_access_config` exists to catch: an instance with
# an external IP. Removing the access_config block below does not "fix" a bug,
# it disarms a test — and the mutation test asserts the block is still here, so
# the attempt fails loudly rather than quietly.

resource "google_compute_instance" "fixture_with_external_ip" {
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

  network_interface {
    subnetwork = "sl-fixture-subnet"

    # THE VIOLATION. An empty access_config grants an ephemeral external IP,
    # which routes around both the load balancer and the egress policy.
    access_config {}
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
