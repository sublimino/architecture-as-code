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
| F5 identity-ci | `feat/gcp-tf-identity-ci` | `terraform/modules/identity/**`, `scripts/ci/gcp-tf-ci.sh`, `scripts/ci/gcp-tf-reaper.sh`, `test/terraform-identity.bats`, `test/terraform-ci-lifecycle.bats`, `test/ci-lane-reaper-mutation-proof.sh` |
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

### `modules/compute` (F3) — serves BOTH lane kinds

Since 2026-08-20 this module builds demo lanes **and** CI lanes. `modules/ci-runner` was
absorbed into it and deleted; there is no second compute module. A CI lane is a demo lane
that additionally carries the `ci-lane` label, publishes an idle-suspend budget, and is not
deletion-protected. Instance names are `sl-<key>-vm` for both kinds.

| Direction | Name | Type |
|---|---|---|
| in | `project_id`, `environment_key`, `name_prefix`, `labels` | — |
| in | `kind` | string — `"demo"` or `"ci"`. **No default**, deliberately: a `demo` default gives a CI lane no `ci-lane` label and it becomes invisible to the reaper forever with no error anywhere; a `ci` default gives a demo VM the label the reaper selects on. Both defaults fail open. |
| in | `zone` | string |
| in | `machine_type` | string |
| in | `boot_disk_gb` | number |
| in | `subnet_self_link` | string |
| in | `network_tag` | string |
| in | `service_account_email` | string |
| in | `deletion_protection` | bool — a CI lane is refused at plan time unless this is `false` |
| in | `startup_script_path` | string |
| in | `idle_suspend_minutes` | number (default `0` = disabled, the demo answer). CI lanes must pass ≥ 5. |
| out | `instance_self_link` | string |
| out | `instance_name` | string |
| out | `internal_ip` | string |
| out | `instance_group_self_link` | string (unmanaged instance group wrapping the VM) |
| out | `ci_lane_label` | string — the `ci-lane` label value, `""` for a demo lane |

**The `ci-lane` label is a safety interface, not a convenience.** `scripts/ci/gcp-tf-reaper.sh`
SUSPENDS instances and selects them on it. This module is the only thing that emits it, and its
lifecycle preconditions require `var.kind`, the env-contract `kind` label and the environment
key's own prefix to agree before the plan proceeds. Do not weaken that agreement.

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

### `modules/ci-runner` (F5) — **DELETED 2026-08-20**

Absorbed into `modules/compute`. Recorded here rather than removed outright, because the
obvious repair for a future "CI lanes need something demo lanes do not" is to bring it back.

**Do not.** The reason the split was removed is that `modules/ci-runner` had no
`metadata_startup_script` at all, so a CI lane booted a bare box and every fix to the demo
bring-up landed on a machine CI never ran — CI was green against something that was not the
demo. Add the difference to `modules/compute` behind `var.kind` instead.

Its two lifecycle preconditions (name length ≤ 63, `ci-lane` label integrity) live on in
`modules/compute` as COMPUTE-RULE-06 and COMPUTE-RULE-09/10, and its `deletion_protection = false`
hardcode became COMPUTE-RULE-11 so the property survives the value becoming configurable.

The rename it forced is the safety-critical part: instances are `sl-<key>-vm` now, not
`sl-<key>-runner`, and `scripts/ci/gcp-tf-reaper.sh` used to select on that name shape. See the
gate list at the head of that script before touching it.

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

### 5a. Environment identity must have ONE source — the init/apply mismatch

This is the highest-risk failure mode in the whole design, and the original contract did not
close it.

Today environment identity is carried in **two independent places**: the backend prefix chosen
at `terraform init`, and the map key chosen at `terraform apply` via tfvars. Nothing makes them
agree. Run `init` against `osramp/environments/demo-1`, then `apply` with `demo-2.tfvars`, and
Terraform raises no objection — a changed backend config is only detected when `init` is re-run,
and `plan`/`apply` silently reuse the cached `.terraform/` backend pointer. The result is either
demo-2's resources written into demo-1's state, or a plan that reads
**"destroy demo-1, create demo-2"** into demo-1's state file. Both are silent and both are
plausible on a tired evening.

Three mechanisms close it. All three are required; none is sufficient alone.

1. **`target_env` filter.** The environments root takes a required `target_env` variable and
   instantiates exactly one environment, while keeping the whole map in scope so the
   cross-environment collision validations still bite:
   ```hcl
   for_each = { for k, v in var.environments : k => v if k == var.target_env }
   ```
   Plus a validation block asserting `contains(keys(var.environments), var.target_env)` — a
   typo'd `target_env` must fail loudly rather than silently produce a zero-resource plan.

2. **Per-environment `TF_DATA_DIR`.** Make exports `TF_DATA_DIR=.terraform-$(ENV)` for every
   terraform invocation. Two environments then cannot share a cached backend pointer at all —
   cross-contamination becomes physically impossible rather than merely detected.

3. **Post-init prefix assertion.** After `init`, Make reads the resolved backend prefix back
   (from `$(TF_DATA_DIR)/terraform.tfstate`) and asserts it contains `$(ENV)` before running
   plan or apply. A mismatch aborts non-zero. This is the belt to the other two braces, and it
   is the one that catches a human editing state by hand.

`target_env` must equal `ENV` must equal the backend prefix suffix. Any disagreement aborts.

### 5b. What `terraform/platform` actually owns

The platform root is not a naming convenience — it exists for **credential separation**, and it
must not ship empty. `bootstrap` needs `roles/storage.admin`; `platform` needs IAM, logging, and
DNS admin; `environments` needs neither. Platform owns exactly the project-level singletons that
N environments would otherwise each claim to own:

- the Workload Identity Federation pool and provider
- the log sink, the audit/log bucket, and the data-access audit config
- the Cloud DNS managed zone (if Terraform manages it at all)
- the billing budget and the notification channels
- the CI plan/apply service accounts

Anything scoped to one environment belongs in `environments`, never here.

### 5c. State-bucket protection is IAM, not config

`prevent_destroy` and `force_destroy = false` live *in the config* — the same commit that
destroys the bucket can delete them. They are useful tripwires, not enforcement. The only real
mechanism is IAM: **no plan/apply principal may hold `roles/storage.admin` on the state
bucket.** `roles/storage.objectAdmin` is sufficient to read and write state objects and
insufficient to delete the bucket. Assert the negative as well as the positive.

## 6. Hard prohibitions — these are anti-criteria, and they are tested

- No `terraform apply`, `terraform destroy`, `terraform init` against a real backend, or any
  `gcloud` mutation. **Agents run `terraform init -backend=false`, `validate`, `fmt`, and
  `tflint` only.**

  **Working `gcloud` credentials DO exist on this machine.** That makes this rule more
  important, not less. An authenticated CLI is exactly what turns a plausible-looking
  `terraform apply` into real, billable, possibly public infrastructure. The proposal this work
  implements carries an explicit approval gate: *no GCP resource, DNS record, state bucket, or
  deployment is created until Andrew approves*. Read-only inspection (`gcloud projects
  describe`, `gcloud compute instances list`) is permitted if it genuinely informs the design.
  Anything that creates, modifies, or deletes is not, regardless of how safe it looks.
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
  condition is violated.

### 7b. Mutate the REAL file. A fixture mutation proves only that the fixture is wired up.

This rule previously read "using a fixture copy under `test/fixtures/terraform/` — never by
mutating the real tree". That was wrong in a way that cost us three dead assertions in a single
task on 2026-08-20, every one of them inside a suite that was green and had a passing mutation
test. A fixture mutation asks "does my scanner detect this string in a file I just wrote it
into?" — it cannot ask "does the thing I am guarding actually exist in the shipped code?"

The three, because the shapes recur:

1. **Prose satisfied the assertion.** `[[ "$log" == *"Restart=always"* ]]` passed with
   `Restart=no` in the systemd unit. `demo-up.sh` builds remote scripts as heredocs and ships
   them via `--command`, so the script's own COMMENTS travel to the VM and land in the stub's
   command log — one of them contained the phrase. Match config directives as **complete
   lines** (`grep -qxF 'Restart=always'`, `grep -qE '^ExecStart=…'`); a comment can never be a
   whole directive line.

2. **The other branch satisfied the assertion.** A substring check for `systemctl enable`
   stayed green when it was deleted from the branch under test, because the stub receives the
   ENTIRE script — both branches — as one string and cannot report which one ran. Where an
   invariant must hold on every branch, assert a **count**, and say why in the test.

3. **A stub can only ever prove the CALLER's half.** `STUB_PF_RC=5` proves the driver *handles*
   exit 5. It cannot prove the remote script *produces* it, because the stub never executes
   that script. Deleting the real `kubectl get service` pre-check failed **nothing** across 57
   tests, including the test written for it. Any assertion about a remote script's behaviour
   needs a **source-level guard as well**, placed FIRST so the failure names the missing
   mechanism rather than a missing message.

So: fixture mutations are still welcome for exercising a scanner's edge cases, and are the only
option when the defect cannot exist in the real tree. But **the guard is not proven until the
real file has been mutated and the right test has gone red for the right reason.**

Doing that safely is the part the old rule was protecting, and it is a procedure, not a
prohibition:

- Copy the file to a path **outside the repository** first, and restore from that copy — never
  `git checkout`, which silently reverts uncommitted work in the same directory.
- **Assert the mutation applied.** A `sed` whose pattern no longer matches exits 0 and changes
  nothing, so the mutation test that follows runs against correct code and passes — a proof of
  the opposite of what it claims. Compare hashes, or use a helper that fails on a no-op. Watch
  for shell metacharacters: an unescaped `|` in a `sed` expression is a syntax error that reads
  as "the guard is dead".
- **Verify restoration** by comparing the hash to the pre-mutation one, and report it.
- A mutation that fails NOTHING is a finding, not a nuisance. Fix the assertion before moving on.
- Prefer `rg`/`grep` over parsing HCL with regex where a `terraform validate` or
  `terraform console` check would be more truthful, but do not require network access.

---

## 7a. Native Terraform tests (`.tftest.hcl`) — the primary correctness surface

**This is now the primary test surface for anything expressible in it. The bats suites in §7 are
the secondary surface, for what `terraform test` cannot reach.**

The distinction matters. A bats test greps HCL *text* and proves the source says the right thing.
`terraform test` asserts on the *evaluated configuration* — the resource attributes Terraform
actually computed, after variables, locals, `for_each`, conditionals, and module composition have
all resolved. A grep cannot tell you that `public_access_prevention` came out `"enforced"` for the
environment you actually planned; `terraform test` can. Verified working offline in this repo at
Terraform 1.15.8:

```hcl
mock_provider "google" {}

variables {
  project_id = "CHANGEME-project"
}

run "state_bucket_is_hardened" {
  command = plan

  assert {
    condition     = google_storage_bucket.state.public_access_prevention == "enforced"
    error_message = "state bucket must enforce public access prevention"
  }
}
```

### Rules

- Test files live in `tests/` inside the root or module they test, named `<topic>.tftest.hcl`.
- **`mock_provider "google" {}` and `mock_provider "google-beta" {}` are mandatory in every test
  file.** No test may reach a real provider, require credentials, or touch the network.
- **`command = plan` only.** Never `command = apply` — apply against a mocked provider still
  writes state, and the habit is the thing we are trying not to build.
- Every module and every root ships at least one `.tftest.hcl`.
- Negative tests use `expect_failures` against the variable that should reject the input. This is
  the correct way to prove a `validation` block fires, and it is far more truthful than parsing
  stderr from a fixture root:

  ```hcl
  run "rejects_prod_prefix" {
    command = plan
    variables {
      environments = { "prod-1" = { /* … */ } }
    }
    expect_failures = [var.environments]
  }
  ```

- **Every negative test must be paired with a positive one proving the same configuration passes
  when the offending input is corrected.** A `run` block that fails for an unrelated reason —
  a syntax error, a missing variable — is indistinguishable from a validation rule firing
  correctly. Baseline-green then mutation-red, every time. This is the single most common way a
  `terraform test` suite ends up measuring nothing.
- `terraform test` requires `terraform init -backend=false` to have run in that directory first.
  The Make target owns that; do not commit `.terraform/` directories.
- Keep each file under 30 seconds.

### What goes where

| Assertion | Surface |
|---|---|
| A resource attribute has the required value after evaluation | `.tftest.hcl` |
| A variable validation rejects bad input | `.tftest.hcl` with `expect_failures` |
| Module composition wires output → input correctly | `.tftest.hcl` |
| A forbidden construct appears **nowhere** in the tree (`access_config`, `google_service_account_key`, `roles/owner`) | bats — this is a whole-tree property, not a plan property |
| Shell script behaviour, Make target behaviour, file layout, git hygiene | bats |
| Documentation content | bats |

Absence-across-the-whole-tree is the case `terraform test` genuinely cannot do: it can only see
what a given plan evaluated, not what no configuration anywhere contains. Keep those in bats.

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
