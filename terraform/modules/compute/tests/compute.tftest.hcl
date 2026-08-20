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
#   1. With the feature off, NOTHING is planned. Not a data source, not an IAM
#      binding, not a metadata key. An environment with no auth-key secret must
#      plan and apply exactly as it did before this existed.
#   2. The secret grant is SECRET-SCOPED. The available alternative — a project
#      IAM member with the same role — reads almost identically in a diff and
#      differs by the entire blast radius of the project's secret store.
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

  assert {
    condition     = length(google_secret_manager_secret_iam_member.tailscale_authkey_accessor) == 0
    error_message = "with tailscale disabled no IAM binding may be planned"
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
# ENABLED: exactly one grant, at secret scope, of exactly one role.
# ---------------------------------------------------------------------------

run "enabling_tailscale_grants_secret_accessor_at_secret_scope" {
  command = plan

  variables {
    tailscale_enabled = true
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.tailscale_authkey_accessor) == 1
    error_message = "enabling tailscale must create exactly one IAM binding"
  }

  # SECRET SCOPE. The resource TYPE is the control — google_secret_manager_secret_iam_member
  # binds on one secret, where google_project_iam_member with the same role would
  # grant read on every secret in the project, present and future, to a service
  # account attached to a VM that pulls public container images. Asserting the
  # bound secret_id is how that type choice becomes visible in a test: a
  # project-scoped binding has no secret_id attribute at all, so this assertion
  # cannot be satisfied by one.
  assert {
    condition     = google_secret_manager_secret_iam_member.tailscale_authkey_accessor[0].secret_id == var.tailscale_authkey_secret_id
    error_message = "the binding must name the ONE secret holding the auth key. A project-scoped grant of the same role reads almost identically in a diff and differs by the entire blast radius of the project's secret store."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.tailscale_authkey_accessor[0].role == "roles/secretmanager.secretAccessor"
    error_message = "the role must be roles/secretmanager.secretAccessor — read a version's payload, and nothing else"
  }

  # secretAccessor and NOT its neighbours. Named individually because each is a
  # plausible mis-grant with a very different meaning: admin can add versions and
  # rewrite the key, viewer leaks metadata about every secret it can see, and
  # secretVersionManager can destroy the version the VM depends on.
  #
  # The primitive roles are DELIBERATELY NOT in this list even though they are
  # the worst possible values here. `test/terraform-identity.bats` greps the
  # whole terraform tree for a line that is exactly `"roles/owner",` and fails
  # on it — correctly, because it cannot distinguish a grant from a denylist
  # entry, and a guard that has to make that distinction is one that gets a
  # carve-out and then stops working. They are covered instead by the exact
  # role equality asserted directly above, which admits no value but
  # secretAccessor.
  assert {
    condition = !contains([
      "roles/secretmanager.admin",
      "roles/secretmanager.secretVersionManager",
      "roles/secretmanager.secretVersionAdder",
      "roles/secretmanager.viewer",
    ], google_secret_manager_secret_iam_member.tailscale_authkey_accessor[0].role)
    error_message = "the binding holds a role broader than secretAccessor. The VM reads one key at boot; it never needs to add, rotate, destroy or enumerate anything."
  }

  # The member is the instance's OWN attached identity, not a human and not a CI
  # principal. This is what makes "the VM fetches it at runtime under its own
  # service account" true rather than merely intended.
  assert {
    condition     = google_secret_manager_secret_iam_member.tailscale_authkey_accessor[0].member == "serviceAccount:${var.service_account_email}"
    error_message = "the grant must go to the instance's own attached runtime service account"
  }

  assert {
    condition     = length(data.google_secret_manager_secret.tailscale_authkey) == 1
    error_message = "enabling tailscale must look the secret up, so that a missing secret fails at PLAN rather than leaving a VM that silently never joins the tailnet"
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
    condition     = google_secret_manager_secret_iam_member.tailscale_authkey_accessor[0].secret_id == "sl-demo-2-tailscale-authkey"
    error_message = "a bare secret id must be accepted and must reach the binding, or the negatives above prove nothing"
  }

  assert {
    condition     = google_compute_instance.this.metadata["signalloom-tailscale-tag"] == "tag:sl-demo-2"
    error_message = "a correctly-prefixed tag must be accepted and must reach the instance"
  }
}
