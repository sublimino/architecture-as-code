# Wiring the environments root at integration

`terraform/environments/main.tf` ships with one live module (`env_contract`) and five
commented-out module blocks. This file says exactly which blocks to uncomment, in what order,
and what has to be true before each one will plan. The point is that integration should be
mechanical — a person following this file needs to read no Terraform to do the wiring, only to
review it afterwards.

One of those five, `module "identity"`, is **not to be uncommented at all** — identity moved to
`terraform/platform` and this root consumes it read-only through `terraform_remote_state`. The
reasoning is at the bottom of this file under "Correction"; the ordering table below already
reflects it, so following the table is sufficient and reading the correction is optional.

The blocks are commented rather than absent because `../modules/{network,compute,edge,ci-runner}`
are built by chunks F3, F4 and F5 in parallel worktrees and do not exist on this branch. A live
`module` block pointing at a missing directory makes `terraform init` fail, which would make the
root un-validatable, which would make `test/terraform-environment-keys.bats` — the only test in
the tree that *executes* the validation rules rather than grepping for them — impossible to run.
The tests are the deliverable, so the root stays green.

## Order

Uncomment in this order. It is a dependency order, not a preference: each step consumes an
output of the one before it, and doing them out of order produces a "reference to undeclared
module" error that reads like a typo rather than like a sequencing mistake.

| # | Block in `main.tf` | Chunk | Do this only once | Consumes | Produces for later blocks |
|---|--------------------|-------|-------------------|----------|---------------------------|
| 1 | `data "terraform_remote_state" "platform"` | F6 owns the producer | the **platform root has been applied** (not merely planned) against `prefix=osramp/platform` | `var.state_bucket_name` | `runtime_service_account_emails` (map keyed by environment key), `dns_managed_zone_name`, `notification_channel_ids` |
| 2 | `module "network"` | F3 | `terraform/modules/network/` exists **and** step 1 is live | `local.target_environments`, `data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]` | `subnet_self_link`, `network_tag` |
| 3 | `module "compute"` | F3 | `terraform/modules/compute/` exists **and** step 2 is live | step 2's outputs, `var.startup_script_path` | `instance_group_self_link` |
| 4 | `module "edge"` | F4 | `terraform/modules/edge/` exists **and** step 3 is live | `module.compute[each.key].instance_group_self_link`, `var.dns_managed_zone`, `var.access_mode`, `var.iap_members` | the LB — nothing downstream |
| 5 | `module "ci_runner"` | F5 | `terraform/modules/ci-runner/` exists **and** step 2 is live | step 2's outputs, `data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]` | nothing downstream |

Steps 4 and 5 are independent of each other; either order works.

**Step 1 is not a code change you can validate your way through.** A
`terraform_remote_state` data source reads a state object that must already
exist; there is no plan-time stand-in for it. So the ordering constraint is not
"uncomment identity first", it is **"apply `terraform/platform` first"** — a
real apply, against the real bucket, by a human. `terraform/RUNBOOK.md` step 5
is that apply. Until it has happened, steps 2–5 here cannot produce a plan, and
the error they produce names a missing output rather than a missing step.

### Two root variables the edge wiring needs, which are not declared yet

`terraform/environments/variables.tf` does **not** currently declare
`access_mode` or `iap_members`, and `demo-1.tfvars.example` sets both. Terraform
treats a value for an undeclared variable in a `-var-file` as a *warning*, so
this does not fail a plan — it silently drops the value and the edge module
takes its own default. That is the worst available failure mode for a variable
whose whole job is to decide whether the environment is publicly reachable, so
declare them before step 4:

```hcl
variable "access_mode" {
  description = "Edge reachability. \"iap\" puts Identity-Aware Proxy in front of the backend; \"public\" leaves the Cloud Armor allowlist as the only gate."
  type        = string
  default     = "iap"

  validation {
    condition     = contains(["iap", "public"], var.access_mode)
    error_message = "access_mode must be \"iap\" or \"public\"."
  }
}

variable "iap_members" {
  description = "IAM principals permitted through IAP, each prefixed user:/group:/serviceAccount:. Ignored when access_mode is \"public\"."
  type        = list(string)
  default     = []
}
```

They are **root variables, not fields on the `environments` object**, because
that object type is frozen by CONTRACT §3 — "copy this type verbatim; do not add
or rename fields". They follow the existing precedent set by
`rate_limit_threshold_per_minute` and `enable_cdn`: an edge-module input that
varies by deployment rather than by environment key lives at the root and is
passed down.

After each step: `terraform init -backend=false && terraform validate && tflint`. Do not batch
the uncommenting. A single `plan` covering five newly-live modules attributes every error to the
whole change, and the input-name mismatches this file exists to prevent are exactly the errors
that get lost in a wall of them.

## What each block is filtered on, and why

Three different `for_each` expressions appear, and the differences are load-bearing:

- **`identity` is not filtered at all**, and is not `for_each`ed. The Workload Identity pool and
  the CI service accounts are project-level singletons, and a runtime service account must exist
  for *every* environment key regardless of which one is being applied. Filtering this module by
  `target_env` would mean `apply` for demo-1 deletes demo-2's service account.
- **`network` uses `local.target_environments`** — the single targeted environment. Networks are
  per-environment and must not be touched by another environment's apply.
- **`compute`, `edge` and `ci_runner` filter `local.target_environments` further on `kind`.** A
  CI lane gets a runner and no public edge; a demo lane gets a VM and an edge. That filter is why
  a `ci-*` entry carries `hostname = ""` — there is no DNS record because there is no load
  balancer.

`local.target_environments` is derived from `module.env_contract.environments` (the resolved map,
carrying `name_prefix` and merged labels), narrowed by `k == var.target_env`. The **whole** map
still enters `module.env_contract`, which is what keeps the cross-environment uniqueness rules
able to see a collision between two environments when only one is being applied.

## Before the first real apply

These are not this chunk's to do, but the wiring is not finished until they are true.

1. **The Makefile must supply mechanisms 2 and 3 of CONTRACT.md §5a.** This root supplies
   mechanism 1 (`target_env` plus its existence validation). It cannot supply the other two,
   because they are properties of how Terraform is *invoked*:
   - `TF_DATA_DIR=.terraform-$(ENV)` exported for every invocation, so two environments cannot
     share a cached backend pointer;
   - a post-`init` assertion that the resolved backend prefix in `$(TF_DATA_DIR)/terraform.tfstate`
     contains `$(ENV)`, aborting non-zero on any mismatch.

   `terraform output -raw target_env` is published for exactly that comparison. Until all three
   exist, `target_env` narrows the blast radius but does not guarantee that the state file being
   written belongs to the environment named in the tfvars.

2. **`github_owner_id` must be the numeric ID, looked up rather than guessed** — and it is now
   supplied to the **platform** root, not this one, because that is where the workload identity
   provider lives. It remains declared here (defaulting to `""` in `ci-1.tfvars.example`) only as
   a pass-through for the CI lane's own wiring. A wrong value silently widens who may assume the
   CI service accounts. `gh api users/<owner> --jq .id` is read-only and is the intended lookup.

3. **`project_number` must be set on the platform root** before its identity module goes live;
   the workload identity pool path is built from it. This root's `project_number` variable is
   informational and may stay `""`.

4. **`dns_managed_zone` must name a pre-existing zone**, or stay `""`. `""` disables DNS record
   creation for every environment, and the edge module still builds — the load balancer simply
   has no name pointed at it.

## If a sibling module's inputs disagree with the commented block

The input names in `main.tf` are copied from `CONTRACT.md` §4 and are frozen. If a module's real
inputs differ, **the module is wrong, not this file** — raise it with the orchestrator rather
than editing either side. A unilateral rename on one side of a frozen interface is the failure
mode the contract exists to prevent, and it converts a merge into a rewrite.

## Correction — `module "identity"` does NOT belong in this root

Step 1 of the table above originally said to uncomment `module "identity"` here. **Do not.**
An adversarial security review found that instruction to be a reversibility hole, and it has
been removed from `main.tf`.

The reasoning behind it was half right: the WIF pool and the CI service accounts are
project-level singletons, so they must not be filtered by `target_env` — otherwise applying
`demo-1` deletes `demo-2`'s runtime service account. That much is true.

The conclusion did not follow. A singleton declared in *this* root is stored in an
*environment's* state file, and `make gcp-tf-destroy ENV=demo-1` destroys everything in that
state. The destroy guard refuses the `platform` and `bootstrap` roots **by path**, so it would
have permitted this destroy without complaint — taking the workload identity pool, both CI
service accounts and every `google_project_iam_member` with it. CI could no longer
authenticate, and recovery would need bootstrap-level credentials. The target's closing line
("the platform singletons were not touched") would have been false.

Singletons live in `terraform/platform` per CONTRACT §5b, which exists for exactly this
credential- and lifecycle-separation reason. This root consumes them read-only via
`terraform_remote_state` against prefix `osramp/platform`. Step 1 is therefore: **apply the
platform root first**, then wire the data source. Steps 2 onward are unchanged apart from
reading `data.terraform_remote_state.platform.outputs.runtime_service_account_emails[each.key]`
where they previously read `module.identity.runtime_service_account_emails[each.key]`.
