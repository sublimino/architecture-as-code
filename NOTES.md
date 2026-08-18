# G1-iap-private-edge — build notes

Branch `feat/gcp-tf-iap-private-edge`. Extends `terraform/modules/edge` so the edge can satisfy
Andy's actual requirement: *"I want to be able to route to it, but not have public access so it
stays secure."*

## What was built

`access_mode` on `modules/edge`, with exactly three legal values and **`iap` as the default**:

| Mode | Authorisation | Cloud Armor's job |
|---|---|---|
| `iap` (default) | Identity-Aware Proxy — named principals | WAF, rate limit, adaptive protection, default deny |
| `allowlist` | The IP allowlist (unchanged prior behaviour) | Allowlist is the authorisation control |
| `iap_and_allowlist` | Both | Narrows who reaches the sign-in page |

Plus: `iap_enabled` on the backend service; `google_iap_web_backend_service_iam_member` granting
`roles/iap.httpsResourceAccessor` to `iap_members`; validations rejecting an empty `iap_members`
under an IAP mode and rejecting `allUsers` / `allAuthenticatedUsers` / wildcard members; three new
outputs (`access_mode`, `iap_enabled`, `iap_authorised_member_count`).

## Verification

| Gate | Result |
|---|---|
| `terraform fmt -recursive -check` | clean |
| `terraform init -backend=false && terraform validate` | Success |
| `tflint` (modules/edge) | exit 0, no findings |
| `terraform test` (modules/edge, offline, mock_provider) | **55 passed, 0 failed** (was 33; +22 new runs, all 33 previous still passing) |
| `bats test/terraform-edge-security.bats` | **27/27 ok** (was 22; +5 new) |
| Worktree | committed and clean |

No `apply`, no `destroy`, no `init` against a real backend, no `gcloud` mutation. Every
`.tftest.hcl` uses `mock_provider` and `command = plan` only.

## The IAP OAuth client decision — IAP-managed

**Used the IAP-managed client** (both `oauth2_client_id` and `oauth2_client_secret` omitted,
passed as `null`). Checked the schema rather than assuming:

```
$ terraform providers schema -json   # hashicorp/google 6.50.0, constraint ~> 6.8
google_compute_backend_service.iap:
  enabled              | required=True
  oauth2_client_id     | optional=True
  oauth2_client_secret | optional=True, sensitive=True
```

Both are optional at the pinned provider version, so the IAP-managed form is genuinely supported.
Chosen because it removes the manual OAuth brand/client provisioning step, and because the
alternative requires a client **secret** to flow through tfvars and into state — CONTRACT §6
prohibits secret literals in committed files, and this avoids the question entirely. An
externally-managed client is still available: set both variables, and a validation rejects setting
one without the other (half a client pair is broken, not degraded — the provider would send an id
with no secret and IAP would reject every sign-in).

## Contract objections and divergences — read before merging

### 1. The brief's Cloud Armor instruction for `iap` mode is not implementable as written

The brief said: *"In `iap` mode the allow rules should permit Google's IAP forwarding range so IAP
can actually reach the backend, and nothing else."* I did not do this, because it would ship an
edge that nobody can open while every test went green.

On a **global external** Application Load Balancer — which is what this module builds
(`load_balancing_scheme = "EXTERNAL_MANAGED"`) — Cloud Armor is evaluated **before** IAP, against
the **original client IP**:

> "For a backend service of a global external Application Load Balancer, Cloud Armor evaluation
> happens first. If Cloud Armor blocks a request, IAP doesn't evaluate the request."
> — <https://cloud.google.com/armor/docs/integrating-cloud-armor>

Two consequences:

- IAP is an inline check at the same Google front end, **not** an upstream proxy with its own
  source addresses. There is no IAP-sourced request arriving at Cloud Armor to admit.
- `35.235.240.0/20` is the IAP **TCP-forwarding** range. It governs the VPC firewall for SSH
  tunnelling (ISC-84, ISC-349, F3's network module) and carries no web traffic through this load
  balancer.

So a policy admitting only IAP ranges would return `403` to every real browser, the sign-in page
would never render, and the demo would be unopenable — the same "locked door with no key" failure
the brief rightly demanded be prevented for an empty `iap_members`, reached by a different route.

**What I built instead.** In `iap` mode Cloud Armor admits clients to the *sign-in boundary* and
IAP performs authorisation. This widens **exposure**, not **authorisation** — everything behind it
must still pass IAP, which is strictly stronger than the IP allowlist it replaces. The instruction
to keep the default deny is honoured literally: `deny(403)` at priority 2147483647 survives in
every mode, as do the WAF denies, adaptive protection and rate limiting. `iap_and_allowlist` is the
mode that narrows both layers, and is the one to prefer for anything sensitive.

**The assertion this changes.** "In `iap` mode no allow rule admits an arbitrary client CIDR" is
implemented as: no allow rule admits a CIDR **taken from the allowlist** — proving the allowlist is
genuinely not consulted for authorisation, so a stale `allowed_ipv4` in tfvars cannot silently
become a grant. That is the property that actually protects anyone. It is backed by a
`lifecycle { precondition }` reading the **computed** chunk list (not the mode string), which makes
a wildcard allow unrepresentable while IAP is off, and by a paired assertion in `allowlist` mode
proving no wildcard appears there.

**If the orchestrator disagrees**, the change is contained: `local.raw_chunks` in `armor.tf` is the
single decision point.

### 2. `terraform/SECURITY.md` is F6's file (CONTRACT §1)

I was explicitly instructed to update it and did — new section **5a**, inserted after §5 without
touching any existing row. Flagging the ownership collision because CONTRACT §1 assigns
`terraform/SECURITY.md` to F6-obs-make-docs exclusively. If F6 also edited §5, expect a conflict
confined to that region.

### 3. Existing test files were pinned to their intended posture

Four `.tftest.hcl` files predate `access_mode` and would otherwise have run under the new `iap`
default. `armor_posture` and `allowlist_chunking` now say `access_mode = "allowlist"` explicitly:
their assertions ("no allow rule matches `*`", the 7-rule count) are true of allowlist mode and are
*meant* to be false of iap mode. This preserves their meaning rather than laundering them green —
iap posture is asserted separately in `iap_access.tftest.hcl`. `allowlist_width` is pinned for
clarity. `tls_frontend` is deliberately left on the **default** so the shipping posture is proven to
build a complete frontend; it only needed `iap_members` added.

### 4. ISA divergence — ISC-133

ISC-133 reads *"Allow rules are generated from the allowlist variable with one rule per CIDR
group."* True in `allowlist` and `iap_and_allowlist`; false by design in `iap`, where the allowlist
is not an authorisation input. No ISA edit made (CONTRACT §1 forbids it).

## A mutation check found a real gap — worth knowing about

The dedicated `allUsers` / `allAuthenticatedUsers` validation — the brief called it the single most
dangerous line in the chunk — **was not independently tested**, and I only found this by mutating
it. Deleting the entire guard left the suite at **53 passed, 0 failed**.

Cause: the structural prefix rule (`^(user|group|serviceAccount|domain|principal|principalSet):`)
also rejects both tokens, because neither carries a `type:` prefix. Two overlapping guards, one
test surface, and `expect_failures` cannot say *which* rule fired. The most dangerous guard in the
module could have been deleted in review and shipped green.

Fixed by giving that guard a case only it can reject: a **wildcard principalSet**
(`principalSet://.../workloadIdentityPools/pool/*`) is prefix-valid, so the prefix rule passes it.
That is also a genuine footgun on its own — it reads as a scoped grant and admits every identity in
the pool. Deleting the guard now fails `rejects_a_wildcard_principalset`, and a bats mutation check
(`MUTATION: dropping the allUsers guard turns the suite red`) proves it stays that way. Both
mutation checks assert the edit applied before running, so a `sed` that stops matching cannot
report a green suite as a passing mutation.

## Handoff — what the orchestrator must do

1. **Wire the environments root.** `terraform/environments/main.tf` lines 160–176 have the
   `module "edge"` call **commented out**, and it does not pass `access_mode` or `iap_members`.
   Uncommenting it as-is will **fail at plan** with *"access_mode includes IAP but iap_members is
   empty"*. That is the intended loud failure, but F2 owns
   `terraform/environments/**` so I did not touch it. It needs `iap_members` threaded through —
   either as a new field on the environment object (CONTRACT §3, F2's call) or as a root variable.
2. **No ISC IDs claimed.** ISC-122..154 is F4's range and covers the pre-IAP edge; those remain
   satisfied (all 33 prior runs still pass). No existing ISC covers IAP *at the edge* — ISC-177 is
   IAP **TCP tunnel** access in the network module. New ISCs should be allocated for: the `iap`
   default, the `httpsResourceAccessor` grant, the empty-`iap_members` rejection, and the
   `allUsers`/`allAuthenticatedUsers`/wildcard rejection.
3. **Andy applies, not me.** No GCP resource, DNS record, state bucket or deployment was created.
   The approval gate is untouched. Note that IAP also requires the OAuth consent screen /
   brand to exist in the project before first apply — that is a console or `gcloud` step outside
   this module and outside my permission to perform.
4. No real project id, domain, IP or OAuth secret is committed. Placeholders throughout:
   `CHANGEME-project`, `example.invalid`, RFC5737 (`192.0.2.0/24`, `198.51.100.0/24`,
   `203.0.113.0/24`), `2001:db8::/32`.
