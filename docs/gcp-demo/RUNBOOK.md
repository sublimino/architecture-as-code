# GCP demo runbook — zero to a browser

From an empty GCP project to the Signal Loom dashboard open in front of you,
then back to nothing. Every command here is real and in order.

The estate is a hardened, IAP-only VM with **no external IP**. There is nothing
to browse to and nothing to SSH to from the open internet; all access is through
an IAP tunnel, which is why the last step of getting a browser onto it is a
`make` target rather than a URL you can bookmark.

Throughout, `ENV` is the environment key — `demo-1`, `demo-2`, `ci-1`. It is
matched against `^(demo|ci)-[1-9][0-9]*$`; `prod-1` is rejected on purpose.

---

## The short version

```bash
export TF_STATE_BUCKET=<your-state-bucket>

make gcp-tf-up      ENV=demo-1     # plan, review, apply, write the hand-off
make gcp-tf-demo-up ENV=demo-1     # deliver the code, build the estate, test it
make gcp-tf-connect ENV=demo-1     # open the tunnel; prints the URL and login
```

Then the teardown, which is not optional — the VM bills until it is gone:

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1
./scripts/gcp-tf/teardown-verify.sh          # believe the destroy only after this
```

---

## Step 0 — Prerequisites

| Thing | Why | Check |
| :--- | :--- | :--- |
| `gcloud`, `terraform`, `jq`, `tar` | the driver shells out to all four | `command -v gcloud terraform jq tar` |
| An authenticated gcloud | everything below | `gcloud auth list` |
| `deploy/gcp/deploy-sa` | one line, the **Terraform deploy** SA email. Untracked. | `cat deploy/gcp/deploy-sa` |
| A state bucket | Terraform's backend | `make gcp-tf-bootstrap` (below) |

Two service accounts are involved and they are **not** the same thing:

- **deploy SA** — what Terraform impersonates to build the estate. Read from
  `deploy/gcp/deploy-sa`. It holds resource-creation rights.
- **operator SA** — what the *driver* impersonates to SSH and tunnel. Published
  into the hand-off as `operator_sa`, or overridden with
  `GCP_TF_DEMO_OPERATOR_SA`. It holds no creation rights.

The driver refuses to fall back from one to the other. See
[Why impersonation, and why it is not the usual reason](#why-impersonation-and-why-it-is-not-the-usual-reason).

---

## Step 1 — Bootstrap the state bucket (once, ever)

```bash
make gcp-tf-bootstrap
```

This is **plan-only** by design. Applying it creates the bucket every other
root's state lives in — the one action in the estate with no state to roll back
from — so it is not reachable by a one-word target typed absentmindedly. Review
the plan, then apply it by hand:

```bash
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

Record the bucket name; everything below wants it.

```bash
export TF_STATE_BUCKET=<the bucket you just created>
```

---

## Step 2 — Preflight (optional, cheap, worth it)

```bash
./scripts/gcp-tf/preflight.sh
```

Answers "can this apply actually succeed?" before you spend an evening
discovering that it cannot — quota, APIs, IAM, org policy. Read-only by
construction: every cloud call goes through an allowlist of `describe`/`list`
verbs, so it cannot mutate the project it is inspecting.

---

## Step 3 — Plan and apply

The single target, which cannot skip a step:

```bash
make gcp-tf-up ENV=demo-1
```

That runs, in order: `init` + `plan` → render and summarise the saved plan →
`apply` **that exact plan file** → write the hand-off. It refuses to apply a
plan this invocation did not create, because a bare `terraform apply` re-plans
at apply time, so what you read and what Terraform executes are two different
plans.

If you want the steps individually — to review a plan properly, or to re-run one
after fixing one thing:

```bash
make gcp-tf-plan    ENV=demo-1
make gcp-tf-apply   ENV=demo-1
make gcp-tf-handoff ENV=demo-1
```

---

## Step 4 — The hand-off

`make gcp-tf-handoff` writes `deploy/gcp/demo-1.handoff.json`, schema
`signalloom.gcp.handoff/v1`. It is derived entirely from
`terraform output -json` and is **untracked**, because every field in it names a
real project.

```bash
jq . deploy/gcp/demo-1.handoff.json
```

Everything downstream reads this one file and takes no flags. Nothing about the
estate is typed on a command line and nothing is hardcoded in a script.

**Do not hand-write one.** A hand-off with a plausible-looking wrong field
produces a driver that reaches an estate that does not exist and reports on it.

---

## Step 5 — Stand the demo up

```bash
make gcp-tf-demo-up ENV=demo-1
```

What happens, in order:

1. Resume the VM if it is `SUSPENDED` or `TERMINATED`, and wait for SSH.
2. Package this checkout and deliver it over the IAP tunnel.
3. Run `scripts/gcp-tf/demo-pipeline.sh` on the VM — Kind cluster, the full
   Signal Loom estate, the test suite. Its output **streams to your terminal**
   and is also written to `demo-reports/pipeline.log`.
4. Collect the report directory back into `demo-reports/`.
5. Decide PASS / FAIL / ABORTED / STALE and exit accordingly.

Expect this to take a while. The fence is 90 minutes; raise it with
`GCP_TF_DEMO_TIMEOUT_MINUTES=<n>`.

**What is not delivered.** `.git`, `.keys`, any `*.tfvars`, any
`*.handoff.json`, `deploy/gcp/deploy-sa`, `node_modules` and `.terraform*`. No
signing key and no real project input leaves this machine. The driver inspects
the built artefact and refuses to send it if any of that is present — checking
the tarball, not the flag list, because a `--exclude` that silently matches
nothing looks exactly like a correct one.

Kustomize needs a `.git` directory as a security boundary for relative path
traversal (`../base/` is rejected without one). The pipeline `git init`s a
throwaway snapshot repo on the VM for that. It is a marker, not history — which
is why the driver stamps the report with the commit from **your** checkout, and
treats a report stamped with anything else as `STALE`.

To re-run just the tests against a cluster that is already standing:

```bash
make gcp-tf-demo-test ENV=demo-1
```

---

## Step 6 — Connect

```bash
make gcp-tf-connect ENV=demo-1
```

This opens `gcloud compute start-iap-tunnel <instance> 30754
--local-host-port=localhost:30754` in the **foreground** and prints everything
you need first. Ctrl-C closes it.

### What you have to do

**1. Add the hosts entry** (once per machine):

```
127.0.0.1 dashboard.osramp.acme.local
```

The dashboard is served by the Envoy Gateway behind an **SNI hostname**.
`https://localhost:30754` reaches the Gateway and is then rejected at TLS,
because the name in the request is not the name the certificate and the route
are keyed on.

**2. Accept the certificate.** It is self-signed. There is no public CA in this
estate and there is not meant to be.

**3. Open** <https://dashboard.osramp.acme.local:30754>

**4. Log in through Dex:**

```
username: demo-user@signalloom.local
password: demo-user
```

### Confirm the tunnel before opening a browser

```bash
curl -k --resolve dashboard.osramp.acme.local:30754:127.0.0.1 \
  https://dashboard.osramp.acme.local:30754/readyz
```

`ready` means the estate is up. A hang means the tunnel is not bound. A
connection that 404s means the tunnel is fine and the estate is not — which is a
completely different problem and a completely different fix.

### Port 30754 is not negotiable

Dex pins its OIDC issuer **and** its callback client to it — see
`scripts/acceptance-test.sh`, function `setup_gateway_forward`. On any other
local port the dashboard loads, the login redirect fails, and the result
presents as a *broken application* rather than as a port mismatch. That costs an
hour aimed at the wrong layer, so `gcp-tf-connect` refuses to open a different
port rather than letting you find out. `GCP_TF_DEMO_ALLOW_PORT_MISMATCH=1`
overrides it if you genuinely mean to.

---

## Step 7 — Tear down

The VM bills until it is gone. `gcp-tf-demo-up` leaves it **running** on a
failure so it can be inspected — that is deliberate, and it is your job to close
it out.

Suspend it (keeps the disk, resumes fast, still costs storage):

```bash
gcloud compute instances suspend <instance> --zone=<zone> --project=<project> \
  --impersonate-service-account=<operator-sa>
```

Or destroy the environment outright:

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1
```

`CONFIRM` must be typed and must match `ENV`. Typing the key is the point: it is
the step that fails when you meant `demo-2` and your shell history said
`demo-1`.

Then verify it, and believe the destroy only once this passes:

```bash
./scripts/gcp-tf/teardown-verify.sh
```

`terraform destroy` reporting success means Terraform removed everything *it*
knows about. That is a narrower claim than "the environment is gone", and the
gap between the two is where the bill comes from.

---

## Failure modes, and how to tell them apart

The four verdicts are not interchangeable and the exit codes carry them.

| Verdict | Exit | What it means | First move |
| :--- | :--- | :--- | :--- |
| `PASS` | 0 | tests ran, all green | `make gcp-tf-connect ENV=…` |
| `FAIL` | pipeline's own, or 1 | tests ran, some failed | read `demo-reports/summary.json` |
| `ABORTED` | pipeline's own, or 2 | **no verdict was produced** | read `demo-reports/pipeline.log` |
| `STALE` | as ABORTED | the report describes a *different* run | re-run; do not read the report |

**`ABORTED` is worse than `FAIL`, not better.** It means the pipeline never
reached the test stages, so nothing was measured. A missing summary is never
read as a pass — that exact ambiguity was read as a pass twice in one day on
2026-08-13, which is why this table exists and why the classifier has four
answers rather than two.

The verdict is always on disk at `demo-reports/summary.json`, stamped with the
branch and commit it describes. Read that file, not the VM's state — suspending
is what a pass looks like *and* what a manual cleanup looks like.

### `demo-up: no hand-off for ENV=demo-1`

You have not run `make gcp-tf-handoff ENV=demo-1`, or you are in a different
checkout from the one that produced it (it is untracked, so it does not travel).
Regenerate it. Do not hand-write one.

### `agent refused operation`, or an IAP SSH that "times out"

A populated `ssh-agent` breaks IAP SSH. This reads as a VM provisioning fault
and is a purely local one — on 2026-08-03 it cost ten minutes pointed at a VM
that had finished provisioning in 124 seconds.

`demo-up.sh` empties `SSH_AUTH_SOCK` on every path, so if you see this it came
from an **ad-hoc** `gcloud compute ssh` you typed yourself. Prefix it:

```bash
SSH_AUTH_SOCK= gcloud compute ssh ...
```

### `roles/compute.osLoginExternalUser` / permission denied on SSH

You are reaching the cloud as yourself instead of as the operator SA. See
below — the fix is not to grant yourself the role.

### `gcloud is not authenticated, so <instance>'s state is UNKNOWN`

An unreadable state is **not** an absent VM. Do not re-apply Terraform on this
basis; you would be building a duplicate estate. Run `gcloud auth login`.

### `REFUSING to open the tunnel on port <n>`

The hand-off's `app_port` is not the Dex-pinned 30754. Fix the estate, not the
tunnel — see [Port 30754 is not negotiable](#port-30754-is-not-negotiable).

### The dashboard loads and the login bounces

Almost always the port. Check the tunnel is on 30754 at *both* ends, and that
your `/etc/hosts` line is present. The application is fine.

### `backend prefix mismatch — this is CONTRACT §5a firing`

Terraform was about to write one environment's resources into another's state.
Re-run `terraform init -reconfigure`, and work out how the data dir got crossed
before you do anything else.

---

## Why impersonation, and why it is not the usual reason

Everywhere else in this estate impersonation exists because the human's own
principal is `roles/editor`, which can create a VPC and a VM and cannot create
the IAM-shaped resources — so a direct apply gets a long way in and then dies,
leaving a half-built estate and inviting the wrong fix.

For the **demo driver** the reason is different. The operator is EXTERNAL to the
owning organisation, so `gcloud compute ssh` requires
`roles/compute.osLoginExternalUser` — a role an external principal cannot grant
itself. The error names an OS Login permission, so the diagnosis it invites is
"grant that role", which is not an action you have the authority to take. An
org-internal service account is not subject to the rule at all, so every gcloud
call the driver makes carries `--impersonate-service-account`.

This is measured, not theoretical.

---

## The pipeline contract

`demo-up.sh` (local) and `scripts/gcp-tf/demo-pipeline.sh` (on the VM) are two
halves of one thing. The interface, so neither can drift silently:

**Invocation** — `bash scripts/gcp-tf/demo-pipeline.sh`, with the working
directory set to `SL_DEMO_WORK_DIR`, running as the VM's demo user under
`bash -l`.

**Configuration** — environment only, no arguments:

| Variable | Meaning |
| :--- | :--- |
| `SL_DEMO_ENV` | environment key, e.g. `demo-1` |
| `SL_DEMO_STAGE` | `full` (build the estate, then test) or `test` (tests only) |
| `SL_DEMO_WORK_DIR` | absolute path of the delivered checkout |
| `SL_DEMO_REPORT_DIR` | absolute directory to write reports into |
| `SL_DEMO_SUMMARY_FILE` | absolute path of the JSON verdict file |
| `SL_DEMO_APP_PORT` | port to serve the UI on (30754) |
| `SL_DEMO_HOSTNAME` | dashboard SNI name (`dashboard.osramp.acme.local`) |
| `SL_DEMO_LOG` | absolute path of the pipeline log on the VM |
| `SL_DEMO_SOURCE_COMMIT` | short SHA of the **local** checkout |
| `SL_DEMO_SOURCE_BRANCH` | branch of the local checkout |

**Output** — `SL_DEMO_SUMMARY_FILE`, a JSON object carrying at least:

```json
{ "outcome": "PASS", "commit": "<SL_DEMO_SOURCE_COMMIT>" }
```

`outcome` is one of `PASS`, `FAIL`, `ABORTED`. `commit` **must** be the
`SL_DEMO_SOURCE_COMMIT` it was handed — the VM's own git SHA belongs to a
throwaway snapshot repo and stamping that instead makes every run read as
`STALE`.

**Exit status** — 0 for pass, non-zero otherwise. A zero exit with no summary is
treated as `ABORTED`, never as a pass.

---

## Environment overrides

Every external dependency of the driver is injectable, which is what makes
`test/terraform-demo-driver.bats` able to exercise the whole control flow
against stubs with no cloud access.

| Variable | Default | Use |
| :--- | :--- | :--- |
| `GCP_TF_DEMO_OPERATOR_SA` | from the hand-off | override the SSH identity |
| `GCP_TF_DEMO_TIMEOUT_MINUTES` | `90` | raise the pipeline fence |
| `GCP_TF_DEMO_REPORT_DIR` | `demo-reports/` | where reports land locally |
| `GCP_TF_DEMO_REMOTE_DIR` | `/home/demo/osramp-demo` | delivery target on the VM |
| `GCP_TF_DEMO_ALLOW_PORT_MISMATCH` | `0` | open a non-Dex port anyway |
| `GCP_TF_DEMO_GCLOUD` | `gcloud` | the gcloud binary, plus flags |
| `GCP_TF_HANDOFF_DIR` | `deploy/gcp` | where hand-offs are read from |

---

## Read next

| File | Why |
| :--- | :--- |
| `deploy/gcp/README.md` | the estate's own documentation |
| `terraform/CONTRACT.md` | what the Terraform roots guarantee |
| `scripts/ci/README.md` | the *other* GCP lane (CI VMs), and its traps |
| `test/terraform-demo-driver.bats` | what this lane is actually proven to do |
