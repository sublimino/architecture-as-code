# Terraform Layout

This Terraform estate is split into three roots because the operators and credentials are different, not because the names are different. `terraform/bootstrap` needs bucket-admin rights to create and protect the remote-state bucket, `terraform/platform` needs project-level IAM, logging and DNS administration to create shared singletons, and `terraform/environments` needs neither of those privilege sets because it owns only per-environment runtime infrastructure.

Apply the roots in this order: bootstrap, then platform, then environments. The sequence matters because bootstrap creates the backend consumed by the other roots, and platform creates shared identities and controls that the environment roots depend on.

`terraform/platform` and `terraform/environments` are part of the intended contract for this layout but are not present in this worktree yet; they land in a later merge. Their backend shape is fixed now so operators can treat the layout as stable even before those roots arrive.

## Root Contract

| Root | Owns | Backend |
|---|---|---|
| `terraform/bootstrap` | The GCS state bucket and its IAM. Nothing else. | No `backend` block at all; local state only. |
| `terraform/platform` | Project-level singletons that multiple environments would otherwise each try to own: the Workload Identity Federation pool and provider, the log sink, the audit/log bucket, the data-access audit config, the Cloud DNS managed zone, the billing budget and notification channels, and the CI plan/apply service accounts. | `backend "gcs" {}` initialised with `-backend-config=bucket=CHANGEME-osramp-tfstate -backend-config=prefix=osramp/platform` |
| `terraform/environments` | Everything scoped to one environment: network, compute, edge, and per-environment runtime service accounts. | `backend "gcs" {}` initialised with `-backend-config=bucket=CHANGEME-osramp-tfstate -backend-config=prefix=osramp/environments/<key>` |

The empty `backend "gcs" {}` form in the consuming roots is deliberate. A partially configured backend would allow an operator to reuse a previous prefix accidentally; an empty block forces `terraform init` to name the bucket and prefix explicitly before an apply can proceed.

## Environment Identity Hazard

The highest-risk failure mode in this design is environment identity drift. The chosen environment lives in two independent places: the backend prefix selected at `terraform init`, and the map key selected at `terraform apply` through the environment tfvars. Terraform does not make those two choices agree. If an operator initialises against `osramp/environments/demo-1` and later applies `demo-2.tfvars` without re-running `terraform init`, `plan` and `apply` reuse the cached backend pointer in `.terraform/` without complaint. The result is either `demo-2` resources written into `demo-1` state, or a plan that proposes to destroy `demo-1` and create `demo-2` against `demo-1` state. Both failure modes are silent until damage is already in scope.

Three mitigations are required, and none is sufficient on its own:

- A required `target_env` variable filters the environment map to exactly one entry, with validation that rejects an unknown key loudly instead of producing a misleading zero-resource plan.
- A per-environment `TF_DATA_DIR=.terraform-$(ENV)` prevents two environments from sharing one cached backend pointer at all.
- A post-init assertion reads the resolved backend prefix back and aborts unless it contains the requested environment key.

Those mitigations are delivered by other chunks. They belong in the operator contract here because the hazard exists whether or not the implementation has landed in this worktree yet.

## Destroy Boundaries

Destroy operations are for platform and environment resources only. They do not touch the state bucket and they do not touch the log sink.

That exclusion is deliberate. Destroying the state bucket deletes the record of what existed, and destroying the log sink deletes the evidence of what happened to it. A teardown that removes its own audit trail cannot be reviewed afterwards; recovering from that is not a rollback but an archaeology exercise.

## Verified Offline

Two offline Bats suites verify the repository contract in under 30 seconds:

- `test/terraform-conventions.bats` checks repo layout, formatting, version pins, variable typing and descriptions, that no state files or `.terraform/` directories are tracked, and that no absolute home-directory paths are committed.
- `test/terraform-state-protection.bats` checks that bootstrap declares no backend block, the state bucket protection attributes are set, no public-principal IAM is granted, no bucket-admin grant exists, no consuming root declares a state bucket, and the platform backend prefix is `osramp/platform`.

These suites do not prove successful applies, live GCP behaviour, or remote-state recovery. They verify only the static conventions and protections listed above.

## Conventions

- Each root pins Terraform and provider versions in its own `versions.tf`: `required_version >= 1.9`, `hashicorp/google ~> 6.8`, and `hashicorp/google-beta ~> 6.8`.
- `.terraform.lock.hcl` is committed.
- Every variable declares an explicit `type` and a non-empty `description`.
- Modules declare `required_providers` and do not declare `provider` blocks.
