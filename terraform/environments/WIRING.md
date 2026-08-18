# Wiring the environments root at integration

`terraform/environments/main.tf` ships with one live module (`env_contract`) and five
commented-out module blocks. This file says exactly which blocks to uncomment, in what order,
and what has to be true before each one will plan. The point is that integration should be
mechanical — a person following this file needs to read no Terraform to do the wiring, only to
review it afterwards.

The blocks are commented rather than absent because `../modules/{identity,network,compute,edge,ci-runner}`
are built by chunks F3, F4 and F5 in parallel worktrees and do not exist on this branch. A live
`module` block pointing at a missing directory makes `terraform init` fail, which would make the
root un-validatable, which would make `test/terraform-environment-keys.bats` — the only test in
the tree that *executes* the validation rules rather than grepping for them — impossible to run.
The tests are the deliverable, so the root stays green.

## Order

Uncomment in this order. It is a dependency order, not a preference: each step consumes an
output of the one before it, and doing them out of order produces a "reference to undeclared
module" error that reads like a typo rather than like a sequencing mistake.

| # | Block in `main.tf` | Chunk | Uncomment only once | Consumes | Produces for later blocks |
|---|--------------------|-------|---------------------|----------|---------------------------|
| 1 | `module "identity"` | F5 | `terraform/modules/identity/` exists | `project_id`, `project_number`, `module.env_contract.environment_keys`, the three `github_*` variables | `runtime_service_account_emails` (map keyed by environment key) |
| 2 | `module "network"` | F3 | `terraform/modules/network/` exists **and** step 1 is live | `local.target_environments`, `module.identity.runtime_service_account_emails[each.key]` | `subnet_self_link`, `network_tag` |
| 3 | `module "compute"` | F3 | `terraform/modules/compute/` exists **and** step 2 is live | step 2's outputs, `var.startup_script_path` | `instance_group_self_link` |
| 4 | `module "edge"` | F4 | `terraform/modules/edge/` exists **and** step 3 is live | `module.compute[each.key].instance_group_self_link`, `var.dns_managed_zone` | the public LB — nothing downstream |
| 5 | `module "ci_runner"` | F5 | `terraform/modules/ci-runner/` exists **and** step 2 is live | step 2's outputs, `module.identity.runtime_service_account_emails[each.key]` | nothing downstream |

Steps 4 and 5 are independent of each other; either order works.

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

2. **`github_owner_id` must be the numeric ID, looked up rather than guessed.** It defaults to
   `""` in `ci-1.tfvars.example` because a wrong value here silently widens who may assume the CI
   service accounts. `gh api users/<owner> --jq .id` is read-only and is the intended lookup.

3. **`project_number` must be set** before `identity` goes live; the workload identity pool path
   is built from it.

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
