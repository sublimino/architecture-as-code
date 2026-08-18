# `modules/operator-identity`

The service account a **human becomes** in order to reach a demo VM.

It is not the deploy identity, and that is the whole design. `modules/deploy-identity`
builds the estate and cannot log into it; this account logs into the estate and
cannot build it.

---

## The problem

The demo VMs have no external IP. The only route in is Identity-Aware Proxy TCP
forwarding, and the only login mechanism is OS Login.

OS Login has a rule that stays invisible until it bites:

```
You must be granted the roles/compute.osLoginExternalUser IAM role on the
external organization to configure POSIX account information.
```

A Google identity **external to the organisation that owns the project** cannot
configure POSIX account data without `roles/compute.osLoginExternalUser`, and
that role is grantable **only at organisation scope**. The operator of this
estate holds a personal Google account; `gcloud organizations list` returns zero
items for him. He cannot grant it to himself, and every path to someone who can
is a wait on a third party. That wait cost a day.

## The mechanism

A service account created **inside the project** is internal to the owning
organisation by construction, so the external-user rule does not apply to it.

Measured on 2026-08-18 against `sl-port-over-sandbox`: impersonating an
in-project service account made the OS Login error disappear entirely and moved
the failure to the IAP layer — `4033: 'not authorized'`, which is
`roles/iap.tunnelResourceAccessor` missing, and that is a **project**-scoped
grant the project owner can make without leaving the project.

So the module converts an organisation-level dependency nobody working on this
project can satisfy into a project-level one the project owner can. The operator
authenticates as himself, impersonates this account, and the tunnel and the
login both happen as the account:

```bash
gcloud compute ssh INSTANCE --zone ZONE --project PROJECT \
  --tunnel-through-iap \
  --impersonate-service-account=sl-operator@PROJECT.iam.gserviceaccount.com
```

Every action is still attributable to the human: impersonation is logged with
the caller's own identity in `protoPayload.authenticationInfo.principalEmail`
and `serviceAccountDelegationInfo`.

---

## The three grants, and the operation each one is for

| Role | Scope | Required by |
|---|---|---|
| `roles/iap.tunnelResourceAccessor` | project | Opening the IAP TCP tunnel. Without it `--tunnel-through-iap` fails with `4033: 'not authorized'` before SSH is attempted. |
| `roles/compute.osAdminLogin` | project | Logging in via OS Login **with sudo**. |
| `roles/iam.serviceAccountUser` | **the runtime service account resource** | OS Login to an instance that carries a non-default service account requires `actAs` on that account. |

That is the entire footprint. `tests/operator_identity.tftest.hcl` pins both the
count and the exact membership, so adding a fourth is a failing diff that has to
be argued for in a review rather than a line nobody noticed.

### Why `osAdminLogin` and not `osLogin`

`roles/compute.osLogin` is the narrower role and was the preferred answer. It
does not work here, on evidence rather than caution:

- `scripts/ci/gcp-ci.sh:124` runs **every** remote command as `sudo -u ci bash -c …`.
- `scripts/ci/gcp-ci.sh:418-421` unpacks the work tree with `sudo rm -rf`,
  `sudo mkdir`, `sudo tar -xzf` and `sudo chown -R ci:ci`.
- `scripts/ci/vm-pipeline.sh:178` and `:201` open and re-close `/usr/local/bin`
  with `sudo chmod`, and `:205` installs the Playwright browser with `sudo npx`.

An operator identity that cannot run the pipeline does not solve the problem
this module was written for, so the sudo-capable role is the one granted. If the
pipeline is ever reworked to install tools under `$HOME` and drop the
`sudo -u ci` wrapper, downgrade to `roles/compute.osLogin` — the budget test
will fail until the number is updated, which is the point.

### Why `serviceAccountUser` is resource-scoped and never project-scoped

At project scope, `roles/iam.serviceAccountUser` means *"may act as every
service account in this project"* — including `sl-tf-deploy`, which holds
`roles/resourcemanager.projectIamAdmin` and can therefore grant itself anything.
A project-scoped `actAs` on the operator is a two-hop path from "can open a
tunnel" to "owns the project", and it looks like a simplification in a diff.

The module uses `google_service_account_iam_member`, which has no project-wide
form. The resource type is the enforcement, not a comment. One binding per
environment runtime account, fed from
`modules/identity.runtime_service_account_emails`, so the grant tracks the
environments that actually exist.

---

## Deliberately absent

**`google_organization_iam_member` / `_binding` / `_policy`.** Declaring
`roles/compute.osLoginExternalUser` in Terraform would make direct human SSH
work too — and would make the entire estate unappliable by anyone without
organisation-level rights, which is precisely the dependency this module exists
to remove. It stays a documented manual convenience in
`deploy/gcp/ACCESS-REQUEST.md` and never becomes a prerequisite.
`test/terraform-operator-access.bats` fails if an org-scoped IAM resource
appears anywhere in the terraform tree.

**`roles/compute.admin`, `roles/resourcemanager.projectIamAdmin`,
`roles/storage.admin`.** These belong to `modules/deploy-identity`. None is
needed to open a tunnel and log in. An operator who can also rebuild the estate
is one credential whose compromise costs everything.

**Any role containing `legacy`.** CIS GCP Benchmark guidance, and the same
reasoning as `deploy-identity`: legacy roles are deprecated on Google's schedule
rather than yours, and their meaning changes under you when the provider revises
them.

**`google_service_account_key`.** Never a key. A downloaded JSON key is a bearer
credential with no expiry that lives wherever it was last pasted and is
attributable to nobody. Access to this account is `roles/iam.serviceAccountTokenCreator`
and nothing else.

---

## Inputs

| Variable | Type | Default | Notes |
|---|---|---|---|
| `project_id` | `string` | — | The account must be created **in this project**; that is what makes it internal to the owning organisation. |
| `account_id` | `string` | `sl-operator` | GCP service account id rules are enforced by a validation. |
| `runtime_service_account_emails` | `map(string)` | `{}` | From `modules/identity`. One resource-scoped `actAs` binding per entry. Values must be full service account emails — a bare account id would build a well-formed name for an account that does not exist and fail late at apply. |
| `impersonators` | `list(string)` | `[]` | Prefixed IAM principals. `allUsers`, `allAuthenticatedUsers` and wildcards are rejected structurally. |

`impersonators` defaults to empty, unlike `deploy-identity` which rejects an
empty list. The difference is deliberate: a deploy identity nobody can assume
makes the estate undeployable, so an empty list there is a configuration error.
An operator identity nobody can assume is merely **inert** — the estate still
builds and runs, and the fix is one tfvars line rather than a re-bootstrap.

## Outputs

| Output | What it is |
|---|---|
| `operator_service_account_email` | The email to pass to `--impersonate-service-account`. |
| `granted_roles` | All three roles, at any scope, sorted. For diffing intent against reality. |
| `project_roles` | The project-scoped subset — the two with a blast radius beyond one VM. |
| `act_as_service_account_names` | The service account **resources** the operator may act as. Every entry contains `/serviceAccounts/`, which is how a caller proves the grant never became project-wide. |
| `ssh_command` | The exact `gcloud compute ssh` invocation, with `INSTANCE` and `ZONE` left as placeholders. |

`operator_service_account_email` is derived (`<account_id>@<project>.iam.gserviceaccount.com`)
rather than read off `google_service_account.operator.email`, matching
`modules/identity`. The resource attribute is computed and therefore unknown at
plan, which would force every downstream assertion into an `apply`. The tftest
suite asserts the derivation still matches the resource's own `account_id` and
`project`, so the two cannot drift.

## Where it is instantiated

`terraform/platform`, per CONTRACT §5b: it is a project-level singleton, a
sibling of the CI plan/apply accounts that section already assigns to that root.
Declaring it in `terraform/environments` would mean
`make gcp-tf-destroy ENV=demo-1` deletes the only way to log into `demo-2`.

## Tests

```bash
terraform -chdir=terraform/modules/operator-identity init -backend=false
terraform -chdir=terraform/modules/operator-identity test
```

Offline, `mock_provider`, `command = plan` only. The whole-tree absence
properties — no org-scoped IAM, no service account key, no project-scoped
`actAs` — live in `test/terraform-operator-access.bats`, because a plan can only
tell you about the configuration it evaluated, never about the configuration
nobody wrote (CONTRACT §7a).
