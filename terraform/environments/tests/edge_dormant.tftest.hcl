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

  environments = {
    "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
    "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = { tier = "demo" } }
  }
}

run "no_lane_has_an_edge" {
  command = plan

  assert {
    condition     = length(output.edge_environment_keys) == 0
    error_message = "the root instantiates no edge module today, so any lane appearing in edge_environment_keys means local.edge_environments and the commented-out module \"edge\" block have drifted apart; re-enabling one without the other is how a public HTTPS frontend with IAP gets reintroduced silently."
  }
}

run "the_health_check_ingress_is_not_created" {
  command = plan

  # This root-level tftest can see root outputs cleanly, but it cannot make an
  # honest assertion about a private resource inside module.network without the
  # module exporting it. So this run asserts the root-level fact that feeds
  # edge_enabled — the one place a lane can be declared edge-bearing — rather
  # than pretending it observed google_compute_firewall.allow_health_checks.
  #
  # The module's own suite already exercises both branches of the internal
  # count-gated resource. This file's job is to guard the root wiring that must
  # keep the input-side answer empty while the edge module stays dormant.
  assert {
    condition     = !contains(output.edge_environment_keys, output.target_env)
    error_message = "demo-1 must not appear in edge_environment_keys while the edge module stays commented out, because that same emptiness is what feeds module.network's edge_enabled input and keeps the health-check ingress absent."
  }
  assert {
    condition     = length(output.edge_environment_keys) == 0
    error_message = "edge_environment_keys must stay empty until the documented two-line re-enable path is taken together."
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
