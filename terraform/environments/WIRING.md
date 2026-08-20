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

The blocks are commented rather than absent because `../modules/{network,compute,edge}`
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
| 4 | `module "edge"` | F4 | `terraform/modules/edge/` exists **and** step 3 is live | `module.compute[each.key].instance_group_self_link`, `var.dns_managed_zone`, `var.access_mode`, `var.iap_members` | the LB — **and the health-check firewall rule, which does not exist today; see "Step 4 is now TWO edits" below** |
| ~~5~~ | ~~`module "ci_runner"`~~ | — | **DELETED 2026-08-20.** `modules/ci-runner` was absorbed into `modules/compute`, so step 3 now covers CI lanes too. Do not reintroduce it — `terraform/CONTRACT.md` §4 records why. | — | — |

There is no step 5. Step 4 is the last.

**Step 1 is not a code change you can validate your way through.** A
`terraform_remote_state` data source reads a state object that must already
exist; there is no plan-time stand-in for it. So the ordering constraint is not
"uncomment identity first", it is **"apply `terraform/platform` first"** — a
real apply, against the real bucket, by a human. `terraform/RUNBOOK.md` step 5
is that apply. Until it has happened, steps 2–5 here cannot produce a plan, and
the error they produce names a missing output rather than a missing step.

### Step 4 is now TWO edits, and the second one is easy to miss

`module "edge"` is commented out and there is no load balancer anywhere in the
project. Because of that, `google_compute_firewall.allow_health_checks` in
`modules/network` — INGRESS from Google's probe ranges `130.211.0.0/22` and
`35.191.0.0/16` to `app_port` — is **not created for any lane**. It was dead
ingress surface on all four while nothing could ever arrive from those ranges.

**So reviving the edge means reviving that firewall rule with it**, or the
backend service will health-check a VM whose network refuses the probe and the
backend will never turn healthy. The symptom reads as a broken application, not
as a missing firewall rule, which is exactly why it is written down here.

Both halves come from one place, `local.edge_environments` in `main.tf`:

1. Uncomment the `module "edge"` block. Its `for_each` already reads
   `local.edge_environments`.
2. Change that local from `{}` to
   `{ for k, v in local.target_environments : k => v if v.kind == "demo" }`.

`module "network"` passes `edge_enabled = contains(keys(local.edge_environments), each.key)`,
so step 2 turns the health-check rule back on for exactly the lanes step 1
gives an edge to. Do them together.

Doing one without the other **turns a test red rather than failing silently** —
that is the point, and it is why this is a safety catch rather than a trap:

| You did | What goes red |
|---|---|
| Uncommented the module, left the local `{}` | `test/terraform-edge-dormant.bats` → *the environments root instantiates no edge module* |
| Changed the local, left the module commented | `tests/edge_dormant.tftest.hcl` → `no_lane_has_an_edge`, and the four `*_plans_no_health_check_ingress` runs |
| Both, correctly | Both of the above go red **and should** — update them in the same commit; they assert the dormant state deliberately, and their failure messages say so. |

Note the third row. When the revival is correct, these guards are *supposed* to
fail; they are asserting a state you have chosen to leave. Retire them in the
same change, do not weaken them in place. `test/edge-dormant-mutation-proof.sh`
retires with them.

Two further consequences of the revival worth knowing before you start. The
hand-off's `access_mode` currently reports `iap_tunnel`; it resolves back to
`var.access_mode` on its own, because `local.effective_access_mode` reads the
same map. And `modules/edge` gates only its **TLS frontend** on `hostname` — the
backend service, health check, IAP binding and Cloud Armor policy exist whenever
the module does, which is precisely why the firewall rule is keyed on the module
being instantiated rather than on `hostname != ""`.

### The two edge-reachability root variables

`access_mode` and `iap_members` are **declared in
`terraform/environments/variables.tf`** and published through
`local.integration_inputs`, so step 4 can wire them straight into
`modules/edge`. Three things about them are load-bearing.

**They are root variables, not fields on the `environments` object.** That
object type is frozen by CONTRACT §3 — "copy this type verbatim; do not add or
rename fields". They follow the precedent set by
`rate_limit_threshold_per_minute` and `enable_cdn`: an edge input that varies by
deployment rather than by environment key lives at the root and is passed down.

**The root must mirror the module's default, not merely its name.** A module
default governs only while the caller passes **no** value. The moment this root
wires `access_mode = var.access_mode`, `modules/edge`'s `default = "iap"` is
dead and the root's default is what ships. A root defaulting to `"allowlist"`
would silently reverse the entire private-edge posture while every module test
stayed green — the module would be behaving exactly as designed with the input
it was handed. The evaluated default is asserted in
`tests/edge_access_defaults.tftest.hcl`, in its own file because run-level
`variables` blocks *merge* with the file-level block rather than replacing it,
so a test about defaults is meaningless in a file whose header sets the thing
under test.

**`access_mode` has exactly three legal values** — `iap` (default),
`allowlist`, `iap_and_allowlist`. `"public"` is the value a reader guesses by
analogy and it is not one of them; the validation rejects it, and a tftest run
proves the rejection.

One of `modules/edge`'s three `iap_members` validations is **not** mirrored
here: the non-empty check. It is correct and it fires — on every plan of this
root that names no principal, including `tests/root_contract.tftest.hcl`, whose
file-level variables block predates these variables and sets neither. Restoring
it needs one line in that suite's header
(`iap_members = ["user:someone@example.invalid"]`), which is a pre-existing test
and not this chunk's to edit. Until then the rule still bites at the module
boundary, which is also the only point at which an empty list can lock anyone
out — before the edge module is wired there is no edge. Only the location of the
error moves, not whether it is raised. Recorded in `NOTES.md`.

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
- **`compute` is NOT filtered on `kind`; `edge` still is.** Every lane gets a VM from the same
  module — that is the point of the merge, since a CI lane exists to run the demo bring-up. Only
  `edge` filters, because a CI lane has no public frontend, which is why a `ci-*` entry carries
  `hostname = ""`: there is no DNS record because there is no load balancer.

  **`compute`'s unfiltered `for_each` is load-bearing for safety, not only for coverage.** The
  module emits the `ci-lane` label that `scripts/ci/gcp-tf-reaper.sh` selects on to SUSPEND
  instances, and it emits it from `each.value.kind`. Narrowing this `for_each` again would leave
  CI lanes unbuilt; widening `edge`'s would give a CI lane a public load balancer.

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
