# `deploy/gcp/` — the real inputs, and the hand-off to the test code

Everything Terraform needs that is specific to a real Google Cloud project lives
here, and almost none of it is tracked. The Terraform code in `terraform/` is
generic; this directory is where it meets one billable estate.

The Makefile is the interface. Nothing in here is meant to be fed to
`terraform` by hand.

---

## Files

| File | Tracked | What it is |
|---|---|---|
| `README.md` | yes | This. |
| `ACCESS-REQUEST.md` | yes | The IAM grants the deploy service account needs, written for the project owner to action. |
| `*.example.tfvars` | yes | Worked examples with placeholder values. Copy one; never edit it in place. |
| `environments.tfvars` | **no** | The real environment map. What `make gcp-tf-plan` and `gcp-tf-up` pass as `-var-file`. |
| `bootstrap.tfvars` | **no** | The real inputs for the one-time state-bucket root. |
| `deploy-sa` | **no** | One line: the email of the service account Terraform impersonates. |
| `<env>.handoff.json` | **no** | Generated. The single file the test code reads to know what it is testing. |

`.gitignore` covers `*.tfvars` (with an exception for `*.example.tfvars`),
`deploy/gcp/deploy-sa`, `deploy/gcp/*.handoff.json` and `*.tfplan`. A test in
`test/terraform-make-contract.bats` asserts each of those and asserts that
`README.md` is *not* ignored — a blanket `deploy/gcp/` ignore would satisfy the
first checks and quietly hide the documentation too.

---

## Why the real tfvars live here and not in `terraform/`

This is not a filing preference.

Terraform auto-loads `terraform.tfvars` and `*.auto.tfvars` from the root
directory it is running in. That happens during `terraform test` exactly as it
happens during `terraform plan`. So a real inputs file sitting in
`terraform/environments/` silently overrides the fixture values that every
native test suite asserts against: the suites stay green and stop measuring what
they claim to measure.

Keeping the real inputs one directory outside any Terraform root makes that
impossible rather than merely discouraged. `GCP_TF_VAR_FILE` therefore defaults
to `../../deploy/gcp/environments.tfvars` — relative to the `-chdir` root — and
`GCP_TF_BOOTSTRAP_VAR_FILE` to `../../deploy/gcp/bootstrap.tfvars`.

**Do not move them back.**

---

## Why impersonation is mandatory

Terraform runs as a service account. Never as the human at the keyboard.

A human operator on this project typically holds `roles/editor`. That is enough
to create a VPC, a subnet, a NAT and a VM — and not enough to create the
IAM-shaped resources the estate needs. The failure mode is therefore the ugly
one: the apply gets a long way in, dies part-way through with a permission error
naming an IAM API, and leaves a half-built estate behind.

The error names IAM, so the obvious next move is to widen IAM. That is the wrong
fix, applied under time pressure, to a project that is now in an inconsistent
state. The cause was never IAM; it was that the run had no impersonation.

The Makefile makes that unrepeatable:

- `GCP_TF_IMPERSONATE`, when non-empty, exports
  `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` onto **every** terraform invocation in
  the block — init, plan, show, apply, destroy, output.
- `TF_DEPLOY_SA` is read from `deploy/gcp/deploy-sa`, and `GCP_TF_IMPERSONATE`
  defaults to it. Nobody retypes a service account email.
- The mutating targets — `gcp-tf-plan`, `gcp-tf-apply`, `gcp-tf-destroy`,
  `gcp-tf-up` — **refuse to run** when `deploy/gcp/deploy-sa` names an identity
  and the exported value is blank. The refusal happens before any terraform
  invocation, and the message names impersonation before it mentions IAM.
- `GCP_TF_NOCREDS` strips `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT` from the offline
  sweeps, so a developer with it exported gets the same result as a runner
  without it.

Bucket *creation* and bucket IAM remain a privileged human step. The deploy
service account populates buckets and runs plans and applies; it is not a bucket
admin, and nothing here asks for that.

---

## The two service accounts, and why they are two

| Account | Module | What it does | What it cannot do |
|---|---|---|---|
| `sl-tf-deploy` | `terraform/modules/deploy-identity` | Applies and destroys the estate. | Log into a VM. |
| `sl-operator` | `terraform/modules/operator-identity` | Opens an IAP tunnel and logs into a VM to run the demo pipeline. | Create, modify or destroy anything. |

Merging them is a four-line change and would be a mistake. The deploy identity
holds `roles/compute.admin` and `roles/resourcemanager.projectIamAdmin` — it can
grant itself anything in the project. Giving it an interactive sudo shell on
every VM it builds makes build rights and run-on-the-box rights one credential,
so a compromise of either is a compromise of both.

### Why the operator account exists at all

The operator's own Google account is **external to the organization that owns
the project**. OS Login refuses to configure POSIX account data for an external
identity without `roles/compute.osLoginExternalUser`, and that role is grantable
**only at organization scope** — `gcloud organizations list` returns zero items
here, so it cannot be self-granted and blocked this work for a day.

A service account created *inside* the project is internal to the owning
organization by construction, so the rule does not apply to it. Impersonate it
and OS Login works. Measured on 2026-08-18: the `osLoginExternalUser` error
disappears entirely and the failure moves to the IAP layer
(`4033: 'not authorized'`), which is a project-scoped grant the project owner can
make.

```bash
gcloud compute ssh sl-demo-1-vm --zone us-east4-a --project CHANGEME-project \
  --tunnel-through-iap \
  --impersonate-service-account=sl-operator@CHANGEME-project.iam.gserviceaccount.com
```

### The operator's four roles, and the operation each one is for

| Role | Scope | Required by |
|---|---|---|
| `roles/iap.tunnelResourceAccessor` | project | Opening the IAP TCP tunnel. Without it `--tunnel-through-iap` fails with `4033: 'not authorized'` before SSH is attempted. |
| `roles/compute.osAdminLogin` | project | OS Login **with sudo**. `scripts/ci/gcp-ci.sh` runs every remote command as `sudo -u ci` and unpacks its work tree with `sudo tar`/`sudo chown`; `scripts/ci/vm-pipeline.sh` opens `/usr/local/bin` with `sudo chmod`. The no-sudo `roles/compute.osLogin` cannot run the pipeline. |
| `slOperatorInstanceLifecycle` (**custom**) | project | Suspending, resuming and starting a demo VM — the step that stops the billing on a parked lane. Four permissions: `compute.instances.suspend`, `.resume`, `.start`, and `compute.zoneOperations.get` for the operation poll gcloud performs unless `--async` is passed. |
| `roles/iam.serviceAccountUser` | **the runtime service account resource** | OS Login to an instance carrying a non-default service account requires `actAs` on that account. Never at project scope — there it would cover every service account in the project, including `sl-tf-deploy`. |

That is the whole footprint. A `terraform test` budget pins the count *and* the
exact membership, so a fifth grant is a failing diff rather than a line nobody
noticed. The custom role's **permission** list is pinned the same way, because a
role budget counts roles and one custom role can hold any number of permissions.
Neither account ever gets a JSON key; access to both is
`roles/iam.serviceAccountTokenCreator`.

> **Suspend needs one thing Terraform may not be able to do for you.** Creating a
> custom role requires `iam.roles.create`, which lives in `roles/iam.roleAdmin`
> and is **not** in the `roles/resourcemanager.projectIamAdmin` that `sl-tf-deploy`
> holds. Apply the platform root as an identity with `roleAdmin` or `owner`, or
> set `manage_operator_lifecycle_role = false` and create the role once by hand.
> The `operator_can_suspend` output reports which case is in force — when it is
> `false`, suspending a demo VM still needs project owner.

Full reasoning: `terraform/modules/operator-identity/README.md`. The manual
`gcloud` equivalent, for a project owner who has not run Terraform yet:
`deploy/gcp/ACCESS-REQUEST.md`.

---

## Ordered command sequence for a fresh deploy

Replace every `CHANGEME-` value with the real one. None of these strings belong
in a tracked file.

### 0. One time per project — privileged human, not the deploy SA

```bash
make gcp-tf-bootstrap
# Review terraform/bootstrap/bootstrap.tfplan, then apply it by hand:
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

`gcp-tf-bootstrap` is plan-only on purpose. Applying it creates the bucket every
other root's state lives in — the one action in the estate with no state to roll
back from — so it is not reachable by a one-word target typed absentmindedly.

### 1. One time per checkout — record the deploy identity

```bash
echo 'CHANGEME-deploy@CHANGEME-project.iam.gserviceaccount.com' > deploy/gcp/deploy-sa
```

Untracked, and everything from here on picks it up automatically.

### 2. One time per checkout — the real inputs

```bash
cp deploy/gcp/CHANGEME-project.example.tfvars deploy/gcp/environments.tfvars
$EDITOR deploy/gcp/environments.tfvars
```

### 3. Every change — the offline gate

```bash
make gcp-tf-validate
```

`fmt -check`, `validate`, `tflint`, every `terraform test` suite and every
`test/terraform-*.bats` suite. No network beyond provider installation, no
cloud credentials, no impersonation.

### 4. Deploy

```bash
make gcp-tf-up ENV=demo-1 TF_STATE_BUCKET=CHANGEME-project-osramp-tfstate
```

One target, four ordered steps, none skippable:

1. `init -reconfigure` with the backend prefix derived from `ENV`, then read the
   resolved prefix back out of the data dir and abort unless it is exactly
   `osramp/environments/demo-1`.
2. `plan -out=` a saved plan file, then `show` it and print the `Plan:` summary.
3. `apply` **that exact file**. Any pre-existing plan file is deleted and a
   sentinel stamped before planning, so a plan file present afterwards was
   written by this run and is newer than the sentinel. Anything else is refused,
   not applied — a plan file of unknown provenance is a diff nobody read.
4. Write `deploy/gcp/demo-1.handoff.json`.

`TF_STATE_BUCKET` has no default and never will: a default would be either a
real bucket name in a public repo, or a placeholder that 404s instead of
explaining itself.

### 5. Hand the estate to the tests

```bash
make gcp-tf-test ENV=demo-1
```

The test code reads `deploy/gcp/demo-1.handoff.json`. It needs no flags.

To regenerate the hand-off from current state without touching the estate:

```bash
make gcp-tf-handoff ENV=demo-1 TF_STATE_BUCKET=CHANGEME-project-osramp-tfstate
```

### Tearing down

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1 TF_STATE_BUCKET=CHANGEME-project-osramp-tfstate
```

Typing the key is the point: it is the step that fails when you meant `demo-2`
and your shell history said `demo-1`.

---

## The hand-off contract

`make gcp-tf-handoff ENV=<key>` writes `deploy/gcp/<key>.handoff.json`.

Every value is derived from `terraform output -json`. Nothing in it is typed by
a human, and nothing in it is hardcoded in the Makefile — a test asserts that
changing what Terraform reports changes the file.

If a required field cannot be resolved, **the target fails and writes nothing**.
It names the field and the output that would have supplied it. A hand-off
carrying a blank field is strictly worse than no hand-off: the test suite parses
it successfully and reports on an estate it never reached.

### Fields

| Field | Type | Source | May be empty |
|---|---|---|---|
| `schema` | string | Fixed at `signalloom.gcp.handoff/v1`. Match on this before trusting the shape. | no |
| `schema_version` | number | Fixed at `1`. Bump both on any breaking change. | no |
| `project_id` | string | `.project_id` or `.integration_inputs.project_id` | no |
| `environment_key` | string | `.target_env` | no |
| `env` | string | Alias of `environment_key`, asserted equal to it. | no |
| `region` | string | `.target_environment.region` | no |
| `zone` | string | `.target_environment.zone` | no |
| `instance_name` | string | `.instance_name`, or `.instance_names[<env>]` | no |
| `internal_ip` | string | `.internal_ip`, or `.internal_ips[<env>]` | no |
| `app_port` | **number** | `.target_environment.app_port` | no |
| `state_bucket` | string | `TF_STATE_BUCKET` | no |
| `state_prefix` | string | derived from `ENV` | no |
| `deploy_sa` | string | `GCP_TF_IMPERSONATE` / `deploy/gcp/deploy-sa` | no |
| `access_mode` | string | `.access_mode` or `.integration_inputs.access_mode` | no |
| `hostname` | string | `.target_environment.hostname` | **yes** |
| `generated_at` | string | UTC, `%Y-%m-%dT%H:%M:%SZ` | no |

`hostname` is the one field allowed to be empty: an environment with DNS
disabled genuinely has none, and demanding a value would force a fabricated one.
The key is always present, so consuming code reads a field rather than
discovering an absent one at runtime.

`app_port` is a JSON number, not a string, because the code that reads it
compares it to a port.

### Worked example

`access_mode` reports **the access path actually in force**, which is not the
same thing as `var.access_mode` in the tfvars.

Three of its values come from `var.access_mode` and describe the posture of the
**web edge** — Identity-Aware Proxy in front of an HTTPS load balancer: `iap`,
`allowlist`, `iap_and_allowlist` (see `terraform/environments/variables.tf`).
Anything reading those as a boolean "IAP or allowlist" will mishandle the
combined mode.

The fourth value is `iap_tunnel`, and it is what this estate reports today.
`module "edge"` is commented out in `terraform/environments/main.tf`, so no lane
has a load balancer — verified live against `sl-port-over-sandbox` on
2026-08-20: zero forwarding rules, zero backend services, zero global
addresses, zero managed certificates, zero Cloud Armor policies. With no web
front door there is no web posture for `var.access_mode` to describe, and
echoing `"iap"` told a reader the estate had a control it does not have. The
path genuinely in force is the IAP **TCP tunnel** —
`roles/iap.tunnelResourceAccessor`, source range `35.235.240.0/20`, ports 22
and `app_port` — which is a different and narrower thing, hence a distinct
value rather than a reused one.

It resolves back to `var.access_mode` automatically when the edge is wired up
again, because both facts derive from the single `local.edge_environments` map
in `terraform/environments/main.tf`.

#### Why this is not a schema bump

The field's documented meaning has not changed: it has always been "the access
path in force", and `iap_tunnel` is the first value that describes that path
honestly rather than aspirationally. What changed is the value SET, which is a
compatible change for a consumer treating the field as opaque and a breaking one
for a consumer enumerating the three tfvars values.

No such consumer exists. Every reference was checked
(`rg -n 'access_mode' --glob '!.claude'`): the Makefile writes it, this document
and `terraform/notes/i1-make-handoff.md` describe it, and
`test/terraform-make-contract.bats` asserts it non-empty and echoed. No script
branches on it — `scripts/gcp-tf/conformance.sh` mentions `access_mode` only in
the prose of a remediation message, and reads the live backend service rather
than this file. So `schema` stays `signalloom.gcp.handoff/v1` and
`schema_version` stays `1`.

A consumer that must distinguish "there is a web edge" from "there is not"
should read the `edge_environment_keys` root output rather than pattern-matching
this string; an empty list is the unambiguous answer.

`env` and `schema` are aliases carried for a consumer written against those
spellings. They are additive; `environment_key` and `schema_version` are the
canonical names. A test asserts `env == environment_key`, so the two cannot
drift apart.

```json
{
  "schema": "signalloom.gcp.handoff/v1",
  "schema_version": 1,
  "project_id": "CHANGEME-project",
  "environment_key": "demo-1",
  "env": "demo-1",
  "region": "CHANGEME-region",
  "zone": "CHANGEME-region-a",
  "instance_name": "osramp-demo-1-vm",
  "internal_ip": "10.20.0.7",
  "app_port": 8080,
  "state_bucket": "CHANGEME-project-osramp-tfstate",
  "state_prefix": "osramp/environments/demo-1",
  "deploy_sa": "CHANGEME-deploy@CHANGEME-project.iam.gserviceaccount.com",
  "access_mode": "iap",
  "hostname": "demo-1.CHANGEME.example",
  "generated_at": "2026-08-18T18:40:11Z"
}
```

### Reading it

```bash
jq -r .internal_ip deploy/gcp/demo-1.handoff.json
jq -r '"\(.instance_name) in \(.zone) on port \(.app_port)"' deploy/gcp/demo-1.handoff.json
```

---

## Variable reference

Every one is overridable; the defaults are what an operator should be relying on.

| Variable | Default | Notes |
|---|---|---|
| `ENV` | *(none)* | Required. Matches `^(demo\|ci)-[1-9][0-9]*$`. |
| `TF_STATE_BUCKET` | *(none)* | Required for anything touching remote state. |
| `GCP_TF_DEPLOY_SA_FILE` | `deploy/gcp/deploy-sa` | One line, the SA email. |
| `TF_DEPLOY_SA` | contents of the file above | Comments and blank lines stripped. |
| `GCP_TF_IMPERSONATE` | `$(TF_DEPLOY_SA)` | Exported as `GOOGLE_IMPERSONATE_SERVICE_ACCOUNT`. |
| `GCP_TF_VAR_FILE` | `../../deploy/gcp/environments.tfvars` | Relative to the `-chdir` root. |
| `GCP_TF_BOOTSTRAP_VAR_FILE` | `../../deploy/gcp/bootstrap.tfvars` | Relative to the `-chdir` root. |
| `GCP_TF_HANDOFF_DIR` | `deploy/gcp` | Redirected by the contract tests so they never write a real hand-off. |
| `TF_STATE_PREFIX_BASE` | `osramp` | Prefix is `<base>/environments/<ENV>`. |
