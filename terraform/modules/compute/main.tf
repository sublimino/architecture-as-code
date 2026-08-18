# ---------------------------------------------------------------------------
# Signal Loom demo VM — private, shielded, OS Login only.
#
# The instance has no external IP and no `access_config` block anywhere in this
# module. Reachability is exactly two paths: IAP TCP forwarding for SSH, and
# the HTTPS load balancer for the app port. Everything else is denied by the
# network module's firewall.
#
# This module is the demo VM. CI runners are a separate module
# (modules/ci-runner, F5) because they are typed differently: disposable,
# suspendable, and not deletion-protected.
# ---------------------------------------------------------------------------

data "google_compute_image" "boot" {
  family  = var.image_family
  project = var.image_project
}

locals {
  instance_name = "${var.name_prefix}-vm"

  # Falls back to the module's own version-controlled script. A variable
  # default cannot reference path.module, so the choice is made here.
  startup_script_file = var.startup_script_path != "" ? var.startup_script_path : "${path.module}/startup/demo-vm.sh"

  # Confidential Computing forces the host-maintenance behaviour: a SEV
  # instance cannot live-migrate, so it must terminate and restart instead.
  on_host_maintenance = var.enable_confidential_compute ? "TERMINATE" : "MIGRATE"
}

resource "google_compute_instance" "this" {
  name         = local.instance_name
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type

  description = "Signal Loom ${var.environment_key} demo VM"
  labels      = var.labels
  tags        = [var.network_tag]

  deletion_protection = var.deletion_protection

  # Permits machine_type and shielded-config changes to apply by stopping the
  # instance rather than failing the plan.
  #
  # This is the mechanism that makes a resize an UPDATE rather than a REPLACE.
  # machine_type is not a ForceNew attribute in the Google provider, but it
  # cannot be changed on a running instance either: without this flag the plan
  # is accepted and the apply fails at the API with "instance must be stopped",
  # leaving the environment half-applied. With it, the provider stops the
  # instance, resizes it, and starts it again — the disk, the internal IP, the
  # instance group membership and everything already on the box survive.
  #
  # That matters for the sizing profile specifically: e2-standard-4 →
  # n2-standard-16 is a change a demo VM is expected to survive, and a rebuild
  # would take the Kind cluster and the whole deployed estate with it. Confirmed
  # in the plan by `resizing_the_vm_is_an_update_not_a_replacement` in
  # tests/compute.tftest.hcl.
  #
  # ─── The disk does NOT behave the same way, and the difference bites ──────
  #
  # THE MACHINE TYPE IS AN UPDATE. THE BOOT DISK SIZE IS A REPLACEMENT.
  #
  # boot_disk.initialize_params is ForceNew in the provider, so changing
  # boot_disk_gb prints `# forces replacement` on google_compute_instance and
  # destroys the VM. Confirmed on a real plan against the deployed demo-1
  # estate: 100 → 200 planned as 1 to add, 2 to change, 1 to destroy.
  #
  # This was harmless on the environment where it was found, because the VM
  # carried nothing yet. It will not be harmless the second time. "Resize the
  # disk" reads like an in-place operation in every other context — cloud
  # consoles, LVM, every managed database — and nothing in the variable name
  # suggests otherwise. Read the plan before applying a disk change to a VM
  # that has a cluster on it; growing the disk in-place with `gcloud compute
  # disks resize` plus an online filesystem grow, and then reconciling the
  # Terraform value, is the non-destructive route.
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image  = data.google_compute_image.boot.self_link
      size   = var.boot_disk_gb
      type   = var.boot_disk_type
      labels = var.labels
    }
  }

  # No access_config block. Its absence is what makes this instance private —
  # adding one would give it an ephemeral external IP and route around both the
  # load balancer and the egress policy in one line.
  network_interface {
    subnetwork = var.subnet_self_link
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Confidential Computing is addressed rather than omitted. It is off by
  # default because it constrains the instance to the N2D/C2D machine families
  # and forces TERMINATE on host maintenance, and the demo's default machine
  # type is n2-standard-16. Enabling it is a two-variable change:
  # enable_confidential_compute = true with a compatible machine_type.
  # Emitted ONLY when confidential compute is actually wanted.
  #
  # Declared unconditionally, this block produced a perpetual diff that forced
  # instance REPLACEMENT on every plan: the API returns an empty
  # confidential_instance_config for a non-confidential VM, Terraform compares
  # that to the block we sent, sees a difference in a ForceNew attribute, and
  # proposes destroy-and-create. Observed live on sl-demo-1-vm — a routine
  # `terraform apply` would have silently rebuilt a running demo.
  #
  # dynamic with a zero-length list emits nothing at all, which is what matches
  # the API's own representation of "not confidential".
  dynamic "confidential_instance_config" {
    for_each = var.enable_confidential_compute ? [1] : []

    content {
      enable_confidential_compute = true
    }
  }

  scheduling {
    # Explicitly not preemptible and not Spot. The demo VM is long-lived; a
    # preemption mid-acceptance-run reads as a product failure.
    preemptible         = false
    provisioning_model  = "STANDARD"
    automatic_restart   = !var.enable_confidential_compute
    on_host_maintenance = local.on_host_maintenance
  }

  service_account {
    # Per-environment runtime SA from modules/identity, never the project's
    # default compute service account.
    email = var.service_account_email

    # cloud-platform with IAM doing the restricting. Legacy scopes are a second,
    # weaker authorisation system layered under IAM; narrowing there while the
    # role bindings stay broad produces a posture nobody can reason about, and
    # scopes cannot express "read this one bucket".
    scopes = ["cloud-platform"]
  }

  metadata = {
    # OS Login: SSH authorisation goes through IAM rather than through keys
    # pasted into project metadata.
    enable-oslogin = "TRUE"

    # Project-wide SSH keys would bypass OS Login entirely, so they are
    # refused at the instance.
    block-project-ssh-keys = "TRUE"

    # Serial console access is an out-of-band path that ignores the firewall.
    serial-port-enable = "FALSE"

    signalloom-environment = var.environment_key
  }

  metadata_startup_script = file(local.startup_script_file)

  lifecycle {
    # The boot image family resolves to a new self-link whenever Google
    # publishes a patched image. Without this, every plan after an upstream
    # image release proposes destroying the demo VM.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }
}

# The edge module's backend service takes an instance group, not a bare
# instance. An unmanaged group is the right shape here: exactly one VM, no
# autoscaling, no rolling replacement.
resource "google_compute_instance_group" "this" {
  name    = "${var.name_prefix}-ig"
  project = var.project_id
  zone    = var.zone

  description = "Signal Loom ${var.environment_key} unmanaged instance group"

  instances = [google_compute_instance.this.self_link]

  named_port {
    name = "http"
    port = var.app_port
  }
}
