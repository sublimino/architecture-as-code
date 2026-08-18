# Wiring the platform root at integration

This root is complete and validates on its own, but one of its two module calls
is **commented out**: `modules/identity` is built by chunk F5 on branch
`feat/gcp-tf-identity-ci` and does not exist in the F6 worktree. Terraform
resolves `source = "../modules/identity"` at `init` time, so an uncommented call
to a missing directory fails `terraform init` outright — not at plan, not with a
warning. That is why it ships commented rather than "wired but untested".

`modules/observability` is **already live** — it is owned by this chunk, it
exists here, and the tftest suite in `tests/` asserts on its evaluated output.
Nothing needs uncommenting for observability.

## What to uncomment, in order

Do these in sequence. Each step ends in a green check, so a failure names the
step that caused it.

### 1. `main.tf` — the variables inside the wiring block

Uncomment, in `terraform/platform/main.tf`, between the
`WIRING BLOCK` and `END WIRING BLOCK` markers:

| # | Declaration | Notes |
|---|---|---|
| 1 | `variable "project_number"` | No default — it is genuinely required by the WIF provider resource name. Numeric project number, **not** the project id. |
| 2 | `variable "environment_keys"` | Must equal `keys(var.environments)` in the environments root, or an environment gets no runtime service account and its compute module fails on an empty email. |
| 3 | `variable "github_owner_id"` | Numeric GitHub owner id. A login can be released and re-registered by a stranger; the numeric id cannot. |
| 4 | `variable "github_repository"` | `owner/repo` form. |
| 5 | `variable "github_allowed_ref"` | Single ref, e.g. `refs/heads/main`. |

**Check:** `terraform validate` still passes. Nothing consumes the variables
yet, so this step alone changes no plan.

### 2. `main.tf` — the `module "identity"` block

Uncomment the `module "identity"` block. Its inputs are copied verbatim from
`terraform/CONTRACT.md` section 4:

```
project_id  project_number  environment_keys
github_owner_id  github_repository  github_allowed_ref
```

**Do not rename any of these when uncommenting.** If they no longer match F5's
module, that is a contract violation to reconcile at merge, not a local rename
to paper over. A rename here is exactly how six parallel chunks turn into a
rewrite.

**Check:** `terraform init -backend=false && terraform validate`. This is the
step that fails if F5's inputs drifted.

### 3. `outputs.tf` — the four identity outputs

Uncomment, between the same markers in `terraform/platform/outputs.tf`:

| # | Output | Consumed by |
|---|---|---|
| 1 | `workload_identity_provider_name` | The GitHub Actions `google-github-actions/auth` step. |
| 2 | `ci_plan_service_account_email` | The read-only plan lane. |
| 3 | `ci_apply_service_account_email` | The privileged apply lane. |
| 4 | `runtime_service_account_emails` | The environments root, fed into `modules/compute`'s `service_account_email` per environment. |

**Check:** `terraform validate`.

### 4. `tests/` — the identity assertions

`tests/platform_wiring.tftest.hcl` carries a commented `run` block asserting the
WIF provider's `attribute_condition` is non-empty (ISC-350). Uncomment it once
step 2 lands.

**Check:** `terraform test`.

### 5. Supply the new variables

Add to the platform tfvars (or `-var` flags):

```hcl
project_number     = "000000000000"
environment_keys   = ["demo-1"]
github_owner_id    = "00000000"
github_repository  = "CHANGEME-owner/osramp-demo"
github_allowed_ref = "refs/heads/main"
```

**Check:** `make gcp-tf-plan ENV=demo-1` produces a reviewable plan.

## Ordering against the other roots

`bootstrap` → `platform` → `environments`. Platform consumes
`state_bucket_name` from bootstrap's output and produces
`runtime_service_account_emails`, `dns_managed_zone_name` and
`notification_channel_ids` for environments.

**The environments root consumes those outputs through `terraform_remote_state`,
not through a module call.** That changes the ordering from a preference into a
hard gate, and it is worth being precise about why.

Identity used to be instantiated in the environments root. An adversarial review
found that to be a reversibility hole: a project-level singleton declared in an
environment's root is stored in an *environment's* state file, and
`make gcp-tf-destroy ENV=demo-1` destroys everything in that state. The destroy
guard refuses `platform` and `bootstrap` **by path**, so it would have permitted
exactly that destroy — taking the workload identity pool, both CI service
accounts and every `google_project_iam_member` with it, after which CI could no
longer authenticate at all and recovery needed bootstrap-level credentials. So
the singletons live here, per CONTRACT §5b, and environments reads them:

```hcl
data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket_name
    prefix = "osramp/platform"
  }
}
```

The consequence for sequencing: a `terraform_remote_state` data source reads a
state object that must **already exist**. Planning `demo-1` before this root has
been *applied* — not planned, applied — fails on a missing remote state, and the
error names a missing output rather than a missing step. There is no plan-time
stand-in, so this cannot be worked around by validating harder.

Two practical consequences:

1. **Apply this root before the first environment plan.**
   `terraform/RUNBOOK.md` step 5 is that apply; step 6 is the environment.
2. **`environment_keys` here must be a superset of every environment key that
   will ever be planned.** A runtime service account must exist for *every*
   environment, not only the one being applied — that is precisely why these are
   singletons and not per-environment resources. Adding `demo-2` therefore means
   re-applying this root with `environment_keys = ["demo-1", "demo-2"]` first,
   and only then planning `demo-2`.

## What deliberately stays commented

Nothing else. If you find yourself commenting out a resource to make a plan
succeed, that is a finding to record, not a fix to apply.
