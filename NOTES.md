# H1-useast4-sandbox — build notes

Branch `feat/gcp-tf-useast4-sandbox`. The apply-ready configuration for the
first live demo environment, retargeted from `europe-west2` to `us-east4`.

Everything below was verified read-only against the live project on 2026-08-18.
No mutating call of any kind was made, and no `terraform apply`, `destroy`, or
`init` against a real backend was run.

---

## 1. The finding that changes what Andy should do

**As shipped, `demo-1` has no way in at all.** Not "no certificate" — no
entry point.

`modules/edge` gates the *entire* public frontend on `hostname`, not on
`dns_managed_zone`:

```hcl
tls_enabled = var.hostname != ""
dns_enabled = var.hostname != "" && var.dns_managed_zone != ""
```

Every one of `google_compute_global_address`, `google_compute_managed_ssl_certificate`,
`google_compute_target_https_proxy`, `google_compute_global_forwarding_rule.https`,
`google_compute_target_http_proxy.redirect` and
`google_compute_global_forwarding_rule.http_redirect` carries
`count = local.tls_enabled ? 1 : 0`. With `hostname = ""` none is created, and
the `lb_ip_address` output is the empty string — the module's own output
description says so: *"Empty string when hostname is `""` and no public frontend
was created."*

The backend service, the Cloud Armor policy and the IAP grant **are** created.
Nothing routes to them.

This matters because the brief for this chunk assumed the opposite — "the LB
then has no certificate and IAP still protects it" — and so did two prose blocks
in `demo-1.tfvars.example` and the opening paragraph of `RUNBOOK.md`, all of
which claimed the environment stays "reachable by IP over IAP". All three are
now corrected. The configuration was always right; the documentation described a
different system.

**Andy's stated goal was "route to it, but not public".** The shipped input
gives him the "not public" half and none of the "route to it" half. The fix is
one line, and it does not need a Cloud DNS zone:

| `hostname` | `dns_managed_zone` | Result |
|---|---|---|
| `""` *(as shipped)* | `""` | Fail-closed. No address, cert, proxy or forwarding rule. **Unreachable.** |
| a name Andy controls | `""` | Full HTTPS frontend + IAP. Only the DNS record left to add by hand. |

For the second row: apply, read `terraform output lb_ip_address`, create an A
record for that name at the registrar pointing at it. The Google-managed
certificate sits in `PROVISIONING` until the record resolves, then issues on its
own.

`hostname` is left empty deliberately. Guessing which domain Andy controls is
how a certificate ends up stuck forever against a name nobody owns. **This is the
one decision to make before planning.**

---

## 2. Where the real tfvars lives, and why not where it was asked for

**Asked for:** `terraform/environments/sl-port-over-sandbox.tfvars`.
**Shipped at:** `deploy/gcp/sl-port-over-sandbox.example.tfvars`.
**Committed:** yes.

Two committed guards forbid the requested path. Both were confirmed by probe
rather than by reading, and neither may be modified under this chunk's rules.

1. **`test/terraform-environment-keys.bats` — "no .tfvars file is committed
   under terraform/, only .tfvars.example"** runs
   `find terraform/ -name '*.tfvars' -type f` and asserts the output is empty.
   That is a *filesystem* check, not a git one. Dropping a scratch
   `terraform/environments/PROBE.tfvars` turned the test red immediately, so a
   real `.tfvars` there breaks the suite whether or not git tracks it.
   Independently, `.gitignore:98` (`*.tfvars`) means it could not be committed
   there anyway.

2. **`test/terraform-environment-keys.bats` — "no example contains a real
   project id, domain, or address"** loops over
   `terraform/environments/*.tfvars.example` and rejects any **code** line
   matching `\.(com|net|org|io|dev|co\.uk)\b`. The single most important value
   in this file — `user:sublimino@gmail.com` — trips it. Comments are stripped
   before the check, so the address is fine in prose and fatal as a value.
   Confirmed by probe.

So a real `.tfvars` cannot sit under `terraform/`, and a `.tfvars.example`
under `terraform/environments/` cannot carry the real IAP principal. Renaming
the file to slip past either check would be defeating a control that earns its
place, so it lives outside `terraform/`, where `.gitignore:100`
(`!*.example.tfvars`) explicitly permits committing it. Verified stageable with
`git status --untracked-files=all` and `git add --dry-run`.

**Is it safe to commit? Yes.** It carries no secret. A GCP project id is not
sensitive, the project number is derivable from it, and the email address is
Andy's own and already public. The things those guards exist to stop — a real
hostname, a real office IP range, a credential — are not present. The
`.example` in the name is not a claim that the values are fake; it is the
filename pattern `.gitignore` permits, and the file is copied into place
verbatim.

**A latent trap worth knowing:** `.gitignore:100` un-ignores `*.example.tfvars`,
but the `find terraform/ -name '*.tfvars'` guard matches that pattern too. So a
file named `foo.example.tfvars` is committable by gitignore and instantly fails
the bats suite *if placed under `terraform/`*. The two rules disagree, and only
in that directory.

**Operational consequence for Andy:** the runbook's copy step creates
`terraform/environments/environments.tfvars`, which turns that same guard red
for as long as it exists. That is pre-existing behaviour, not new, but the
runbook now says plainly to delete the copy after applying.

---

## 3. Subnet choice

**Chosen: `10.10.1.0/24`** — unchanged from the existing allocation, now with
evidence behind it.

`gcloud compute networks subnets list --project sl-port-over-sandbox` shows the
project carries **only the auto-mode `default` VPC**, whose per-region subnets
occupy `10.128.0.0/9` — 40 ranges from `10.128.0.0/20` to `10.224.0.0/20`.
`us-east4`'s is `10.150.0.0/20`.

`10.10.0.0/16` is therefore clear of every existing range. The estate's
allocations (`demo-1` 10.10.1.0/24, `ci-1` 10.10.2.0/24, `demo-2` 10.10.3.0/24)
all remain collision-free, and none collides with the hand-built CI estate's
`10.0.0.0/24` either.

Note: the `signalloom-ci` VPC referenced in the examples' prose **does not exist
in this project**. This is a fresh project, not the one the old CI estate runs
in.

---

## 4. us-east4 capability findings

Every check read-only. All clear — nothing was unavailable and nothing was
silently substituted.

| Capability | Verdict | Evidence |
|---|---|---|
| Region / zones | **OK** | `us-east4-a`, `-b`, `-c` all `UP` |
| Global external HTTPS LB | **OK — confirmed global, not assumed** | `gcloud compute backend-services list --global` answered for the project (0 items). Backend services, URL maps, target proxies and global forwarding rules are a global collection; the region imposes no constraint. |
| Cloud Armor | **OK — confirmed global** | `gcloud compute security-policies list` answered with no `--region` flag, i.e. a global collection. |
| IAP for web backends | **OK** | `iap.googleapis.com` is enabled. IAP attaches to the **global** backend service (`google_iap_web_backend_service_iam_member`), so it is not region-limited. |
| `n2-standard-8` in `us-east4-a` | **OK** | `machine-types list --filter='zone:us-east4-a'` → present, 8 vCPU / 32 GB. `n2-standard-4/8/16/48/80` and `e2-standard-8` all present. |
| Cloud DNS managed zone | **NONE EXIST** | `dns managed-zones list` → 0 items. Hence `dns_managed_zone = ""`, and §1 above. |
| APIs | **OK** | compute, iap, dns, iam, iamcredentials, storage all enabled. |

---

## 5. Sizing and cost

**`n2-standard-8` (8 vCPU / 32 GB), 100 GB boot disk.**

Chosen over `demo-1.tfvars.example`'s `n2-standard-16`/200 GB. It matches
`ci-1.tfvars.example`'s existing allocation, so it is a precedent in this repo
rather than an invention. The 16-vCPU machine is the CI lane's size for parallel
test throughput; a single Kind-based demo does not need it, and the VM is by far
the dominant line on the bill.

`deletion_protect = false`, against the example's `true`. This is a sandbox that
exists to be torn down after a demo; deletion protection turns
`make gcp-tf-destroy` into a two-step puzzle at exactly the moment the meter is
running.

### Monthly estimate — roughly **£300–330 / \$390–410** if left running 24/7

| Component | Rate assumed | Monthly (730h) |
|---|---|---|
| `n2-standard-8` on-demand | ~\$0.0378/vCPU-h + ~\$0.0051/GB-h | **~\$339** |
| 100 GB pd-balanced | ~\$0.10/GB-month | ~\$10 |
| Cloud NAT gateway | ~\$0.045/h + data | ~\$33 |
| Cloud Armor policy | ~\$5/policy + ~\$1/rule | ~\$10 |
| LB forwarding rule | ~\$0.025/h | ~\$18 *(only once `hostname` is set)* |

**Honesty about this figure:** it is list-price arithmetic, not an API-verified
quote. I could not query the Cloud Billing catalogue from this box, and
`terraform/COSTS.md` (ISC-219) does not exist yet, so there was no in-repo
anchor to check against. The per-unit rates are stated so the arithmetic is
checkable, and the sustained-use discount (typically ~20–30% on N2 for a
full month) is **not** applied, so the real bill should come in under this.

**The lever that matters:** stopping the VM between demos drops it to roughly
**\$55/month** (disk + NAT + Armor persist; compute stops billing). For a
sandbox used a few days a month that is the difference between ~\$400 and ~\$70.
Worth wiring into the demo workflow before this runs for a full month.

---

## 6. Deliberate non-changes

- **`terraform/environments/variables.tf`** still defaults `default_region` to
  `europe-west2`. Not in this chunk's owned paths, and it only sets the
  provider fallback — every environment carries its own `region`, and both
  committed examples plus the real input now set `us-east4` explicitly. Worth a
  follow-up for tidiness, not a correctness issue.
- **`terraform/environments/ci-1.tfvars.example`** still targets `europe-west2`.
  Not an owned path. Arguably correct as-is: the CI lane belongs to the old
  estate's region. Flagging it so the inconsistency is a decision rather than an
  oversight.
- **`terraform/bootstrap/terraform.tfvars.example`** carries
  `location = "CHANGEME-location"`, a placeholder rather than a region, so there
  was nothing to retarget. Added a header explaining that the value is immutable
  at bucket creation and that `us-east4` is the right choice for this estate.

## 7. Pre-existing failure, not caused by this chunk

`test/terraform-identity.bats` → *"TFID the pre-existing CI scripts are
byte-identical to their recorded state"* **fails**, and it failed before this
work started.

`test/fixtures/gcp-tf-ci/untouched-scripts.sha256` records
`1b4da9d8…` for `scripts/ci/vm-pipeline.sh`, but the file already hashed
`8b29bdee…` at this branch's base commit `50b3886` — proven with
`git show 50b3886:scripts/ci/vm-pipeline.sh | sha256sum`, no checkout. The
working tree copy is byte-identical to that base version; no commit on this
branch touches `scripts/`. It was last changed by `ff65b68` *"fix(ci): run the
Agent Trust activation, and let the parity guard see it"*, which edited the
script without refreshing the digest fixture.

Left alone: `scripts/**` and pre-existing tests are both outside this chunk's
remit. **Someone owns fixing this** — either restore the script or re-record the
digest — because until then the guard that exists to detect edits to the CI
scripts is red for a reason unrelated to any new edit, which is exactly how a
real one gets waved through.

---

## 8. Verification

| Gate | Result |
|---|---|
| `terraform fmt -check -recursive terraform/` | clean |
| `terraform init -backend=false` + `validate` (environments) | **Success! The configuration is valid.** |
| `terraform test` (environments) | **25 passed, 0 failed** |
| `tflint` (environments, bootstrap) | exit 0, no findings |
| `bats test/terraform-demo1-bringup.bats` | **29 passed, 0 failed** (19 pre-existing + 10 new) |
| `bats test/terraform-*.bats` | **252 passed, 1 failed** — the pre-existing failure in §7 |

Guards were falsified, not merely observed green:

- The examples-region guard was run against a hand-reverted `europe-west2`
  example and produced the expected red with the right message; the file was
  then restored and verified clean.
- The zone/region predicate has two mutation tests: a zone moved into another
  region, and a file it can parse nothing out of — because a parser returning
  nothing otherwise reports the same silence as a clean file.
- The apply-ready and posture guards each have a mutation proving they can fail.
- The `find terraform/ -name '*.tfvars'` guard was falsified with a scratch file
  before any design decision was based on it.
