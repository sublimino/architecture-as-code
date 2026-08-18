# modules/operator-identity — the service account a human becomes to reach a VM.
#
# ─── The problem this exists to solve ──────────────────────────────────────
#
# The demo VMs have no external IP. The only route in is Identity-Aware Proxy
# TCP forwarding, and the only login mechanism is OS Login. OS Login has a rule
# that is invisible until it bites: a Google identity that is EXTERNAL to the
# organisation owning the project cannot configure POSIX account information
# without roles/compute.osLoginExternalUser, and that role is grantable only at
# ORGANISATION scope. The operator here holds a personal Google account and
# `gcloud organizations list` returns nothing for him, so he cannot grant it to
# himself and cannot escalate to someone who can without waiting on a third
# party. That wait has already cost a day.
#
# A service account created inside the project is internal to the organisation
# by construction, so the external-user rule does not apply to it. Measured on
# 2026-08-18: impersonating an in-project service account removes the OS Login
# error entirely and moves the failure to the IAP layer, which is a
# project-scoped grant the project owner can make. That is the whole reason this
# module exists — it converts an organisation-level dependency the operator
# cannot satisfy into a project-level one the project owner can.
#
# ─── Why this is NOT the deploy identity ───────────────────────────────────
#
# The obvious shortcut is to add roles/iap.tunnelResourceAccessor and
# roles/compute.osAdminLogin to modules/deploy-identity and be done in four
# lines. That identity holds roles/compute.admin, roles/resourcemanager.
# projectIamAdmin and roles/iam.serviceAccountUser — it can grant itself
# anything in the project. Giving it an interactive root shell on every VM it
# builds collapses the separation the deploy module's own comments argue for at
# length: build rights and run-on-the-box rights become one credential, and a
# compromise of either is a compromise of both.
#
# So: two identities, two blast radii. The deploy identity can create a VM and
# cannot log into it. This identity can log into a VM and cannot create one — it
# holds no compute.admin, no IAM admin of any kind, and cannot modify the estate
# it is running inside.
#
# ─── Why there is no key ───────────────────────────────────────────────────
#
# Same reason as deploy-identity: a downloaded JSON key is a bearer credential
# with no expiry that lives wherever it was last pasted. google_service_account_
# key does not appear anywhere in this estate, and test/terraform-identity.bats
# fails if it ever does.

locals {
  # ── Project-scoped roles: exactly two, each tied to one operation ─────────
  #
  # This list is the module's entire project-level footprint. The budget test in
  # tests/operator_identity.tftest.hcl pins both its length and its membership,
  # so adding a third is a failing diff rather than a quiet widening.
  operator_project_roles = [
    # Opens the IAP TCP tunnel. Without it `gcloud compute ssh
    # --tunnel-through-iap` fails at the tunnel, before SSH is even attempted,
    # with `4033: 'not authorized'`. This is the grant that replaces the
    # organisation-level ask.
    "roles/iap.tunnelResourceAccessor",

    # OS Login WITH sudo. The narrower roles/compute.osLogin was considered and
    # rejected on evidence, not preference: scripts/ci/gcp-ci.sh runs every
    # remote command as `sudo -u ci`, unpacks the work tree with `sudo tar` and
    # `sudo chown -R ci:ci`, and scripts/ci/vm-pipeline.sh opens and re-closes
    # /usr/local/bin with `sudo chmod`. The pipeline is therefore unrunnable
    # without sudo, and an operator identity that cannot run the pipeline does
    # not solve the problem this module was written for.
    #
    # If the pipeline is ever reworked to install tools under $HOME and drop the
    # `sudo -u ci` wrapper, downgrade this to roles/compute.osLogin — the budget
    # test will need updating, which is the point.
    "roles/compute.osAdminLogin",
  ]

  # ── The third grant, and why it is not in the list above ─────────────────
  #
  # roles/iam.serviceAccountUser is granted on ONE SERVICE ACCOUNT RESOURCE, not
  # on the project. At project scope it would mean "may act as every service
  # account in the project, including the deploy identity" — which is a path
  # straight back to projectIamAdmin and undoes the separation the comment above
  # spends twenty lines establishing. At resource scope it means "may log into
  # the VMs that carry this one runtime account", which is exactly the operation
  # that needs it: OS Login to an instance with a non-default service account
  # attached requires actAs on that account.
  #
  # It is named here rather than inlined so the budget test can assert the total
  # count of DISTINCT roles this identity holds at any scope, which is the number
  # a reviewer actually cares about.
  runtime_act_as_role = "roles/iam.serviceAccountUser"

  # Every role granted to the operator identity anywhere, at any scope. Three.
  operator_all_roles = concat(local.operator_project_roles, [local.runtime_act_as_role])

  # The provider's canonical id for each runtime service account, keyed by
  # environment. Derived from the email rather than from a resource reference so
  # this module has no dependency on modules/identity — see the comment on
  # google_service_account_iam_member.act_as_runtime below.
  runtime_account_names = {
    for key, email in var.runtime_service_account_emails :
    key => "projects/${var.project_id}/serviceAccounts/${email}"
  }

  # Derived, not read back off the resource, for the same reason modules/identity
  # derives its emails: google_service_account.email is computed, so a caller
  # asserting on it gets "unknown value" at plan and has to run an apply to test
  # anything. The form is fixed by GCP and the resource is created with exactly
  # these two components, so deriving it is not a guess.
  operator_email = "${var.account_id}@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_service_account" "operator" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = "Signal Loom demo operator"
  description  = "Reaches demo VMs over IAP and runs the demo pipeline on them. Impersonated, never keyed. Cannot create, modify or destroy the estate."
}

resource "google_project_iam_member" "operator" {
  for_each = toset(local.operator_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.operator_email}"

  depends_on = [google_service_account.operator]
}

# ── actAs, at RESOURCE scope ────────────────────────────────────────────────
#
# google_service_account_iam_member, not google_project_iam_member. The resource
# type is the enforcement: this binding cannot accidentally become project-wide,
# because the type has no project-wide form. One binding per environment runtime
# account, so removing an environment removes its grant.
#
# The account name is built from the email rather than taken from a resource
# reference so this module does not have to depend on modules/identity. The
# projects/<project>/serviceAccounts/<email> form is the provider's canonical
# id for a service account and is what modules/identity's own resources resolve
# to.
resource "google_service_account_iam_member" "act_as_runtime" {
  for_each = local.runtime_account_names

  service_account_id = each.value
  role               = local.runtime_act_as_role
  member             = "serviceAccount:${local.operator_email}"

  depends_on = [google_service_account.operator]
}

# ── Who may become this account ─────────────────────────────────────────────
#
# Impersonation, never a key — every use is attributable to the human behind it
# and the grant is revocable in one place.
#
# Unlike the deploy identity, an empty list is legal here. The platform root
# plans and applies before anyone has decided who the operators are, and an
# account nobody can assume is inert rather than dangerous. The validations on
# var.impersonators still reject the shapes that would make it dangerous.
resource "google_service_account_iam_member" "impersonators" {
  for_each = toset(var.impersonators)

  service_account_id = google_service_account.operator.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}

# ── DELIBERATELY ABSENT ─────────────────────────────────────────────────────
#
# google_organization_iam_member / _binding / _policy.
#
# The whole point of this module is that the access path stops at the project
# boundary. roles/compute.osLoginExternalUser would make direct human SSH work
# too, and it is a perfectly reasonable thing for an organisation administrator
# to grant — but the moment Terraform declares it, the estate cannot be applied
# by anyone without organisation-level rights, and the operator is back to
# waiting on someone he cannot reach. It stays a documented manual convenience
# in deploy/gcp/ACCESS-REQUEST.md and never becomes a dependency.
# test/terraform-operator-access.bats fails if any org-scoped IAM resource
# appears anywhere in the terraform tree.
#
# roles/compute.admin, roles/resourcemanager.projectIamAdmin, roles/storage.admin.
#
# All three belong to the deploy identity and none of them is needed to open a
# tunnel and log in. An operator who can also rebuild the estate is a single
# credential whose compromise costs everything, which is the arrangement this
# module was split out to avoid.
#
# Any role containing "legacy". CIS GCP Benchmark guidance, and the same
# reasoning as deploy-identity: legacy roles are deprecated on Google's schedule
# rather than yours, and their meaning changes under you when the provider
# revises them.
