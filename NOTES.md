# NOTES — chunk I1-v2-make-handoff

Branch `feat/gcp-tf-v2-make-handoff`. Owns the `gcp-tf-*` block of `Makefile`,
`test/terraform-make-contract.bats`, `deploy/gcp/README.md`, and three new
mutation fixtures under `test/fixtures/terraform/make/`.

---

## What the orchestrator must know

### 1. BLOCKER for `gcp-tf-handoff` against the live estate

`terraform/environments/outputs.tf` does **not** re-export the compute module's
`instance_name` and `internal_ip`. The module publishes both
(`terraform/modules/compute/outputs.tf`), but the root does not, so
`terraform output -json` on the live estate carries neither.

`make gcp-tf-handoff` therefore fails today against the real estate, by design:
it names the two unresolved fields, points at
`terraform/environments/outputs.tf`, and writes nothing. It does not fabricate
values and it does not emit a partial file.

`terraform/**` is outside this chunk's scope, so I have not made the change.
Whoever owns that root needs to add:

```hcl
output "instance_name" {
  description = "Compute instance name for the targeted environment. Consumed by the deploy hand-off."
  value       = try(module.compute[var.target_env].instance_name, "")
}

output "internal_ip" {
  description = "Compute instance internal IP for the targeted environment. Consumed by the deploy hand-off."
  value       = try(module.compute[var.target_env].internal_ip, "")
}
```

The generator also accepts map-shaped alternatives without any Makefile change —
`.instance_names[<env>]` / `.internal_ips[<env>]`, or
`.compute[<env>].instance_name` / `.compute[<env>].internal_ip` — so if that
root prefers a per-environment map, publish one and the hand-off resolves it.
For a CI lane (`kind = "ci"`) there is no compute module at all, so this needs
deciding before `gcp-tf-handoff ENV=ci-1` is expected to work.

### 2. Two pre-existing defects fixed in passing

Both were inside this chunk's scope and both were breaking things now.

- **`test/terraform-make-contract.bats` had a red assertion on `main`.** It
  asserted `gcp-tf-bootstrap` passes `-var-file=../../deploy/gcp/bootstrap.tfvars`;
  the target passed no `-var-file` at all. It has never passed. Fixed by adding
  the flag (via a new `GCP_TF_BOOTSTRAP_VAR_FILE`).
- **`GCP_TF_VAR_FILE` defaulted to `environments.tfvars`**, which resolves
  *inside* `terraform/environments/`. That is exactly the auto-load hazard the
  brief says to avoid: Terraform auto-loads `terraform.tfvars` / `*.auto.tfvars`
  from a root during `terraform test` as well as plan, so a real inputs file
  there silently overrides the fixtures every native suite asserts against. The
  default is now `../../deploy/gcp/environments.tfvars`.

### 3. Not fixed, flagged: a tracked filename names the real project

`deploy/gcp/sl-port-over-sandbox.example.tfvars` is tracked (it matches the
`!*.example.tfvars` un-ignore) and its **filename** carries the real project id.
The contents use placeholders; the name does not. Renaming it to something like
`environments.example.tfvars` would fix it, but it belongs to another chunk and
a rename is not a surgical edit — raising rather than doing.

### 4. `TF_STATE_BUCKET` is still typed on every invocation

It has no default and the rationale for that is sound (a default is either a
real bucket name in a public repo, or a placeholder that 404s). But it means
`gcp-tf-up` is not literally one word. If we want the same treatment
`deploy/gcp/deploy-sa` gets for the SA, the shape is obvious — a
`deploy/gcp/state-bucket` file feeding `TF_STATE_BUCKET ?=`. It was not in this
chunk's brief so I did not add it. Cheap to add later; say the word.

---

## The hand-off schema

Written by `make gcp-tf-handoff ENV=<key>` to `deploy/gcp/<key>.handoff.json`.
Gitignored. Every value derived from `terraform output -json` — a test asserts
that changing what Terraform reports changes the file, so nothing here can be a
Makefile constant.

| Field | Type | Empty allowed | Source |
|---|---|---|---|
| `schema_version` | number | no | fixed `1` |
| `project_id` | string | no | `.project_id` \|\| `.integration_inputs.project_id` |
| `environment_key` | string | no | `.target_env` |
| `region` | string | no | `.target_environment.region` |
| `zone` | string | no | `.target_environment.zone` |
| `instance_name` | string | no | `.instance_name` \|\| `.instance_names[env]` \|\| `.compute[env].instance_name` |
| `internal_ip` | string | no | `.internal_ip` \|\| `.internal_ips[env]` \|\| `.compute[env].internal_ip` |
| `app_port` | **number** | no | `.target_environment.app_port` |
| `state_bucket` | string | no | `TF_STATE_BUCKET` |
| `state_prefix` | string | no | derived from `ENV` |
| `deploy_sa` | string | no | `GCP_TF_IMPERSONATE` / `deploy/gcp/deploy-sa` |
| `access_mode` | string | no | `.access_mode` \|\| `.integration_inputs.access_mode` |
| `hostname` | string | **yes** | `.target_environment.hostname` |
| `generated_at` | string | no | `date -u +%Y-%m-%dT%H:%M:%SZ` |

`hostname` is the only field allowed to be empty — an environment with DNS
disabled genuinely has none. The key is always present, so consuming code reads
a field rather than discovering an absent one at runtime. `app_port` is a JSON
number because the code that reads it compares it to a port.

`schema_version` is `1`. Bump it on any breaking change and tell the consumers.

**Failure is silent-proof by construction.** If any non-`hostname` field
resolves empty, the target exits non-zero, names the field and the output that
would supply it, and writes nothing. A hand-off with a blank field is worse than
no hand-off: the test suite parses it and reports on an estate it never reached.

---

## Design decisions worth knowing

**Impersonation is defaulted, not demanded.** `GCP_TF_IMPERSONATE` defaults to
`TF_DEPLOY_SA`, read from the untracked `deploy/gcp/deploy-sa`. An operator who
has written that file once never types it again, and the refusal fires only in
the state that is actually dangerous: a deploy identity IS configured for this
checkout and the exported value is nonetheless blank. When nothing is
configured at all — a fresh clone, the contract tests — the targets warn and
proceed, because refusing there would make the granular targets unusable and
would say nothing true about the estate.

**The refusal names impersonation before it names IAM,** and a test asserts that
ordering. The observed real failure names an IAM permission, which invites
widening IAM on a half-built project. Leading with IAM would reinforce exactly
the wrong diagnosis.

**`gcp-tf-up` proves plan provenance in two steps.** It deletes any existing
plan file and stamps a sentinel *before* planning. Afterwards the plan file must
exist (so this run created it) and must be newer than the sentinel (so it is not
a copy something else dropped in between). Either check failing aborts before
apply. Both halves have their own test and the sentinel half has its own
mutation fixture — a mutation that points the comparison at a sentinel path
never created degrades the check into a bare existence test, and a stale plan
sails through.

**All the granular targets survive.** `gcp-tf-up` delegates to `gcp-tf-plan`,
`gcp-tf-apply` and `gcp-tf-handoff` rather than reimplementing them, so there is
one copy of each guard. `GCP_TF_FORWARD` passes the variables explicitly:
command-line variables reach a sub-make through `MAKEFLAGS` on their own, but
`GCP_TF_IMPERSONATE` has a *computed* default and does not — an apply that
silently lost impersonation is the exact failure this block exists to prevent,
and there is a test for the forwarding.

---

## Test surface

`bats test/terraform-make-contract.bats` — **66 tests, all green, fully
offline.** 38 pre-existing (one of which had never passed and now does), 28 new.
Runtime 12 seconds, measured.

Every test executes make against a stub `terraform` and `gcloud` early on
`PATH`, and asserts on recorded argv — not on Makefile text. The stub gained
three behaviours because the new targets consume terraform's *output*, not just
its exit code: `plan -out=F` writes `F` (suppressible via
`STUB_TF_NO_PLAN_FILE`, backdatable via `STUB_TF_PLAN_MTIME`, so both halves of
the provenance check are reachable), `show` emits a `Plan:` summary, and
`output -json` emits a fixture (`STUB_TF_OUTPUT_JSON`).

Every impersonation test pins `GCP_TF_DEPLOY_SA_FILE` at a temp path. Its
default is an untracked file that exists on an operator's machine and not on a
runner — a suite left at the default would assert different things in the two
places and pass in both.

Three new mutation fixtures, each paired with a positive case:

| Fixture | Demonstrates |
|---|---|
| `impersonation-guard.sed` | Neutered guard → apply runs unimpersonated. |
| `up-plan-provenance.sed` | Sentinel path never created → stale plan is applied. |
| `handoff-completeness.sed` | Neutered check → hand-off written with blank fields. |

Falsification proof run for `impersonation-guard.sed`: replacing it with a
non-matching program turned the case red at the `apply_mutation` line (the
helper diffs the mutated Makefile and refuses to continue if nothing changed),
and restoring it turned the case green again. So a future Makefile edit that
breaks a mutation pattern fails loudly instead of quietly ceasing to test
anything.

Two hygiene cases worth calling out:

- `no gcp-tf target writes into the repository's deploy/gcp during the suite` —
  the tests redirect `GCP_TF_HANDOFF_DIR`; if that stopped working, a run
  against a live checkout would emit a file naming the real estate.
- `running this suite leaves no artefact in the working tree` — `gcp-tf-bootstrap`
  is the one target no test redirects (the assertion is about the default path),
  and the stub now writes whatever `-out=` names, so every run deposited
  `terraform/bootstrap/bootstrap.tfplan`. Gitignored (`*.tfplan`) and removed in
  `teardown`, with a case that fails if either half regresses.

**Nothing was run against the live estate.** No `terraform apply`, no
`terraform destroy`, no `terraform init` against a real backend, no real
`gcloud` invocation. All cloud tooling in the tests is stubbed.

---

## What an operator types now

```bash
echo 'CHANGEME-deploy@CHANGEME-project.iam.gserviceaccount.com' > deploy/gcp/deploy-sa   # once
cp deploy/gcp/*.example.tfvars deploy/gcp/environments.tfvars && $EDITOR deploy/gcp/environments.tfvars
make gcp-tf-validate
make gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=CHANGEME-project-osramp-tfstate
make gcp-tf-test ENV=demo-1
```

Full sequence, including the privileged bootstrap step: `deploy/gcp/README.md`.
