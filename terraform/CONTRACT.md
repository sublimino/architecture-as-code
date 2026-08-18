# Terraform GCP Platform — Interface Contract

**This file is the merge contract.** Six chunks are built in parallel worktrees. They collide
unless every one of them consumes the interfaces below *verbatim* rather than inventing its own.

If you believe an interface here is wrong, **do not change it in your worktree**. Record the
objection in your chunk's `NOTES.md` and implement the contract as written. The orchestrator
reconciles objections at merge time. A unilateral interface change is the one failure mode that
turns a merge into a rewrite.

Companion documents: `terraform/ISA.md` (the 321 criteria — this is what "done" means).

---

## 1. Directory ownership — disjoint by construction

Touch **only** the paths your chunk owns. Creating a file in another chunk's subtree is a
merge conflict by definition.

| Chunk | Branch | Owns (exclusively) |
|-------|--------|--------------------|
| F1 foundation | `feat/gcp-tf-foundation` | `terraform/bootstrap/**`, `terraform/versions.tf`, `terraform/README.md`, `terraform/.gitignore` additions, `test/terraform-conventions.bats`, `test/terraform-state-protection.bats` |
| F2 envmodel | `feat/gcp-tf-envmodel` | `terraform/modules/env-contract/**`, `terraform/environments/**` (variables + validation + tfvars examples), `test/terraform-environment-keys.bats` |
| F3 network-compute | `feat/gcp-tf-network-compute` | `terraform/modules/network/**`, `terraform/modules/compute/**`, `test/terraform-network-security.bats` |
| F4 edge | `feat/gcp-tf-edge` | `terraform/modules/edge/**`, `scripts/gcp-tf/edge-probe-*.sh`, `test/terraform-edge-security.bats` |
| F5 identity-ci | `feat/gcp-tf-identity-ci` | `terraform/modules/identity/**`, `terraform/modules/ci-runner/**`, `scripts/ci/gcp-tf-ci.sh`, `scripts/ci/gcp-tf-reaper.sh`, `test/terraform-identity.bats`, `test/terraform-ci-lifecycle.bats` |
| F6 obs-make-docs | `feat/gcp-tf-obs-make-docs` | `terraform/modules/observability/**`, `terraform/platform/**`, `Makefile` (append-only), `terraform/RUNBOOK.md`, `terraform/SECURITY.md`, `terraform/COSTS.md`, `.github/workflows/terraform-validate.yaml`, `test/terraform-make-contract.bats` |

**Shared-file rule.** `Makefile` is owned by F6 alone and is **append-only**: add a clearly
delimited block at the end of the file. No other chunk edits it. `.gitignore` is owned by F1
alone, also append-only.

**Nobody** edits: `scripts/ci/gcp-ci.sh`, `scripts/ci/vm-pipeline.sh`, `scripts/ci/ci-lock.sh`,
`d2-osramp-fleet/terraform/**`, any existing file under `test/`, `d2-signalloom/**`,
`terraform/ISA.md`, or this file.

---

## 2. Version pins — identical in every root and module

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.8"
    }
  }
}
```

Every root (`bootstrap`, `platform`, `environments`) and every module directory carries a
`versions.tf` with exactly this block. Modules declare `required_providers` but **never**
`provider` blocks — providers are configured in roots only.

---

## 3. The environment object type — the single most-shared interface

Declared by **F2** in `terraform/modules/env-contract/variables.tf` and consumed by every
other chunk. Copy this type verbatim; do not add or rename fields.

```hcl
variable "environments" {
  description = "Typed map of every Signal Loom environment, keyed by stable environment key."
  type = map(object({
    kind             = string       # "demo" | "ci"
    subnet_cidr      = string       # RFC1918 /24, unique across the map
    region           = string       # e.g. "europe-west2"
    zone             = string       # e.g. "europe-west2-a"
    machine_type     = string       # e.g. "n2-standard-16"
    boot_disk_gb     = number
    hostname         = string       # fully-qualified, unique across the map; "" disables DNS
    allowed_ipv4     = list(string) # CIDRs permitted at the edge; never 0.0.0.0/0
    allowed_ipv6     = list(string) # CIDRs permitted at the edge; never ::/0
    app_port         = number       # backend port the LB health-checks and forwards to
    deletion_protect = bool
    labels           = map(string)  # extra labels, merged over the mandatory set
  }))
}
```

### Mandatory validation blocks (F2 owns these)

Every one of these is an ISC. Each is a separate `validation` block so the failure message
names the actual rule that fired.

1. Every key matches `^(demo|ci)-[1-9][0-9]*$`.
2. Every entry's `kind` is `demo` or `ci`.
3. Every key's prefix equals its `kind`.
4. `hostname` values are unique across the map (ignoring `""`).
5. `subnet_cidr` values are unique across the map.
6. Every `subnet_cidr` parses as a CIDR and is RFC1918.
7. Every `allowed_ipv4` entry parses as an IPv4 CIDR.
8. Every `allowed_ipv6` entry parses as an IPv6 CIDR.
9. No `allowed_ipv4` entry is `0.0.0.0/0`.
10. No `allowed_ipv6` entry is `::/0`.
11. Every `app_port` is between 1 and 65535.

### Mandatory naming and labelling locals (F2 owns, everyone consumes)

```hcl
locals {
  # Deterministic, key-embedded, and <= 63 chars for GCP name limits.
  name_prefix = { for k, v in var.environments : k => "sl-${k}" }

  mandatory_labels = { for k, v in var.environments : k => merge(
    {
      environment = k
      kind        = v.kind
      managed-by  = "terraform"
      component   = "signalloom"
    },
    v.labels,
  ) }
}
```

**Every** resource in every module sets `labels = var.labels` (passed down) and names itself
`"${var.name_prefix}-<role>"`. No resource invents its own naming scheme.

---

## 4. Module interfaces — inputs and outputs are frozen

Each module receives the *resolved single-environment* values, never the whole map. The roots
do the `for_each`. This keeps modules simple and makes a single-environment plan readable.

### `modules/network` (F3)

| Direction | Name | Type |
|---|---|---|
| in | `project_id` | string |
| in | `environment_key` | string |
| in | `name_prefix` | string |
| in | `labels` | map(string) |
| in | `region` | string |
| in | `subnet_cidr` | string |
| in | `app_port` | number |
| in | `runtime_service_account_email` | string |
| in | `nat_log_filter` | string (default `"ERRORS_ONLY"`) |
| out | `network_self_link` | string |
| out | `subnet_self_link` | string |
| out | `network_tag` | string |
| out | `subnet_cidr` | string |

### `modules/compute` (F3)

| Direction | Name | Type |
|---|---|---|
| in | `project_id`, `environment_key`, `name_prefix`, `labels` | — |
| in | `zone` | string |
| in | `machine_type` | string |
| in | `boot_disk_gb` | number |
| in | `subnet_self_link` | string |
| in | `network_tag` | string |
| in | `service_account_email` | string |
| in | `deletion_protection` | bool |
| in | `startup_script_path` | string |
| out | `instance_self_link` | string |
| out | `instance_name` | string |
| out | `internal_ip` | string |
| out | `instance_group_self_link` | string (unmanaged instance group wrapping the VM) |

### `modules/edge` (F4)

| Direction | Name | Type |
|---|---|---|
| in | `project_id`, `environment_key`, `name_prefix`, `labels` | — |
| in | `hostname` | string (`""` disables DNS record creation) |
| in | `dns_managed_zone` | string (`""` disables DNS record creation) |
| in | `backend_instance_group` | string |
| in | `app_port` | number |
| in | `allowed_ipv4` | list(string) |
| in | `allowed_ipv6` | list(string) |
| in | `rate_limit_threshold_per_minute` | number |
| in | `enable_cdn` | bool (default `false`) |
| out | `lb_ip_address` | string |
| out | `certificate_name` | string |
| out | `security_policy_name` | string |
| out | `backend_service_name` | string |

### `modules/identity` (F5)

| Direction | Name | Type |
|---|---|---|
| in | `project_id` | string |
| in | `project_number` | string |
| in | `environment_keys` | list(string) — this module IS map-aware |
| in | `github_owner_id` | string (numeric, immutable) |
| in | `github_repository` | string (`owner/repo`) |
| in | `github_allowed_ref` | string |
| out | `runtime_service_account_emails` | map(string) keyed by environment key |
| out | `workload_identity_provider_name` | string |
| out | `ci_plan_service_account_email` | string |
| out | `ci_apply_service_account_email` | string |

### `modules/ci-runner` (F5)

| Direction | Name | Type |
|---|---|---|
| in | `project_id`, `environment_key`, `name_prefix`, `labels` | — |
| in | `zone`, `machine_type`, `boot_disk_gb` | — |
| in | `subnet_self_link`, `network_tag`, `service_account_email` | — |
| in | `idle_suspend_minutes` | number |
| out | `instance_name` | string |
| out | `instance_self_link` | string |

### `modules/observability` (F6)

| Direction | Name | Type |
|---|---|---|
| in | `project_id` | string |
| in | `labels` | map(string) |
| in | `log_retention_days` | number |
| in | `uptime_targets` | map(object({ hostname = string, app_port = number })) |
| in | `notification_channel_ids` | list(string) |
| in | `billing_account_id` | string (`""` disables the budget) |
| in | `budget_amount_currency` | string (default `"GBP"`) |
| in | `budget_amount_units` | number |
| out | `log_bucket_name` | string |
| out | `log_sink_writer_identity` | string |

---

## 5. Backend configuration — no backend block is ever hand-completed

- `terraform/bootstrap` has **no** `backend` block at all.
- `terraform/platform` declares `backend "gcs" {}` (empty) and is initialised with
  `-backend-config=bucket=<x> -backend-config=prefix=osramp/platform`.
- `terraform/environments` declares `backend "gcs" {}` (empty) and is initialised with
  `-backend-config=bucket=<x> -backend-config=prefix=osramp/environments/<key>`.

The empty-block form is deliberate: a partially-configured backend makes it *impossible* to
run `terraform apply` in the environments root without having named a prefix, which is what
stops "forgot to re-init between environments" from silently reusing the previous state.
F6's Make targets always run `init -reconfigure` with the prefix derived from `ENV`.

---

## 6. Hard prohibitions — these are anti-criteria, and they are tested

- No `terraform apply`, `terraform destroy`, `terraform init` against a real backend, or any
  `gcloud` mutation. **Agents run `terraform init -backend=false`, `validate`, `fmt`, and
  `tflint` only.** There are no cloud credentials in this environment and there must be no
  attempt to obtain any.
- No `access_config` block anywhere (no external IPs).
- No `google_service_account_key` resource.
- No `google_project_iam_policy` resource (authoritative; destroys existing bindings). Use
  `google_project_iam_member`.
- No IAM binding granting `roles/owner` or `roles/editor`.
- No firewall rule with `source_ranges` including `0.0.0.0/0`.
- No `0.0.0.0/0` or `::/0` in any allowlist default or example.
- No real project ID, billing account ID, domain name, or IP address of Andy's in any committed
  file. Use `CHANGEME-project`, `example.invalid`, and RFC5737 documentation ranges
  (`192.0.2.0/24`, `198.51.100.0/24`) in examples.
- No absolute path under `/home/andy` in any committed file.
- No `terragrunt.hcl`.
- No `terraform workspace` invocation.
- No secret, token, or key literal.
- **No guard that repairs what it detects.** A check that auto-formats, auto-fills a default,
  or auto-corrects its input can never fail, so the broken input ships green. Verify and fail.
- **No test that passes vacuously.** Every bats file must first assert that the thing under
  test *exists*, then assert its behaviour. A `grep -v` that finds nothing because the file was
  never created is a green test measuring nothing.

---

## 7. Test conventions

- New bats files live in `test/` and are named `terraform-<topic>.bats`.
- Every file starts with a presence assertion (`[ -f ... ]` / `[ -d ... ]`) before any
  behavioural assertion — see the "no vacuous pass" rule above.
- Every file must run green **offline**, with no network and no cloud credentials.
- Every file must complete in under 30 seconds.
- Include at least one *mutation check*: a test that proves the suite fails when the guarded
  condition is violated, using a fixture copy under `test/fixtures/terraform/` — never by
  mutating the real tree.
- Prefer `rg`/`grep` over parsing HCL with regex where a `terraform validate` or
  `terraform console` check would be more truthful, but do not require network access.

---

## 8. Commit conventions

- Conventional commits with a scope: `feat(terraform): …`, `test(terraform): …`,
  `docs(terraform): …`, `feat(make): …`.
- Commits are **unsigned** — this branch's history shows `%G? = N`. Use
  `git commit --no-gpg-sign`. Never invoke `gpg` interactively; it blocks on pinentry.
- Commit early and often inside your worktree. **Zero commits is a failure, not idleness.**
- Leave the worktree clean at hand-off: `git status --porcelain` empty.
- Do not rebase, merge, push, or touch any branch other than your own.

---

## 9. What "done" means for a chunk

1. Every ISC in your assigned range is either satisfied or explicitly reported as not-done
   with a reason.
2. `terraform fmt -recursive -check` passes on your subtree.
3. `terraform init -backend=false && terraform validate` passes on every root/module you own.
4. `tflint` passes on every module you own.
5. Your bats file(s) run green offline, and your mutation check proves they can fail.
6. `shellcheck` passes on every shell script you added.
7. Your worktree is committed and clean.
8. `NOTES.md` in your worktree root records: what you built, which ISCs you claim,
   which you could not satisfy and why, any contract objection, and anything the
   orchestrator must know before merging.
