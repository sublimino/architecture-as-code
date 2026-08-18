# The environments root, asserted against the evaluated configuration.
#
# CONTRACT.md §7a. What this file can prove that a grep cannot: that
# `local.target_environments` actually resolved to exactly one environment,
# that it resolved to the one named in `target_env`, and that the whole map
# nevertheless stayed in scope for the cross-environment rules. Those are
# properties of evaluation, not of source text.
#
# `command = plan` only, and both providers are mocked, so nothing here reaches
# GCP. That matters more than usual: this machine has working gcloud
# credentials, which is exactly what turns a plausible-looking apply into real
# billable infrastructure.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id = "sl-demo-platform"
  target_env = "demo-1"

  # access_mode defaults to "iap", and an IAP environment that names no
  # principal is a locked door with no key. The root's non-empty validation
  # therefore aborts any plan without this, which is the guard working — so the
  # fixture names a principal rather than the guard being removed. Supplying it
  # here also makes the fixture realistic: every environment this root will ever
  # plan for real has one.
  iap_members = ["user:someone@example.invalid"]
  environments = {
    "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24", "198.51.100.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
    "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = { tier = "demo" } }
  }
}

# ─── CONTRACT.md §5a mechanism 1 — one environment per apply ─────────────────

run "target_env_narrows_the_apply_to_exactly_one_environment" {
  command = plan

  assert {
    condition     = join(",", output.target_environment_keys) == "demo-1"
    error_message = "exactly one environment must be instantiated, and it must be the one named by target_env"
  }
  assert {
    condition     = length(output.target_environment_keys) == 1
    error_message = "a length other than one means the for_each filter is not filtering; zero would be a plan that destroys everything in state"
  }
  assert {
    condition     = output.target_env == "demo-1"
    error_message = "target_env must be published for the Makefile to compare against ENV and the backend prefix suffix"
  }
}

run "the_whole_map_stays_in_scope_while_one_environment_is_applied" {
  command = plan

  # This is the property that makes the narrowing safe. If the root filtered
  # the map before handing it to env-contract, a hostname or subnet collision
  # between demo-1 and demo-2 would become invisible — and it would become
  # invisible precisely on the apply that introduces the second environment.
  assert {
    condition     = join(",", output.environment_keys) == "demo-1,demo-2"
    error_message = "both environments must remain in scope for the cross-environment uniqueness rules"
  }
  assert {
    condition     = join(",", output.target_environment_keys) == "demo-1"
    error_message = "...while still instantiating only one of them"
  }
}

run "switching_target_env_switches_the_instantiated_environment" {
  # Same map, same file, different target. Proves target_env is doing the
  # selecting rather than the map order or the first key winning.
  command = plan
  variables {
    target_env = "demo-2"
  }

  assert {
    condition     = join(",", output.target_environment_keys) == "demo-2"
    error_message = "target_env = demo-2 must instantiate demo-2 and nothing else"
  }
  assert {
    condition     = output.target_environment.name_prefix == "sl-demo-2"
    error_message = "the resolved single-environment view must be demo-2's"
  }
  assert {
    condition     = output.target_environment.subnet_cidr == "10.10.3.0/24"
    error_message = "resolving the wrong environment's subnet is how one environment's resources land in another's state"
  }
}

run "target_env_naming_an_absent_key_is_rejected" {
  # The quietest failure in the design. Without the rule the filter yields an
  # empty map, and a for_each over an empty map is a SUCCESSFUL plan — one
  # proposing to destroy every resource already in that environment's state.
  # Paired with the positive runs above, which use the same map with a
  # target_env that exists.
  command = plan
  variables {
    target_env = "demo-9"
  }
  expect_failures = [var.target_env]
}

# ─── project_id: ISC-58, ISC-59 ──────────────────────────────────────────────

run "a_placeholder_project_id_is_rejected" {
  command = plan
  variables {
    project_id = "CHANGEME-project"
  }
  expect_failures = [var.project_id]
}

run "an_example_project_id_is_rejected" {
  command = plan
  variables {
    project_id = "example-proj"
  }
  expect_failures = [var.project_id]
}

run "a_too_short_project_id_is_rejected" {
  command = plan
  variables {
    project_id = "abc"
  }
  expect_failures = [var.project_id]
}

run "a_malformed_but_non_placeholder_project_id_is_rejected" {
  # This run exists because deleting PROJECT-RULE-02-FORMAT left the whole
  # suite green without it. The three rejections above are all caught by
  # PROJECT-RULE-01 as well, so none of them isolates the format rule, and the
  # format rule could have been deleted silently.
  #
  # "SL-Demo-Platform" is long enough, contains neither CHANGEME nor example,
  # and so passes rule 01 — but GCP project IDs are lowercase, so only rule 02
  # can reject it. Found by deleting each rule in turn against a throwaway copy
  # rather than by reading the tests.
  command = plan
  variables {
    project_id = "SL-Demo-Platform"
  }
  expect_failures = [var.project_id]
}

run "a_well_formed_project_id_is_accepted" {
  # The corrected pair for all three rejections above: same configuration,
  # only the project ID fixed. Without this run, a project_id rejection caused
  # by an unrelated broken variable would read as the placeholder rule firing.
  command = plan
  variables {
    project_id = "sl-demo-platform"
  }

  assert {
    condition     = output.integration_inputs.project_id == "sl-demo-platform"
    error_message = "a valid project_id must pass validation and reach the modules"
  }
}

# ─── The empty map: ISC-54 ───────────────────────────────────────────────────

run "an_empty_environments_map_is_rejected" {
  command = plan
  variables {
    environments = {}
  }
  expect_failures = [var.environments]
}

# ─── Extensibility: ISC-75, executed rather than described ───────────────────

run "one_environment_resolves_with_the_same_unmodified_source" {
  command = plan
  variables {
    target_env = "demo-1"
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
    }
  }

  assert {
    condition     = join(",", output.environment_keys) == "demo-1"
    error_message = "the single-environment map must resolve"
  }
}

run "adding_demo_2_costs_a_map_entry_and_nothing_else" {
  # The run above and this one differ by ONE map entry and no Terraform source
  # at all — same root, same module, same file on disk. Names and labels for
  # demo-2 appear without anything having been told about demo-2, which is what
  # "adding an environment is a tfvars edit" has to mean if it is to be true.
  command = plan
  variables {
    target_env = "demo-2"
    environments = {
      "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = {} }
      "demo-2" = { kind = "demo", subnet_cidr = "10.10.3.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-2.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }

  assert {
    condition     = join(",", output.environment_keys) == "demo-1,demo-2"
    error_message = "the second environment must resolve with no source change"
  }
  assert {
    condition     = output.name_prefix["demo-2"] == "sl-demo-2"
    error_message = "demo-2 must get a derived name prefix nobody wrote by hand"
  }
  assert {
    condition = alltrue([
      output.mandatory_labels["demo-2"]["environment"] == "demo-2",
      output.mandatory_labels["demo-2"]["kind"] == "demo",
      output.mandatory_labels["demo-2"]["managed-by"] == "terraform",
      output.mandatory_labels["demo-2"]["component"] == "signalloom",
    ])
    error_message = "demo-2 must get the full mandatory label set with no per-environment block"
  }
  assert {
    condition     = join(",", output.target_environment_keys) == "demo-2"
    error_message = "and it must be applyable on its own, selected by target_env"
  }
}

# ─── A CI lane resolves differently from a demo lane ─────────────────────────

run "a_ci_lane_resolves_with_no_dns_and_no_uptime_target" {
  command = plan
  variables {
    target_env = "ci-1"
    environments = {
      "ci-1" = { kind = "ci", subnet_cidr = "10.10.2.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-8", boot_disk_gb = 100, hostname = "", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = false, labels = {} }
    }
  }

  assert {
    condition     = join(",", output.ci_keys) == "ci-1"
    error_message = "a ci-* key must be partitioned as a CI lane"
  }
  assert {
    condition     = length(output.uptime_targets) == 0
    error_message = "a CI lane has no public edge and no hostname, so it must produce no uptime target to alert on forever"
  }
  assert {
    condition     = output.target_environment.deletion_protect == false
    error_message = "a CI lane must be destroyable; deletion protection on an ephemeral lane is how estates leak cost"
  }
}

# ─── The root mirrors modules/edge's non-empty IAP rule ─────────────────────
#
# This validation was initially left out of the root because enabling it aborted
# every plan of a fixture that named no principal — the guard working, read as
# the guard being in the way. The fixture was wrong, not the rule: an IAP
# environment that authorises nobody is a locked door with no key, and the
# failure mode is a demo nobody can open, discovered at demo time.
#
# Failing at the ROOT is better than failing inside the module: the operator
# sees the error against the variable they actually set in their tfvars.

run "an_iap_environment_naming_no_principal_is_rejected" {
  command = plan

  variables {
    access_mode = "iap"
    iap_members = []
  }

  expect_failures = [var.iap_members]
}

run "iap_and_allowlist_naming_no_principal_is_also_rejected" {
  command = plan

  variables {
    access_mode = "iap_and_allowlist"
    iap_members = []
  }

  expect_failures = [var.iap_members]
}

# An allowlist-only environment has no IAP to lock anyone out of, so an empty
# principal list is legal there. Without this the rule could be "always require
# principals" and both negatives above would still pass.
run "an_allowlist_only_environment_may_name_no_iap_principal" {
  command = plan

  variables {
    access_mode = "allowlist"
    iap_members = []
  }

  assert {
    condition     = var.access_mode == "allowlist"
    error_message = "an allowlist-only environment must plan cleanly with no IAP principals"
  }
}

# Paired positive for the negatives: the same IAP config with a principal named
# must plan. Without it, a rule that rejected every value would look correct.
run "an_iap_environment_naming_a_principal_plans_cleanly" {
  command = plan

  variables {
    access_mode = "iap"
    iap_members = ["user:someone@example.invalid"]
  }

  assert {
    condition     = length(var.iap_members) == 1
    error_message = "the corrected baseline must plan cleanly, or the two negatives above prove nothing"
  }
}
