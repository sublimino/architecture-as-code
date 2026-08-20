# Native Terraform tests for the platform root.
#
# The module tests in modules/observability/tests/ prove the module is correct in
# isolation. These prove the ROOT composes it correctly — that the channels this
# root creates actually reach the alert policies, that the audit sink is not
# pointed at the state bucket by the values this root passes down, and that the
# DNS gate is a real gate.
#
# mock_provider mandatory, command = plan only. See CONTRACT.md section 7a.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id        = "changeme-project"
  state_bucket_name = "changeme-project-tfstate"

  # Required since the identity module was wired into this root at integration.
  project_number            = "123456789012"
  environment_keys          = ["demo-1"]
  github_owner_id           = "123456789012"
  github_repository         = "example-org/osramp-demo"
  github_allowed_ref        = "refs/heads/main"
  github_apply_workflow_ref = "example-org/osramp-demo/.github/workflows/gcp-apply.yml@refs/heads/main"

  notification_emails = ["platform-owner@example.invalid"]

  uptime_targets = {
    "demo-1" = { hostname = "demo-1.example.invalid", app_port = 8080 }
  }

  billing_account_id = "000000-AAAAAA-BBBBBB"

  dns_zone_name = "signalloom-demo"
  dns_domain    = "demo.example.invalid."
}

# ---------------------------------------------------------------------------
# ISC-206 / ISC-207 — evaluated at the composition boundary
# ---------------------------------------------------------------------------

# ─── Replaced when observability went dormant (2026-08-20) ──────────────────
#
# This run asserted that the audit sink's bucket was not the Terraform state
# bucket, reading `output.log_bucket_name`. That output is dormant with
# module "observability" (see main.tf), so the run no longer references
# anything that exists and terraform test fails to even evaluate it.
#
# Deleting it and moving on would have been the wrong repair, because the
# property it protected — "the audit sink never writes into the state bucket" —
# is real and must come back with the module. It is preserved verbatim below so
# restoring observability restores its guard in the same edit.
#
# What replaces it is the stronger claim for the current configuration, and it
# is NOT the same assertion weakened: it says no audit sink exists to be
# misdirected. That distinction matters. An absent output would satisfy a
# "!= state_bucket" test trivially, which is exactly the vacuous pass the
# second assertion below was written to prevent — so the honest test for a
# dormant module is one about dormancy, not a survivor of the old one.
#
# run "audit_sink_destination_is_not_the_state_bucket" {
#   command = plan
#
#   assert {
#     condition     = output.log_bucket_name != var.state_bucket_name
#     error_message = "The platform root wired the audit sink into the Terraform state bucket."
#   }
#
#   assert {
#     condition     = output.log_bucket_name != ""
#     error_message = "The audit bucket name evaluated empty — the assertion above would then pass vacuously against any non-empty state bucket name."
#   }
# }

# The dormancy assertion deliberately does NOT live here. `terraform test`
# observes a plan, and a plan cannot show the absence of a module: there is no
# address to reference, so any condition written here would either fail to
# evaluate (the error this replaced) or be a tautology that passes whether or
# not observability is live. EdgeGuard's edge_dormant.tftest.hcl can assert
# dormancy only because modules/network publishes health_check_firewall_names
# for it to count; nothing analogous exists once module "observability" is gone.
#
# The guard is in test/terraform-observability-dormant.bats instead, where the
# resolved module graph is observable and a positive control can prove the check
# would see a live module if there were one.

# ---------------------------------------------------------------------------
# ISC-213 / ISC-214 — the channels this root creates reach the alert policies
# ---------------------------------------------------------------------------

run "notification_channels_are_created_and_propagated" {
  command = plan

  assert {
    condition     = length(google_monitoring_notification_channel.owners) == length(var.notification_emails)
    error_message = "one notification channel must be created per named owner"
  }

  assert {
    condition     = google_monitoring_notification_channel.owners["platform-owner@example.invalid"].type == "email"
    error_message = "owner channels must be email channels"
  }

  assert {
    condition     = google_monitoring_notification_channel.owners["platform-owner@example.invalid"].labels.email_address == "platform-owner@example.invalid"
    error_message = "the channel must carry the owner's address"
  }

  assert {
    condition     = length(output.notification_channel_ids) > 0
    error_message = "the composed channel list reaching modules/observability evaluated empty"
  }
}

run "externally_managed_channels_are_merged_in" {
  command = plan

  variables {
    notification_emails            = []
    extra_notification_channel_ids = ["projects/changeme-project/notificationChannels/2222222222"]
  }

  assert {
    condition     = length(google_monitoring_notification_channel.owners) == 0
    error_message = "no channel should be created when no owner email is supplied"
  }

  assert {
    condition     = output.notification_channel_ids == ["projects/changeme-project/notificationChannels/2222222222"]
    error_message = "a PagerDuty or Slack channel managed outside Terraform must still reach the alert policies"
  }
}

# ---------------------------------------------------------------------------
# ISC-352 — mandatory labels survive composition
# ---------------------------------------------------------------------------

run "platform_resources_carry_the_mandatory_label_set" {
  command = plan

  variables {
    labels = { owner = "controlplane" }
  }

  assert {
    condition = alltrue([
      for k in ["environment", "kind", "managed-by", "component"] :
      contains(keys(google_dns_managed_zone.demo[0].labels), k)
    ])
    error_message = "platform resources must carry environment, kind, managed-by and component labels"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].labels["managed-by"] == "terraform"
    error_message = "managed-by must evaluate to terraform"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].labels["owner"] == "controlplane"
    error_message = "caller-supplied labels must merge over the mandatory set, not replace or be replaced by it"
  }
}

# ---------------------------------------------------------------------------
# DNS gate — a real gate, in both directions
# ---------------------------------------------------------------------------

run "dns_zone_is_created_with_dnssec_when_configured" {
  command = plan

  assert {
    condition     = length(google_dns_managed_zone.demo) == 1
    error_message = "a managed zone must be created when dns_zone_name is set"
  }

  assert {
    condition     = google_dns_managed_zone.demo[0].dns_name == "demo.example.invalid."
    error_message = "the managed zone must carry the configured fully-qualified domain"
  }

  assert {
    condition     = one(google_dns_managed_zone.demo[0].dnssec_config).state == "on"
    error_message = "DNSSEC must default to on"
  }

  assert {
    condition     = output.dns_managed_zone_name == "signalloom-demo"
    error_message = "the zone name must be exported for the environments root to attach records to"
  }
}

run "dns_is_omitted_entirely_when_unconfigured" {
  command = plan

  variables {
    dns_zone_name = ""
    dns_domain    = ""
  }

  assert {
    condition     = length(google_dns_managed_zone.demo) == 0
    error_message = "no managed zone may be created when Terraform is not managing DNS"
  }

  assert {
    condition     = output.dns_managed_zone_name == ""
    error_message = "the exported zone name must be empty so the environments root creates no records"
  }

  # Everything else must still plan. Domain ownership is a prerequisite Andy
  # supplies later; not having it yet must not block the platform.
  #
  # This used to read `output.log_bucket_name != ""`, borrowing the audit
  # bucket as a proxy for "the rest of the root still planned". That output is
  # dormant with module "observability" (see main.tf), so the proxy is gone.
  #
  # Replaced with a value this root owns directly rather than another borrowed
  # proxy. notification_channel_ids is built from a resource this file creates
  # and from var.extra_notification_channel_ids, so it evaluating at all proves
  # the root planned past the DNS block — which is the only thing this assertion
  # was ever for. Choosing a locally-owned value also means the next module to
  # go dormant does not silently break this test the way the last one did.
  assert {
    condition     = output.notification_channel_ids != null
    error_message = "the root must still plan its notification channels when DNS is unconfigured"
  }
}

# ---------------------------------------------------------------------------
# Operator identity — composition, which is the part the module cannot test
# ---------------------------------------------------------------------------
#
# modules/operator-identity/tests proves the module is correct given its inputs.
# What only this file can prove is that the ROOT feeds it the right ones: that
# the actAs grant lands on the runtime accounts modules/identity actually
# creates, and not on some literal typed twice.

run "the_operator_can_act_as_the_runtime_accounts_this_root_creates" {
  command = plan

  variables {
    environment_keys       = ["demo-1", "demo-2"]
    operator_impersonators = ["user:someone@example.invalid"]
  }

  assert {
    condition     = length(module.operator_identity.act_as_service_account_names) == 2
    error_message = "One actAs binding must exist per environment runtime account. A count that does not track environment_keys means the operator cannot log into some environment's VMs, which surfaces as an OS Login failure months later."
  }

  assert {
    condition = alltrue([
      for name in module.operator_identity.act_as_service_account_names :
      contains(
        [for e in values(module.identity.runtime_service_account_emails) : "projects/${var.project_id}/serviceAccounts/${e}"],
        name
      )
    ])
    error_message = "The operator's actAs bindings do not match the runtime service accounts modules/identity creates. A binding on an account that does not exist grants nothing and fails at apply."
  }

  # Vacuity guard. Both assertions above are satisfied by an empty list, which is
  # exactly what a broken wiring would produce.
  assert {
    condition     = length(module.identity.runtime_service_account_emails) == 2
    error_message = "modules/identity produced no runtime accounts for two environment keys, so the assertions above measured nothing."
  }
}

run "the_operator_is_not_the_deploy_or_ci_identity" {
  command = plan

  variables {
    environment_keys = ["demo-1"]
  }

  # Separation of duties, asserted as an evaluated fact rather than a comment.
  # If the operator account is ever "simplified" into the CI apply account, this
  # is what says no.
  assert {
    condition     = output.operator_service_account_email != output.ci_apply_service_account_email
    error_message = "The operator identity must not be the CI apply identity. The apply identity can rebuild the estate; giving it a sudo shell on every VM merges two blast radii."
  }

  assert {
    condition     = output.operator_service_account_email != output.ci_plan_service_account_email
    error_message = "The operator identity must be its own account, distinct from the CI plan identity."
  }

  assert {
    condition = !contains(
      [for e in values(output.runtime_service_account_emails) : e],
      output.operator_service_account_email
    )
    error_message = "The operator identity must not be a runtime identity. The runtime account is what the VM runs AS; the operator is who logs IN. Merging them means anything running on the VM can open a tunnel to every other VM."
  }

  assert {
    condition     = length(output.operator_granted_roles) == 4
    error_message = "The platform root must export exactly the four operator roles. A different count here and in the module's own budget means the root is composing a different module than the one under test."
  }

  # The fourth role is the instance-lifecycle CUSTOM role, added 2026-08-20 so
  # the operator can suspend a parked lane without escalating to project owner.
  # The count above moved from three to four with it; these two assertions are
  # what stop that number being nudged again by something that is not a custom
  # role holding exactly the four justified permissions.
  assert {
    condition     = length(output.operator_lifecycle_role_permissions) == 4
    error_message = "The platform root must export exactly the four instance-lifecycle permissions. If this and the module's own permission budget disagree, the root is composing a different module than the one under test — which is the failure the role-count assertion above cannot see, because a custom role can gain permissions without gaining a role."
  }

  # Not merely four SOMETHINGS. A count alone is satisfied by four permissions
  # nobody justified, and the whole argument for a custom role over
  # roles/compute.instanceAdmin.v1 is about which verbs, not how many.
  assert {
    condition = toset(output.operator_lifecycle_role_permissions) == toset([
      "compute.instances.resume",
      "compute.instances.start",
      "compute.instances.suspend",
      "compute.zoneOperations.get",
    ])
    error_message = "The instance-lifecycle permissions exported by the platform root are not the justified set. Each has a driver call site named in modules/operator-identity/main.tf."
  }

  # Suspend is the step that stops the billing, so whether the estate can
  # actually perform it is a fact the root must state rather than imply. Pinned
  # true here because that is this root's default; the module's own suite covers
  # the false case, where the role is a documented manual follow-up because the
  # applying identity lacked iam.roles.create.
  assert {
    condition     = output.operator_can_suspend
    error_message = "The platform root defaults to NOT creating the instance-lifecycle role, so suspending a demo VM still needs project owner. If that default is deliberate, this assertion is the place to argue for it."
  }
}

# ---------------------------------------------------------------------------
# ISC-346 — negative runs, each PAIRED with a positive above
# ---------------------------------------------------------------------------

# Paired with "notification_channels_are_created_and_propagated": identical
# except that no channel of any kind is configured.
run "alerts_enabled_with_no_channel_of_any_kind_is_rejected" {
  command = plan

  variables {
    enable_alerts                  = true
    notification_emails            = []
    extra_notification_channel_ids = []
  }

  expect_failures = [var.notification_emails]
}

# Paired with "dns_is_omitted_entirely_when_unconfigured": a domain with no zone
# is a silent no-op today, which is exactly the class of mistake that reads as
# "DNS is configured" in a review.
run "a_domain_without_a_zone_is_rejected" {
  command = plan

  variables {
    dns_zone_name = ""
    dns_domain    = "demo.example.invalid."
  }

  expect_failures = [var.dns_domain]
}

# Paired with "dns_zone_is_created_with_dnssec_when_configured".
run "a_domain_without_a_trailing_dot_is_rejected" {
  command = plan

  variables {
    dns_zone_name = "signalloom-demo"
    dns_domain    = "demo.example.invalid"
  }

  expect_failures = [var.dns_domain]
}

# ===========================================================================
# WIRING BLOCK — uncomment with modules/identity. See WIRING.md step 4.
# ===========================================================================
#
# run "wif_provider_carries_a_non_empty_attribute_condition" {
#   command = plan
#
#   variables {
#     project_number     = "000000000000"
#     environment_keys   = ["demo-1"]
#     github_owner_id    = "00000000"
#     github_repository  = "CHANGEME-owner/osramp-demo"
#     github_allowed_ref = "refs/heads/main"
#   }
#
#   assert {
#     condition     = output.workload_identity_provider_name != ""
#     error_message = "the WIF provider must be created"
#   }
# }
#
# END WIRING BLOCK
# ===========================================================================
