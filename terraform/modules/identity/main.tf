# modules/identity — the cloud identity boundary.
#
# Two things live here and nothing else: the GitHub Workload Identity Federation
# pool/provider that lets CI authenticate without a long-lived key, and the
# least-privilege service accounts that CI and the runtimes assume.
#
# The single most dangerous line in this module is `attribute_condition`. GCP
# accepts a provider with no condition at all, and the resulting pool will mint
# tokens for *any* GitHub repository on earth, because every GitHub Actions
# token is issued by the same issuer. The condition is the only thing separating
# "our CI can deploy" from "anyone with a GitHub account can deploy".

locals {
  # Account ids and emails are derived from ONE source so the IAM bindings, the
  # outputs, and the tests cannot drift apart. They are also deterministic, which
  # means every downstream assertion is on a known value at plan time rather than
  # on a computed attribute that only exists after apply.
  runtime_account_ids = { for k in var.environment_keys : k => "sl-rt-${k}" }
  ci_plan_account_id  = "sl-ci-plan"
  ci_apply_account_id = "sl-ci-apply"

  sa_domain = "${var.project_id}.iam.gserviceaccount.com"

  runtime_emails = { for k, id in local.runtime_account_ids : k => "${id}@${local.sa_domain}" }
  ci_plan_email  = "${local.ci_plan_account_id}@${local.sa_domain}"
  ci_apply_email = "${local.ci_apply_account_id}@${local.sa_domain}"

  # CEL, evaluated by GCP's STS before it will exchange a GitHub token.
  #
  # repository_owner_id is the immutable numeric id. repository_owner (the string
  # name) is deliberately NOT used: GitHub releases a renamed org's name for
  # immediate re-registration, so a name-pinned condition can be satisfied by a
  # stranger's repository the day after a rename.
  attribute_condition = join(" && ", [
    format("assertion.repository_owner_id == %q", var.github_owner_id),
    format("assertion.repository == %q", var.github_repository),
    format("assertion.ref == %q", var.github_allowed_ref),
  ])

  # Scoped by attribute, not pool-wide. The pool-wide form
  #   principalSet://.../workloadIdentityPools/<pool>/*
  # grants every identity the pool can ever mint, which defeats the point of
  # having a condition on the provider in the first place.
  #
  # This repository-scoped set is the PLAN identity's principal. It is
  # deliberately the weaker of the two: any workflow in the repository that the
  # provider will mint a token for can assume it, and it holds read-only roles.
  wif_plan_principal = join("", [
    "principalSet://iam.googleapis.com/projects/${var.project_number}",
    "/locations/global/workloadIdentityPools/${var.pool_id}",
    "/attribute.repository/${var.github_repository}",
  ])

  # The APPLY identity is scoped to one workflow file, not to the repository.
  #
  # Both bindings previously used the repository-scoped set above — byte
  # identical — while the comment beside them claimed they "decide which service
  # accounts an accepted token may impersonate". Identical members decide
  # nothing. Any token the pool accepted could impersonate the apply account,
  # which holds compute.admin, iam.serviceAccountAdmin and dns.admin; the
  # read-only ci_plan_roles list was guarding a boundary that existed only in
  # prose. An adversarial review found it.
  #
  # job_workflow_ref names the workflow file that is actually executing, so a
  # token minted by any other workflow in the same repository — including one
  # added by a pull request — cannot assume the apply identity.
  wif_apply_principal = join("", [
    "principalSet://iam.googleapis.com/projects/${var.project_number}",
    "/locations/global/workloadIdentityPools/${var.pool_id}",
    "/attribute.job_workflow_ref/${var.github_apply_workflow_ref}",
  ])
}

# ── Workload Identity Federation ────────────────────────────────────────────

resource "google_iam_workload_identity_pool" "github" {
  count                     = var.manage_project_iam ? 1 : 0
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "Signal Loom GitHub"
  description               = "Keyless CI authentication for GitHub Actions."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  count                              = var.manage_project_iam ? 1 : 0
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "sl-github-oidc"
  display_name                       = "GitHub Actions OIDC"

  # Absent or tautological => any repository on earth. See the module comment.
  attribute_condition = local.attribute_condition

  attribute_mapping = {
    "google.subject"                = "assertion.sub"
    "attribute.repository"          = "assertion.repository"
    "attribute.repository_owner_id" = "assertion.repository_owner_id"
    "attribute.ref"                 = "assertion.ref"
    "attribute.job_workflow_ref"    = "assertion.job_workflow_ref"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  lifecycle {
    # A plan-time control, not documentation. If a future edit reduces the
    # condition to nothing or to `true`, the plan fails rather than shipping an
    # open pool.
    precondition {
      condition = (
        trimspace(local.attribute_condition) != "" &&
        trimspace(local.attribute_condition) != "true" &&
        can(regex("repository_owner_id", local.attribute_condition))
      )
      error_message = "attribute_condition must be non-empty, must not be the tautology `true`, and must pin assertion.repository_owner_id."
    }
  }
}

# ── Service accounts ────────────────────────────────────────────────────────

resource "google_service_account" "runtime" {
  for_each = local.runtime_account_ids

  project      = var.project_id
  account_id   = each.value
  display_name = "Signal Loom runtime — ${each.key}"
  description  = "Attached to the ${each.key} instance. One per environment so a compromise is scoped to one environment."
}

resource "google_service_account" "ci_plan" {
  project      = var.project_id
  account_id   = local.ci_plan_account_id
  display_name = "Signal Loom CI — plan"
  description  = "Read-only. Assumed by pull-request CI, which must never be able to change infrastructure."
}

resource "google_service_account" "ci_apply" {
  project      = var.project_id
  account_id   = local.ci_apply_account_id
  display_name = "Signal Loom CI — apply"
  description  = "Write-capable. Assumed only by the approved ref pinned in the WIF attribute condition."
}

# ── WIF → service account impersonation ─────────────────────────────────────
#
# Additive members, scoped by attribute. Note this is the SECOND control: the
# provider's attribute_condition decides which tokens the pool will accept at
# all, and these bindings decide which service accounts an accepted token may
# impersonate. Either alone is insufficient.

resource "google_service_account_iam_member" "ci_plan_wif" {
  count              = var.manage_project_iam ? 1 : 0
  service_account_id = google_service_account.ci_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_plan_principal
}

resource "google_service_account_iam_member" "ci_apply_wif" {
  count              = var.manage_project_iam ? 1 : 0
  service_account_id = google_service_account.ci_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.wif_apply_principal
}

# ── Project IAM — additive members only ─────────────────────────────────────
#
# google_project_iam_member is additive. google_project_iam_policy is
# authoritative: it replaces the project's entire policy, silently deleting
# every binding Terraform does not know about, including the ones that let
# humans back in. It is never used in this tree.

resource "google_project_iam_member" "runtime" {
  for_each = var.manage_project_iam ? {
    for pair in setproduct(var.environment_keys, var.runtime_roles) :
    "${pair[0]}::${pair[1]}" => { key = pair[0], role = pair[1] }
  } : {}

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${local.runtime_emails[each.value.key]}"

  depends_on = [google_service_account.runtime]
}

resource "google_project_iam_member" "ci_plan" {
  for_each = var.manage_project_iam ? toset(var.ci_plan_roles) : toset([])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${local.ci_plan_email}"

  depends_on = [google_service_account.ci_plan]
}

resource "google_project_iam_member" "ci_apply" {
  for_each = var.manage_project_iam ? toset(var.ci_apply_roles) : toset([])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${local.ci_apply_email}"

  depends_on = [google_service_account.ci_apply]
}

resource "google_project_iam_member" "operators" {
  for_each = var.manage_project_iam ? {
    for pair in setproduct(var.operator_members, var.operator_roles) :
    "${pair[0]}::${pair[1]}" => { member = pair[0], role = pair[1] }
  } : {}

  project = var.project_id
  role    = each.value.role
  member  = each.value.member
}

# ── State bucket IAM — objectAdmin, never admin ─────────────────────────────
#
# Contract §5c. prevent_destroy and force_destroy live in the config, so the
# same commit that deletes the bucket can delete them; they are tripwires, not
# enforcement. IAM is the enforcement. objectAdmin reads and writes state
# objects and cannot delete the bucket; storage.admin can.

resource "google_storage_bucket_iam_member" "ci_state" {
  for_each = var.state_bucket_name == "" ? {} : {
    plan  = "serviceAccount:${local.ci_plan_email}"
    apply = "serviceAccount:${local.ci_apply_email}"
  }

  bucket = var.state_bucket_name
  role   = "roles/storage.objectAdmin"
  member = each.value
}

# The plan and apply principals must never converge again.
#
# They were byte-identical once, which meant the read-only ci_plan_roles list
# and the write-capable ci_apply_roles list described a boundary that nothing
# enforced. A grep-based test would not have caught it — both lines were
# individually correct, and the defect was that they were the SAME line. This is
# a plan-time control, evaluated on the values Terraform actually computed.
check "wif_principals_are_distinct" {
  assert {
    condition     = local.wif_plan_principal != local.wif_apply_principal
    error_message = "The plan and apply WIF principals are identical, so any token that can assume the read-only plan identity can also assume the write-capable apply identity. Scope apply to a job_workflow_ref."
  }

  assert {
    condition     = can(regex("attribute\\.job_workflow_ref/", local.wif_apply_principal))
    error_message = "The apply WIF principal must be scoped by job_workflow_ref, not by repository."
  }
}
