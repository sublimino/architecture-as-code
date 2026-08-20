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

run "project_role_budget_is_exactly_three" {
  command = plan

  # Was two until 2026-08-20. The third is the instance-lifecycle CUSTOM role,
  # added so the operator can suspend the estate it parks — see main.tf for the
  # call site behind each of its four permissions. The number moved deliberately
  # and this assertion moved with it; it is still an exact count, so a fourth
  # role is still a failing diff.
  assert {
    condition     = length(local.operator_project_roles) == 3
    error_message = "The operator identity's project role count changed. Three roles are justified: one to open the IAP tunnel, one to log in with the sudo the pipeline requires, and one custom role holding suspend/resume/start plus the operation poll. Adding a fourth is a privilege increase — update this number ONLY with a comment in main.tf naming the operation that forced it."
  }

  # Exactly one of the three may be a custom role. A second custom role would be
  # a second permission budget that nothing in this file pins, which is how the
  # count stays at three while the reachable surface doubles.
  assert {
    condition = length([
      for r in local.operator_project_roles : r
      if !startswith(r, "roles/")
    ]) == 1
    error_message = "The operator identity holds more than one non-predefined project role. Each custom role carries its own unpinned permission list, so a second one widens the identity without moving any number in this file."
  }
}

run "total_role_budget_at_any_scope_is_exactly_four" {
  command = plan

  # The number a reviewer actually asks for. Three project roles plus the
  # resource-scoped actAs. A fifth grant appearing at ANY scope fails here even
  # if someone splits it across files.
  assert {
    condition     = length(local.operator_all_roles) == 4
    error_message = "The operator identity holds more than four roles. Four is the whole budget: tunnel, login-with-sudo, the instance-lifecycle custom role, and actAs on the runtime account it logs in beside."
  }

  assert {
    condition     = length(toset(local.operator_all_roles)) == 4
    error_message = "A role is duplicated across the project and resource-scoped lists, which would make the count of four misleading."
  }
}

run "roles_are_exactly_the_justified_set" {
  command = plan

  # Set equality, not a subset check. A subset check passes while something extra
  # is granted, which is precisely the drift this is meant to catch.
  #
  # This was WRITTEN as `setunion(toset(actual), toset(expected)) == toset(expected)`
  # and that expression is a subset test, not an equality test: setunion(A, E)
  # equals E exactly when A is contained in E, so it fires on an ADDED role and
  # is blind to a REMOVED one. The comment above it claimed equality and the code
  # underneath implemented containment. Found on 2026-08-20 by deleting a
  # permission from the real module and watching the paired permission assertion
  # stay green (CONTRACT §7b — the mutation that fails nothing is the finding).
  # Direct comparison of the two sets has both directions.
  #
  # The custom role is pinned by its FULL resource name, project id included.
  # var.project_id is "changeme-project" for this suite (set at the top of the
  # file), so this also catches the role being moved to another project — a
  # binding to projects/<someone-else>/roles/<id> is a grant this estate cannot
  # see the contents of.
  assert {
    condition = toset(local.operator_all_roles) == toset([
      "roles/iap.tunnelResourceAccessor",
      "roles/compute.osAdminLogin",
      "roles/iam.serviceAccountUser",
      "projects/changeme-project/roles/slOperatorInstanceLifecycle",
    ])
    error_message = "The operator identity's roles are no longer exactly the justified set. Something was added, removed or renamed."
  }
}

# ═══════════════════════════════════════════════════════════════════════════
# PERMISSION BUDGET — the custom role's contents
#
# A role budget counts ROLES. A custom role is one role holding an arbitrary
# number of permissions, so counting roles alone would let this identity acquire
# compute.instances.delete without any number in this file moving. These runs
# pin the permission list the same way the role list is pinned: exact count,
# exact membership, plus shape guards that name the verb rather than the string
# so a rename cannot slip past a count that was updated without being read.
# ═══════════════════════════════════════════════════════════════════════════

run "the_custom_role_is_created_and_bound_to_this_identity" {
  command = plan

  # Positive first, for the same reason as the top of this file: every negative
  # below is satisfied by a role that does not exist.
  assert {
    condition     = length(google_project_iam_custom_role.instance_lifecycle) == 1
    error_message = "The instance-lifecycle custom role must be created when manage_lifecycle_custom_role is true, or the operator still cannot suspend a VM and every permission assertion below passes over an empty set."
  }

  assert {
    condition     = one(google_project_iam_custom_role.instance_lifecycle).role_id == "slOperatorInstanceLifecycle"
    error_message = "The custom role id changed. It is pinned because local.operator_lifecycle_role_name derives the binding target from it, and a rename would bind the operator to a role that does not exist."
  }

  # The role must actually reach the operator. A custom role nobody is bound to
  # is a permission list with no holder, and it would satisfy every membership
  # assertion in this file.
  assert {
    condition = contains([
      for m in values(google_project_iam_member.operator) : m.role
    ], "projects/changeme-project/roles/slOperatorInstanceLifecycle")
    error_message = "The instance-lifecycle role is declared but never bound to the operator identity. The role would exist, hold exactly the right permissions, and grant nobody anything."
  }

  assert {
    condition     = one(google_project_iam_custom_role.instance_lifecycle).stage == "GA"
    error_message = "The custom role must be stage GA. The provider default is ALPHA, which reads as unfinished and invites replacing it with roles/compute.instanceAdmin.v1."
  }
}

run "lifecycle_permission_budget_is_exactly_four" {
  command = plan

  assert {
    condition     = length(local.operator_lifecycle_permissions) == 4
    error_message = "The instance-lifecycle permission count changed. Four are justified, each with a call site named in main.tf: suspend, resume, start (the 60-day suspend limit transitions a parked lane to TERMINATED), and zoneOperations.get (gcloud polls the operation unless --async, and no driver passes --async)."
  }

  assert {
    condition     = length(toset(local.operator_lifecycle_permissions)) == 4
    error_message = "A permission is repeated in the instance-lifecycle role, which would make the count of four overstate the number of distinct verbs granted."
  }
}

run "lifecycle_permissions_are_exactly_the_justified_set" {
  command = plan

  # Set equality in BOTH directions, written as a direct comparison rather than
  # the `setunion(actual, expected) == expected` idiom used elsewhere in this
  # repo. That idiom is a containment test: it fires when a permission is added
  # and stays green when one is removed. Removal is the half that matters most
  # here — dropping compute.instances.start breaks the TERMINATED branch of every
  # driver's lane state machine, and nothing looks wrong until a parked lane will
  # not come back.
  #
  # This is the assertion that fails if someone later adds
  # compute.instances.delete, and it fails whether or not they remember to update
  # the count above.
  assert {
    condition = toset(local.operator_lifecycle_permissions) == toset([
      "compute.instances.suspend",
      "compute.instances.resume",
      "compute.instances.start",
      "compute.zoneOperations.get",
    ])
    error_message = "The instance-lifecycle role's permissions are no longer exactly the justified set. Each of the four has a call site in a driver script named in main.tf; a fifth needs one too, and a missing one breaks a branch of the lane state machine."
  }

  # The declared resource must carry the same list the budget above pins.
  # Without this, the local could be correct while the resource was built from
  # something else entirely, and every assertion here would be about a value
  # nothing is deployed from.
  assert {
    condition     = toset(one(google_project_iam_custom_role.instance_lifecycle).permissions) == toset(local.operator_lifecycle_permissions)
    error_message = "The custom role resource's permissions differ from local.operator_lifecycle_permissions. The budget assertions above are then measuring a value that is not what gets applied."
  }
}

run "the_lifecycle_role_grants_no_estate_mutating_verb" {
  command = plan

  # Named by VERB rather than by full string, so this also catches the verb
  # arriving on a resource type nobody thought of — compute.disks.delete, say,
  # or compute.snapshots.create. The role's job is to park and unpark a machine
  # that already exists; anything that builds, destroys or reconfigures one is
  # the deploy identity's job and is what makes instanceAdmin.v1 unacceptable.
  assert {
    condition = length([
      for p in local.operator_lifecycle_permissions : p
      if length([
        for verb in [
          "create", "insert", "delete", "update", "setMetadata", "setIamPolicy",
          "setServiceAccount", "attachDisk", "detachDisk", "setTags", "setLabels",
          "addAccessConfig", "reset", "setMachineType", "setDiskAutoDelete",
        ] : verb if endswith(p, ".${verb}")
      ]) > 0
    ]) == 0
    error_message = "An estate-mutating verb (create/insert/delete/update/setMetadata/setIamPolicy/setServiceAccount/attachDisk/detachDisk/setTags/setLabels/addAccessConfig/reset/setMachineType/setDiskAutoDelete) appears in the instance-lifecycle role. This role parks and unparks machines; building and reconfiguring them belongs to modules/deploy-identity."
  }

  # Nothing outside the two API surfaces the lane state machine actually calls.
  # A permission from another service in here would be invisible to the verb
  # guard above and to any reviewer skimming for "admin".
  assert {
    condition = alltrue([
      for p in local.operator_lifecycle_permissions :
      startswith(p, "compute.instances.") || startswith(p, "compute.zoneOperations.")
    ])
    error_message = "The instance-lifecycle role reaches beyond compute.instances and compute.zoneOperations. Those are the only two surfaces the drivers call: instances for suspend/resume/start, zoneOperations for the poll each of those returns."
  }
}

run "already_held_permissions_are_not_restated_in_the_custom_role" {
  command = plan

  # compute.instances.get and .list ARE required — vm_status() runs `instances
  # describe` and the reaper runs `instances list` — and are ALREADY granted by
  # roles/compute.osAdminLogin. Restating them would grow this role's count
  # while granting nothing, which makes the budget number a worse signal than it
  # was before. Asserted rather than commented, because "we already have that"
  # is exactly the kind of claim that decays silently.
  assert {
    condition = length([
      for p in local.operator_lifecycle_permissions : p
      if contains(["compute.instances.get", "compute.instances.list"], p)
    ]) == 0
    error_message = "compute.instances.get or compute.instances.list appears in the custom role. Both are already granted by roles/compute.osAdminLogin (verified against the live role definition), so this role must hold only the DELTA over what the identity already has."
  }

  # And the paired positive: the role that supplies them is still granted. If
  # osAdminLogin is ever narrowed to roles/compute.osLogin, get and list survive
  # (both roles carry them) — but this is the assertion that stops the negative
  # above passing because the whole login role was dropped.
  assert {
    condition     = contains(local.operator_project_roles, "roles/compute.osAdminLogin")
    error_message = "roles/compute.osAdminLogin is gone, so compute.instances.get and .list are no longer held from anywhere, and the custom role was deliberately built without them."
  }
}

run "the_custom_role_can_be_left_to_a_manual_follow_up" {
  command = plan
  variables { manage_lifecycle_custom_role = false }

  # The deploy identity holds projectIamAdmin and not roleAdmin, so it cannot
  # create a custom role. This is the case that lets the platform root apply
  # cleanly as that identity instead of dying part-way with an IAM error.
  assert {
    condition     = length(google_project_iam_custom_role.instance_lifecycle) == 0
    error_message = "With manage_lifecycle_custom_role = false no custom role may be declared, or the apply still requires iam.roles.create and the flag achieves nothing."
  }

  # And nothing may be BOUND to it. A binding to a role Terraform did not create
  # fails at apply with a confusing "role not found", which is a worse failure
  # than the one the flag exists to avoid.
  assert {
    condition = length([
      for m in values(google_project_iam_member.operator) : m
      if !startswith(m.role, "roles/")
    ]) == 0
    error_message = "A binding to the custom role survives when the role itself is not created. The apply would fail on a role that does not exist."
  }

  # The tunnel and the login must SURVIVE. An operator who loses shell access
  # because a suspend feature was disabled is a strictly worse outcome than one
  # who cannot suspend.
  assert {
    condition     = length(google_project_iam_member.operator) == 2
    error_message = "Disabling the custom role must leave exactly the two predefined grants — the IAP tunnel and OS Login. Losing either takes away shell access to fix the very thing that is disabled."
  }

  # The BUDGET does not shrink. operator_project_roles is a statement of
  # entitlement, and a budget that quietly drops to two when a flag is flipped
  # would let a future role be added under cover of "we are back to three".
  assert {
    condition     = length(local.operator_project_roles) == 3
    error_message = "The role budget shrank when manage_lifecycle_custom_role was disabled. The budget must state what this identity is entitled to hold regardless of what the current configuration binds."
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
