# The root's edge-reachability variables, asserted on the EVALUATED default.
#
# Why this is a separate file rather than more runs in root_contract.tftest.hcl:
# run-level `variables` blocks MERGE with the file-level block, they do not
# replace it. A run that "omits" an input still receives the file header's
# value, so a test about DEFAULTS is meaningless in a file whose header sets the
# thing under test. This header sets only the three genuinely required
# variables and nothing else.
#
# Why the root and not just modules/edge: a module default governs only while
# the caller passes no value. `terraform/environments` passes
# `access_mode = var.access_mode` into the edge module, so from that moment the
# MODULE's default is dead and the value below is what ships. A root quietly
# defaulting to "allowlist" would reverse the private-edge posture while every
# module test stayed green.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id = "sl-demo-platform"
  target_env = "demo-1"

  # The root now mirrors modules/edge's non-empty IAP rule, and access_mode
  # defaults to "iap", so a fixture that names no principal cannot plan. That is
  # the guard working: an IAP environment authorising nobody is a locked door
  # with no key. The runs below that specifically test the empty case override
  # this with an explicit expect_failures.
  iap_members = ["user:someone@example.invalid"]

  environments = {
    "demo-1" = { kind = "demo", subnet_cidr = "10.10.1.0/24", region = "europe-west2", zone = "europe-west2-a", machine_type = "n2-standard-16", boot_disk_gb = 200, hostname = "demo-1.example.invalid", allowed_ipv4 = ["192.0.2.0/24"], allowed_ipv6 = ["2001:db8::/32"], app_port = 8080, deletion_protect = true, labels = { tier = "demo" } }
  }
}

# ─── access_mode ────────────────────────────────────────────────────────────

run "default_access_mode_is_iap" {
  command = plan

  assert {
    condition     = output.integration_inputs.access_mode == "iap"
    error_message = "the root's access_mode default is not \"iap\". The safe posture must be what you get by not thinking about it; a default of \"allowlist\" here silently removes authentication from every environment."
  }
}

# The paired positive for the negative below. Without it, a run that failed for
# an unrelated reason — a syntax error, a renamed variable — would be
# indistinguishable from the validation rule firing correctly.
run "the_other_two_legal_access_modes_are_accepted" {
  command = plan

  variables {
    access_mode = "iap_and_allowlist"
    iap_members = ["user:someone@example.invalid"]
  }

  assert {
    condition     = output.integration_inputs.access_mode == "iap_and_allowlist"
    error_message = "iap_and_allowlist is a legal access_mode and must plan cleanly"
  }
}

run "an_access_mode_outside_the_three_legal_values_is_rejected" {
  command = plan

  variables {
    # "public" is the value a reader guesses by analogy. It is not one of the
    # three, and guessing it must fail loudly rather than fall through.
    access_mode = "public"
  }

  expect_failures = [var.access_mode]
}

# ─── iap_members ────────────────────────────────────────────────────────────

run "a_prefixed_principal_is_accepted" {
  command = plan

  variables {
    iap_members = ["user:someone@example.invalid", "group:team@example.invalid"]
  }

  assert {
    condition     = length(output.integration_inputs.iap_members) == 2
    error_message = "correctly-prefixed principals must plan cleanly; without this the rejections below prove nothing"
  }
}

run "all_users_is_rejected" {
  command = plan

  variables {
    iap_members = ["allUsers"]
  }

  expect_failures = [var.iap_members]
}

run "all_authenticated_users_is_rejected" {
  command = plan

  variables {
    # The dangerous one. "authenticated" reads as a restriction; in IAP it means
    # any Google account in existence.
    iap_members = ["allAuthenticatedUsers"]
  }

  expect_failures = [var.iap_members]
}

run "a_wildcard_principal_set_is_rejected" {
  command = plan

  variables {
    # Prefix-valid, so only the wildcard clause can reject this. That clause is
    # the reason this file can tell the two iap_members rules apart at all.
    iap_members = ["principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/pool/*"]
  }

  expect_failures = [var.iap_members]
}

run "a_bare_email_address_is_rejected" {
  command = plan

  variables {
    # Not a principal. Accepted silently by a weaker guard, and grants nothing
    # at all — an environment nobody can open, with no error to explain it.
    iap_members = ["someone@example.invalid"]
  }

  expect_failures = [var.iap_members]
}
