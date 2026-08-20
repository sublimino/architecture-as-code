# Native Terraform tests for modules/compute.
#
# Assertions are on the EVALUATED instance — the attribute values Terraform
# computed, not the HCL text that produced them. `terraform test` can prove the
# instance this plan would create has no external IP; only bats can prove no
# `access_config` exists anywhere in the tree. Both surfaces are needed and
# neither substitutes for the other.
#
# Offline by construction: both providers are mocked. `command = plan` only.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id            = "CHANGEME-project"
  environment_key       = "demo-1"
  kind                  = "demo"
  name_prefix           = "sl-demo-1"
  zone                  = "europe-west2-a"
  subnet_self_link      = "projects/CHANGEME-project/regions/europe-west2/subnetworks/sl-demo-1-subnet"
  network_tag           = "sl-demo-1-node"
  service_account_email = "sl-demo-1-runtime@CHANGEME-project.iam.gserviceaccount.com"
  deletion_protection   = true
  app_port              = 8080

  labels = {
    environment = "demo-1"
    kind        = "demo"
    managed-by  = "terraform"
    component   = "signalloom"
  }
}

# ---------------------------------------------------------------------------
# Baseline. The negative tests below are only meaningful because this passes.
# ---------------------------------------------------------------------------

run "the_demo_vm_is_private_and_shielded" {
  command = plan

  # ISC-100. The evaluated network interface has no external IP configuration.
  # A grep proves the source has no access_config block; this proves the
  # instance Terraform would actually create has no external address.
  assert {
    condition     = length(one(google_compute_instance.this.network_interface).access_config) == 0
    error_message = "the demo VM must have no external IP"
  }

  assert {
    condition     = one(google_compute_instance.this.network_interface).subnetwork == var.subnet_self_link
    error_message = "the instance must attach to the subnet the network module created"
  }

  # ISC-105/106. All three, not the usual two.
  assert {
    condition     = one(google_compute_instance.this.shielded_instance_config).enable_secure_boot == true
    error_message = "secure boot must be enabled"
  }

  assert {
    condition     = one(google_compute_instance.this.shielded_instance_config).enable_vtpm == true
    error_message = "vTPM must be enabled"
  }

  assert {
    condition     = one(google_compute_instance.this.shielded_instance_config).enable_integrity_monitoring == true
    error_message = "integrity monitoring must be enabled; without vTPM it has nothing to measure against"
  }

  # ISC-102/104.
  assert {
    condition     = google_compute_instance.this.metadata["enable-oslogin"] == "TRUE"
    error_message = "OS Login must be enforced so SSH authorisation goes through IAM"
  }

  assert {
    condition     = google_compute_instance.this.metadata["block-project-ssh-keys"] == "TRUE"
    error_message = "project-wide SSH keys would bypass OS Login entirely"
  }

  assert {
    condition     = google_compute_instance.this.metadata["serial-port-enable"] == "FALSE"
    error_message = "the serial console is an out-of-band path that ignores the firewall"
  }

  # ISC-109/111.
  assert {
    condition     = one(google_compute_instance.this.service_account).email == var.service_account_email
    error_message = "the instance must carry the per-environment runtime service account"
  }

  assert {
    condition = anytrue([
      for s in one(google_compute_instance.this.service_account).scopes :
      can(regex("cloud-platform$", s))
    ])
    error_message = "scopes must be cloud-platform, with IAM doing the restricting"
  }

  # ISC-112/116.
  assert {
    condition     = google_compute_instance.this.tags == toset([var.network_tag])
    error_message = "the instance must carry exactly the network tag the network module derived"
  }

  assert {
    condition     = google_compute_instance.this.deletion_protection == true
    error_message = "deletion protection must resolve from the caller, not from a module default"
  }

  # ISC-114.
  assert {
    condition     = one(google_compute_instance.this.scheduling).preemptible == false
    error_message = "the demo VM must not be preemptible; a preemption mid-run reads as a product failure"
  }

  assert {
    condition     = one(google_compute_instance.this.scheduling).provisioning_model == "STANDARD"
    error_message = "the demo VM must not be a Spot instance"
  }

  # ISC-108.
  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == var.boot_disk_gb
    error_message = "boot disk size must come from the variable"
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).type == var.boot_disk_type
    error_message = "boot disk type must come from the variable"
  }
}

# ---------------------------------------------------------------------------
# ISC-351/352: evaluated names embed the environment key, and the evaluated
# labels carry the contract's mandatory set.
# ---------------------------------------------------------------------------

run "evaluated_names_and_labels_follow_the_contract" {
  command = plan

  assert {
    condition     = can(regex("demo-1", google_compute_instance.this.name))
    error_message = "the instance name must embed the environment key"
  }

  assert {
    condition     = can(regex("demo-1", google_compute_instance_group.this.name))
    error_message = "the instance group name must embed the environment key"
  }

  assert {
    condition = alltrue([
      for k in ["environment", "kind", "managed-by", "component"] :
      contains(keys(google_compute_instance.this.labels), k)
    ])
    error_message = "the instance must carry the contract's mandatory label set"
  }

  assert {
    condition     = google_compute_instance.this.labels["environment"] == var.environment_key
    error_message = "the environment label must match the environment key"
  }

  # The boot disk is labelled too — an unlabelled disk survives its instance
  # and then nobody can attribute the cost.
  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).labels["component"] == "signalloom"
    error_message = "the boot disk must carry the mandatory labels as well as the instance"
  }
}

# ---------------------------------------------------------------------------
# ISC-120: the unmanaged instance group the edge module's backend service
# resolves by named port. A group with the wrong port fails no plan and no
# grep — the load balancer simply never finds a healthy backend.
# ---------------------------------------------------------------------------

run "the_instance_group_tracks_the_app_port" {
  command = plan

  variables {
    app_port = 9443
  }

  assert {
    condition     = one(google_compute_instance_group.this.named_port).port == 9443
    error_message = "the instance group's named port must track var.app_port"
  }

  assert {
    condition     = one(google_compute_instance_group.this.named_port).name == "http"
    error_message = "the named port must be called http; the edge backend service resolves it by name"
  }

  assert {
    condition     = google_compute_instance_group.this.zone == var.zone
    error_message = "the instance group must be in the instance's zone"
  }
}

# ---------------------------------------------------------------------------
# ISC-107: Confidential Computing is addressed, and enabling it carries the
# host-maintenance consequences with it rather than producing an instance that
# fails to create.
# ---------------------------------------------------------------------------

run "confidential_compute_is_off_by_default" {
  command = plan

  assert {
    condition = length(google_compute_instance.this.confidential_instance_config) == 0
    # An EMPTY block is what "not confidential" looks like, and it is what the
    # API returns. Emitting the block with enable=false instead produced a
    # permanent diff on a ForceNew attribute, so every plan proposed replacing
    # a healthy VM. Found by deploying, not by any static assertion.
    error_message = "confidential compute must be explicitly off, not silently absent"
  }

  assert {
    condition     = one(google_compute_instance.this.scheduling).on_host_maintenance == "MIGRATE"
    error_message = "without confidential compute the instance should live-migrate"
  }

  assert {
    condition     = one(google_compute_instance.this.scheduling).automatic_restart == true
    error_message = "without confidential compute the instance should restart automatically"
  }
}

run "enabling_confidential_compute_forces_terminate_on_maintenance" {
  command = plan

  variables {
    enable_confidential_compute = true
    machine_type                = "n2d-standard-16"
  }

  assert {
    condition     = one(google_compute_instance.this.confidential_instance_config).enable_confidential_compute == true
    error_message = "the variable must actually enable confidential compute"
  }

  # A SEV instance cannot live-migrate. If the module left MIGRATE here the
  # apply fails at the API, which is a slow way to learn a static fact.
  assert {
    condition     = one(google_compute_instance.this.scheduling).on_host_maintenance == "TERMINATE"
    error_message = "a confidential instance cannot live-migrate; maintenance must terminate"
  }

  assert {
    condition     = one(google_compute_instance.this.scheduling).automatic_restart == false
    error_message = "automatic restart must be off when host maintenance terminates the instance"
  }
}

# ---------------------------------------------------------------------------
# The VM profile: sized for the workload that actually runs on it.
#
# The demo VM carries a Kind cluster running the whole Signal Loom estate,
# brought up by this repo's own `make demo-signalloom-up`. The measured
# reference for that exact bring-up is v1 CI: n2-standard-16 with a 200GB boot
# disk (scripts/ci/gcp-ci.sh). These runs assert the module can express that
# profile and that both values reach the instance rather than stopping at a
# variable nobody wired through.
# ---------------------------------------------------------------------------

run "the_measured_profile_reaches_the_instance" {
  command = plan

  variables {
    machine_type = "n2-standard-16"
    boot_disk_gb = 200
  }

  assert {
    condition     = google_compute_instance.this.machine_type == "n2-standard-16"
    error_message = "machine_type must reach the instance; v1 CI runs this same bring-up on n2-standard-16"
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == 200
    error_message = "boot_disk_gb must reach the boot disk; v1 CI provisions 200GB for this workload"
  }
}

run "the_module_defaults_are_the_measured_profile" {
  command = plan

  # No `variables` block: this asserts what an operator who sets NEITHER value
  # gets. A module whose defaults are undersized is one forgotten tfvars line
  # away from an acceptance run that times out, and the default is the value
  # that governs in exactly the case nobody reviewed.
  assert {
    condition     = google_compute_instance.this.machine_type == "n2-standard-16"
    error_message = "the module default machine type must be the measured profile, not a guess"
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == 200
    error_message = "the module default boot disk must be the measured 200GB"
  }
}

# ---------------------------------------------------------------------------
# Resizing must be an UPDATE, not a REPLACEMENT.
#
# What this run can honestly prove, and what it cannot: a mocked-provider plan
# has no prior state, so every resource is a create and Terraform never emits
# an update-vs-replace verdict for anything. What it CAN prove is that the
# mechanism which produces the update is present in the evaluated resource.
# Without allow_stopping_for_update the plan is still accepted and the APPLY
# fails at the API with "instance must be stopped", leaving the environment
# half-applied — so this attribute is the difference between a resize that
# works and one that strands the demo.
#
# The replacement hazard that was real here is separately covered by
# `confidential_compute_is_off_by_default`: an unconditional
# confidential_instance_config produced a perpetual diff on a ForceNew
# attribute and every plan proposed rebuilding a healthy VM.
# ---------------------------------------------------------------------------

run "resizing_the_vm_is_an_update_not_a_replacement" {
  command = plan

  variables {
    machine_type = "n2-standard-32"
  }

  assert {
    condition     = google_compute_instance.this.allow_stopping_for_update == true
    error_message = "allow_stopping_for_update must be true, or a machine_type change plans cleanly and then fails the apply with \"instance must be stopped\""
  }

  assert {
    condition     = google_compute_instance.this.machine_type == "n2-standard-32"
    error_message = "a larger machine type must be accepted; the floor is a floor, not a fixed size"
  }

  # The boot disk image is the one attribute deliberately ignored, because an
  # upstream image release otherwise proposes destroying the VM. Nothing else
  # may join it — a machine_type in ignore_changes would silently discard every
  # future resize.
  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == var.boot_disk_gb
    error_message = "boot disk size must still track the variable when the machine type changes"
  }

  # Scope note, so this run's NAME is not read as a claim it does not make.
  # It covers the MACHINE TYPE only. A boot_disk_gb change is ForceNew in the
  # provider and DOES destroy the instance — confirmed on a real plan against
  # the deployed demo-1 estate, where 100 → 200 planned 1 to add, 2 to change,
  # 1 to destroy. An offline mocked plan has no prior state and so cannot
  # observe either verdict; the distinction is documented at the
  # allow_stopping_for_update comment in main.tf, and this assertion pins the
  # source of the value rather than the update semantics.
  assert {
    condition     = google_compute_instance.this.allow_stopping_for_update == true
    error_message = "the stop-and-start mechanism must remain in place for machine-type changes"
  }
}

# ---------------------------------------------------------------------------
# Negative tests. Paired with "accepts_the_corrected_inputs" below.
# ---------------------------------------------------------------------------

# The specific value this profile exists to refuse. e2-standard-4 (4 vCPU /
# 16GB) was the demo default, chosen against nothing, while the identical
# bring-up was measured at 16 vCPU / 64GB in v1 CI.
run "rejects_the_undersized_demo_default" {
  command = plan

  variables {
    machine_type = "e2-standard-4"
  }

  expect_failures = [var.machine_type]
}

# Shared-core types carry no vCPU count in the name at all. The rule must
# reject them rather than fail to parse them — `try(..., 0)` is what turns an
# unparseable type into a refusal instead of an error about a regex.
run "rejects_a_shared_core_machine_type" {
  command = plan

  variables {
    machine_type = "e2-micro"
  }

  expect_failures = [var.machine_type]
}

# The one that satisfies the vCPU floor and is still wrong. n2-highcpu-16 has
# 16 vCPU and 16GB of RAM — less memory than the e2-standard-4 above.
run "rejects_a_highcpu_machine_type_despite_enough_vcpus" {
  command = plan

  variables {
    machine_type = "n2-highcpu-16"
  }

  expect_failures = [var.machine_type]
}

# The neighbour of every rejection above: the floor value itself, which is the
# sandbox's real choice (deploy/gcp/sl-port-over-sandbox.example.tfvars) and
# must plan. A floor that rejected its own boundary would be an off-by-one that
# no negative test could distinguish from correct behaviour.
run "accepts_the_machine_type_at_the_floor" {
  command = plan

  variables {
    machine_type = "n2-standard-8"
    boot_disk_gb = 100
  }

  assert {
    condition     = google_compute_instance.this.machine_type == "n2-standard-8"
    error_message = "8 vCPU is the documented floor and must be accepted"
  }
}

# highmem is the other legal class, and a custom type must survive the parser:
# `n2-custom-16-65536` embeds its vCPU count in the middle of the name, which a
# regex anchored to the end of the string would miss.
run "accepts_highmem_and_custom_machine_types" {
  command = plan

  variables {
    machine_type = "n2-highmem-16"
  }

  assert {
    condition     = google_compute_instance.this.machine_type == "n2-highmem-16"
    error_message = "highmem is a legal class for this workload and must be accepted"
  }
}

run "accepts_a_custom_machine_type_with_enough_vcpus" {
  command = plan

  variables {
    machine_type = "n2-custom-16-65536"
  }

  assert {
    condition     = google_compute_instance.this.machine_type == "n2-custom-16-65536"
    error_message = "a custom type naming 16 vCPUs must be accepted; the count is mid-string, not at the end"
  }
}


run "rejects_the_default_compute_service_account" {
  command = plan

  variables {
    # The one that carries project-wide Editor in most projects.
    service_account_email = "123456789012-compute@developer.gserviceaccount.com"
  }

  expect_failures = [var.service_account_email]
}

run "rejects_an_empty_service_account" {
  command = plan

  variables {
    # An empty value makes GCP silently attach the default compute SA.
    service_account_email = "  "
  }

  expect_failures = [var.service_account_email]
}

run "rejects_a_boot_disk_too_small_for_the_demo" {
  command = plan

  variables {
    # 50 rather than 10 on purpose. 10 is absurd and would be caught by almost
    # any rule; 50 is a value someone might actually type, and it is still half
    # of what the demo's container images need. A negative test whose input is
    # obviously wrong proves less than one whose input is plausibly wrong.
    boot_disk_gb = 50
  }

  expect_failures = [var.boot_disk_gb]
}

run "rejects_an_unknown_boot_disk_type" {
  command = plan

  variables {
    boot_disk_type = "pd-extreme-turbo"
  }

  expect_failures = [var.boot_disk_type]
}

run "rejects_an_out_of_range_app_port" {
  command = plan

  variables {
    app_port = 0
  }

  expect_failures = [var.app_port]
}

# The positive half of every pairing above. Each value here is the neighbour of
# a rejected one, so the validations are narrow rather than merely present.
run "accepts_the_corrected_inputs" {
  command = plan

  variables {
    service_account_email = "sl-ci-1-runtime@CHANGEME-project.iam.gserviceaccount.com"
    boot_disk_gb          = 100
    boot_disk_type        = "pd-ssd"
    app_port              = 1
    deletion_protection   = false
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == 100
    error_message = "100GB is the documented floor and must be accepted"
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).type == "pd-ssd"
    error_message = "pd-ssd is a valid boot disk type and must be accepted"
  }

  assert {
    condition     = one(google_compute_instance_group.this.named_port).port == 1
    error_message = "port 1 is in range and must be accepted"
  }

  # An SA whose name merely contains "compute" is not the default compute SA.
  # The validation must reject the suffix, not the substring.
  assert {
    condition     = one(google_compute_instance.this.service_account).email == "sl-ci-1-runtime@CHANGEME-project.iam.gserviceaccount.com"
    error_message = "a per-environment SA must be accepted"
  }

  assert {
    condition     = google_compute_instance.this.deletion_protection == false
    error_message = "ci environments pass deletion_protection = false and must be accepted"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# TAILSCALE
#
# Three claims are made in prose elsewhere and enforced here:
#
#   1. With the feature off, NOTHING is planned. Not a data source, not a
#      metadata key. An environment with no auth-key secret must plan and apply
#      exactly as it did before this existed.
#   2. With the feature on, the secret is looked up READ-ONLY and the lookup is
#      LOAD-BEARING — the metadata key the VM reads is taken from it, so the
#      published name is provably the name of a secret that resolved at plan
#      time. The secret's IAM is granted once by a human and is not declared in
#      this module at all; the structural half of that claim (no Secret Manager
#      IAM resource anywhere in the environments root's module closure) is in
#      test/terraform-tailscale-infra.bats, because a plan cannot assert the
#      absence of a resource type it would have to name to reference.
#   3. The auth key is NEVER in metadata. Instance metadata is plain text and
#      readable by anyone holding compute.instances.get; what travels there is
#      the NAME of the secret. The whole-file version of that assertion lives in
#      test/terraform-tailscale-access.bats, because absence-across-a-file is
#      not something a plan can see.
#
# In this file rather than a suite of its own for the same reason the network
# module's UDP runs are: test/terraform-network-security.bats copies
# `tests/*.tftest.hcl` onto one destination path, so a second file here breaks
# that guard with a `cp` error.
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# OFF BY DEFAULT, and off means nothing is planned.
#
# The three assertions are deliberately separate resources rather than one
# combined condition: a `count` edit, a data-source edit and a metadata edit are
# three different mistakes, and a merged assertion would name none of them.
# ---------------------------------------------------------------------------

run "tailscale_is_off_by_default_and_plans_no_resource" {
  command = plan

  assert {
    condition     = var.tailscale_enabled == false
    error_message = "tailscale_enabled must default to false. The auth-key secret is created out of band, so a true default makes every environment without one fail at plan with \"secret not found\" — including CI lanes that will never have a tailnet."
  }

  assert {
    condition     = length(data.google_secret_manager_secret.tailscale_authkey) == 0
    error_message = "with tailscale disabled the module must not look the secret up at all; a data source that always runs makes an optional feature mandatory at plan time"
  }

  # Metadata keys ABSENT, not present-and-empty. An empty-string value is a
  # value the startup script would still have to interpret; absence is
  # unambiguous, and it means a non-Tailscale instance's metadata is identical
  # to what it was before this feature existed.
  assert {
    condition     = !contains(keys(google_compute_instance.this.metadata), "signalloom-tailscale-enabled")
    error_message = "with tailscale disabled no signalloom-tailscale-* metadata key may be emitted"
  }

  assert {
    condition     = !contains(keys(google_compute_instance.this.metadata), "signalloom-tailscale-secret-id")
    error_message = "with tailscale disabled the secret name must not appear in instance metadata"
  }

  # The hardening the module already had is untouched by any of this. Asserted
  # in the same run so a change that added Tailscale by weakening the instance
  # fails here rather than in a file nobody re-reads.
  assert {
    condition     = google_compute_instance.this.metadata["enable-oslogin"] == "TRUE"
    error_message = "OS Login must survive the metadata merge; a merge that dropped it would move SSH authorisation off IAM entirely"
  }

  assert {
    condition     = google_compute_instance.this.metadata["block-project-ssh-keys"] == "TRUE"
    error_message = "project-wide SSH keys must still be refused at the instance"
  }

  assert {
    condition     = google_compute_instance.this.metadata["serial-port-enable"] == "FALSE"
    error_message = "serial console access must still be disabled"
  }
}

# ---------------------------------------------------------------------------
# ENABLED: the secret is READ, and the read is load-bearing.
#
# This run used to assert a `google_secret_manager_secret_iam_member` — one
# grant, secret-scoped, of exactly one role. Every one of those claims was true
# and the resource is gone anyway, because it was declared by the wrong owner.
# Managing the secret's policy from here requires the deploy identity to hold
# secretmanager.secrets.setIamPolicy on it, and an identity that can setIamPolicy
# on a secret can grant itself read of that secret. That account runs unattended.
# See the long comment at the head of ../main.tf, and its precedent at the foot
# of modules/deploy-identity/main.tf: creation and IAM are lifecycle, and
# lifecycle belongs to the one-time privileged human step.
#
# What survives here is the half that is still this module's business — that the
# lookup happens, and that it cannot be quietly deleted without breaking the
# instance.
# ---------------------------------------------------------------------------

run "enabling_tailscale_reads_the_secret_and_the_read_gates_the_instance" {
  command = plan

  variables {
    tailscale_enabled = true
  }

  assert {
    condition     = length(data.google_secret_manager_secret.tailscale_authkey) == 1
    error_message = "enabling tailscale must look the secret up, so that a missing secret fails at PLAN rather than leaving a VM that silently never joins the tailnet"
  }

  # The lookup is a DATA source and stays one. A `resource` of the same name
  # would put the auth key's payload in state; a `_version` resource is refused
  # tree-wide by test/terraform-tailscale-infra.bats. Here the property asserted
  # is narrower and is the one a plan can see: what the module read is the secret
  # it was told to read, not some other secret in the project.
  assert {
    condition     = data.google_secret_manager_secret.tailscale_authkey[0].secret_id == var.tailscale_authkey_secret_id
    error_message = "the module must look up the ONE secret named by tailscale_authkey_secret_id"
  }

  # THE EDGE, and the reason this run is not decoration.
  #
  # The metadata key the VM reads is taken from the data source rather than from
  # the variable. The two strings are identical — `secret_id` is a required input
  # on that data source, not a computed attribute — so this asserts nothing about
  # the VALUE. It asserts the DEPENDENCY: the instance cannot be planned without
  # the existence check having resolved first. While the IAM binding lived here
  # it consumed the data source and that edge came for free. Nothing else
  # consumes it now, so a future edit that "tidied up an unused data source"
  # would silently remove the plan-time gate and no other assertion in this file
  # would notice.
  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-secret-id"] == data.google_secret_manager_secret.tailscale_authkey[0].secret_id
    error_message = "the secret name published to the VM must come FROM the lookup, so deleting the lookup breaks the instance instead of silently removing the plan-time existence gate"
  }
}

# ---------------------------------------------------------------------------
# What travels in metadata, and what must not.
# ---------------------------------------------------------------------------

run "metadata_carries_the_secret_name_and_never_the_key" {
  command = plan

  variables {
    tailscale_enabled = true
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-enabled"] == "TRUE"
    error_message = "the enabled flag must reach the instance, or the startup script's Tailscale stage never runs"
  }

  # The NAME of the secret. Resolving it to a value requires
  # roles/secretmanager.secretAccessor, which is the grant asserted above.
  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-secret-id"] == var.tailscale_authkey_secret_id
    error_message = "metadata must carry the secret's NAME so the VM can resolve it at runtime"
  }

  # No metadata VALUE may look like a Tailscale key. Startup scripts and
  # metadata are stored in plain text and readable by anyone holding
  # compute.instances.get, which is the exact threat the module header names.
  #
  # Enumerated over every value rather than over the keys this feature adds: a
  # key smuggled in under an unrelated name — signalloom-environment, a label —
  # would pass a per-key check and fail this one.
  assert {
    condition = alltrue([
      for v in values(google_compute_instance.this.metadata) :
      !strcontains(v, "tskey-")
    ])
    error_message = "an instance metadata value looks like a Tailscale auth key. Metadata is plain text and readable by anyone with compute.instances.get; the key is fetched from Secret Manager at runtime and must never be written here."
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-tag"] == "tag:sl-demo"
    error_message = "the ACL tag must reach the instance; an untagged node is owned by the user whose key created it rather than by the tailnet policy"
  }
}

# ---------------------------------------------------------------------------
# The node's hostname is DERIVED, not configured.
#
# Run with a non-default environment_key so a hardcoded "sl-demo-1" in the
# module fails here. That is the whole reason this run exists — asserting the
# demo-1 value would be satisfied by a literal.
# ---------------------------------------------------------------------------

run "the_tailscale_hostname_derives_from_the_environment_key" {
  command = plan

  variables {
    tailscale_enabled = true
    environment_key   = "demo-7"
    name_prefix       = "sl-demo-7"
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-hostname"] == "sl-demo-7"
    error_message = "the tailnet hostname must derive from the environment key. A deterministic name is what makes the EPHEMERAL key's reap predictable: a rebuilt VM reclaims sl-demo-7 rather than accumulating sl-demo-7-1, sl-demo-7-2 in the tailnet device list."
  }

  # And it tracks the environment rather than the prefix, which are separate
  # inputs that happen to agree in every environment shipped so far.
  assert {
    condition     = strcontains(google_compute_instance.this.metadata["signalloom-tailscale-hostname"], var.environment_key)
    error_message = "the tailnet hostname must embed the environment key"
  }
}

# ---------------------------------------------------------------------------
# Tailscale SSH: off unless asked for, on when asked for.
#
# Both halves, because "defaults to false" is satisfied by a flag that is wired
# to nothing at all.
# ---------------------------------------------------------------------------

run "tailscale_ssh_is_off_unless_the_environment_asks" {
  command = plan

  variables {
    tailscale_enabled = true
  }

  assert {
    condition     = var.tailscale_ssh_enabled == false
    error_message = "tailscale_ssh_enabled must default to false: it adds a second authorisation system that GCP IAM and the GCP audit log cannot see, on a VM whose posture claim is that IAM is the only gate"
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-ssh"] == "FALSE"
    error_message = "the default must reach the instance as FALSE, or the flag governs nothing"
  }
}

run "enabling_tailscale_ssh_reaches_the_instance" {
  command = plan

  variables {
    tailscale_enabled     = true
    tailscale_ssh_enabled = true
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-ssh"] == "TRUE"
    error_message = "setting tailscale_ssh_enabled must reach the instance; without this the run above proves only that a constant is constant"
  }

  # Enabling the tailnet's own SSH must not disturb the cloud's. Both gates
  # stand; the trade being made is "a second path", never "a replacement".
  assert {
    condition     = google_compute_instance.this.metadata["enable-oslogin"] == "TRUE"
    error_message = "enabling Tailscale SSH must not disable OS Login"
  }
}

# ---------------------------------------------------------------------------
# The VM stays private. Every one of these held before Tailscale existed and
# must still hold with it fully enabled — that is the claim the whole feature
# rests on, so it is asserted rather than argued.
# ---------------------------------------------------------------------------

run "an_enabled_tailscale_node_is_still_a_private_shielded_vm" {
  command = plan

  variables {
    tailscale_enabled     = true
    tailscale_ssh_enabled = true
  }

  # No external IP. `access_config` is what would create one, and its absence is
  # the single property that keeps this instance off the public internet.
  assert {
    condition     = length(google_compute_instance.this.network_interface[0].access_config) == 0
    error_message = "the instance must have no access_config and therefore no external IP. Tailscale needs none — it is outbound-only — and adding one would route around both the load balancer and the egress policy in one line."
  }

  assert {
    condition = alltrue([
      one(google_compute_instance.this.shielded_instance_config).enable_secure_boot,
      one(google_compute_instance.this.shielded_instance_config).enable_vtpm,
      one(google_compute_instance.this.shielded_instance_config).enable_integrity_monitoring,
    ])
    error_message = "all three Shielded VM protections must survive the Tailscale change"
  }

  assert {
    condition     = one(google_compute_instance.this.service_account).email == var.service_account_email
    error_message = "the instance must still run as the per-environment runtime service account"
  }
}

# ---------------------------------------------------------------------------
# Negatives, each paired with a positive.
# ---------------------------------------------------------------------------

run "rejects_a_full_resource_path_as_the_secret_id" {
  command = plan

  variables {
    tailscale_enabled           = true
    tailscale_authkey_secret_id = "projects/CHANGEME-project/secrets/sl-demo-tailscale-authkey"
  }

  expect_failures = [var.tailscale_authkey_secret_id]
}

run "rejects_an_empty_secret_id" {
  command = plan

  variables {
    tailscale_enabled           = true
    tailscale_authkey_secret_id = ""
  }

  expect_failures = [var.tailscale_authkey_secret_id]
}

run "rejects_an_untagged_tailscale_tag" {
  command = plan

  variables {
    # The plausible mistake: the tag's NAME without the "tag:" prefix.
    # Tailscale refuses it at `tailscale up`, on the VM, at boot, with the
    # message going to a serial console this instance has disabled — so the
    # observed symptom is a node that never joins.
    tailscale_enabled = true
    tailscale_tag     = "sl-demo"
  }

  expect_failures = [var.tailscale_tag]
}

run "rejects_an_uppercase_tailscale_tag" {
  command = plan

  variables {
    tailscale_enabled = true
    tailscale_tag     = "tag:SL-Demo"
  }

  expect_failures = [var.tailscale_tag]
}

run "accepts_a_corrected_secret_id_and_tag" {
  command = plan

  variables {
    tailscale_enabled           = true
    tailscale_authkey_secret_id = "sl-demo-2-tailscale-authkey"
    tailscale_tag               = "tag:sl-demo-2"
  }

  assert {
    condition     = data.google_secret_manager_secret.tailscale_authkey[0].secret_id == "sl-demo-2-tailscale-authkey"
    error_message = "a bare secret id must be accepted and must reach the lookup, or the negatives above prove nothing"
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-tag"] == "tag:sl-demo-2"
    error_message = "a correctly-prefixed tag must be accepted and must reach the instance"
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# CI LANES
#
# Migrated from terraform/modules/ci-runner/tests/ci_runner.tftest.hcl, which
# was deleted with its module on 2026-08-20. Everything that suite asserted
# about a lane instance is asserted here against modules/compute with
# `kind = "ci"`, plus the properties that only exist once the two kinds share a
# module: that a CI lane really is the demo machine, and that a demo lane
# really does not carry the reaper's selector.
#
# ─── The one that matters ──────────────────────────────────────────────────
#
# scripts/ci/gcp-tf-reaper.sh SUSPENDS instances and selects them on the
# `ci-lane` label. This module is the only thing that emits it. So the pair
# `a_ci_lane_carries_the_reapers_selector` /
# `a_demo_lane_carries_no_reapers_selector` is a positive-and-negative control
# and neither half is worth anything alone: the negative is trivially satisfied
# by a module that emits no labels at all, which is also what a broken
# implementation produces. Read them together, and never delete one.
# ═══════════════════════════════════════════════════════════════════════════

run "a_ci_lane_is_the_same_machine_as_a_demo_lane" {
  command = plan

  variables {
    environment_key       = "ci-1"
    kind                  = "ci"
    name_prefix           = "sl-ci-1"
    service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    subnet_self_link      = "projects/CHANGEME-project/regions/europe-west2/subnetworks/sl-ci-1-subnet"
    network_tag           = "sl-ci-1-node"
    deletion_protection   = false
    idle_suspend_minutes  = 45
    labels = {
      environment = "ci-1"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  # THE REASON THE MODULES WERE MERGED. modules/ci-runner had no
  # metadata_startup_script at all, so a CI lane booted a bare box and every fix
  # to the demo bring-up landed on a machine CI never ran. A CI lane that does
  # not carry the bring-up is a CI lane testing something the demo is not.
  #
  # Asserted as a length rather than a `!= ""`, because an empty file would
  # satisfy the latter and is the same defect wearing a shorter name.
  assert {
    condition     = length(google_compute_instance.this.metadata_startup_script) > 100
    error_message = "a CI lane must carry the same bring-up startup script as a demo lane; modules/ci-runner carried none, which is why it was removed"
  }

  # Shielded VM, all three fields. Secure boot alone is not shielded VM.
  assert {
    condition = alltrue([
      one(google_compute_instance.this.shielded_instance_config).enable_secure_boot,
      one(google_compute_instance.this.shielded_instance_config).enable_vtpm,
      one(google_compute_instance.this.shielded_instance_config).enable_integrity_monitoring,
    ])
    error_message = "a CI lane must be shielded on all three axes, exactly as a demo lane is"
  }

  assert {
    condition     = google_compute_instance.this.metadata["enable-oslogin"] == "TRUE"
    error_message = "OS Login must be enforced on a CI lane"
  }

  assert {
    condition     = google_compute_instance.this.metadata["block-project-ssh-keys"] == "TRUE"
    error_message = "project-wide SSH keys would bypass OS Login entirely, on a CI lane as much as a demo one"
  }

  # ISC-183's property, migrated: omitting the service_account block does not
  # produce an identity-less VM, it produces one running as the default Compute
  # Engine SA, which holds roles/editor on the whole project.
  assert {
    condition     = one(google_compute_instance.this.service_account).email == "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    error_message = "a CI lane must run as its own per-lane runtime service account"
  }

  assert {
    condition     = length(one(google_compute_instance.this.network_interface).access_config) == 0
    error_message = "a CI lane must have no external IP"
  }

  # ISC-182's property, migrated, with the name shape that CHANGED. Both kinds
  # are `sl-<key>-vm` now; `sl-ci-1-runner` was modules/ci-runner's shape and the
  # reaper's old selector matched exactly that string.
  assert {
    condition     = google_compute_instance.this.name == "sl-ci-1-vm"
    error_message = "a CI lane must use the unified name shape sl-<key>-vm, not modules/ci-runner's sl-<key>-runner"
  }

  assert {
    condition     = length(google_compute_instance.this.name) <= 63
    error_message = "instance name exceeds GCP's 63-character limit"
  }
}

run "a_ci_lane_carries_the_reapers_selector" {
  command = plan

  variables {
    environment_key       = "ci-1"
    kind                  = "ci"
    name_prefix           = "sl-ci-1"
    service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    deletion_protection   = false
    idle_suspend_minutes  = 45
    labels = {
      environment = "ci-1"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  # The positive half of the control. scripts/ci/gcp-tf-reaper.sh gate 1 selects
  # on this label's PRESENCE and gate 2 on its VALUE; if it is absent or wrong,
  # the reaper silently reaps nothing and lanes bill forever.
  assert {
    condition     = google_compute_instance.this.labels["ci-lane"] == "ci-1"
    error_message = "a CI lane must carry ci-lane = <lane key>; the reaper selects on it"
  }

  assert {
    condition     = output.ci_lane_label == "ci-1"
    error_message = "the emitted ci_lane_label output must equal the lane key"
  }

  # The reaper's gates 3 and 4 read these two. They come from the env-contract's
  # mandatory set and must survive the ci-lane merge.
  assert {
    condition     = google_compute_instance.this.labels["kind"] == "ci"
    error_message = "the kind label is the reaper's gate 3; it must survive the ci-lane merge"
  }

  assert {
    condition     = google_compute_instance.this.labels["environment"] == "ci-1"
    error_message = "the environment label is the reaper's gate 4; it must equal the ci-lane label"
  }

  assert {
    condition     = google_compute_instance.this.labels["managed-by"] == "terraform"
    error_message = "the contract's mandatory labels must survive the ci-lane merge"
  }

  # Migrated from ci_runner.tftest.hcl. The reaper reads its budget off the
  # instance rather than carrying a duplicate constant, so a lane cannot
  # disagree with the reaper about its own idle window.
  assert {
    condition     = google_compute_instance.this.metadata["idle-suspend-minutes"] == "45"
    error_message = "the idle suspend budget must be published on the instance for the reaper to read"
  }

  # Deliberately the opposite of the demo VM.
  assert {
    condition     = google_compute_instance.this.deletion_protection == false
    error_message = "CI lanes must not have deletion protection; a lane that cannot be deleted outlives the branch that needed it and bills quietly"
  }
}

run "a_demo_lane_carries_no_reapers_selector" {
  command = plan

  # Inherits the file-level demo-1 variables. NOTHING is overridden here on
  # purpose: this is the configuration the live estate actually plans.

  # ─── The safety property, in plan form ─────────────────────────────────────
  #
  # sl-demo-1-vm is a running demo. scripts/ci/gcp-tf-reaper.sh gate 1 admits an
  # instance because it carries this label. If modules/compute ever emitted it
  # for a demo lane, the reaper would be entitled to suspend that demo — and the
  # only thing between the two would be gates 3-5, which exist precisely because
  # nobody should have to rely on a single check for this.
  #
  # Read with `a_ci_lane_carries_the_reapers_selector` above. Alone, this
  # assertion is satisfied by a module that emits no labels at all, which is
  # indistinguishable from the broken implementation it is supposed to catch.
  assert {
    condition     = !contains(keys(google_compute_instance.this.labels), "ci-lane")
    error_message = "a demo VM must NOT carry the ci-lane label; scripts/ci/gcp-tf-reaper.sh selects instances to SUSPEND on it"
  }

  assert {
    condition     = output.ci_lane_label == ""
    error_message = "the ci_lane_label output must be empty for a demo lane"
  }

  # And the metadata half. A demo VM advertising an idle-suspend budget invites
  # exactly the mistake the label design exists to prevent, so the key must be
  # ABSENT rather than zero — absent is unambiguous, 0 is a value something has
  # to interpret.
  assert {
    condition     = !contains(keys(google_compute_instance.this.metadata), "idle-suspend-minutes")
    error_message = "a demo VM must not publish an idle-suspend budget at all, not even 0"
  }

  # The positive control for the two negatives above: this instance DOES carry
  # labels and metadata, so their emptiness is not what makes the assertions
  # pass. Without this, a module that emitted nothing would satisfy all three.
  assert {
    condition     = google_compute_instance.this.labels["kind"] == "demo"
    error_message = "positive control: the demo lane must carry the mandatory kind label, or the ci-lane absence above proves nothing"
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-environment"] == "demo-1"
    error_message = "positive control: the demo lane must carry its environment metadata, or the idle-suspend absence above proves nothing"
  }
}

run "a_second_ci_lane_produces_its_own_instance_and_selector" {
  command = plan

  variables {
    environment_key       = "ci-2"
    kind                  = "ci"
    name_prefix           = "sl-ci-2"
    service_account_email = "sl-rt-ci-2@CHANGEME-project.iam.gserviceaccount.com"
    deletion_protection   = false
    idle_suspend_minutes  = 45
    labels = {
      environment = "ci-2"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  assert {
    condition     = google_compute_instance.this.name == "sl-ci-2-vm"
    error_message = "a second lane must produce its own instance name"
  }

  assert {
    condition     = google_compute_instance.this.labels["ci-lane"] == "ci-2"
    error_message = "a second lane must carry its own ci-lane label"
  }
}

# ── Negative tests, each paired with a positive (CONTRACT §7a) ──────────────

run "rejects_an_unknown_lane_kind" {
  command = plan

  variables {
    kind = "prod"
  }

  expect_failures = [var.kind]
}

run "accepts_the_two_known_lane_kinds" {
  command = plan

  # The paired positive for the rule above. `demo` is the file-level default and
  # is exercised by every other run; `ci` is proven by the CI runs above. This
  # asserts the boundary explicitly so "rejects prod" is not indistinguishable
  # from "rejects everything".
  variables {
    kind = "demo"
  }

  assert {
    condition     = google_compute_instance.this.labels["kind"] == "demo"
    error_message = "the corrected kind must be accepted"
  }
}

run "rejects_an_idle_suspend_window_short_enough_to_kill_a_live_run" {
  command = plan

  variables {
    idle_suspend_minutes = 1
  }

  expect_failures = [var.idle_suspend_minutes]
}

run "accepts_zero_as_the_demo_lane_answer" {
  command = plan

  # 0 is legal and means "not a reapable lane". This is the paired positive for
  # the rule above AND the reason the floor of 5 is a precondition rather than a
  # variable validation — a validation cannot know that 0 is right for a demo
  # lane and fatal for a CI one.
  variables {
    idle_suspend_minutes = 0
  }

  assert {
    condition     = !contains(keys(google_compute_instance.this.metadata), "idle-suspend-minutes")
    error_message = "0 must be accepted and must emit no metadata key at all"
  }
}

run "rejects_a_ci_lane_with_no_idle_budget" {
  command = plan

  # 0 is legal for a demo lane and fatal for a CI one: the metadata key would be
  # absent, the reaper would have nothing to read, and the lane would run until
  # somebody looked at the invoice. COMPUTE-RULE-12.
  variables {
    environment_key       = "ci-1"
    kind                  = "ci"
    name_prefix           = "sl-ci-1"
    service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    deletion_protection   = false
    idle_suspend_minutes  = 0
    labels = {
      environment = "ci-1"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  expect_failures = [google_compute_instance.this]
}

run "rejects_a_deletion_protected_ci_lane" {
  command = plan

  # COMPUTE-RULE-11. modules/ci-runner hardcoded deletion_protection = false;
  # making it configurable here without this rule would have silently dropped
  # that property, and its failure mode is a bill rather than an error.
  variables {
    environment_key       = "ci-1"
    kind                  = "ci"
    name_prefix           = "sl-ci-1"
    service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    deletion_protection   = true
    idle_suspend_minutes  = 45
    labels = {
      environment = "ci-1"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  expect_failures = [google_compute_instance.this]
}

run "rejects_a_kind_that_disagrees_with_the_merged_label" {
  command = plan

  # COMPUTE-RULE-07. This is the shape that would let a demo VM acquire a CI
  # selector: var.kind says "ci" — so the ci-lane label is emitted — while the
  # environment this was actually built from is a demo. Both derive from one
  # tfvars entry through modules/env-contract, so they only disagree when
  # something wired them from different places.
  variables {
    kind                 = "ci"
    idle_suspend_minutes = 45
    deletion_protection  = false
    labels = {
      environment = "demo-1"
      kind        = "demo"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  expect_failures = [google_compute_instance.this]
}

run "rejects_a_kind_that_disagrees_with_the_environment_key" {
  command = plan

  # COMPUTE-RULE-08. The other direction: a `ci` kind on a `demo-` key. CONTRACT
  # §3 validation rule 3 makes the key prefix equal the kind, so this can only
  # arise from a key and a kind taken from different entries.
  variables {
    environment_key      = "demo-1"
    kind                 = "ci"
    name_prefix          = "sl-demo-1"
    idle_suspend_minutes = 45
    deletion_protection  = false
    labels = {
      environment = "demo-1"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  expect_failures = [google_compute_instance.this]
}

run "accepts_a_consistent_ci_lane_after_the_corrections" {
  command = plan

  # The paired positive for all four precondition negatives above. Without it,
  # a precondition that fired for an unrelated reason — a typo in a condition, a
  # missing variable — would be indistinguishable from the rule under test.
  variables {
    environment_key       = "ci-3"
    kind                  = "ci"
    name_prefix           = "sl-ci-3"
    service_account_email = "sl-rt-ci-3@CHANGEME-project.iam.gserviceaccount.com"
    deletion_protection   = false
    idle_suspend_minutes  = 45
    labels = {
      environment = "ci-3"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  assert {
    condition     = google_compute_instance.this.labels["ci-lane"] == "ci-3"
    error_message = "the corrected, internally consistent CI lane must be accepted"
  }

  assert {
    condition     = google_compute_instance.this.name == "sl-ci-3-vm"
    error_message = "the corrected CI lane must plan its instance"
  }
}
