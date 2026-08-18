# modules/ci-runner — one suspendable CI VM per named lane.
#
# Same hardening as the demo VM, with one deliberate difference:
# deletion_protection is false. CI lanes are disposable; a lane that cannot be
# deleted is a lane that outlives the branch that needed it and quietly bills.
#
# The `ci-lane` label is load-bearing, not decoration. scripts/ci/gcp-tf-reaper.sh
# selects on it, and it is the only thing that makes a reaper structurally
# incapable of suspending a demo environment.

locals {
  instance_name = "${var.name_prefix}-runner"

  labels = merge(var.labels, {
    ci-lane = var.environment_key
  })
}

resource "google_compute_instance" "runner" {
  project      = var.project_id
  name         = local.instance_name
  zone         = var.zone
  machine_type = var.machine_type

  labels = local.labels
  tags   = [var.network_tag]

  # CI lanes are disposable by design. See the module comment.
  deletion_protection = false

  # Suspension requires the guest to support ACPI S3, which needs a UEFI boot.
  # Shielded VM implies it, and the lifecycle script suspends after every run.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image  = var.boot_image
      size   = var.boot_disk_gb
      type   = "pd-balanced"
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link
    # No access_config block: no external IP, ever. Ingress is IAP only.
  }

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    # OS Login binds SSH access to IAM rather than to keys pasted into project
    # metadata. Blocking project keys is what makes that binding exclusive —
    # without it, a project-wide key still gets in.
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    # Read by the reaper. Keeping the threshold on the instance means a lane
    # cannot disagree with the reaper about its own idle budget.
    idle-suspend-minutes = tostring(var.idle_suspend_minutes)
    ci-lane              = var.environment_key
  }

  scheduling {
    # Suspension and live migration are incompatible with preemptible; keep the
    # lane standard so the lifecycle script owns the on/off decision.
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  lifecycle {
    precondition {
      condition     = length(local.instance_name) <= 63
      error_message = "Instance name exceeds GCP's 63-character limit."
    }
    precondition {
      condition     = lookup(local.labels, "ci-lane", "") == var.environment_key
      error_message = "The ci-lane label must equal the environment key — the reaper selects on it."
    }
  }
}
