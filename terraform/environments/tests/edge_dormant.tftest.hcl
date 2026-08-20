# The dormant-edge wiring, asserted against the evaluated root configuration.
#
# The point of this file is not "the edge defaults are private" — other suites
# cover that. The point is the sharper claim that TODAY no lane has a live
# HTTPS load balancer at all, and that the root must publish and consume that
# fact from one place rather than by implication.
#
# `command = plan` only, both providers mocked, and terraform_remote_state
# overridden, so nothing here reaches GCP or a real state bucket.

mock_provider "google" {}
mock_provider "google-beta" {}

override_data {
  target = data.terraform_remote_state.platform

  values = {
    outputs = {
      runtime_service_account_emails = {
        "demo-1" = "sl-rt-demo-1@changeme-project.iam.gserviceaccount.com"
        "demo-2" = "sl-rt-demo-2@changeme-project.iam.gserviceaccount.com"
        "ci-1"   = "sl-rt-ci-1@changeme-project.iam.gserviceaccount.com"
        "ci-2"   = "sl-rt-ci-2@changeme-project.iam.gserviceaccount.com"
      }
      ci_plan_service_account_email  = "sl-ci-plan@changeme-project.iam.gserviceaccount.com"
      ci_apply_service_account_email = "sl-ci-apply@changeme-project.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id          = "sl-demo-platform"
  state_bucket_name   = "changeme-tfstate"
  startup_script_path = "../modules/compute/startup/demo-vm.sh"
  target_env          = "demo-1"

  # access_mode still defaults to "iap", and the root validates that an IAP
  # posture names at least one principal. The dormant-edge runs therefore keep
  # a realistic principal in place so the edge-dormancy assertions, not an
  # unrelated input guard, decide whether the plan is green.
  iap_members = ["user:someone@example.invalid"]

  # All FOUR lanes, at the n2-standard-8 the CPUS_ALL_REGIONS quota of 32
  # forces (4 x 8 = 32 exactly). The estate is being torn down and rebuilt on
  # these, so every lane below is recreated from scratch and whatever this
  # wiring decides is what the new estate gets on day one — which is why the
  # fixture carries the real lane set rather than a convenient pair.
  environments = {
    "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
    "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = { tier = "demo" } }
    "ci-1"   = { kind = "ci", subnet_cidr = "10.10.5.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "", allowed_ipv4 = [], allowed_ipv6 = [], app_port = 8080, deletion_protect = false, labels = { tier = "ci" } }
    "ci-2"   = { kind = "ci", subnet_cidr = "10.10.7.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "", allowed_ipv4 = [], allowed_ipv6 = [], app_port = 8080, deletion_protect = false, labels = { tier = "ci" } }
  }
}

run "no_lane_has_an_edge" {
  command = plan

  assert {
    condition     = length(output.edge_environment_keys) == 0
    error_message = "the root instantiates no edge module today, so any lane appearing in edge_environment_keys means local.edge_environments and the commented-out module \"edge\" block have drifted apart; re-enabling one without the other is how a public HTTPS frontend with IAP gets reintroduced silently."
  }
}

# ─── The rule itself, per lane, not merely the input that gates it ──────────
#
# modules/network publishes health_check_firewall_names precisely so this file
# can observe the PLANNED RESOURCE rather than the variable passed down to it.
# An earlier version of this run asserted only that edge_environment_keys was
# empty and trusted the module to act on it — which is an untested claim
# wearing the vocabulary of a test.
#
# One run per lane because `target_env` instantiates exactly one, and "no lane
# has the rule" is not proven by checking whichever lane happened to be the
# fixture default. The estate is about to be rebuilt on all four.

run "demo_1_plans_no_health_check_ingress" {
  command = plan

  variables {
    target_env = "demo-1"
  }

  assert {
    condition     = length(module.network["demo-1"].health_check_firewall_names) == 0
    error_message = "demo-1 planned a health-check ingress rule. With no load balancer the GCP probe ranges 130.211.0.0/22 and 35.191.0.0/16 reach this lane never, so the rule admits nothing and is pure surface."
  }
}

run "demo_2_plans_no_health_check_ingress" {
  command = plan

  variables {
    target_env = "demo-2"
  }

  assert {
    condition     = length(module.network["demo-2"].health_check_firewall_names) == 0
    error_message = "demo-2 planned a health-check ingress rule despite having no edge."
  }
}

run "ci_1_plans_no_health_check_ingress" {
  command = plan

  variables {
    target_env = "ci-1"
  }

  assert {
    condition     = length(module.network["ci-1"].health_check_firewall_names) == 0
    error_message = "ci-1 planned a health-check ingress rule. A CI lane has no public edge by design, so this is surface with no possible legitimate source."
  }
}

run "ci_2_plans_no_health_check_ingress" {
  command = plan

  variables {
    target_env = "ci-2"
  }

  assert {
    condition     = length(module.network["ci-2"].health_check_firewall_names) == 0
    error_message = "ci-2 planned a health-check ingress rule despite having no edge."
  }
}

# ─── The branch cannot be flipped by tfvars content ─────────────────────────
#
# The worry this answers, in the orchestrator's words: "I do not want to
# discover at rebuild time that the condition reads a variable the live tfvars
# does not set."
#
# It reads none. local.edge_environments is the literal `{}`, so edge_enabled is
# false for every lane whatever the environment map says. This run proves that
# by setting a hostname on both demo lanes — the field that gates the TLS
# frontend inside modules/edge, and the most plausible thing a future operator
# would set while believing they were turning the edge on — and showing the
# health-check ingress STILL does not appear.
#
# That is the difference between a condition derived from configuration data
# and one derived from whether the module is instantiated. Only the second is
# true by construction.
run "setting_a_hostname_does_not_resurrect_the_ingress" {
  command = plan

  variables {
    target_env = "demo-1"
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = { tier = "demo" } }
    }
  }

  assert {
    condition     = length(module.network["demo-1"].health_check_firewall_names) == 0
    error_message = "a hostname in the environment map resurrected the health-check ingress. The condition has started reading configuration data instead of whether module \"edge\" is instantiated, so the firewall rule can now disagree with whether a load balancer exists."
  }

  assert {
    condition     = length(output.edge_environment_keys) == 0
    error_message = "a hostname in the environment map made a lane claim an edge, but no edge module is instantiated to serve it."
  }
}

run "the_access_mode_reported_is_the_tunnel_not_the_web_edge" {
  command = plan

  assert {
    condition     = output.access_mode == "iap_tunnel"
    error_message = "reporting \"iap\" with no edge deployed claims a control the estate does not have; the real path in force is the IAP TCP tunnel, and the hand-off file is read by the test suite."
  }
}

run "a_non_default_access_mode_is_still_masked_while_the_edge_is_dormant" {
  command = plan

  variables {
    access_mode = "iap_and_allowlist"
    iap_members = ["user:someone@example.invalid"]
  }

  assert {
    condition     = output.access_mode == "iap_tunnel"
    error_message = "while no edge is instantiated, even a non-default web-edge posture must be masked to iap_tunnel; otherwise the hand-off reports an HTTPS frontend posture the estate does not actually have."
  }
}
