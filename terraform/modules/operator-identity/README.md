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

## The four grants, and the operation each one is for

| Role | Scope | Required by |
|---|---|---|
| `roles/iap.tunnelResourceAccessor` | project | Opening the IAP TCP tunnel. Without it `--tunnel-through-iap` fails with `4033: 'not authorized'` before SSH is attempted. |
| `roles/compute.osAdminLogin` | project | Logging in via OS Login **with sudo**. |
| `slOperatorInstanceLifecycle` (**custom**) | project | Suspending, resuming and starting a demo VM. Four permissions; see below. |
| `roles/iam.serviceAccountUser` | **the runtime service account resource** | OS Login to an instance that carries a non-default service account requires `actAs` on that account. |

That is the entire footprint. `tests/operator_identity.tftest.hcl` pins both the
count and the exact membership, so adding a fifth is a failing diff that has to
be argued for in a review rather than a line nobody noticed.

---

## The instance-lifecycle custom role

### Why it exists

The operator could open a tunnel and log in, and could not turn the machine off.
On 2026-08-19 `sl-demo-2-vm` had to be suspended **as project owner**. The estate
runs a hot/cold pattern — one lane parked suspended, one rebuilt from scratch —
and suspend is the step that stops the billing. A teardown that requires project
owner is either skipped or performed with an over-privileged credential, and both
are worse than fixing the grant.

### Why not `roles/compute.instanceAdmin.v1`

It is the **only** predefined role carrying `compute.instances.suspend`. Measured
against the live role definition on 2026-08-20:

```console
$ gcloud iam roles describe roles/compute.instanceAdmin.v1
529 permissions, including compute.instances.create, .delete, .setMetadata,
.setServiceAccount, .attachDisk, and compute.disks.delete
```

529 permissions to reclaim two verbs. `setServiceAccount` combined with the
`actAs` grant this module already holds is a path to running code as the runtime
identity, and `setMetadata` is an SSH-key write — the OS Login bypass this whole
module exists to make unnecessary. So: a custom role holding only the verbs the
drivers call.

### The four permissions, and the call site that forces each

| Permission | Justification |
|---|---|
| `compute.instances.suspend` | The operation. `gcp-tf-ci.sh:248`, `gcp-ci.sh:535` and `:1301`, `gcp-tf-reaper.sh:138`. Documented requirement for suspend. |
| `compute.instances.resume` | The reciprocal, and the `SUSPENDED)` branch of every driver: `demo-up.sh:532`, `gcp-tf-ci.sh:219`, `gcp-ci.sh:271`. Suspend without resume is a one-way door. |
| `compute.instances.start` | **Not implied by resume** — the docs treat stop/start and suspend/resume as separate pairs with separate permissions. Needed because *"You can suspend an instance for only up to 60 days before Compute Engine automatically transitions its state to `TERMINATED`"*, and a parked lane is exactly what sits suspended for months. Every driver already has the `TERMINATED \| STOPPED)` arm: `demo-up.sh:538`, `gcp-tf-ci.sh:225`, `gcp-ci.sh:278`. |
| `compute.zoneOperations.get` | The one that would have been missed. Suspend/resume/start are **asynchronous**; gcloud polls the returned Operation unless `--async` is passed, and `--async` appears in **none** of the four drivers. Without it the VM really does suspend and the driver reports a 403 — the worst shape available, because the operator then retries against an already-suspended machine. |

### Deliberately *not* in the permission list

- **`compute.instances.get` / `.list`.** Genuinely required — `vm_status()` runs
  `instances describe`, the reaper runs `instances list` — and **already held**:
  `roles/compute.osAdminLogin` includes both (verified against the live role
  definition). Restating them would grow the count while granting nothing. This
  role is the **delta** over what the identity already has, not a standalone
  description of what it can do.
- **`compute.instances.stop`.** No call site stops an instance; the estate
  suspends, because suspend preserves memory. A verb with no caller is a verb
  granted on speculation.
- **`compute.disks.*`.** The question is not academic — suspend does write guest
  memory to storage. It writes to Compute-Engine-managed storage attached to the
  instance, not to a caller-owned `google_compute_disk`, which is why the
  documented requirement names no disk permission. Taken from the doc rather than
  from the plausible inference, which pointed the other way.
- **`compute.zoneOperations.list`.** `get` polls an operation whose name the API
  just returned; `list` would enumerate every mutation in the zone.
- **`iam.serviceAccounts.actAs`.** Already granted at **resource** scope. A
  permission inside a project-level custom role is a project-level grant, which is
  precisely the widening the `actAs` section below refuses.

### The cost, stated plainly

Creating this role requires `iam.roles.create`. That permission is in
`roles/iam.roleAdmin` and is **not** in `roles/resourcemanager.projectIamAdmin` —
verified on 2026-08-20, where `projectIamAdmin` resolves to nine permissions, all
`resourcemanager.projects.*` or `iam.policybindings.*`, none of them `iam.roles.*`.
`modules/deploy-identity` grants `projectIamAdmin` and not `roleAdmin`, so **the
deploy identity cannot create this role.**

That is not being fixed by widening the deploy identity. `roleAdmin` on an
identity that already holds `compute.admin` and `projectIamAdmin` would let it
mint a role containing any permission and bind that role to itself — a strictly
more general form of the escalation `deploy-identity`'s own comments say it is
bounding.

So the caller chooses, exactly as `modules/identity` does with
`manage_project_iam`: apply the platform root as an identity holding `roleAdmin`
or `owner`, or set `manage_lifecycle_custom_role = false` and create the role once
by hand. The flag exists so the estate applies **cleanly** either way instead of
dying part-way with an error naming an IAM API. When false, the operator keeps the
tunnel and the login and still cannot suspend — reported by
`lifecycle_role_is_managed`, never silent.

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
| `manage_lifecycle_custom_role` | `bool` | `true` | Whether to create the instance-lifecycle custom role. Needs `iam.roles.create`, which the deploy identity does not hold. False leaves it as a documented follow-up and applies everything else cleanly. |
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
| `granted_roles` | All four roles, at any scope, sorted. For diffing intent against reality. |
| `project_roles` | The project-scoped subset — the three with a blast radius beyond one VM. |
| `lifecycle_role_permissions` | The custom role's four permissions, sorted. A role name alone does not tell a reviewer what it grants, which is the whole reason a custom role beat `instanceAdmin.v1`. |
| `lifecycle_role_is_managed` | Whether Terraform created the custom role. False means suspending a demo VM still needs project owner. Reported, because a silently-absent grant is indistinguishable from a working one until the estate needs turning off. |
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
