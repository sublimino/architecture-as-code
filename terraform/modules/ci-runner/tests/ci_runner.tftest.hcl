# Native terraform tests for modules/ci-runner.
#
# Mocked providers, plan only. The assertions are on evaluated attributes: what
# the instance actually came out as, not what the source says.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id      = "CHANGEME-project"
  environment_key = "ci-1"
  name_prefix     = "sl-ci-1"
  labels = {
    environment = "ci-1"
    kind        = "ci"
    managed-by  = "terraform"
    component   = "signalloom"
  }
  zone                  = "europe-west2-a"
  machine_type          = "n2-standard-16"
  boot_disk_gb          = 200
  subnet_self_link      = "projects/CHANGEME-project/regions/europe-west2/subnetworks/sl-ci-1-subnet"
  network_tag           = "sl-ci-1"
  service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
  idle_suspend_minutes  = 45
}

run "instance_is_named_for_its_lane" {
  command = plan

  # ISC-182.
  assert {
    condition     = google_compute_instance.runner.name == "sl-ci-1-runner"
    error_message = "The lane instance must be named from name_prefix, embedding the lane key."
  }

  assert {
    condition     = strcontains(google_compute_instance.runner.name, var.environment_key)
    error_message = "The instance name must embed the lane key."
  }

  assert {
    condition     = length(google_compute_instance.runner.name) <= 63
    error_message = "Instance name exceeds GCP's 63-character limit."
  }
}

run "labels_carry_the_ci_lane_selector" {
  command = plan

  # ISC-184. The reaper selects on this label; if it is absent or wrong, the
  # reaper silently reaps nothing and lanes bill forever.
  assert {
    condition     = google_compute_instance.runner.labels["ci-lane"] == var.environment_key
    error_message = "The instance must carry label ci-lane = <lane key>."
  }

  assert {
    condition     = google_compute_instance.runner.labels["managed-by"] == "terraform"
    error_message = "The contract's mandatory labels must survive the ci-lane merge."
  }

  assert {
    condition     = google_compute_instance.runner.labels["component"] == "signalloom"
    error_message = "The contract's mandatory labels must survive the ci-lane merge."
  }

  assert {
    condition     = output.ci_lane_label == var.environment_key
    error_message = "The emitted ci-lane label must equal the lane key."
  }
}

run "no_external_ip_is_ever_configured" {
  command = plan

  assert {
    condition     = length(google_compute_instance.runner.network_interface[0].access_config) == 0
    error_message = "The lane instance must have no access_config — no external IP, ingress via IAP only."
  }

  assert {
    condition     = google_compute_instance.runner.network_interface[0].subnetwork == var.subnet_self_link
    error_message = "The lane instance must attach to the supplied subnet."
  }
}

run "shielded_vm_is_fully_enabled" {
  command = plan

  # All three fields. Secure boot alone is not shielded VM.
  assert {
    condition     = google_compute_instance.runner.shielded_instance_config[0].enable_secure_boot
    error_message = "Secure boot must be enabled."
  }

  assert {
    condition     = google_compute_instance.runner.shielded_instance_config[0].enable_vtpm
    error_message = "vTPM must be enabled."
  }

  assert {
    condition     = google_compute_instance.runner.shielded_instance_config[0].enable_integrity_monitoring
    error_message = "Integrity monitoring must be enabled."
  }
}

run "os_login_is_on_and_project_ssh_keys_are_blocked" {
  command = plan

  # OS Login binds SSH to IAM. Without block-project-ssh-keys, a project-wide
  # key still gets in and the IAM binding is not exclusive.
  assert {
    condition     = google_compute_instance.runner.metadata["enable-oslogin"] == "TRUE"
    error_message = "OS Login must be enabled."
  }

  assert {
    condition     = google_compute_instance.runner.metadata["block-project-ssh-keys"] == "TRUE"
    error_message = "Project-wide SSH keys must be blocked."
  }

  assert {
    condition     = !can(google_compute_instance.runner.metadata["ssh-keys"])
    error_message = "No ssh-keys metadata may be set on a lane instance."
  }
}

run "lane_uses_its_own_service_account" {
  command = plan

  # ISC-183. Omitting this block entirely does not produce an identity-less VM —
  # it produces one running as the default Compute Engine SA, which holds editor.
  assert {
    condition     = google_compute_instance.runner.service_account[0].email == var.service_account_email
    error_message = "The lane must run as its own per-lane service account."
  }

  assert {
    condition     = strcontains(google_compute_instance.runner.service_account[0].email, var.environment_key)
    error_message = "The lane's service account must be the one keyed on this lane."
  }

  assert {
    condition     = !strcontains(google_compute_instance.runner.service_account[0].email, "compute@developer.gserviceaccount.com")
    error_message = "The lane must never run as the default Compute Engine service account."
  }
}

run "ci_lanes_are_disposable" {
  command = plan

  # Deliberately the opposite of the demo VM: a lane that cannot be deleted
  # outlives the branch that needed it and bills quietly.
  assert {
    condition     = google_compute_instance.runner.deletion_protection == false
    error_message = "CI lanes must not have deletion protection."
  }

  assert {
    condition     = google_compute_instance.runner.metadata["idle-suspend-minutes"] == "45"
    error_message = "The idle suspend budget must be published on the instance for the reaper to read."
  }
}

run "a_second_lane_produces_a_distinct_instance_and_label" {
  command = plan

  variables {
    environment_key       = "ci-2"
    name_prefix           = "sl-ci-2"
    service_account_email = "sl-rt-ci-2@CHANGEME-project.iam.gserviceaccount.com"
    labels = {
      environment = "ci-2"
      kind        = "ci"
      managed-by  = "terraform"
      component   = "signalloom"
    }
  }

  assert {
    condition     = google_compute_instance.runner.name == "sl-ci-2-runner"
    error_message = "A second lane must produce its own instance name."
  }

  assert {
    condition     = google_compute_instance.runner.labels["ci-lane"] == "ci-2"
    error_message = "A second lane must carry its own ci-lane label."
  }
}

# ── Negative tests, each paired with a positive (ISC-346) ───────────────────

run "rejects_a_demo_environment_key" {
  command = plan

  variables {
    environment_key = "demo-1"
  }

  expect_failures = [var.environment_key]
}

run "accepts_a_ci_environment_key" {
  command = plan

  variables {
    environment_key       = "ci-3"
    name_prefix           = "sl-ci-3"
    service_account_email = "sl-rt-ci-3@CHANGEME-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_compute_instance.runner.labels["ci-lane"] == "ci-3"
    error_message = "The corrected CI lane key must be accepted."
  }
}

run "rejects_an_empty_service_account_email" {
  command = plan

  variables {
    service_account_email = ""
  }

  expect_failures = [var.service_account_email]
}

run "accepts_a_service_account_email" {
  command = plan

  variables {
    service_account_email = "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
  }

  assert {
    condition     = google_compute_instance.runner.service_account[0].email == "sl-rt-ci-1@CHANGEME-project.iam.gserviceaccount.com"
    error_message = "The corrected service account email must be accepted."
  }
}

run "rejects_an_idle_suspend_window_short_enough_to_kill_a_live_run" {
  command = plan

  variables {
    idle_suspend_minutes = 1
  }

  expect_failures = [var.idle_suspend_minutes]
}

run "accepts_a_sane_idle_suspend_window" {
  command = plan

  variables {
    idle_suspend_minutes = 20
  }

  assert {
    condition     = google_compute_instance.runner.metadata["idle-suspend-minutes"] == "20"
    error_message = "The corrected idle window must be accepted and published."
  }
}

run "rejects_an_undersized_boot_disk" {
  command = plan

  variables {
    boot_disk_gb = 5
  }

  expect_failures = [var.boot_disk_gb]
}

run "accepts_a_sane_boot_disk" {
  command = plan

  variables {
    boot_disk_gb = 100
  }

  assert {
    condition     = google_compute_instance.runner.boot_disk[0].initialize_params[0].size == 100
    error_message = "The corrected boot disk size must be accepted."
  }
}
