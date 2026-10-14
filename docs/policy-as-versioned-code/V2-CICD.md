# v2 CI/CD — the Signal Loom Terraform estate

> **v1 is not deprecated and is not being switched off by this document.** It
> continues to target ControlPlane until it is migrated deliberately. Everything
> below describes the *second* estate, which exists alongside it.

## What v2 is

v2 is the Terraform-provisioned estate in the Signal Loom sandbox project. Where
v1 builds a CI environment by running `gcloud` commands in sequence from a shell
script, v2 declares the environment and applies it: the network, the VM, the
edge, the identities and the state bucket are all resources in a plan a reviewer
can read before anything exists.

That difference is the point of the migration. A shell script that provisions is
a description of *how* the estate was built on the day it last ran successfully;
a Terraform root is a description of what the estate *is*, which is a thing you
can diff, review, test and re-apply.

## How v2 differs from v1

| | **v1 — ControlPlane CI** | **v2 — Signal Loom Terraform** |
|---|---|---|
| **Project** | `sl-port-over-sandbox` | `sl-port-over-sandbox` (org `510505892391`) |
| **Identity** | `andy@control-plane.io` | `sublimino@gmail.com`, impersonating `sl-tf-deploy@sl-port-over-sandbox.iam.gserviceaccount.com` |
| **Region** | `europe-west2` | `us-east4` |
| **Provisioning** | imperative — `scripts/ci/gcp-tf-ci.sh` drives `gcloud` | declarative — `terraform apply` over `terraform/environments` |
| **State** | none; the VM *is* the state | GCS backend, versioned, UBLA + public-access prevention enforced |
| **Compute** | two long-lived VMs, `sl-ci-1-vm` and `sl-ci-2-vm`, suspended between runs | per-environment VM named from the environment key, e.g. `sl-demo-1-vm` |
| **Access path** | `gcloud compute ssh` | Identity-Aware Proxy — no external IP on any instance |
| **Environment key** | implicit in the VM name | explicit: `demo-1`, and every resource is named `sl-<key>-<role>` |
| **Teardown** | suspend the VM | `terraform destroy`, verified by `scripts/gcp-tf/teardown-verify.sh` |

The two estates share a repository and nothing else. Different projects,
different identities, different regions, different resource names.

## What of v1 remains, and why

All of it, for now.

- **`scripts/ci/gcp-tf-ci.sh`, `scripts/gcp-tf/demo-pipeline.sh`**
  — the imperative pipeline. Still the path that runs the D2 end-to-end suite on
  a real cluster. v2 does not yet run that workload.
- **`.github/workflows/sl-ci-1-vm.yaml`** — resumes `sl-ci-1-vm` in
  `europe-west2` under `sl-port-over-sandbox`. Untouched.
- **`make gcp-tf-demo-up ENV=ci-1` / `make gcp-tf-demo-up ENV=ci-2`** — their entry points.

The reason to leave them is not sentiment. v1 currently carries the only working
end-to-end kind-cluster run in the repository, and the v2 estate has a VM that
is provisioned but not yet running the application. Retiring v1 before v2 can
replace that workload would trade a working pipeline for a partial one. The
migration order is: get v2 serving, prove it with acceptance, *then* move v1.

## Running v2 acceptance

Acceptance is read-only. It asserts; it does not provision, and it cannot
mutate — every cloud call passes through an allowlist that refuses any verb
outside `describe` / `list` / `version` / `get-iam-policy`. The estate is live
and billable, so this matters more than it usually would.

```bash
# 1. Describe the deployed environment. Writes deploy/gcp/demo-1.handoff.json.
make gcp-tf-handoff

# 2. Grade it.
./scripts/gcp-tf/acceptance-v2.sh --env demo-1

# In CI, where an unchecked control is not the same as a checked one:
./scripts/gcp-tf/acceptance-v2.sh --env demo-1 --strict

# Against a handoff somewhere else:
./scripts/gcp-tf/acceptance-v2.sh --handoff /path/to/demo-1.handoff.json

# The offline suite. No network, no credentials, a few seconds.
bats test/terraform-v2-acceptance.bats
```

### Exit codes

| Code | Meaning |
|---|---|
| `0` | No `FAIL`. `UNKNOWN`s may be present and are listed. |
| `1` | At least one `FAIL`. |
| `2` | Usage error. |
| `3` | `--strict`, no `FAIL`, but at least one `UNKNOWN`. |
| `4` | A v1 estate was named. Refused, not graded. |
| `5` | The handoff file is absent, unreadable or not JSON. |

### Where the configuration comes from

`deploy/gcp/<env>.handoff.json`, emitted by `make gcp-tf-handoff`. Nothing in
the acceptance script reconstructs a resource name from a naming convention.

That is a deliberate constraint rather than a convenience. A script that builds
`sl-${ENV}-vm` from a rule will happily describe a resource that does not exist,
and an absent resource looks exactly like a clean one — so the report goes green
on a question it never asked. A field the handoff does not carry produces
`UNKNOWN`, which is a statement about the *report*, not about the estate.

## The four verdicts

| Verdict | Meaning |
|---|---|
| `PASS` | Checked, and it is as required. |
| `FAIL` | Checked, and it is **not** as required. The named threat is live. |
| `UNKNOWN` | Could **not** be checked — no permission, no resource, no key in the handoff. |
| `N/A` | There is **nothing to check**, by design. Not a gap in the report. |

`UNKNOWN` is never downgraded to `PASS` or promoted to `FAIL`. "I could not read
the IAM policy" and "the IAM policy is wrong" are different facts, and only one
of them means something is broken.

### Why `N/A` is a separate verdict rather than a kind of `UNKNOWN`

A CI lane (`kind = "ci"`) has no compute module, so it has no instance and no
application port. That is the environment working as designed.

Folding that into `UNKNOWN` has a concrete consequence: `--strict` exits `3` on
any unchecked control, so a perfectly correct CI hand-off would fail every
strict run and **CI lanes could never pass acceptance**. Three facts —
"I could not look", "I looked and it is wrong", and "there is nothing here to
look at" — need three answers.

`N/A` is **fail-closed**. Only the exact string `ci` takes it. `kind = "demo"`,
an absent `kind`, and any unrecognised value all take the strict path and report
`UNKNOWN`, because the shape that would make this dangerous is a demo
environment misclassified as something unfamiliar and handed over with blank
instance fields. The unexpected case must never be the permissive one.

The checks that remain meaningful for a CI lane — state bucket protection,
deploy-SA roles, access mode — still run and still have to pass.

## The IAP distinction, which is the most useful thing the report says

The tunnel check has three outcomes and they have three different owners:

| Outcome | Verdict | Whose problem |
|---|---|---|
| Permission denied | `FAIL` | **IAM.** The tunnel refuses the caller. |
| Authorised, nothing listening on the app port | `PASS` on authorisation, with a note; the app-port check `FAIL`s separately | **Deploy.** IAM is correct; the application is not running. |
| Authorised and connected | `PASS` | Nobody. |

**As of this writing the live `demo-1` environment is in the middle state.** The
tunnel authorises and the application is not running.

Reporting that as "permission denied" would send an engineer to audit an IAM
configuration that is already correct, and they would find nothing wrong with
it, because nothing is. The suite pins this by comparing the two runs against
each other rather than against a string, so an implementation that collapses
them into one verdict cannot pass.

There is a fourth case, and it is the one that bites. When a token has expired
or an API is disabled, `gcloud` answers `PERMISSION_DENIED` to *everything*,
including the tunnel probe. A classifier keying on that text alone reports "IAP
refuses you" — the same expensive wrong answer, from a completely different
cause. So a denial is only treated as evidence about IAP if some other read in
the same run succeeded. Under a total blackout the verdict is `UNKNOWN`, which
is the same discrimination `teardown-verify.sh` draws around a missing state
bucket.

## Pointing v2 acceptance at v1

It refuses.

A handoff or a command-line flag naming `sl-port-over-sandbox`, `andy@control-plane.io`,
`europe-west2`, `sl-ci-1-vm` or `sl-ci-2-vm` exits `4` before a single
cloud call is made.

This is a real guard, not a courtesy. The two estates have different identities,
so a cross-run would not fail cleanly — it would authenticate as the Signal Loom
identity, find nothing named `sl-demo-1-*` in `sl-port-over-sandbox`, and report a tidy
page of `UNKNOWN`s. The reader's reasonable conclusion is "the estate is
unreachable", when the truth is "you graded the wrong estate". Refusing is the
only outcome that cannot be misread.

v1 has its own path and is unaffected: `scripts/ci/gcp-tf-ci.sh`.

## What acceptance checks

| Check | What a failure means |
|---|---|
| instance exists and is `RUNNING` | nothing is serving |
| no external IP | traffic can route around the edge entirely |
| Shielded VM: secure boot, vTPM, integrity monitoring | a tampered boot chain would not be detected |
| OS Login on, project SSH keys blocked | SSH authorisation is not going through IAM |
| per-environment runtime SA, not the default compute SA | a project-wide shared identity, Editor by default |
| no `0.0.0.0/0` ingress in the instance's own network | the whole internet reaches the VPC |
| SSH only from the IAP range `35.235.240.0/20` | SSH is reachable without Identity-Aware Proxy |
| `access_mode` authenticates | SECURITY.md #5 — an allowlist says *where* a request came from, never *who* sent it |
| IAP tunnel authorises | see above; three outcomes, three owners |
| app port responds through the tunnel | the application is down or erroring |
| SSH path via IAP tunnel | operator access is broken — and see the OS Login note below |
| state bucket: versioning, UBLA, public-access prevention | state holds resource ids and IAM member lists |
| deploy SA holds `objectAdmin` **only** on the state bucket | `storage.admin` and the legacy bucket roles can delete the bucket that holds every state version |
| the handoff still describes this estate | the file is stale; everything above graded a machine that may have been rebuilt |

### `access_mode` is three-valued, not a boolean

`terraform/environments/variables.tf` validates exactly three values, and
acceptance grades all three:

| Value | Verdict | Why |
|---|---|---|
| `iap` | `PASS` | IAP in front of the backend; no anonymous path. |
| `iap_and_allowlist` | `PASS` | IAP **plus** an IP allowlist. The variable's own description calls this the strongest posture. |
| `allowlist` | `FAIL` | Cloud Armor IP allowlist only. Coarse exposure control, explicitly not authentication. |
| anything else | `UNKNOWN` | The enum has drifted. The script will not guess a posture it does not understand. |

Treating this as an either/or switch is a real defect rather than a cosmetic
one — it fails the *strongest* configuration, and `iap_and_allowlist` is the
mode most likely in use on a demo estate that is both IAP-gated and
IP-restricted. So the wrong answer would appear precisely on the
best-configured environment.

### Ingress and egress are not the same question

Platform egress is deliberately open: an **egress-only** allow, TCP 443, to
`0.0.0.0/0`, scoped by `target_service_accounts` to the runtime SA. That is
expected and correct — it is how the VM reaches package repositories and
`googleapis.com`.

Ingress is unchanged: `deny-all-ingress` from `0.0.0.0/0` still stands, IAP SSH
from `35.235.240.0/20` only, and no external IP on any instance.

The `no 0.0.0.0/0 ingress` check therefore filters on `direction == "INGRESS"`
and reads `sourceRanges`, never `destinationRanges`. A check that ignored
direction would report a false `FAIL` on a healthy estate — which is worse than
having no check at all, because the next genuine finding gets read as another
false alarm.

### SSH: two things that fail independently

`gcloud compute ssh` currently fails against the live estate while the raw IAP
tunnel works. These are two different controls and only one of them is broken:

1. **The IAP TCP tunnel to port 22** — governed by
   `roles/iap.tunnelResourceAccessor` and the IAP firewall rule. This works, and
   it is the path acceptance uses.
2. **OS Login authorisation** — what `gcloud compute ssh` *additionally* needs.
   The calling identity is external to the organisation, so it requires
   `roles/compute.osLoginExternalUser`, which is an **org-scoped** grant. No
   amount of project-level IAM will produce it.

Acceptance reports these as separate named conditions and never invokes
`gcloud compute ssh` — it is a mutating verb, both gates refuse it, and it would
fail here for a reason that has nothing to do with the estate's posture. A
generic "SSH access failed" would send the reader to the wrong layer entirely.

### Everything else

Firewall rules are scoped to the network the instance is **actually attached
to**, read from the instance itself rather than from a VPC name the script
invented. A VM attached to an unexpected network is then graded on the network
it is attached to, which is the case a name-scoped check walks straight past.

No server-side `--filter` is used for any absence check. A mistyped filter
returns an empty list, an empty list reads as "clean", and the report goes green
on a question it never asked.

## Known v1 assumptions still in the tree

Two of these sit in the **v2** Terraform and are worth knowing about before the
next `apply`. Neither is breaking `demo-1` today; both are latent.

- **`terraform/environments/variables.tf`** — `default_region` defaults to
  `europe-west2`. It feeds the provider block in `providers.tf`, so it is the
  fallback for any resource that does not set a region explicitly. `demo-1` sets
  `region = "us-east4"` in its own entry, so nothing lands in the wrong region
  today; a resource added without an explicit region would.
- **`terraform/platform/variables.tf`** — `log_bucket_location` defaults to
  `europe-west2`, and nothing in `deploy/` overrides it. The audit log bucket for
  a `us-east4` estate would be created in the v1 region: cross-region egress, and
  a data-residency question worth answering deliberately rather than by default.
- **`scripts/ci/gcp-tf-ci.sh`** — `ZONE` defaults to `europe-west2-a`.

The full inventory, including the files that are v1 by design and correctly so,
is in `NOTES.md` at the repository root.
