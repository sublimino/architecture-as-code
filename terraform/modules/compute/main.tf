# ---------------------------------------------------------------------------
# Signal Loom lane VM — private, shielded, OS Login only.
#
# The instance has no external IP and no `access_config` block anywhere in this
# module. Reachability is exactly two paths: IAP TCP forwarding for SSH, and
# the HTTPS load balancer for the app port. Everything else is denied by the
# network module's firewall.
#
# ─── One module, two lane kinds. Why the split was removed ──────────────────
#
# This module used to build demo VMs only, and `modules/ci-runner` built CI
# lanes. They were measured against each other and found to be the same machine:
# identical shielded config, identical OS Login and blocked project keys,
# identical cloud-platform scope, identical scheduling, identical pd-balanced
# boot disk, identical subnet and network tag. Everything ci-runner had that
# this module lacked was five lines; everything this module had that ci-runner
# lacked was the ENTIRE bootstrap — `metadata_startup_script`, the Tailscale
# block, configurable deletion protection, the instance group.
#
# So a CI lane was a demo lane with the demo removed, which is precisely the
# wrong way round: the whole value of a CI environment is that it is the demo
# environment. Two modules meant every fix to the bring-up landed on one of them
# and CI silently kept testing something else.
#
# A CI lane is therefore a lane that ADDITIONALLY:
#   * carries the `ci-lane = <key>` label, which is what the reaper selects on;
#   * publishes `idle-suspend-minutes` so the reaper reads its budget off the
#     instance rather than carrying a duplicate constant;
#   * is not deletion-protected, because a lane that cannot be deleted outlives
#     the branch that needed it and quietly bills.
#
# ─── The `ci-lane` label is load-bearing, not decoration ────────────────────
#
# scripts/ci/gcp-tf-reaper.sh SELECTS on it, and this module is the only thing
# that emits it. It is emitted for `kind = "ci"` and for nothing else, and the
# preconditions on the instance below make that a checked property rather than a
# convention: `var.kind`, the `kind` label the env-contract merged, and the
# environment key's own prefix must all agree before the plan is allowed to
# proceed. Three independent sources deriving from one environment definition is
# what makes "a demo VM cannot carry a CI selector" structural.
#
# Read that alongside the reaper's own gate list. It refuses on the same label
# from the other side, and it refuses anything carrying demo markers regardless.
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
#
# READ-ONLY, and that word is now load-bearing — see the block below.
data "google_secret_manager_secret" "tailscale_authkey" {
  count = var.tailscale_enabled ? 1 : 0

  project   = var.project_id
  secret_id = var.tailscale_authkey_secret_id
}

# ---------------------------------------------------------------------------
# THE SECRET'S IAM IS NOT DECLARED HERE, AND THAT IS THE POINT.
#
# This module used to carry a `google_secret_manager_secret_iam_member` granting
# roles/secretmanager.secretAccessor on the auth-key secret to the VM's runtime
# service account. It was correct about scope — secret-scoped, never
# project-scoped — and wrong about OWNERSHIP, which is the more expensive axis.
#
# Declaring it here means the identity that runs `terraform apply` must hold
# secretmanager.secrets.setIamPolicy on that secret. It does not, and the two
# applies that first exercised this path both died on exactly that:
#
#     Error 403: Permission 'secretmanager.secrets.setIamPolicy' denied
#       on 'projects/<p>/secrets/sl-demo-tailscale-authkey'
#
# The available fix — widen the deploy identity — is the wrong one, and this
# repo has already argued why at length for a different resource. See the long
# comment at the foot of modules/deploy-identity/main.tf: bucket CREATION and
# bucket IAM are LIFECYCLE, lifecycle belongs to the privileged bootstrap step a
# human runs once, and what the deploy identity does is POPULATE. The same split
# applies here with more force, not less, because the resource is a secret. An
# identity that can setIamPolicy on a secret can grant itself secretAccessor on
# it, so granting that to the account which runs UNATTENDED — from CI, on a
# branch — makes the tailnet auth key readable by anything that can land a
# commit. The secret is deliberately created out of band precisely so its
# payload never reaches an unattended principal; owning its policy from here
# would hand back the same access through the other door.
#
# So the grants are made ONCE, by a human who already holds elevated rights, in
# the same act that creates the secret. Two of them, and they are asymmetric on
# purpose:
#
#   sl-rt-demo-N  roles/secretmanager.secretAccessor  reads the PAYLOAD, at boot
#   sl-tf-deploy  roles/secretmanager.viewer          reads the METADATA only
#
# viewer is what makes the data source above resolve, and it is the whole reason
# that source can stay. It answers "does this secret exist" and cannot answer
# "what is in it" — so a plan gets its existence gate and the deploy identity
# still cannot read the key.
#
# Rejected alternative, recorded so it is not re-proposed: declaring the binding
# in terraform/bootstrap/ alongside the state bucket's. The bucket's IAM lives
# there because bootstrap CREATES the bucket. Bootstrap does not create this
# secret and must not, and the runtime accounts it would name do not exist until
# terraform/platform has run — so it would be a third home for the grant with an
# ordering trap in it. Whoever creates the secret grants its access, in one step.
#
# Commands: terraform/bootstrap/README.md § "The Tailscale auth-key secret".
# Enforced by test/terraform-tailscale-infra.bats, which fails if any Secret
# Manager IAM resource reappears anywhere in the environments root's transitive
# module closure.
# ---------------------------------------------------------------------------

locals {
  instance_name = "${var.name_prefix}-vm"

  # ─── Lane kind, and the three things that must agree about it ─────────────
  #
  # `kind` is a field of the frozen environment object (CONTRACT §3), passed
  # straight through by the root. It is NOT re-derived from the environment key
  # here, and not defaulted, because both of those fail OPEN: a defaulted kind
  # would give a CI lane no `ci-lane` label, the reaper would select nothing,
  # and the lane would bill forever with no error anywhere. A missing value must
  # fail the plan.
  is_ci_lane = var.kind == "ci"

  # ─── The reaper's selector ────────────────────────────────────────────────
  #
  # Emitted for CI lanes only. `merge` with an empty map rather than a
  # conditional value, so a demo lane's label set is byte-identical to what it
  # was before this module learned about CI lanes — an absent key is
  # unambiguous where an empty-string label is a value something has to
  # interpret. That is what makes "a demo VM carries no CI selector"
  # assertable rather than approximately true.
  ci_lane_labels = local.is_ci_lane ? { ci-lane = var.environment_key } : {}

  instance_labels = merge(var.labels, local.ci_lane_labels)

  # Read by scripts/ci/gcp-tf-reaper.sh. Keeping the threshold on the instance
  # means a lane cannot disagree with the reaper about its own idle budget.
  ci_metadata = local.is_ci_lane ? {
    idle-suspend-minutes = tostring(var.idle_suspend_minutes)
  } : {}

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
  # own attached service account, holding the human-granted secretAccessor
  # described at the head of this file.
  #
  # The secret id is taken from the DATA SOURCE rather than from the variable,
  # and the two are the same string: `secret_id` is a required input on that data
  # source, not a computed attribute, so it echoes exactly what was passed in.
  # The reference is therefore not about the value — it is about the EDGE. It
  # makes the instance depend on the existence check, so the name published to
  # the VM is provably the name of a secret that resolved at plan time, and
  # deleting the data source breaks the instance instead of silently removing the
  # gate. Before the secret's IAM binding moved out of this module that edge came
  # for free, because the binding consumed the data source; this is what carries
  # it now, and it is also why tflint does not report the lookup as unused.
  #
  # Emitted as an empty map when the feature is off, so a non-Tailscale
  # instance's metadata is byte-identical to what it was before this existed and
  # the startup script has exactly one signal to read.
  tailscale_metadata = var.tailscale_enabled ? {
    signalloom-tailscale-enabled   = "TRUE"
    signalloom-tailscale-secret-id = data.google_secret_manager_secret.tailscale_authkey[0].secret_id
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

  description = "Signal Loom ${var.environment_key} ${var.kind} VM"
  labels      = local.instance_labels
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
      labels = local.instance_labels
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
  }, local.tailscale_metadata, local.ci_metadata)

  metadata_startup_script = file(local.startup_script_file)

  lifecycle {
    # The boot image family resolves to a new self-link whenever Google
    # publishes a patched image. Without this, every plan after an upstream
    # image release proposes destroying the demo VM.
    ignore_changes = [boot_disk[0].initialize_params[0].image]

    # Migrated verbatim from modules/ci-runner, which this module absorbed.
    # GCP truncates nothing — it rejects the create — and the rejection arrives
    # at apply time, after everything upstream of the instance has been built.
    precondition {
      condition     = length(local.instance_name) <= 63
      error_message = "COMPUTE-RULE-06-NAME-LENGTH: instance name '${local.instance_name}' exceeds GCP's 63-character limit."
    }

    # ─── The reaper's selector, checked from three directions ──────────────
    #
    # Migrated and strengthened from modules/ci-runner's `ci-lane` label
    # integrity precondition. That one asserted the merge had not lost the
    # label. This asserts the harder property: that the label's PRESENCE is
    # decided by the environment definition and by nothing else.
    #
    # `var.kind` comes from the environment object, `labels["kind"]` comes from
    # the env-contract module's mandatory label set, and the key prefix is
    # enforced by env-contract validation rule 3. All three derive from one
    # tfvars entry, so agreement is free when the wiring is right and
    # impossible when it is not. A demo VM cannot acquire a CI selector by a
    # hand-pasted label, a copied module block, or a `for_each` filter someone
    # widened without thinking — every one of those leaves at least one of the
    # three disagreeing.
    # Strict lookup with an empty default, not `lookup(..., var.kind)`. A
    # forgiving default would make an ABSENT kind label pass, and absent is
    # exactly the state a caller that bypassed env-contract would be in — which
    # is the case this precondition exists to catch.
    precondition {
      condition     = lookup(var.labels, "kind", "") == var.kind
      error_message = "COMPUTE-RULE-07-KIND-LABEL-AGREEMENT: var.kind is '${var.kind}' but the merged label set says kind='${lookup(var.labels, "kind", "<absent>")}'. Both derive from the same environment entry via modules/env-contract, so a disagreement means one of them was wired from somewhere else — and the ci-lane label the reaper selects on is decided by var.kind."
    }

    precondition {
      condition     = startswith(var.environment_key, "${var.kind}-")
      error_message = "COMPUTE-RULE-08-KIND-KEY-AGREEMENT: environment_key '${var.environment_key}' does not carry the '${var.kind}-' prefix its kind requires. CONTRACT §3 validation rule 3 makes the key prefix equal the kind; a disagreement here means this module was called with a key and a kind from different entries."
    }

    # The positive and negative halves of the selector, asserted on the
    # evaluated label map rather than inferred from the locals that built it.
    precondition {
      condition     = local.is_ci_lane == contains(keys(local.instance_labels), "ci-lane")
      error_message = "COMPUTE-RULE-09-CI-LANE-LABEL: the ci-lane label must be present on a CI lane and ABSENT on a demo lane. scripts/ci/gcp-tf-reaper.sh selects instances to SUSPEND on this label; a demo VM that carries it is a demo VM the reaper is entitled to turn off."
    }

    precondition {
      condition     = !local.is_ci_lane || lookup(local.instance_labels, "ci-lane", "") == var.environment_key
      error_message = "COMPUTE-RULE-10-CI-LANE-VALUE: the ci-lane label must equal the environment key. The reaper matches its value against ^ci-[1-9][0-9]*$ and cross-checks it against the environment label; a mismatch makes the lane unreapable and it bills until somebody notices."
    }

    # ─── Disposability, which is the whole cost argument for CI lanes ───────
    #
    # modules/ci-runner hardcoded `deletion_protection = false` and explained
    # why in its header. Making it configurable here without this precondition
    # would silently drop that property: a CI lane applied with the demo
    # default is a lane nobody can delete, and its failure mode is a bill
    # rather than an error. The VALUE stays in tfvars where it is reviewable;
    # what is enforced is that a CI lane cannot be given the demo answer.
    precondition {
      condition     = !local.is_ci_lane || var.deletion_protection == false
      error_message = "COMPUTE-RULE-11-CI-DISPOSABLE: CI lane '${var.environment_key}' must set deletion_protect = false. A lane that cannot be deleted outlives the branch that needed it and bills quietly; that failure has no error message anywhere, which is why it is refused at plan time."
    }

    # A CI lane with no idle budget is the silent version of a broken reaper:
    # the metadata key is absent, the reaper has nothing to read, and the lane
    # runs until somebody looks at the invoice.
    precondition {
      condition     = !local.is_ci_lane || var.idle_suspend_minutes >= 5
      error_message = "COMPUTE-RULE-12-CI-IDLE-BUDGET: CI lane '${var.environment_key}' must publish idle_suspend_minutes >= 5; got ${var.idle_suspend_minutes}. Below 5 the reaper suspends lanes mid-run; at 0 it never suspends them at all."
    }
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
