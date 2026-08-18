# G2 — demo-1 bring-up

Branch `feat/gcp-tf-demo1-bringup`. Everything needed to bring up the
environment named `demo-1`, up to but **not** including the apply.

`demo-1` is specified as **secure, routable, not publicly accessible**: a real
DNS name and a real certificate, with Identity-Aware Proxy in front of the
backend so every request carries a Google identity from `iap_members`. There is
no anonymous path to the application.

---

## The exact ordered list of values Andy must supply

The same list is in `terraform/RUNBOOK.md` (prerequisites table) and, for the
tfvars-resident subset, in the header of `demo-1.tfvars.example`.

| # | Value | Needed at | Where it goes |
|---|---|---|---|
| 1 | Target **project id** | step 1, authenticate | `project_id` in tfvars, `--project` to preflight |
| 2 | **Billing account**, linked and active | step 4, bootstrap | nothing to type; it must simply be linked |
| 3 | **State bucket location** (e.g. `europe-west2`) | step 4, bootstrap | `terraform/bootstrap` tfvars. Immutable once set |
| 4 | **Project number** (numeric, not the id) | step 5, platform | platform tfvars `project_number` |
| 5 | **GitHub owner numeric id** | step 5, platform | platform tfvars `github_owner_id` |
| 6 | **DNS managed zone name** + the domain, delegated at the registrar | step 5, platform | `dns_managed_zone` in tfvars (the zone NAME, not the domain) |
| 7 | **`iap_members` principals** (`user:` / `group:` / `serviceAccount:`) | step 6, demo-1 | `iap_members` in tfvars |
| 8 | **Source IPv4 and IPv6 allowlist** (CIDRs) | step 6, demo-1 | `allowed_ipv4` / `allowed_ipv6` in the `demo-1` entry |
| 9 | **Owner label** | step 6, demo-1 | `labels.owner` in the `demo-1` entry |

Values 1–3 are the only ones that block reaching step 5. Values 6–9 can start
as `""` / documentation ranges and be tightened later; **7 cannot** — an empty
`iap_members` is a fully locked-out environment whose failure mode is a 403
after a successful Google login, which reads like a broken deploy.

---

## What I built

| Path | What it is |
|---|---|
| `terraform/environments/demo-1.tfvars.example` | The worked input. `access_mode = "iap"`, `iap_members` with the three principal forms, `dns_managed_zone`, `project_number`, and a header naming the seven tfvars values in the order they are needed |
| `terraform/environments/demo-1-and-demo-2.tfvars.example` | **Mirrored** — see "scope touches" below |
| `scripts/gcp-tf/preflight.sh` | Read-only readiness check. 8 items, PASS/FAIL/UNKNOWN, exit 1 on any FAIL |
| `terraform/RUNBOOK.md` | Rewritten as eight numbered `demo-1` steps with rollback per step and an execution-status table |
| `terraform/environments/WIRING.md` | Ordering corrected for `terraform_remote_state`; documents the two undeclared root variables |
| `terraform/platform/WIRING.md` | Why platform must be **applied**, not merely planned, before the first environment plan |
| `test/terraform-demo1-bringup.bats` | 12 tests, 0.6s, offline |
| `test/fixtures/terraform/demo1/access-mode-public.sed` | Mutation fixture |

### Test results

`bats test/terraform-demo1-bringup.bats` → **12/12 pass in 0.62s**, offline, no
credentials.

Falsified against a scratch broken tree (posture flipped to `public`,
`preflight.sh` replaced by `exit 1`, `RUNBOOK.md` emptied): **7 of 12 go red**,
including the preflight test — which is the point of asserting on the message
rather than the exit status, since a bare status check passes for a script that
does not exist. The subnet-collision test was falsified separately by adding a
second example whose `demo-9` claims demo-1's `/24`; it goes red naming
`demo-9`.

Full sweep `bats test/terraform-*.bats` → **230/231**. The one failure is
pre-existing and not mine — see below.

---

## Blocked, and why

**The apply cannot be run, by me or by anyone right now.** gcloud's active
account is a personal one with no access to the target project; the work account
that has access is authenticated but its token needs interactive
reauthentication. Reauthentication is interactive by design. So nothing below
step 3 of the RUNBOOK has ever been executed, and the RUNBOOK says so in a
status table at the top rather than in a footnote.

This is also why `preflight.sh` exists and why its first real check is the
identity one: the error gcloud returns for "your account cannot see this
project" reads as "no such project", so the obvious conclusion is a wrong
project id and the obvious next move is to go hunting for a different one. The
script names the fix instead.

**Two root variables do not exist yet.** `terraform/environments/variables.tf`
(F2's file) declares neither `access_mode` nor `iap_members`, and
`demo-1.tfvars.example` sets both. Terraform treats a value for an undeclared
variable in a `-var-file` as a **warning**, not an error — it silently drops the
value and the edge module takes its own default. For a variable whose entire job
is to decide whether the environment is publicly reachable, that is the worst
available failure mode. The exact declarations to add are in
`terraform/environments/WIRING.md`; they belong at the **root**, not as fields on
the `environments` object, because CONTRACT §3 freezes that object type.

I did not add them myself: `variables.tf` is F2's file and a unilateral edit to
a frozen interface is the failure mode the contract exists to prevent.

---

## Contract objection: the `10.20.1.0/24` instruction

I was told to put `demo-1` on `10.20.1.0/24`, chosen "to not collide with the
existing `signalloom-ci` VPC". **I kept `10.10.1.0/24`.** Two reasons, and the
orchestrator can overrule both cheaply.

1. **The stated rationale does not hold.** The pre-existing hand-built CI estate
   creates VPC `signalloom-ci` with a single subnet on `10.0.0.0/24`
   (`scripts/ci/gcp-ci.sh:469`, names at `:43`/`:44`). Neither `10.10.1.0/24`
   nor `10.20.1.0/24` collides with it. There is no collision to avoid.

2. **`10.20.x` turns a pre-existing suite red, and I may not edit it.**
   `test/terraform-environment-keys.bats` (F2's) scans every `*.tfvars.example`
   for IPv4 literals and allows only documentation ranges plus a hardcoded
   `10\.10\.`:

   ```
   grep -vE '192\.0\.2\.|198\.51\.100\.|203\.0\.113\.|10\.10\.'
   ```

   A `10.20.x` literal is not in that allowlist, so the suite fails. Only F2 can
   widen it.

**To move to `10.20.1.0/24` anyway** — two edits, both one line:

- `subnet_cidr = "10.20.1.0/24"` in `demo-1.tfvars.example` *and* in
  `demo-1-and-demo-2.tfvars.example` (they must stay in lockstep, see below);
- add `|10\.20\.` to that guard's allowlist in
  `test/terraform-environment-keys.bats`.

The estate's other allocations (`ci-1` 10.10.2.0/24, `demo-2` 10.10.3.0/24) would
then be inconsistent with demo-1, which is a readability cost rather than a
functional one.

---

## Scope touches the orchestrator must know about before merging

1. **`demo-1-and-demo-2.tfvars.example` is edited**, and it was not in my brief.
   It had to be. `test/terraform-environment-keys.bats` diffs it against
   `demo-1.tfvars.example` and fails on any hunk that is not purely additive
   (`d` or `c` in the diff output) — that is the ISC-75 extensibility proof.
   Adding a line to demo-1 alone produces a deletion hunk and turns the suite
   red. The two files are now mirrored, and the diff is `a`-hunks only:
   the demo-2 entry plus two explanatory comment blocks.

2. **`terraform/RUNBOOK.md` no longer names real account addresses.** The
   previous version named both gcloud accounts by their real addresses in §0.
   CONTRACT §6 forbids a real domain in any committed file, so §1 of the rewrite
   describes the situation ("a personal account is active; the work account that
   has access needs reauthentication") and uses `<work-account>`. No information
   is lost; the reader still knows which of their two accounts to pick.

3. **A pre-existing test fails, at the base commit, before any of my work.**
   `test/terraform-network-security.bats` → "no credential-shaped literal in
   either module tree or the startup script". Verified by running that test
   against a clean `git archive` of base commit `d7d8260`: it fails there too.
   The cause is the **committed** `.terraform.lock.hcl` files — 11 of them are
   tracked — whose `zh:` provider hashes trip the credential-literal heuristic.
   The fix is F3's: exclude `.terraform.lock.hcl` from `tracked_sources`, or
   stop committing the lock files. I did not touch it; it is not my file and it
   is not my defect.

4. **No `.tftest.hcl` added.** Nothing I built is expressible in one — a tfvars
   *example*, a shell script, and three markdown documents are exactly the
   bats-side of the CONTRACT §7a split. The environments root's existing
   `tests/root_contract.tftest.hcl` already covers the evaluated configuration.

---

## Things worth knowing that are not obvious

- **`preflight.sh` is read-only by mechanism, not by promise.** Every cloud call
  goes through `gcloud_ro()`, which allowlists `describe`/`list`/`version` and
  exits 2 on anything else. A future edit reaching for `services enable` aborts
  rather than mutating a project during what everyone believes is an inspection.
  The suite exercises that gate by extracting the function and calling it with
  `services enable`.

- **`UNKNOWN` is never downgraded to `FAIL`.** A preflight that reports "API not
  enabled" when it merely lacked permission to look sends someone to enable an
  API that was already on, and the next reader trusts every other line a little
  less. The suite asserts this specifically: with a stub gcloud that denies
  everything, the API check must read `UNKNOWN`, not `FAIL`.

- **`SSH_AUTH_SOCK` is emptied at the top of `preflight.sh`.** A loaded ssh-agent
  on this machine answers "agent refused operation" to gcloud's IAP tunnel calls,
  and the failure surfaces as a VM or network error — the wrong place to look
  entirely. Same footgun is called out in the RUNBOOK's failure table.

- **The copy destination is `terraform/environments/environments.tfvars`**, not
  `demo-1.tfvars`. `GCP_TF_VAR_FILE` in the Makefile defaults to
  `environments.tfvars`, and a file named after the environment would be silently
  ignored while the plan ran against defaults.

- **The `--dns-zone` argument is a zone NAME, not a domain.** Passing the domain
  produces a `FAIL` that reads like the zone is missing.
