# Runbook — standing up `demo-1`, the first environment

**Audience: a second engineer, at 3am, who did not write any of this.**

> ## Execution status — read this before anything else
>
> **No step in this document has ever been executed.** Not once, not partially,
> not against a scratch project. Every command below is written from the
> configuration, not from a transcript, and the outputs described are what the
> configuration says should happen rather than what anyone has watched happen.
>
> | Step | Ever executed? |
> |---|---|
> | 1 — authenticate | no |
> | 2 — preflight | **the script itself is tested offline against stubs; it has never been pointed at a real project** |
> | 3 — offline gate | yes — `make gcp-tf-validate` runs green in CI and locally |
> | 4 — bootstrap the state bucket | no |
> | 5 — apply platform | no |
> | 6 — plan and apply `demo-1` | no |
> | 7 — verify | no |
> | 8 — destroy | no |
>
> Expect the first real pass to surface an enabled-API gap or an IAM permission
> this document does not name. When it does, **add it here**, in the step where
> it bit. A runbook that is not amended on first contact stays wrong forever.

## The real target

Verified read-only against the live project on 2026-08-18. These are not
placeholders; they are what this runbook now assumes throughout.

| | |
|---|---|
| Account | `sublimino@gmail.com` — the gcloud CLI login, and the identity IAP will authorise |
| Project | `sl-port-over-sandbox`, number `308545937261` |
| Region / zone | **`us-east4`** / `us-east4-a` (zones `-a`, `-b`, `-c` all UP) |
| Environment key | `demo-1` |
| Posture | `access_mode = "iap"` |
| Apply-ready input | `deploy/gcp/sl-port-over-sandbox.example.tfvars` |
| Cloud DNS zones | **none exist in the project** — see the reachability warning below |
| Billing / APIs | billing enabled; compute, iap, dns, iam, iamcredentials, storage all enabled |

The load balancer, its Cloud Armor policy and IAP for web backends are **global**
resources, so `us-east4` constrains none of them. `n2-standard-8` was confirmed
present in `us-east4-a`.

> ### STOP — the environments root does not build anything yet
>
> `make gcp-tf-plan ENV=demo-1` currently produces a plan that creates **zero
> resources**. `terraform/environments/main.tf` has one live module,
> `env_contract`, which declares no resources at all; `network`, `compute`,
> `edge` is commented out inside its INTEGRATION BLOCK (`ci_runner` was deleted 2026-08-20),
> along with the `terraform_remote_state` reference to `terraform/platform`.
>
> The comment says those modules "do not exist on this branch". That is now
> **stale** — `terraform/modules/` contains all of them and `terraform/platform`
> exists too. The modules landed; the wiring step never happened.
>
> Before any of the steps below can produce infrastructure: follow
> `terraform/environments/WIRING.md` to uncomment the blocks in dependency
> order, and apply `terraform/platform` first, because this root consumes its
> outputs read-only. Everything else in this runbook is correct and ready — it
> just has nothing to build until then.

### Reachability — how you actually reach the demo

`demo-1` is **secure, routable by you, and has no public surface whatsoever**.

The public HTTPS edge is **deliberately not instantiated**. IAP for *web*
backends needs an HTTPS load balancer, which needs a certificate on a name that
resolves, and this project has no Cloud DNS managed zone. So instead of a
self-signed certificate and browser warnings, `hostname = ""` and
`dns_managed_zone = ""` mean no global address, no certificate, no proxy and no
forwarding rule are created at all — `modules/edge` gates every one of them on
`hostname`, and `empty_hostname_plans_no_public_frontend_at_all` in
`modules/edge/tests/tls_frontend.tftest.hcl` proves it.

You reach it over **IAP TCP forwarding**: a private VM with no external IP,
ingress permitted only from `35.235.240.0/20` by `allow_iap_ssh`, with
`deny_all_ingress` behind it. Nothing is listening publicly to be scanned.

> **Mind the port, and mind which port.** `allow_iap_ssh` opens TCP **22 only**.
> The application is opened by a second, separately-named rule,
> `allow_iap_app`, and only on the environment's `app_port` — which for a demo
> lane is **8080**, the dashboard nginx Service port. IAP forwarding targets
> dashboard nginx directly; nginx serves the SPA and proxies `/dex/` and `/api/`
> on the same origin. This avoids the former Gateway and Dex port coupling.

```bash
# Direct tunnel to the application. Needs roles/iap.tunnelResourceAccessor.
gcloud compute start-iap-tunnel <instance> 8080 \
  --local-host-port=localhost:8080 --zone us-east4-a
# then open http://localhost:8080
```

The SSH forward still works and is the fallback when the tunnel is blocked by
an org policy on `app_port`:

```bash
gcloud compute ssh <instance> --zone us-east4-a \
  --project sl-port-over-sandbox --tunnel-through-iap \
  -- -L 8080:localhost:8080
```

`access_mode = "iap"` stays set regardless: it is the safe default and it
becomes the live web posture the moment a hostname is added, with no other
change. If you later want the real HTTPS edge, set `hostname` to a name you
control, leave `dns_managed_zone = ""`, and add one A record at your registrar
pointing at the `lb_ip_address` the apply reports. A managed certificate
validates against DNS hosted anywhere — it does not require Cloud DNS.

Note that `roles/iap.tunnelResourceAccessor` is **not** granted by this
Terraform to a human; you will be using it via project `owner`. From a
less-privileged account the tunnel returns a 403 that looks like a networking
fault.

---

## Step 1 — Fix your gcloud identity

This is first because it bites first, and because the error it produces does not
look like an identity problem: it looks like the project does not exist.

Two accounts are authenticated on the workstation this was built on. The
**active** one is a personal account with no access to the target project; the
work account that does have access is authenticated but not active and its
credentials need reauthentication. So the default identity is the one that
cannot see the project, and `gcloud projects describe` answers with a message
that reads as "no such project".

```bash
gcloud auth list                                  # which account is ACTIVE?
gcloud auth login sublimino@gmail.com                  # reauthenticate; opens a browser
gcloud config set account sublimino@gmail.com
gcloud config set project sl-port-over-sandbox

# Terraform does NOT use the gcloud CLI's credentials. It uses Application
# Default Credentials, a separate grant obtained separately. This is the single
# most common "but I am logged in" failure in this whole document.
gcloud auth application-default login

gcloud config list
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```

No browser on the machine? `gcloud auth login --no-launch-browser`, then paste
the verification code back.

**Rollback:** none — this changes local credential state only. To undo,
`gcloud config set account <previous-account>`.

**An agent cannot do this step.** Reauthentication is interactive by design, and
it is the reason everything downstream of here is written rather than run.

---

## Step 2 — Preflight

```bash
./scripts/gcp-tf/preflight.sh \
  --project sl-port-over-sandbox \
  --env demo-1
```

Once the state bucket exists (step 4) and a DNS zone is configured, pass them
too — the script reports `UNKNOWN` for anything it was not given rather than
guessing:

```bash
./scripts/gcp-tf/preflight.sh \
  --project sl-port-over-sandbox \
  --env demo-1 \
  --bucket "${TF_STATE_BUCKET}" \
  --dns-zone <ZONE_NAME>
```

It creates, modifies and deletes nothing — every cloud call passes through an
allowlist of `describe`/`list`/`version`, so a call that would mutate aborts the
script instead. Run it as often as you like, including while an apply is in
flight.

Three verdicts, and the difference between the last two matters:

| Verdict | Meaning |
|---|---|
| `PASS` | checked, and as required |
| `FAIL` | checked, and **not** as required — the fix is printed underneath |
| `UNKNOWN` | **could not be checked** — no permission, no tool, nothing supplied |

`UNKNOWN` is never reported as `FAIL`. A preflight that says "API not enabled"
when it merely could not look sends you to enable an API that was already on.

Exit `0` means no `FAIL`; exit `1` means at least one. **Do not proceed past a
`FAIL`.** Every one of them is a thing that makes a later step fail in a less
obvious place.

**Rollback:** none needed; it changes nothing.

---

## Step 3 — The offline gate

```bash
make gcp-tf-validate
```

`terraform fmt`, `validate` and `tflint` over every root and module, every
native `terraform test` suite, and every `test/terraform-*.bats` suite. All of
it discovered by glob, not by a hand-maintained list, so a suite that lands runs
the same day. No credentials; no network beyond a one-time provider install.

If this is red, **stop**. Nothing below will be more informative.

**Rollback:** none needed; it changes nothing.

---

## Step 4 — Bootstrap the state bucket (once per project, ever)

```bash
make gcp-tf-bootstrap
```

This is **plan only**. It writes `terraform/bootstrap/bootstrap.tfplan` and
stops. Read the plan, then apply it by hand:

```bash
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

The hand step is deliberate. This apply creates the bucket every other root's
state lives in — the one action in the estate with no state to roll back from —
so it is not reachable by a one-word make target typed absentmindedly.

Record the bucket name. Every command from here on needs it:

```bash
export TF_STATE_BUCKET=<the bucket name from the output>
```

**Rollback:** the bucket carries `force_destroy = false` and a `prevent_destroy`
lifecycle rule, so `terraform destroy` refuses. If it genuinely must go, that is
a considered manual `gcloud storage rm --recursive` after confirming no other
root has state in it. Do not automate this. Note that both tripwires live in the
config, so the same commit that destroys the bucket could delete them — the real
protection is IAM (CONTRACT §5c): no plan/apply principal holds
`roles/storage.admin` on the state bucket.

**If it fails:** almost always missing `roles/storage.admin`, or a bucket
location that is not a valid GCS location.

---

## Step 5 — Apply the platform root

Platform must be applied **before** `demo-1`, because `demo-1` reads its
outputs. It owns the project-level singletons that N environments would
otherwise each claim to own: the Workload Identity pool and provider, the CI
plan/apply service accounts, the runtime service accounts, the audit log sink
and bucket, the DNS managed zone, the budget and the notification channels.

First complete `terraform/platform/WIRING.md` — the `modules/identity` call
ships commented out because that module is built on a sibling branch. WIRING.md
lists exactly what to uncomment and in what order.

```bash
terraform -chdir=terraform/platform init -reconfigure \
  -backend-config=bucket="${TF_STATE_BUCKET}" \
  -backend-config=prefix=osramp/platform

terraform -chdir=terraform/platform plan -out=platform.tfplan
# READ THE PLAN.
terraform -chdir=terraform/platform apply platform.tfplan
```

Capture the outputs — `demo-1` consumes them through
`terraform_remote_state`, so they must be in state before step 6:

```bash
terraform -chdir=terraform/platform output
```

- `dns_name_servers` → **delegate the domain to these at the registrar now.**
  Certificate issuance in step 6 depends on it, and takes 15–60 minutes after
  delegation propagates. Doing this at the end of step 6 costs an hour of
  waiting that could have overlapped with the rest of the work.
- `runtime_service_account_emails`, `workload_identity_provider_name`,
  `notification_channel_ids`, `log_bucket_name`.

**Rollback:** `terraform -chdir=terraform/platform destroy`. Know what that
takes with it: the audit sink and the audit bucket. The audit bucket has
`force_destroy = false`, so the destroy refuses while objects are inside it and
within retention — that is the audit trail defending itself, not a bug. No make
target can destroy this root.

---

## Step 6 — Plan and apply `demo-1`

### 6a. Supply the inputs

```bash
cp deploy/gcp/sl-port-over-sandbox.example.tfvars \
   terraform/environments/environments.tfvars
```

`environments.tfvars` is the filename the Makefile passes as `-var-file`,
resolved relative to `terraform/environments`. It is gitignored.

**Remove it once the apply is done.** `test/terraform-environment-keys.bats`
asserts that `find terraform/ -name '*.tfvars'` returns nothing, and it is a
filesystem check rather than a git one — so the suite stays red for as long as
the copy is in place. That is also why the apply-ready input lives outside
`terraform/`.

Unlike `terraform/environments/demo-1.tfvars.example`, this file is **already
filled in**: real project id and number, `us-east4`/`us-east4-a`, and the real
IAP principal. Read it once before planning — the header explains every value —
but the only thing you may need to change is `hostname`, per the reachability
table at the top of this runbook.

If you copy `demo-1.tfvars.example` instead, nothing in it is usable as shipped:
`CHANGEME-project` is rejected by validation, `*.example.invalid` can never
resolve, and the allowlists are RFC 5737/3849 documentation ranges. **A copy
that is not edited fails at plan, not in production.**

Confirm the two lines that carry the security posture survived your edit:

```bash
grep -E 'access_mode|iap_members' terraform/environments/environments.tfvars
```

`access_mode = "iap"` is the difference between "not publicly accessible" and
"publicly accessible". `iap_members` is who may authenticate; an empty list is a
working, fully locked-out environment whose failure mode is a 403 *after* a
successful Google login, which reads like a broken deploy.

### 6b. Plan

```bash
make gcp-tf-plan ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

Four things happen in order, and every one of them can abort:

1. `ENV` must match `^(demo|ci)-[1-9][0-9]*$`. `prod-1` is rejected on purpose.
2. `TF_DATA_DIR=.terraform-demo-1` is exported, so `demo-1` and `demo-2` cannot
   share a cached backend pointer. Cross-contamination becomes physically
   impossible rather than merely detected.
3. `init -reconfigure` against `prefix=osramp/environments/demo-1`, then the
   resolved prefix is read straight back out of the data dir and compared for
   **exact equality** with `osramp/environments/demo-1`. A substring match was
   the original implementation and it let `demo-10` satisfy `ENV=demo-1`.
4. `plan -var target_env=demo-1 -out=.terraform-demo-1/demo-1.tfplan`, so the
   tfvars map key cannot disagree with the state prefix.

**Read the plan.** In particular: no `access_config` block anywhere (no external
IPs), and the Cloud Armor policy's default rule is a deny.

### 6c. Apply

```bash
make gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

**`gcp-tf-apply` only ever applies a saved, reviewed plan file.** It refuses,
non-zero, if `.terraform-demo-1/demo-1.tfplan` does not exist, and it tells you
to run `gcp-tf-plan`. There is no path through this Makefile to a bare
`terraform apply` — a bare apply re-plans at apply time, so what a human read
and what Terraform executes are two different plans. If you find yourself
wanting to bypass this, you want step 6b again.

**Rollback:** step 8.

---

## Step 7 — Verify

```bash
make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

Read-only: `state list` plus `output`. Then the live checks, none of which the
state file can answer:

```bash
# Certificate: expect ACTIVE.
gcloud compute ssl-certificates list --project sl-port-over-sandbox

# No external IP on the VM. The EXTERNAL_IP column must be EMPTY.
gcloud compute instances list --project sl-port-over-sandbox

# SSH is via IAP only. If this says "agent refused operation", that is a local
# ssh-agent problem, not a VM problem: unset SSH_AUTH_SOCK and retry.
gcloud compute ssh sl-demo-1-vm --tunnel-through-iap \
  --zone us-east4-a --project sl-port-over-sandbox
```

- `PROVISIONING` for more than an hour means DNS delegation (step 5) has not
  propagated. `FAILED_NOT_VISIBLE` means it is definitively wrong.
- **From an allowlisted address, signed in as an `iap_members` principal:** the
  demo loads over HTTPS.
- **Signed in as an identity NOT on `iap_members`:** IAP refuses. Test this.
- **From a non-allowlisted address:** `403` from Cloud Armor. Test this too. An
  allowlist nobody has tested from outside is a belief, not a control.
- Confirm the uptime check exists and that each alert policy lists a
  notification channel.

The edge probes automate the last two once the environment is up:

```bash
make gcp-tf-test ENV=demo-1
```

**Rollback:** none needed; every command here is read-only.

---

## Step 8 — Destroy `demo-1`

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

`CONFIRM` must equal `ENV` exactly. Typing the key is the point: it is the step
that fails when you meant `demo-2` and your shell history said `demo-1`.

What this does **not** touch: the state bucket, the audit log bucket, and every
platform singleton — they live in other roots' state. The target refuses
outright against the `platform` and `bootstrap` roots by path.

`deletion_protect = true` in the shipped `demo-1` entry means the VM itself will
refuse to be deleted until you flip it to `false` and re-apply. That is
deliberate: destroying a demo the day before it is demoed is a cheaper mistake
to make than to recover from.

---

## Prerequisites — everything Andy must supply, in one place

Terraform cannot invent any of these. Collect them before starting; each one
discovered mid-run costs a re-plan.

| # | Value | Needed at | Why | How to get it |
|---|---|---|---|---|
| 1 | **Target project id** | step 1 | Every resource is created in it. | Andy — project owner |
| 2 | **Billing account, linked and active** | step 4 | Nothing bills, so nothing creates. Also drives the budget. | Andy — billing admin |
| 3 | **State bucket location** (use `us-east4`, to match the environment) | step 4 | Set at creation and immutable. Wrong means recreating the bucket that holds every root's state. | Andy — data-residency call |
| 4 | **Project number** (numeric, not the id) | step 5 | The Workload Identity provider's resource name uses the number. | `gcloud projects describe <id> --format='value(projectNumber)'` |
| 5 | **GitHub owner numeric id** | step 5 | The WIF attribute condition pins the owner by numeric id. A login can be released and re-registered by a stranger; the numeric id cannot. | `gh api users/<owner> --jq .id` |
| 6 | **DNS managed zone name + domain, and proof the domain is delegated** | step 5 | The managed certificate is issued by DNS validation. Without delegation it stays `PROVISIONING` forever and the demo serves a TLS error. | Andy — registrar access |
| 7 | **`iap_members` principals** | step 6 | Who may reach the environment at all. `user:` / `group:` / `serviceAccount:` prefixed. | Andy — decides the audience |
| 8 | **Source IPv4 and IPv6 allowlist** (CIDRs) | step 6 | Cloud Armor's default rule denies everything; only these ranges reach the demo. `0.0.0.0/0` and `::/0` are rejected by validation, deliberately. | Andy — office/VPN/home egress ranges |
| 9 | **Owner label** | step 6 | On every resource; it is what a budget alert gets routed by. | Andy |

Project APIs. A disabled API surfaces as a generic `403` that reads like an IAM
problem, which is why `preflight.sh` checks them by name:

```bash
gcloud services enable \
  compute.googleapis.com \
  iap.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  cloudresourcemanager.googleapis.com \
  dns.googleapis.com \
  certificatemanager.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  storage.googleapis.com \
  --project sl-port-over-sandbox
```

---

## Why the ordering is bootstrap → platform → environments

The three roots exist for **credential separation**, not tidiness. Running them
out of order does not merely fail; it fails in ways that look like something
else.

| Root | Owns | Needs the role | State lives in |
|---|---|---|---|
| `terraform/bootstrap` | the Terraform state bucket | `roles/storage.admin` | a **local** state file — a root cannot own the bucket holding its own state |
| `terraform/platform` | WIF pool + provider, CI and runtime service accounts, audit sink + audit bucket, data-access audit config, DNS managed zone, budget, notification channels | IAM, logging, monitoring, DNS admin | GCS, prefix `osramp/platform` |
| `terraform/environments` | one demo VM, its subnet, NAT, LB, IAP binding, Cloud Armor policy, DNS record | compute + limited IAM | GCS, prefix `osramp/environments/demo-1` |

Run environments before platform and you get an environment with no runtime
service account and no zone to attach a record to — and the error names a
missing remote state output, not a missing step.

---

## Common failures, in the order you will hit them

| Symptom | Actual cause |
|---|---|
| `permission denied` or `project not found` on the very first call | The active gcloud account is the personal one. Step 1. `preflight.sh` names this explicitly. |
| `could not find default credentials` | `gcloud auth login` was run but `gcloud auth application-default login` was not. Separate grants. |
| Remote state output not found in step 6 | The platform root has not been applied, or was applied under a different prefix. Step 5. |
| `gcloud compute ssh` fails with "agent refused operation" | A local ssh-agent problem, not a VM problem. `unset SSH_AUTH_SOCK` and retry. |
| Certificate stuck `PROVISIONING` | Domain not delegated to the zone's name servers, or delegation has not propagated. |
| `403` after a successful Google login | IAP is working and you are not on `iap_members`. |
| `ERROR: backend prefix mismatch` | CONTRACT §5a mechanism 3 firing. The cached backend pointer names a different environment. `rm -rf terraform/environments/.terraform-demo-1` and re-run step 6b. |
| `ERROR: no saved plan at …` | You ran `gcp-tf-apply` without `gcp-tf-plan`. That is the guard, not a bug. |
| A `403` on an API you are sure you have rights to | A disabled service API. See the enable list above. |
| `terraform init` fails with no network | Only `init` needs the provider registry. `validate`, `test` and `tflint` do not. |

---

## What this runbook deliberately does not do

- **It does not apply anything automatically.** Every apply here is preceded by
  a plan a human is expected to read.
- **It does not create the state bucket via make.** Step 4.
- **It does not destroy the platform or bootstrap roots.** No make target can.
  That is a considered manual action, and the audit bucket's retention policy
  will resist it — correctly.
- **It does not name a real project id, domain, billing account or address.**
  Everything in angle brackets is yours to supply; nothing in this repository
  carries a value that could be applied by accident.
