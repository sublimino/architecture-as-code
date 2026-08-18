# `modules/identity` — Workload Identity Federation and least-privilege service accounts

Keyless CI authentication for GitHub Actions, plus the service accounts the
runtimes and CI assume. No `google_service_account_key` resource exists in this
tree and none ever should: a JSON key is a bearer credential with no expiry that
lives wherever it was pasted.

## Inputs

| Name | Type | Default | Notes |
|---|---|---|---|
| `project_id` | string | — | Project that owns the pool and every SA. |
| `project_number` | string | — | **Numeric.** The `principalSet://` URI requires the number. |
| `environment_keys` | list(string) | — | This module is map-aware; the roots do not `for_each` it. |
| `github_owner_id` | string | — | **Immutable numeric** owner id. See below. |
| `github_repository` | string | — | `owner/repo`. |
| `github_allowed_ref` | string | — | e.g. `refs/heads/main`. |
| `state_bucket_name` | string | `""` | `""` disables the state-bucket binding. Addition to the frozen §4 interface — see `NOTES.md`. |
| `runtime_roles` | list(string) | IAP + OS Login + telemetry | Validated against owner/editor/storage.admin/osAdminLogin. |
| `ci_plan_roles` | list(string) | read-only set | Validated; must not intersect `ci_apply_roles`. |
| `ci_apply_roles` | list(string) | write set | Validated. |
| `operator_members` | list(string) | `[]` | Named principals only. |
| `operator_roles` | list(string) | IAP + OS Login | Validated. |
| `pool_id` | string | `sl-github-pool` | Project-level singleton, owned by `terraform/platform`. |

## Outputs

`runtime_service_account_emails`, `workload_identity_provider_name`,
`ci_plan_service_account_email`, `ci_apply_service_account_email`, plus
`workload_identity_principal` and `attribute_condition` — the last two exist so
callers and tests can assert on the two values that decide whether this module
is a security control or a hole.

## Why the owner id is numeric, and not the org name

Every GitHub Actions OIDC token on earth is signed by the same issuer,
`https://token.actions.githubusercontent.com`. The issuer therefore proves
nothing about *who* is calling. The only thing separating "our CI can deploy" from
"anyone with a GitHub account can deploy" is `attribute_condition`.

It is tempting to write that condition against `assertion.repository_owner` — the
readable org name. Do not. When an organisation is renamed, GitHub releases the
old name for immediate re-registration by anybody. A condition pinned to the
string name is then satisfied by a stranger's repository, and the binding that
looked correct at review time silently starts trusting them. `repository_owner_id`
is a numeric id that GitHub never reissues.

The same argument applies to `repository_id` versus `repository`. This module
pins `repository_owner_id` (numeric) and additionally the repository path and the
ref, because defence in depth here costs one line each.

The variable carries a validation rejecting any non-numeric value, so pasting the
org name in that slot fails the plan rather than producing a plausible-looking
condition that trusts a renameable name.

## The WIF claim-negative test

Everything above is an argument. This is the check that turns it into evidence.
It proves a token minted by the **wrong repository** is refused, which is the
property the whole module exists to provide, and which no `terraform plan` can
demonstrate.

Run it **after** the first real apply, from a scratch repository under an
organisation that is not `github_owner_id`.

1. Create a throwaway repo, e.g. `some-other-org/wif-probe`, and add a workflow:

   ```yaml
   name: wif-probe
   on: workflow_dispatch
   permissions:
     id-token: write
     contents: read
   jobs:
     probe:
       runs-on: ubuntu-latest
       steps:
         - uses: google-github-actions/auth@v2
           with:
             workload_identity_provider: <workload_identity_provider_name output>
             service_account: <ci_plan_service_account_email output>
   ```

2. Dispatch it.

3. **Expected result — the run FAILS** at the auth step with an STS error along
   the lines of:

   ```
   Unable to acquire impersonated credentials
   ... The given credential is rejected by the attribute condition.
   ```

   `INVALID_ARGUMENT` / `PERMISSION_DENIED` from `sts.googleapis.com` is the pass
   condition for this test. A *successful* token exchange is the failure, and it
   means the attribute condition is absent, tautological, or pinned to something
   the probe repository satisfies.

4. Repeat from the real repository on a ref **other** than `github_allowed_ref`
   (e.g. a branch). It must also be refused — that proves the ref pin, not just
   the repository pin, is live.

5. Repeat from the real repository on `github_allowed_ref`. It must succeed.
   Without this third step the first two are indistinguishable from a provider
   that rejects everything, which is a broken deployment rather than a secure one.

6. Confirm the refusals in the audit log:

   ```
   gcloud logging read \
     'protoPayload.serviceName="sts.googleapis.com" AND severity>=WARNING' \
     --project=<project> --limit=20 --freshness=1h
   ```

Record the date and the three outcomes in `terraform/SECURITY.md`. Re-run
whenever `attribute_condition`, `github_owner_id`, or the allowed ref changes.

## What is tested automatically

`tests/identity.tftest.hcl` — 24 runs, mocked providers, `command = plan` only.
Asserts the *evaluated* configuration: issuer URI exact, `attribute_condition`
non-empty, non-tautological and pinning `repository_owner_id`, the WIF member
attribute-scoped rather than pool-wide, one runtime SA per environment key with
the key embedded, plan and apply principals sharing no role, and
`roles/storage.objectAdmin` — never `roles/storage.admin` — on the state bucket.
Every `expect_failures` run is paired with a positive run proving the corrected
input passes.

`test/terraform-identity.bats` — the whole-tree absence properties a plan cannot
see, with mutation fixtures under `test/fixtures/terraform/identity/` proving
each guard can fail.
