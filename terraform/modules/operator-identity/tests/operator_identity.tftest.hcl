# The operator identity is the only principal in the estate with an interactive
# shell and sudo on a running demo VM. Its power is therefore bounded by exactly
# two things: how few roles it holds, and how narrowly the actAs grant is scoped.
# Both are asserted here by exact value, because both are the kind of thing that
# widens by one line during a debugging session and is never narrowed again.
#
# mock_provider mandatory, command = plan only. See CONTRACT.md section 7a.

mock_provider "google" {}
mock_provider "google-beta" {}

variables {
  project_id = "changeme-project"

  runtime_service_account_emails = {
    "demo-1" = "sl-rt-demo-1@changeme-project.iam.gserviceaccount.com"
  }

  impersonators = ["user:someone@example.invalid"]
}

# ---------------------------------------------------------------------------
# The three grants, each asserted at the scope it is supposed to have
# ---------------------------------------------------------------------------

run "the_tunnel_and_login_roles_are_granted_at_project_scope" {
  command = plan

  # Positive first. Every negative below is worthless without proof that the
  # module grants anything at all: a module that granted nothing would satisfy
  # every "must not contain" assertion in this file.
  assert {
    condition     = contains(local.operator_project_roles, "roles/iap.tunnelResourceAccessor")
    error_message = "Without roles/iap.tunnelResourceAccessor the tunnel fails with 4033 'not authorized' before SSH is attempted, which is the failure this module exists to fix."
  }

  assert {
    condition     = contains(local.operator_project_roles, "roles/compute.osAdminLogin")
    error_message = "The demo pipeline runs every remote command through sudo (scripts/ci/gcp-ci.sh), so plain roles/compute.osLogin cannot run it."
  }

  assert {
    condition     = length(google_project_iam_member.operator) == length(local.operator_project_roles)
    error_message = "Every role in the justified list must produce exactly one project binding — a role in the list that produces no binding is a documented grant that was never made."
  }

  # The bindings must name the account this module creates. local.operator_email
  # is derived rather than read off the computed resource attribute, so this is
  # the assertion that stops the derivation drifting away from the resource and
  # binding roles to an account that does not exist.
  assert {
    condition = alltrue([
      for m in values(google_project_iam_member.operator) :
      m.member == "serviceAccount:${google_service_account.operator.account_id}@${google_service_account.operator.project}.iam.gserviceaccount.com"
    ])
    error_message = "The project bindings do not name the service account this module creates. The derived email has drifted from the resource's own account_id or project, which binds roles to an account nobody holds."
  }
}

run "act_as_is_scoped_to_a_service_account_resource_not_the_project" {
  command = plan

  # The single most important assertion in this file. roles/iam.serviceAccountUser
  # at PROJECT scope means "may act as every service account in the project",
  # including the deploy identity, which holds projectIamAdmin. At resource scope
  # it means "may log into VMs carrying this one runtime account".
  assert {
    condition     = length(google_service_account_iam_member.act_as_runtime) == 1
    error_message = "One actAs binding must be created per supplied runtime service account."
  }

  assert {
    condition = alltrue([
      for m in values(google_service_account_iam_member.act_as_runtime) :
      strcontains(m.service_account_id, "/serviceAccounts/")
    ])
    error_message = "The actAs binding must target a service account RESOURCE. A target without /serviceAccounts/ in it is not a service account, and a project-level binding here would hand the operator the deploy identity."
  }

  assert {
    condition = alltrue([
      for m in values(google_service_account_iam_member.act_as_runtime) :
      m.role == "roles/iam.serviceAccountUser"
    ])
    error_message = "The runtime binding must be roles/iam.serviceAccountUser and nothing broader."
  }

  # Resource-type enforcement, restated as an evaluated fact: the role never
  # appears in the project-scoped list. google_project_iam_member has no way to
  # be resource-scoped, so this is the assertion that would catch someone
  # "simplifying" the actAs grant into the project role list.
  assert {
    condition     = !contains(local.operator_project_roles, "roles/iam.serviceAccountUser")
    error_message = "roles/iam.serviceAccountUser must never appear in the project role list. At project scope it covers every service account in the project, including the deploy identity."
  }
}

run "impersonation_is_token_creator_not_a_key" {
  command = plan

  assert {
    condition = alltrue([
      for m in values(google_service_account_iam_member.impersonators) :
      m.role == "roles/iam.serviceAccountTokenCreator"
    ])
    error_message = "Access to the operator identity must be impersonation, not a downloaded key."
  }

  assert {
    condition     = length(google_service_account_iam_member.impersonators) == 1
    error_message = "One token-creator binding must be created per named impersonator, or the assertion above passes vacuously over an empty set."
  }
}

# ---------------------------------------------------------------------------
# Composition edges — the empty cases must plan, and must plan to nothing
# ---------------------------------------------------------------------------

run "no_runtime_accounts_produces_no_act_as_binding" {
  command = plan
  variables { runtime_service_account_emails = {} }

  assert {
    condition     = length(google_service_account_iam_member.act_as_runtime) == 0
    error_message = "With no runtime accounts supplied there is nothing to act as, and a binding here would target a resource that does not exist."
  }

  # The account and its project roles must still exist. An operator identity that
  # silently disappears when one optional input is empty is worse than one that
  # fails, because the estate applies cleanly and nobody can log in.
  assert {
    condition     = length(google_project_iam_member.operator) == length(local.operator_project_roles)
    error_message = "The project-scoped grants must not depend on runtime_service_account_emails. Compared against the role list rather than a literal 2 on purpose: a hardcoded count here would fail whenever the budget legitimately changes, and would report a dependency bug that is really a budget change."
  }
}

run "no_impersonators_is_inert_not_broken" {
  command = plan
  variables { impersonators = [] }

  assert {
    condition     = length(google_service_account_iam_member.impersonators) == 0
    error_message = "An empty impersonator list must produce no token-creator binding."
  }

  assert {
    condition     = google_service_account.operator.account_id == "sl-operator"
    error_message = "The account must still be created when nobody has been nominated to assume it yet."
  }
}

# ---------------------------------------------------------------------------
# Negatives, each paired with a positive above
# ---------------------------------------------------------------------------

# Paired with "impersonation_is_token_creator_not_a_key".
run "rejects_allauthenticatedusers_as_an_impersonator" {
  command = plan
  variables { impersonators = ["allAuthenticatedUsers"] }

  expect_failures = [var.impersonators]
}

# Paired with "impersonation_is_token_creator_not_a_key".
run "rejects_a_wildcard_impersonator" {
  command = plan
  variables { impersonators = ["principalSet://iam.googleapis.com/projects/1/locations/global/workloadIdentityPools/p/*"] }

  expect_failures = [var.impersonators]
}

# Paired with "impersonation_is_token_creator_not_a_key".
run "rejects_a_bare_email_with_no_type_prefix" {
  command = plan
  variables { impersonators = ["someone@example.invalid"] }

  expect_failures = [var.impersonators]
}

# Paired with "act_as_is_scoped_to_a_service_account_resource_not_the_project".
# A bare account id here would build the string
# projects/<p>/serviceAccounts/sl-rt-demo-1, which is a well-formed resource name
# for an account that does not exist — the apply fails late and confusingly
# rather than at plan.
run "rejects_a_runtime_account_that_is_not_a_service_account_email" {
  command = plan
  variables { runtime_service_account_emails = { "demo-1" = "sl-rt-demo-1" } }

  expect_failures = [var.runtime_service_account_emails]
}

# Paired with the same run: a human email would produce an actAs binding on a
# nonexistent service account resource named after a person.
run "rejects_a_user_email_as_a_runtime_account" {
  command = plan
  variables { runtime_service_account_emails = { "demo-1" = "someone@example.invalid" } }

  expect_failures = [var.runtime_service_account_emails]
}

# Paired positive for both of the above, and for the account_id validation.
run "accepts_correctly_shaped_inputs" {
  command = plan

  variables {
    account_id    = "sl-operator"
    impersonators = ["user:someone@example.invalid", "group:sre@example.invalid"]
    runtime_service_account_emails = {
      "demo-1" = "sl-rt-demo-1@changeme-project.iam.gserviceaccount.com"
      "demo-2" = "sl-rt-demo-2@changeme-project.iam.gserviceaccount.com"
    }
  }

  assert {
    condition     = length(google_service_account_iam_member.impersonators) == 2
    error_message = "A correctly-prefixed principal list must plan cleanly, or the negatives above prove nothing."
  }

  assert {
    condition     = length(google_service_account_iam_member.act_as_runtime) == 2
    error_message = "Two runtime accounts must produce two resource-scoped bindings, or the rejections above prove nothing."
  }
}

# Paired with "accepts_correctly_shaped_inputs".
run "rejects_an_account_id_that_gcp_would_refuse" {
  command = plan
  variables { account_id = "SL_Operator" }

  expect_failures = [var.account_id]
}

# ═══════════════════════════════════════════════════════════════════════════
# PERMISSION BUDGET
#
# Modelled on modules/deploy-identity/tests. Every role is pinned by exact count
# AND exact membership, so ADDING one fails the suite. That converts "we granted
# a bit more to make the tunnel work" from an invisible commit into a deliberate,
# reviewable change with a number attached.
#
# When a grant is genuinely needed the required change is: add it, update the
# count, and justify it in the diff. The failure is the feature.
# ═══════════════════════════════════════════════════════════════════════════

run "project_role_budget_is_exactly_two" {
  command = plan

  assert {
    condition     = length(local.operator_project_roles) == 2
    error_message = "The operator identity's project role count changed. Two roles were justified: one to open the IAP tunnel, one to log in with the sudo the pipeline requires. Adding a third is a privilege increase — update this number ONLY with a comment in main.tf naming the operation that forced it."
  }
}

run "total_role_budget_at_any_scope_is_exactly_three" {
  command = plan

  # The number a reviewer actually asks for. Two project roles plus the
  # resource-scoped actAs. A fourth grant appearing at ANY scope fails here even
  # if someone splits it across files.
  assert {
    condition     = length(local.operator_all_roles) == 3
    error_message = "The operator identity holds more than three roles. Three is the whole budget: tunnel, login-with-sudo, and actAs on the runtime account it logs in beside."
  }

  assert {
    condition     = length(toset(local.operator_all_roles)) == 3
    error_message = "A role is duplicated across the project and resource-scoped lists, which would make the count of three misleading."
  }
}

run "roles_are_exactly_the_justified_set" {
  command = plan

  # Set equality, not a subset check. A subset check passes while something extra
  # is granted, which is precisely the drift this is meant to catch.
  assert {
    condition = setunion(toset(local.operator_all_roles), toset([
      "roles/iap.tunnelResourceAccessor",
      "roles/compute.osAdminLogin",
      "roles/iam.serviceAccountUser",
      ])) == toset([
      "roles/iap.tunnelResourceAccessor",
      "roles/compute.osAdminLogin",
      "roles/iam.serviceAccountUser",
    ])
    error_message = "The operator identity's roles are no longer exactly the justified set. Something was added or renamed."
  }
}

run "no_primitive_or_legacy_role_is_ever_granted" {
  command = plan

  # CIS GCP Benchmark guidance: primitive roles (owner/editor/viewer) and legacy
  # roles grant far more than any resource needs and change meaning under you
  # when the provider revises them. Same rule as deploy-identity, applied over
  # the combined set so a legacy role cannot hide at resource scope.
  assert {
    condition = length([
      for r in local.operator_all_roles : r
      if contains(["roles/owner", "roles/editor", "roles/viewer"], r) || strcontains(lower(r), "legacy")
    ]) == 0
    error_message = "A primitive (owner/editor/viewer) or legacy role appears in the operator role set. CIS guidance forbids both, and legacy roles are deprecated on Google's schedule, not yours."
  }
}

run "no_estate_management_role_is_ever_granted" {
  command = plan

  # These three are the deploy identity's, and the reason this module was split
  # out of it. An operator who can rebuild the estate is one credential whose
  # compromise costs everything; an operator who can only log in is a bounded
  # loss. Asserted over the combined set, at any scope.
  assert {
    condition = length([
      for r in local.operator_all_roles : r
      # Deliberately one line. test/terraform-identity.bats guards the whole
      # tree against a BARE list element `"roles/storage.admin",` on its own
      # line, which is what a real grant looks like; splitting this list would
      # make an assertion that the role is absent read, to that guard, exactly
      # like the grant it forbids.
      if contains(["roles/compute.admin", "roles/resourcemanager.projectIamAdmin", "roles/storage.admin"], r)
    ]) == 0
    error_message = "An estate-management role (compute.admin, resourcemanager.projectIamAdmin or storage.admin) appears in the operator role set. Those belong to modules/deploy-identity; granting them here merges the two identities and removes the separation this module exists to create."
  }
}

run "no_admin_or_owner_shaped_role_slips_in_under_another_name" {
  command = plan

  # The budget above pins the exact set, so this is belt to that brace: it names
  # the SHAPE rather than the string, and would catch a rename such as
  # roles/iap.admin or roles/compute.instanceAdmin.v1 arriving alongside an
  # updated budget number that nobody questioned.
  #
  # roles/compute.osAdminLogin is the one deliberate exception. Its "Admin" means
  # "sudo on the guest OS", not "administers the project", and it is required —
  # see the evidence in main.tf.
  assert {
    condition = length([
      for r in local.operator_all_roles : r
      if(strcontains(lower(r), "admin") || strcontains(lower(r), "owner")) && r != "roles/compute.osAdminLogin"
    ]) == 0
    error_message = "An admin- or owner-shaped role other than roles/compute.osAdminLogin appears in the operator role set. If it is genuinely required, add it to this exception with the operation that forced it."
  }
}
