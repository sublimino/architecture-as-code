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

# ---------------------------------------------------------------------------
# The Tailscale auth key, referenced and never declared.
#
# The secret is created OUT OF BAND — `gcloud secrets create` plus a version
# holding a reusable, ephemeral, pre-approved key. It is deliberately not a
# `resource` here, and that is a security decision rather than a convenience:
# a `google_secret_manager_secret_version` resource carries its payload in
# `secret_data`, which means the auth key would be written into Terraform state
# in plain text and into every plan output that touched it. State lives in a
# GCS bucket several principals can read. The key would then be readable by more
# people than the tailnet it admits to.
#
# A data source instead gives the one thing that matters at plan time: if
# tailscale_enabled is true and the secret does not exist, the PLAN fails with
# "secret not found" rather than the apply failing halfway through, or worse,
# succeeding and leaving a VM that boots without a tailnet for reasons nobody
# looks for. The count is what keeps that from being a tax on every environment
# that never asked for Tailscale — with the feature off, this lookup is not
# performed at all, so an environment with no secret still plans and applies.
data "google_secret_manager_secret" "tailscale_authkey" {
  count = var.tailscale_enabled ? 1 : 0

  project   = var.project_id
  secret_id = var.tailscale_authkey_secret_id
}

# SECRET-SCOPED, never project-scoped.
#
# `google_secret_manager_secret_iam_member` binds on ONE secret. The available
# alternative, `google_project_iam_member` with roles/secretmanager.secretAccessor,
# grants read on EVERY secret in the project — present and future — to a service
# account attached to a VM that runs demo workloads and pulls public container
# images. The two lines look almost identical in a diff and differ by the entire
# blast radius of the project's secret store.
#
# Additive by construction: this resource adds one member to one secret's policy
# and touches nothing else. The authoritative sibling
# (`google_secret_manager_secret_iam_policy`) would replace that secret's whole
# policy, silently removing whatever grant lets Andy manage the key himself.
resource "google_secret_manager_secret_iam_member" "tailscale_authkey_accessor" {
  count = var.tailscale_enabled ? 1 : 0

  project   = var.project_id
  secret_id = data.google_secret_manager_secret.tailscale_authkey[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.service_account_email}"
}

locals {
  instance_name = "${var.name_prefix}-vm"

  # ─── Tailscale node identity, decided here rather than in bash ───────────
  #
  # Derived from the environment key so the node name is deterministic and
  # one-to-one with the environment: demo-1 is always `sl-demo-1`, on every
  # rebuild. That matters more than it looks for an EPHEMERAL key — an ephemeral
  # node is reaped by Tailscale shortly after it goes offline, so a VM rebuilt
  # under the same name reclaims the same identity rather than accumulating
  # sl-demo-1-1, sl-demo-1-2, sl-demo-1-3 in the tailnet device list.
  #
  # Computed in Terraform, not in the startup script, because it is the same
  # value modules/network derives its network tag from and a second derivation
  # in bash is a second thing to drift.
  tailscale_hostname = "sl-${var.environment_key}"

  # Instance metadata carrying the Tailscale CONFIGURATION — never the key.
  #
  # Startup scripts and metadata are stored in plain text and readable by anyone
  # holding compute.instances.get, so what goes here is the NAME of the secret,
  # not its contents. The VM resolves the name to a value at runtime under its
  # own attached service account, which is the grant made above.
  #
  # Emitted as an empty map when the feature is off, so a non-Tailscale
  # instance's metadata is byte-identical to what it was before this existed and
  # the startup script has exactly one signal to read.
  tailscale_metadata = var.tailscale_enabled ? {
    signalloom-tailscale-enabled   = "TRUE"
    signalloom-tailscale-secret-id = var.tailscale_authkey_secret_id
    signalloom-tailscale-tag       = var.tailscale_tag
    signalloom-tailscale-hostname  = local.tailscale_hostname
    signalloom-tailscale-ssh       = var.tailscale_ssh_enabled ? "TRUE" : "FALSE"
  } : {}

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

  # merge(), not a single literal, so the Tailscale keys are ABSENT rather than
  # empty when the feature is off. An empty-string metadata value is a value the
  # startup script would still have to interpret; an absent key is unambiguous,
  # and it keeps a non-Tailscale instance's metadata identical to what it was
  # before this feature existed — which is what makes "no Tailscale resource is
  # planned at all" assertable rather than approximately true.
  metadata = merge({
    # OS Login: SSH authorisation goes through IAM rather than through keys
    # pasted into project metadata.
    enable-oslogin = "TRUE"

    # Project-wide SSH keys would bypass OS Login entirely, so they are
    # refused at the instance.
    block-project-ssh-keys = "TRUE"

    # Serial console access is an out-of-band path that ignores the firewall.
    serial-port-enable = "FALSE"

    signalloom-environment = var.environment_key
  }, local.tailscale_metadata)

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
