# Terraform Layout

This Terraform estate is split into three roots because the operators and credentials are different, not because the names are different. `terraform/bootstrap` needs bucket-admin rights to create and protect the remote-state bucket. `terraform/platform` needs project-level IAM, logging and DNS administration to create shared singletons. `terraform/environments` needs neither of those privilege sets because it owns only per-environment runtime infrastructure.

Apply the roots in this order: bootstrap, then platform, then environments. The sequence matters for two reasons. Bootstrap creates the backend consumed by the other roots. Platform creates shared identities and controls that the environment roots depend on.

All three roots are in this directory: [`bootstrap/`](bootstrap/), [`platform/`](platform/), and
[`environments/`](environments/). Each consuming root declares its backend in its own `backend.tf`.

## Root Contract

| Root | Owns | Backend |
|---|---|---|
| `terraform/bootstrap` | The GCS state bucket and its IAM. Nothing else. | No `backend` block at all; local state only. |
| `terraform/platform` | Project-level singletons that multiple environments would otherwise each try to own: the Workload Identity Federation pool and provider, the CI plan/apply service accounts, the runtime service accounts, the operator identity, the Cloud DNS managed zone, and the notification channels. The observability module is dormant, so the root does not create the log sink, the audit/log bucket, the data-access audit config, or the billing budget. [`platform/main.tf`](platform/main.tf) keeps the `module "observability"` call commented out. | `backend "gcs" {}` initialised with `-backend-config=bucket=CHANGEME-osramp-tfstate -backend-config=prefix=osramp/platform` |
| `terraform/environments` | Everything scoped to one environment: network, compute, edge, and per-environment runtime service accounts. | `backend "gcs" {}` initialised with `-backend-config=bucket=CHANGEME-osramp-tfstate -backend-config=prefix=osramp/environments/<key>` |

The empty `backend "gcs" {}` form in the consuming roots is deliberate. A partially configured backend would allow an operator to reuse a previous prefix accidentally. An empty block forces `terraform init` to name the bucket and prefix explicitly before an apply can proceed.

## Environment Identity Hazard

The highest-risk failure mode in this design is environment identity drift. The chosen environment lives in two independent places: the backend prefix selected at `terraform init`, and the map key selected at `terraform apply` through the environment tfvars. Terraform does not make those two choices agree. If an operator initialises against `osramp/environments/demo-1` and later applies `demo-2.tfvars` without re-running `terraform init`, `plan` and `apply` reuse the cached backend pointer in `.terraform/` without complaint. The result is either `demo-2` resources written into `demo-1` state, or a plan that proposes to destroy `demo-1` and create `demo-2` against `demo-1` state. Both failure modes are silent until damage is already in scope.

Three mitigations are required, and none is sufficient on its own:

- A required `target_env` variable filters the environment map to exactly one entry. Its validation rejects an unknown key loudly instead of producing a misleading zero-resource plan.
- A per-environment `TF_DATA_DIR=.terraform-$(ENV)` prevents two environments from sharing one cached backend pointer at all.
- A post-init assertion reads the resolved backend prefix back and aborts unless it contains the requested environment key.

All three mitigations are in the tree:

| Mitigation | Location |
|---|---|
| `target_env` variable and its validation | [`environments/variables.tf`](environments/variables.tf) |
| Per-environment `TF_DATA_DIR` (`GCP_TF_DATA_DIR`) | [`Makefile`](../Makefile), used by the `gcp-tf-*` targets |
| Post-init prefix assertion (`gcp_tf_assert_prefix`, exact match) | [`Makefile`](../Makefile) |

[`CONTRACT.md` §5a](CONTRACT.md#5a-environment-identity-must-have-one-source--the-initapply-mismatch) gives the reasons for each mechanism.

## Destroy Boundaries

Destroy operations are for platform and environment resources only. They do not touch the state bucket and they do not touch the log sink.

That exclusion is deliberate. Destroying the state bucket deletes the record of what existed, and destroying the log sink deletes the evidence of what happened to it. A teardown that removes its own audit trail cannot be reviewed afterwards. Recovering from that is not a rollback but an archaeology exercise.

## Verified Offline

The offline Bats suites are the files that match `test/terraform-*.bats`. `make gcp-tf-validate` finds
them with a glob and runs them without cloud credentials. It also runs `terraform fmt`, `validate`,
`tflint`, and `terraform test`. Two suites own the conventions on this page:

- [`test/terraform-conventions.bats`](../test/terraform-conventions.bats) checks repo layout, formatting, version pins, and variable typing and descriptions.
  It also checks that git tracks no state files or `.terraform/` directories, and no absolute home-directory paths.
- [`test/terraform-state-protection.bats`](../test/terraform-state-protection.bats) checks that bootstrap declares no backend block and that the state bucket protection attributes are set.
  It also checks that no IAM grant goes to a public principal and that no bucket-admin grant exists.
  Last, it checks that no consuming root declares a state bucket and that the platform backend prefix is `osramp/platform`.

The offline suites do not prove successful applies, live GCP behaviour, or remote-state recovery.

## Conventions

- Each root pins Terraform and provider versions in its own `versions.tf`: `required_version >= 1.9`, `hashicorp/google ~> 6.8`, and `hashicorp/google-beta ~> 6.8`.
- `.terraform.lock.hcl` is committed.
- Every variable declares an explicit `type` and a non-empty `description`.
- Modules declare `required_providers` and do not declare `provider` blocks.

## The rest of the documentation

This file is the map. The detail lives in five siblings, and it is worth knowing which one
answers which question before you need it at speed.

| You want to | Read |
|---|---|
| Bring up the first environment, step by step, from nothing | [`RUNBOOK.md`](RUNBOOK.md) |
| Know which threat a given resource or guard exists to stop | [`SECURITY.md`](SECURITY.md) |
| Answer "what does a demo cost if we leave it running?" | [`COSTS.md`](COSTS.md) |
| Understand why the tree is shaped this way, or change an interface | [`CONTRACT.md`](CONTRACT.md) |
| Know what "done" means and what has actually been verified | [`ISA.md`](ISA.md) |
| Operate and debug the four live lanes | [`../docs/gcp-demo/OPERATIONS.md`](../docs/gcp-demo/OPERATIONS.md) |
| Stand a lane up as an operator, not as a Terraform author | [`../docs/gcp-demo/RUNBOOK.md`](../docs/gcp-demo/RUNBOOK.md) |

NOTE: This directory's `RUNBOOK.md` covers `demo-1` from the Terraform author's
side. `../docs/gcp-demo/RUNBOOK.md` covers any lane from the operator's side,
through to a dashboard in a browser. They overlap deliberately and neither
replaces the other.

Per-chunk hand-off notes — including what each build agent could not satisfy and why — are in
[`notes/`](notes/README.md). **Read [`notes/README.md`](notes/README.md) first: it labels which
notes are historical and which are current.** Read a note before assuming an unmet criterion is
an oversight. Most are deliberate boundary decisions recorded at the time.
