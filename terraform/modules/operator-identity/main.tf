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
  # ── The instance-lifecycle custom role ────────────────────────────────────
  #
  # THE PROBLEM. The operator can open a tunnel and log in, and cannot turn the
  # machine off. On 2026-08-19 sl-demo-2-vm had to be suspended as PROJECT OWNER
  # because this identity holds no compute.instances.suspend. The estate runs a
  # hot/cold pattern — one lane parked suspended, one rebuilt — and suspend is
  # the step that stops the billing. A teardown that requires project owner is
  # either skipped or done with an over-privileged credential; both are worse
  # than fixing the grant.
  #
  # WHY NOT A PREDEFINED ROLE. The only predefined role carrying
  # compute.instances.suspend is roles/compute.instanceAdmin.v1. Measured
  # against the live role definition on 2026-08-20:
  #
  #   gcloud iam roles describe roles/compute.instanceAdmin.v1
  #     → 529 permissions, including compute.instances.create,
  #       compute.instances.delete, compute.instances.setMetadata,
  #       compute.instances.setServiceAccount, compute.instances.attachDisk
  #       and compute.disks.delete.
  #
  # 529 permissions to reclaim two verbs, and four of those permissions are
  # individually sufficient to rebuild or take over the estate. setServiceAccount
  # plus the actAs grant this module already holds is a path to running code as
  # the runtime identity; setMetadata is an SSH-key write, which is the OS Login
  # bypass the whole module exists to make unnecessary. The README rejects that
  # class of role by name, and adding it here would retire the argument rather
  # than answer it. So: a custom role holding only the verbs the driver calls.
  #
  # EACH PERMISSION, AND THE CALL SITE THAT FORCES IT. Nothing is here on the
  # grounds that it "seems related"; every entry has a line of shell behind it.
  operator_lifecycle_permissions = [
    # The operation this role exists for. scripts/ci/gcp-tf-ci.sh:248 (end of a
    # CI lane), scripts/ci/gcp-ci.sh:535 and :1301, scripts/ci/gcp-tf-reaper.sh:138
    # (idle-lane reaper). Documented requirement: "To suspend an instance:
    # compute.instances.suspend" — cloud.google.com/compute/docs/instances/
    # suspend-resume-instance, Required roles and permissions.
    "compute.instances.suspend",

    # The reciprocal, and the SUSPENDED branch of every driver's state machine:
    # scripts/gcp-tf/demo-up.sh:532, scripts/ci/gcp-tf-ci.sh:219,
    # scripts/ci/gcp-ci.sh:271 and :1328. Same doc, same section: "To resume an
    # instance: compute.instances.resume". Suspend without resume is a one-way
    # door — the operator could stop the billing and never restart the lane.
    "compute.instances.resume",

    # NOT implied by resume, and required anyway. The docs treat stop/start and
    # suspend/resume as two separate pairs with two separate permissions
    # (cloud.google.com/compute/docs/instances/stop-start-instance: "To restart
    # an instance: compute.instances.start"), so resume does NOT cover start —
    # the question was asked explicitly and this is the answer.
    #
    # It is included because the estate's own hot/cold pattern produces the
    # TERMINATED state without anyone choosing it: "You can suspend an instance
    # for only up to 60 days before Compute Engine automatically transitions its
    # state to TERMINATED" (suspend-resume-instance, Limitations). A parked lane
    # is exactly the thing that sits suspended for months. Every driver already
    # has the branch — demo-up.sh:538, gcp-tf-ci.sh:225, gcp-ci.sh:278, all
    # `TERMINATED | STOPPED)` arms of the same case statement that calls resume —
    # so without this permission the operator's lane lifecycle fails on a state
    # Google itself created, and the fallback is the project-owner escalation
    # this role exists to remove.
    "compute.instances.start",

    # Not a compute.instances verb, and the one that would have been missed.
    # gcloud's suspend/resume/start are ASYNCHRONOUS API calls: the response is
    # an Operation, and gcloud polls zoneOperations.get until it is DONE unless
    # --async is passed. `gcloud compute instances suspend --help` on the
    # installed SDK: "--async  Return immediately, without waiting for the
    # operation in progress to complete." Waiting is therefore the default, and
    # `grep -rn -- --async` across gcp-tf-ci.sh, gcp-ci.sh, demo-up.sh and
    # gcp-tf-reaper.sh returns NOTHING — every call site waits.
    #
    # Without this, the mutation lands and the poll returns 403: the VM really
    # does suspend, and the driver reports a permission failure. That is the
    # worst shape of bug available here, because the operator retries against a
    # machine that is already suspended. resume_lane() in gcp-tf-ci.sh:210 also
    # calls wait_for_ssh() straight after resume, so it depends on the operation
    # actually having been observed to complete.
    "compute.zoneOperations.get",
  ]

  # ── What is deliberately NOT in that list ────────────────────────────────
  #
  # compute.instances.get and compute.instances.list. Both are genuinely needed —
  # vm_status() in demo-up.sh:490 and gcp-tf-ci.sh:172 runs `compute instances
  # describe`, and gcp-tf-reaper.sh:121 runs `compute instances list` — and both
  # are ALREADY HELD. Read off the live role definition on 2026-08-20:
  #
  #   gcloud iam roles describe roles/compute.osAdminLogin
  #     → compute.instances.get, compute.instances.list, compute.projects.get,
  #       resourcemanager.projects.get, compute.instances.osAdminLogin, …
  #
  # Restating them here would inflate this role's count by two while granting
  # nothing new, which is exactly the kind of unexamined widening the budget
  # test exists to catch. The permission set below is the DELTA over what the
  # identity already holds, not a standalone description of what it can do.
  #
  # compute.instances.stop. No call site stops an instance; the estate suspends,
  # because suspend preserves memory and stop does not. A verb with no caller is
  # a verb granted on speculation.
  #
  # compute.disks.*. The suspend documentation's required-permissions section
  # names none, and the question is not academic: suspend does write guest memory
  # to storage. It writes it to Compute-Engine-managed storage attached to the
  # instance, not to a google_compute_disk the caller owns, which is why no disk
  # permission appears in the requirement. Asserted from the doc rather than from
  # the plausible-sounding inference, which pointed the other way.
  #
  # compute.instances.startWithEncryptionKey. Only for customer-supplied
  # encryption keys; terraform/modules/compute declares none.
  #
  # compute.zoneOperations.list. get is enough to poll an operation whose name
  # the API just returned. list would let this identity enumerate every mutation
  # in the zone, which is a disclosure the driver never asks for.
  #
  # iam.serviceAccounts.actAs. Starting an instance that carries a service
  # account needs it, and it is already granted at RESOURCE scope below. It must
  # not be restated here: a permission in a project-level custom role is a
  # project-level grant, which is precisely the widening this module's actAs
  # comment spends twenty lines refusing.

  # Custom role ids are [a-zA-Z0-9_.]{3,64}. Deliberately contains neither
  # "admin" nor "owner": the budget test's shape guard rejects an admin-shaped
  # role name arriving alongside a quietly-updated count, and a role called
  # slOperatorInstanceAdmin would have to be argued for rather than skimmed past.
  operator_lifecycle_role_id = "slOperatorInstanceLifecycle"

  # Derived, not read off google_project_iam_custom_role.instance_lifecycle.id,
  # for the same reason operator_email is derived: the resource attribute is
  # computed and therefore unknown at plan, which would force every assertion
  # about it into an apply. projects/<project>/roles/<role_id> is the provider's
  # canonical id and both components are known inputs.
  operator_lifecycle_role_name = "projects/${var.project_id}/roles/${local.operator_lifecycle_role_id}"

  # ── Project-scoped roles: exactly three, each tied to one operation ───────
  #
  # This list is the module's entire project-level footprint. The budget test in
  # tests/operator_identity.tftest.hcl pins both its length and its membership,
  # so adding a fourth is a failing diff rather than a quiet widening.
  #
  # It went from two to three on 2026-08-20. The third is a CUSTOM role holding
  # four permissions, not a predefined role holding 529 — the count went up by
  # one and the reachable surface went up by four verbs, and the budget test now
  # pins both numbers separately so those two facts cannot drift apart.
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

    # Suspend, resume, start, and the operation poll that all three depend on.
    # Four permissions, declared above with a call site each. This is the only
    # non-predefined entry in the list, and the only one whose contents are
    # pinned by name as well as by count.
    local.operator_lifecycle_role_name,
  ]

  # ── What is actually BOUND, as opposed to what is budgeted ───────────────
  #
  # operator_project_roles above is a statement of entitlement and is constant:
  # the budget test pins it at three whatever the caller configures, because a
  # budget that shrinks when a feature flag is flipped is not a budget.
  #
  # This is the list the bindings are built from, and it drops the custom role
  # when the caller cannot create one. See var.manage_lifecycle_custom_role for
  # why that case exists — briefly: creating a custom role needs iam.roles.create,
  # which the deploy identity does not hold and must not be given.
  operator_bound_project_roles = [
    for r in local.operator_project_roles : r
    if var.manage_lifecycle_custom_role || r != local.operator_lifecycle_role_name
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

  # Every role granted to the operator identity anywhere, at any scope. Four.
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

# ── The instance-lifecycle custom role ──────────────────────────────────────
#
# A custom role rather than roles/compute.instanceAdmin.v1, for the reason set
# out at length in the locals block: the predefined role carries 529 permissions
# and this one carries four.
#
# THE COST, STATED PLAINLY. Creating this resource requires iam.roles.create on
# the project. That permission is in roles/iam.roleAdmin, and it is NOT in
# roles/resourcemanager.projectIamAdmin — verified against the live definitions
# on 2026-08-20, where projectIamAdmin resolves to nine permissions, all of them
# resourcemanager.projects.* or iam.policybindings.*, and none of them
# iam.roles.*. modules/deploy-identity grants projectIamAdmin and does not grant
# roleAdmin, so the deploy identity CANNOT create this role.
#
# That is deliberate and it is not being fixed by widening the deploy identity.
# roleAdmin on the identity that already holds compute.admin and projectIamAdmin
# would let it mint a role containing any permission and bind that role to
# itself, which is a strictly more general form of the privilege escalation the
# deploy module's own comments say it is trying to bound.
#
# So the caller chooses, the same way modules/identity handles the setIamPolicy
# problem with manage_project_iam: apply the platform root as an identity that
# holds roleAdmin or owner, or set manage_lifecycle_custom_role = false and
# create the role once by hand. The flag exists so the estate applies CLEANLY in
# both cases rather than dying part-way with an error naming an IAM API.
resource "google_project_iam_custom_role" "instance_lifecycle" {
  count = var.manage_lifecycle_custom_role ? 1 : 0

  project     = var.project_id
  role_id     = local.operator_lifecycle_role_id
  title       = "Signal Loom operator — instance lifecycle"
  description = "Suspend, resume and start demo VMs, and poll the zone operation each of those returns. Deliberately holds no create, delete, setMetadata or disk permission: this identity parks and unparks the estate, it does not build it."

  permissions = local.operator_lifecycle_permissions

  # GA rather than the provider default of ALPHA. A role left at ALPHA is
  # documented as subject to change and, more practically, reads to a reviewer as
  # unfinished — which invites the "let me just use instanceAdmin" shortcut this
  # whole resource exists to avoid.
  stage = "GA"
}

resource "google_project_iam_member" "operator" {
  for_each = toset(local.operator_bound_project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${local.operator_email}"

  # The custom role must exist before anything is bound to it. depends_on rather
  # than a reference for the same reason the role name is derived rather than
  # read back: a reference to a counted resource's computed id is unknown at
  # plan, and every assertion about these bindings would then need an apply.
  depends_on = [
    google_service_account.operator,
    google_project_iam_custom_role.instance_lifecycle,
  ]
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
# roles/compute.instanceAdmin.v1.
#
# The obvious answer to "the operator cannot suspend a VM", and the reason
# google_project_iam_custom_role.instance_lifecycle exists instead. It is the
# ONLY predefined role carrying compute.instances.suspend, and it carries 529
# permissions to deliver it, including create, delete, setMetadata,
# setServiceAccount and attachDisk. Granting it would give this identity every
# capability the deploy identity has over instances, which collapses the split
# the file spends its first forty lines establishing. The budget test asserts
# both that it is absent and that no other admin-shaped role has taken its place.
#
# Any role containing "legacy". CIS GCP Benchmark guidance, and the same
# reasoning as deploy-identity: legacy roles are deprecated on Google's schedule
# rather than yours, and their meaning changes under you when the provider
# revises them.
