# Runbook — standing up the first demo environment

**Audience: a second engineer, at 3am, who did not write any of this.**

> **No apply has been run.** Nothing in this document has been executed against a
> real GCP project. Every command below is written from the configuration, not
> from a transcript. Expect the first pass to surface an enabled-API gap or an
> IAM permission this document does not name; when it does, add it here.

---

## 0. Before anything: fix your gcloud identity

This is the first step because it is the one that bites first, and because the
error it produces does not look like an identity problem — it looks like the
project does not exist.

On the workstation this was built on, `gcloud auth list` shows **two** accounts:

| Account | State | Can reach the target project? |
|---|---|---|
| `andy@control-plane.io` | authenticated but **NOT active**, credentials **need reauthentication** | yes, once reauthenticated and made active |
| `sublimino@gmail.com` | **active** | **no** |

So the default identity is the one with no access. A `terraform plan` under it
fails with a permission or not-found error against the project, and the obvious
reading — "the project id is wrong" — is wrong.

```bash
gcloud auth list                                   # confirm which account is ACTIVE
gcloud auth login andy@control-plane.io            # reauthenticate; opens a browser
gcloud config set account andy@control-plane.io    # make it the active account
gcloud config set project <TARGET_PROJECT_ID>

# Terraform does NOT use the gcloud CLI's credentials. It uses Application
# Default Credentials, which are a separate grant that must be obtained
# separately. This is the single most common "but I'm logged in" failure.
gcloud auth application-default login

# Verify both, separately.
gcloud config list
gcloud auth application-default print-access-token >/dev/null && echo "ADC OK"
```

If you are on a machine with no browser, use
`gcloud auth login --no-launch-browser` and paste the verification code back.

---

## 1. Prerequisites Andy must supply

Terraform cannot invent any of these. Collect all seven before starting; each
one discovered mid-run costs a re-plan.

| # | Value | Why it is needed | Who can produce it |
|---|---|---|---|
| 1 | **Target project id** (e.g. `CHANGEME-project`) | Every resource is created in it. | Andy — project owner |
| 2 | **Project number** (numeric, not the id) | The Workload Identity Federation provider's resource name uses the number, not the id. `gcloud projects describe <id> --format='value(projectNumber)'` | Derivable once you have (1) |
| 3 | **DNS managed zone name + domain, and proof the domain is delegated** | The load balancer's Google-managed certificate is issued by DNS validation. Without delegation the certificate stays `PROVISIONING` forever and the demo serves a TLS error. | Andy — registrar access |
| 4 | **Source IPv4 and IPv6 allowlist** (CIDRs) | Cloud Armor's default rule denies everything; only these ranges reach the demo. `0.0.0.0/0` and `::/0` are rejected by the environment contract's validation, deliberately. | Andy — office/VPN/home egress ranges |
| 5 | **State bucket location** (e.g. `europe-west2`) | Set at creation and immutable. Getting it wrong means recreating the bucket that holds every root's state. | Andy — data-residency call |
| 6 | **Billing account id** | The budget and its 50/80/100% thresholds. Optional: leave `billing_account_id = ""` and everything else still applies. | Andy — billing admin |
| 7 | **GitHub owner numeric id** | The WIF attribute condition pins the owner by numeric id. A login can be released and re-registered by a stranger; the numeric id cannot. `curl -s https://api.github.com/users/<owner> \| jq .id` | Derivable |

Also confirm these project APIs are enabled — a disabled API surfaces as a
generic `403` that reads like an IAM problem:

```bash
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  dns.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  storage.googleapis.com \
  --project <TARGET_PROJECT_ID>
```

---

## 2. Ordering: bootstrap → platform → environments

The three roots exist for **credential separation**, not tidiness. Running them
out of order does not just fail; it fails in ways that look like something else.

| Root | Owns | Needs the role | State lives in |
|---|---|---|---|
| `terraform/bootstrap` | the Terraform state bucket | `roles/storage.admin` | a **local** state file — a root cannot own the bucket holding its own state |
| `terraform/platform` | WIF pool + provider, CI service accounts, audit sink + audit bucket, data-access audit config, DNS managed zone, budget, notification channels | IAM, logging, monitoring, DNS admin | GCS, prefix `osramp/platform` |
| `terraform/environments` | one demo VM, its subnet, NAT, LB, Cloud Armor policy, DNS record | compute + limited IAM | GCS, prefix `osramp/environments/<key>` |

Run environments before platform and you get an environment with no runtime
service account and no zone to attach a record to.

---

## 3. Step by step

### Step 3.1 — Offline gate first, always

```bash
make gcp-tf-validate
```

Format, validate, tflint, every native `terraform test` suite, every
`test/terraform-*.bats` suite. No network beyond a one-time provider install, no
credentials. If this is red, stop: nothing below will be more informative.

**Rollback:** none needed; it changes nothing.

### Step 3.2 — Bootstrap the state bucket (once per project, ever)

```bash
make gcp-tf-bootstrap
```

This is **plan only**. It writes `terraform/bootstrap/bootstrap.tfplan` and
stops. Read the plan. Then apply it by hand:

```bash
terraform -chdir=terraform/bootstrap apply bootstrap.tfplan
```

The hand step is deliberate. This apply creates the bucket every other root's
state lives in — the one action in the estate with no state to roll back from —
so it is not reachable by a one-word make target typed absentmindedly.

Record the bucket name; every later command needs it.

```bash
export TF_STATE_BUCKET=<the bucket name from the output>
```

**Rollback:** the bucket has `force_destroy = false` and a `prevent_destroy`
lifecycle rule, so `terraform destroy` will refuse. If it genuinely must go,
that is a considered manual `gsutil rm -r` after confirming no other root has
state in it. Do not automate this.

**If it fails:** almost always `roles/storage.admin` missing, or the location in
(5) not being a valid GCS location.

### Step 3.3 — Platform

```bash
terraform -chdir=terraform/platform init -reconfigure \
  -backend-config=bucket="${TF_STATE_BUCKET}" \
  -backend-config=prefix=osramp/platform

terraform -chdir=terraform/platform plan -out=platform.tfplan
# READ THE PLAN.
terraform -chdir=terraform/platform apply platform.tfplan
```

Before this runs, complete `terraform/platform/WIRING.md` — the
`modules/identity` call ships commented out because that module is built on a
sibling branch. WIRING.md lists exactly what to uncomment and in what order.

Capture the outputs; the environments root consumes them:

```bash
terraform -chdir=terraform/platform output
```

- `dns_name_servers` → **delegate the domain to these at the registrar now.**
  Certificate issuance in step 3.4 depends on it and takes 15–60 minutes after
  delegation propagates.
- `runtime_service_account_emails`, `workload_identity_provider_name`,
  `notification_channel_ids`, `log_bucket_name`.

**Rollback:** `terraform -chdir=terraform/platform destroy`. Note what this
takes with it: the audit sink and the audit bucket. The audit bucket has
`force_destroy = false`, so the destroy will refuse while objects are inside it
and within retention — that is the audit trail defending itself, not a bug.

### Step 3.4 — The first demo environment

```bash
make gcp-tf-plan ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

The target does four things in order, and every one of them can abort:

1. Refuses unless `ENV` matches `^(demo|ci)-[1-9][0-9]*$`. `prod-1` is rejected.
2. Exports `TF_DATA_DIR=.terraform-demo-1`, so `demo-1` and `demo-2` cannot
   share a cached backend pointer.
3. `init -reconfigure` against `prefix=osramp/environments/demo-1`, then reads
   the resolved prefix straight back out of the data dir and aborts unless it
   contains `demo-1`.
4. `plan -var target_env=demo-1 -out=…`, so the tfvars map key cannot disagree
   with the state prefix.

**Read the plan.** Then:

```bash
make gcp-tf-apply ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

`gcp-tf-apply` applies the saved plan file and refuses to run without one. There
is no path through this Makefile to a bare `terraform apply`; a bare apply
re-plans at apply time, so what a human read and what Terraform executes are two
different plans.

**Rollback:**

```bash
make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

`CONFIRM` must equal `ENV` exactly. That is the step that fails when you meant
`demo-2` and your shell history said `demo-1`. The target refuses outright
against the `platform` and `bootstrap` roots, and its argument list contains no
reference to the state bucket.

### Step 3.5 — Verify

```bash
make gcp-tf-status ENV=demo-1 TF_STATE_BUCKET="${TF_STATE_BUCKET}"
```

Then the live checks:

- **Certificate.** `gcloud compute ssl-certificates list` — expect `ACTIVE`.
  `PROVISIONING` for more than an hour means DNS delegation (step 3.3) has not
  propagated. `FAILED_NOT_VISIBLE` means it is definitively wrong.
- **From an allowlisted address:** the demo loads over HTTPS.
- **From a non-allowlisted address:** `403` from Cloud Armor. Test this. An
  allowlist nobody has tested from outside is a belief, not a control.
- **No external IP on the VM.** `gcloud compute instances list` — the `EXTERNAL_IP`
  column must be empty. SSH is via IAP only:
  `gcloud compute ssh <instance> --tunnel-through-iap`.
- **Uptime check and alerts:** confirm the uptime check exists and that each
  alert policy lists a notification channel.

---

## 4. Common failures, in the order you will hit them

| Symptom | Actual cause |
|---|---|
| `permission denied` or `project not found` on the very first plan | The active gcloud account is `sublimino@gmail.com`. Go back to §0. |
| `could not find default credentials` | `gcloud auth login` was run but `gcloud auth application-default login` was not. They are separate grants. |
| `gcloud compute ssh` fails with "agent refused operation" | A local ssh-agent problem, not a VM problem. `unset SSH_AUTH_SOCK` and retry. |
| Certificate stuck `PROVISIONING` | Domain not delegated to the zone's name servers, or delegation has not propagated yet. |
| `ERROR: backend prefix mismatch` | CONTRACT §5a mechanism 3 firing. The cached backend pointer names a different environment. `rm -rf terraform/environments/.terraform-<env>` and re-run the plan target. |
| `ERROR: no saved plan at …` | You ran `gcp-tf-apply` without `gcp-tf-plan`. This is the guard, not a bug. |
| A `403` on an API you are sure you have rights to | A disabled service API. See the `gcloud services enable` list in §1. |
| `terraform init` fails with no network | Only `init` needs the provider registry. `validate`, `test` and `tflint` do not. |

---

## 5. What this runbook deliberately does not do

- **It does not apply anything automatically.** Every apply in this document is
  preceded by a plan a human is expected to read.
- **It does not create the state bucket via make.** See step 3.2.
- **It does not destroy the platform or bootstrap roots.** No make target can.
  Doing so is a considered manual action, and the audit bucket's retention
  policy will resist it — correctly.
