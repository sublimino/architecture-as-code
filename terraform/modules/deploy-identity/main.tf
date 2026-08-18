# modules/deploy-identity — the service account that runs and tears down this estate.
#
# ─── Why this lives in bootstrap and not in platform ────────────────────────
#
# Chicken and egg. This account is what applies the platform and environment
# roots, so it cannot be created by them. It is created once, by a human holding
# elevated rights, in the same separately-authorised step that creates the state
# bucket — and from then on nobody needs those elevated rights again.
#
# ─── Why the role list looks long ──────────────────────────────────────────
#
# Every role below was derived from a resource type this estate actually
# declares, not from a "what might a deployer need" guess. The estate creates 34
# distinct google_* resource types; each role here exists because at least one of
# them requires it, and the comment says which. Anything not needed by a declared
# resource is absent — notably roles/owner, roles/editor, and storage.admin.
#
# The two most dangerous grants are called out individually. They are unavoidable
# for a Terraform identity that must manage IAM and impersonate service accounts,
# and pretending otherwise by hiding them in a longer list would be worse than
# naming them.

locals {
  # ── Roles required to CREATE and DESTROY the estate ───────────────────────
  #
  # Terraform needs symmetric rights: an identity that can apply but not destroy
  # produces an estate nobody can tear down, which is the failure mode this
  # whole platform exists to avoid.
  deploy_roles = [
    # Networks, subnets, routers, Cloud NAT, firewall rules, instances,
    # instance groups, health checks, backend services, URL maps, proxies,
    # forwarding rules, global addresses, SSL policies, managed certificates,
    # and Cloud Armor security policies. That is 18 of the 34 resource types.
    #
    # compute.admin rather than a hand-assembled set of narrower compute roles:
    # the narrower split (networkAdmin + instanceAdmin.v1 + securityAdmin +
    # loadBalancerAdmin) covers the same surface, is four grants instead of one,
    # and leaves gaps that only appear at destroy time — the worst moment to
    # discover a missing permission.
    "roles/compute.admin",

    # google_service_account, and setIamPolicy on those accounts for the WIF
    # impersonation bindings. Scoped to service accounts; grants nothing over
    # the project's own IAM policy.
    "roles/iam.serviceAccountAdmin",

    # DANGEROUS, AND REQUIRED. Lets this identity attach a service account to a
    # VM — and therefore run code AS that service account. There is no narrower
    # role that permits attaching an SA to an instance. It is the reason the
    # deploy identity must never be handed to CI without a workflow-scoped
    # binding, and the reason its key must never exist.
    "roles/iam.serviceAccountUser",

    # DANGEROUS, AND REQUIRED. google_project_iam_member and
    # google_project_iam_audit_config both call setIamPolicy on the PROJECT.
    # An identity holding this can grant itself anything, so it is functionally
    # equivalent to owner. It is granted because the estate declares project IAM
    # bindings; if you would rather not grant it, set manage_project_iam = false
    # on the platform root and apply those bindings by hand instead.
    "roles/resourcemanager.projectIamAdmin",

    # google_iam_workload_identity_pool and its provider.
    "roles/iam.workloadIdentityPoolAdmin",

    # google_logging_project_sink.
    "roles/logging.configWriter",

    # google_monitoring_uptime_check_config, alert policies, notification
    # channels.
    "roles/monitoring.editor",

    # google_dns_managed_zone and google_dns_record_set.
    "roles/dns.admin",

    # google_iap_web_backend_service_iam_member. Only needed when an environment
    # runs access_mode = "iap" with a public HTTPS edge.
    "roles/iap.admin",

    # DELIBERATELY ABSENT: roles/storage.admin.
    #
    # The estate declares google_storage_bucket for the audit log bucket, so a
    # naive reading says the deploy identity needs project-wide storage.admin to
    # create it. That grant would also let this identity DELETE THE STATE BUCKET
    # — the one object with no state to roll back from, and the thing the
    # objectAdmin binding below exists specifically to keep out of its reach.
    # Granting it would quietly undo the estate's single most important
    # protection, and test/terraform-identity.bats fails if it ever appears.
    #
    # GCP cannot express "storage.admin except this one bucket" without an IAM
    # deny policy, so the resolution is layering rather than a narrower role:
    # buckets are created by the separately-authorised bootstrap step, by a human
    # who already holds elevated rights, and the deploy identity never creates or
    # deletes a bucket at all. See terraform/bootstrap/README.md.
  ]
}

resource "google_service_account" "deploy" {
  project      = var.project_id
  account_id   = var.account_id
  display_name = "Signal Loom Terraform deploy"
  description  = "Applies and destroys the Signal Loom GCP estate. Impersonated, never keyed."
}

resource "google_project_iam_member" "deploy" {
  for_each = toset(local.deploy_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deploy.email}"
}

# State bucket access is objectAdmin at BUCKET scope, not storage.admin.
#
# objectAdmin reads and writes the state objects and CANNOT delete the bucket or
# change its retention. That asymmetry is the actual protection for the state
# bucket: prevent_destroy lives in the config, and the same commit that destroys
# the bucket can delete it. This binding is the part an attacker cannot edit.
resource "google_storage_bucket_iam_member" "deploy_state" {
  bucket = var.state_bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deploy.email}"
}

# ── Who may become this account ─────────────────────────────────────────────
#
# Impersonation, never a key. A downloaded JSON key is a bearer credential with
# no expiry that lives wherever it was last pasted; an impersonation grant is
# revocable in one place and every use is attributable to the human behind it.
#
# google_service_account_key does not appear anywhere in this estate, and
# test/terraform-identity.bats fails if it ever does.
resource "google_service_account_iam_member" "impersonators" {
  for_each = toset(var.impersonators)

  service_account_id = google_service_account.deploy.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}

# ── State-bucket access: objectAdmin, and deliberately nothing more ─────────
#
# An earlier version of this module granted bucket-IAM permissions here, first
# via roles/storage.legacyBucketOwner and then via a custom role, so that
# Terraform could manage the bindings ON the state bucket.
#
# Both were solving the wrong problem. Bucket CREATION and bucket IAM are
# lifecycle, and lifecycle belongs to the privileged bootstrap step that a human
# runs once; the buckets are never destroyed. What the deploy identity does is
# POPULATE those buckets — Terraform state objects and log objects — and run
# plans and applies against everything else.
#
# Splitting it that way removes the requirement entirely. No buckets.get, no
# getIamPolicy, no setIamPolicy, no custom role to maintain, and no legacy role
# that Google will deprecate on its own schedule. The best permission is the one
# you do not need, and this is the only bucket grant that survives:
# roles/storage.objectAdmin, at bucket scope, which reads and writes objects and
# cannot touch the bucket itself.
