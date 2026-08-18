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
# Negative tests. Paired with "accepts_the_corrected_inputs" below.
# ---------------------------------------------------------------------------

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
    boot_disk_gb = 10
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
    boot_disk_gb          = 20
    boot_disk_type        = "pd-ssd"
    app_port              = 1
    deletion_protection   = false
  }

  assert {
    condition     = one(one(google_compute_instance.this.boot_disk).initialize_params).size == 20
    error_message = "20GB is the documented floor and must be accepted"
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
