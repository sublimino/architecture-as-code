resource "google_storage_bucket" "terraform_state" {
  name     = var.state_bucket_name
  project  = var.project_id
  location = var.location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      # This keeps at least N noncurrent generations because deletion starts only after more than N newer versions exist.
      num_newer_versions = var.noncurrent_versions_kept
      with_state         = "ARCHIVED"
    }
  }

  labels = merge(
    {
      managed-by = "terraform"
      component  = "signalloom"
      purpose    = "terraform-state"
    },
    var.labels,
  )
}

# State-bucket protection is IAM, not config.
#
# prevent_destroy and force_destroy = false live in THIS FILE. The same commit that deletes the
# bucket can delete them. They are tripwires, not enforcement.
#
# The real mechanism is IAM: no plan/apply principal holds bucket-administration rights here.
# roles/storage.objectAdmin is sufficient to read and write state objects and insufficient to
# delete the bucket or change its retention. This root deliberately declares no binding for
# roles/storage.admin — granting it is a one-line change a reviewer must be able to see, and
# test/terraform-state-protection.bats fails if that line ever appears.
resource "google_storage_bucket_iam_binding" "state_object_admins" {
  bucket  = google_storage_bucket.terraform_state.name
  role    = "roles/storage.objectAdmin"
  members = [
    "allUsers",
  ]
}

# The log/audit bucket is deliberately NOT declared here. Three reasons, in ascending order of
# how much they matter:
#
#  1. Ownership. The audit bucket and the log sink belong to terraform/platform, which runs after
#     bootstrap and holds the logging-admin credential this root intentionally lacks.
#  2. Single point of change. Declaring it here would create a second place where a change to log
#     retention has to be made, and the two would drift.
#  3. Decisively: the log bucket must never BE the state bucket. Co-locating audit logs with the
#     state they describe means one deletion destroys both the record and the evidence of it.
#     That is why the separation is structural rather than stylistic.

# ── The deploy identity ─────────────────────────────────────────────────────
#
# Created here because it is what applies the platform and environment roots, so
# it cannot be created by them. One elevated human runs bootstrap once; after
# that, nobody needs elevated rights again — every subsequent apply and destroy
# runs as this account by impersonation.
#
# Gated so bootstrap still works for someone who only wants the state bucket.
module "deploy_identity" {
  count  = var.create_deploy_identity ? 1 : 0
  source = "../modules/deploy-identity"

  project_id        = var.project_id
  account_id        = var.deploy_account_id
  state_bucket_name = google_storage_bucket.terraform_state.name
  impersonators     = var.deploy_impersonators
}

# ---------------------------------------------------------------------------
# Tailscale TLS certificate store — durable across `terraform destroy`
# ---------------------------------------------------------------------------
#
# THE DEFECT THIS EXISTS TO FIX, measured on sl-ci-1-vm 2026-08-23:
#
#   /var/lib/tailscale/        drwx------ Aug 22 17:56   <- the VM rebuild time
#   /var/lib/tailscale/certs/  acme-account.key.pem ONLY, no cert and no key
#
# tailscaled keeps its Let's Encrypt certificate under /var/lib/tailscale/certs,
# which is on the BOOT DISK. A destroy takes the disk, so the next build starts
# with an empty store and asks ACME for a brand new certificate:
#
#   boot (uptime -s)   2026-08-22 17:55:23
#   cert request       2026-08-22T17:56:05  cert("sl-ci-1.taild4da3.ts.net")
#
# 42 seconds after boot, driven by signalloom-tailscale-serve.service, NOT by
# anyone visiting the URL. Let's Encrypt allows FIVE certificates per exact set
# of identifiers per 168h. The MagicDNS name survives the rebuild, so the limit
# is not reset by rebuilding — rebuilding is what CONSUMES it. The estate spent
# its allowance and both lanes now answer 000, because the TLS handshake cannot
# complete without a certificate:
#
#   getCertPEM: 429 urn:ietf:params:acme:error:rateLimited: too many
#   certificates (5) already issued for this exact set of identifiers in the
#   last 168h0m0s
#
# A certificate is valid ~90 days and tailscaled reuses a valid one, so carrying
# it across the rebuild turns "a new certificate every deploy" into "a new
# certificate every ~60 days".
#
# ─── Why THIS root ──────────────────────────────────────────────────────────
#
# Two independent reasons, and the second is the one that decided it.
#
# 1. Survival. The whole point is outliving `terraform destroy`. A bucket in
#    terraform/environments is deleted by `make gcp-tf-destroy ENV=<key>` — the
#    very operation whose cost it removes. That rules out the environments root
#    but not, on its face, the platform root.
#
# 2. CREDENTIAL SEPARATION, which does rule out platform. This estate splits its
#    roots by the rights their applying identity holds: bootstrap holds bucket
#    administration, platform holds IAM, logging, monitoring and DNS, and
#    environments holds none of those. Creating a bucket from the platform root
#    would need bucket-creation rights the platform identity deliberately does
#    not have, so it would have failed at apply with a 403 — and the available
#    "fix", widening that identity, is the one this repo has already argued
#    against at length for the Tailscale auth-key secret (see the long comment
#    in modules/compute/main.tf). Bucket CREATION is LIFECYCLE, and lifecycle
#    belongs to the privileged bootstrap step a human runs once.
#
#    test/terraform-state-protection.bats enforces exactly this: it fails if any
#    google_storage_bucket resource appears in a CONSUMING root. That guard
#    caught this being put in the platform root during development, which is
#    what it is for.
#
# This is the THIRD instance of one defect class — durable state written where
# the rebuild destroys it. The cosign keypair and the zot blob store were the
# first two, both fixed by relocating to a path the re-DELIVERY does not clean.
# That is a weaker guarantee than this needs: a delivery removes the checkout, a
# destroy removes the whole disk, and only the destroy burns an ACME issuance.
#
# ─── Who can read the private key ───────────────────────────────────────────
#
# A TLS private key is a credential, and this bucket holds nothing else.
#
#   * uniform_bucket_level_access — ACLs off, so IAM is the only answer to "who
#     can read this", and it is answerable by reading this file.
#   * public_access_prevention enforced — allUsers and allAuthenticatedUsers
#     cannot be granted even by a later mistake elsewhere.
#   * Each lane's runtime service account gets roles/storage.objectAdmin
#     CONDITIONED on its own object prefix, so sl-rt-demo-1 reads and writes
#     demo-1/ and is denied ci-1/. Without the condition every lane could read
#     every other lane's key; a shared trust domain is not a reason to skip a
#     boundary that costs one expression.
#   * Object administration only. Nothing granted here can change this bucket's
#     own IAM or lifecycle, so a compromised VM cannot widen the condition that
#     confines it.
#   * No human grant is made here.
#
# Dormant by default: with tailnet_cert_bucket_name empty this creates nothing
# at all, and the startup script's restore step stays disabled. An estate that
# never asked for Tailscale must still plan and apply cleanly.

resource "google_storage_bucket" "tailnet_certs" {
  count = var.tailnet_cert_bucket_name == "" ? 0 : 1

  name     = var.tailnet_cert_bucket_name
  project  = var.project_id
  location = var.tailnet_cert_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # The deliberate pair to prevent_destroy below: even with the lifecycle block
  # removed, a non-empty bucket still refuses deletion rather than silently
  # taking every lane's certificate with it.
  force_destroy = false

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }

    condition {
      num_newer_versions = var.noncurrent_versions_kept
      with_state         = "ARCHIVED"
    }
  }

  labels = var.labels
}

# One conditioned grant per lane.
#
# google_storage_bucket_iam_member rather than the authoritative _iam_binding
# the state bucket uses, and that is a real difference rather than an
# inconsistency: an authoritative binding takes a single members list and cannot
# attach a DIFFERENT condition per principal, which is precisely what confines
# each lane to its own prefix. A binding here would mean one shared grant over
# the whole bucket — every lane able to read every other lane's private key.
#
# resource.name for a GCS object is the full
# projects/_/buckets/<bucket>/objects/<name> path, so anchoring on
# ".../objects/<lane>/" scopes the grant to that lane's prefix and nothing else.
# Asserted in test/terraform-tailscale-cert-persistence.bats, because an IAM
# condition that silently stops matching is indistinguishable from no condition
# at all when you are only looking at whether the deploy worked.
resource "google_storage_bucket_iam_member" "tailnet_cert_writers" {
  for_each = var.tailnet_cert_bucket_name == "" ? {} : var.tailnet_cert_writers

  bucket = google_storage_bucket.tailnet_certs[0].name
  role   = "roles/storage.objectAdmin"
  member = each.value

  condition {
    title       = "own-lane-cert-prefix-only"
    description = "Confines ${each.key} to the ${each.key}/ object prefix, so one lane cannot read another lane's TLS private key."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${var.tailnet_cert_bucket_name}/objects/${each.key}/\")"
  }
}
