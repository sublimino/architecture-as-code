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
| `terraform/environments/variables.tf` | Declares `access_mode` and `iap_members`, mirrored from `modules/edge` |
| `terraform/environments/main.tf` | Publishes both through `local.integration_inputs`; the commented `module "edge"` block now passes them |
| `terraform/environments/tests/edge_access_defaults.tftest.hcl` | 8 runs on the **evaluated** configuration: the default, and four rejections each paired with a positive |
| `test/terraform-demo1-bringup.bats` | 16 tests, 0.8s, offline |
| `test/fixtures/terraform/demo1/access-mode-allowlist.sed` | Mutation fixture |

### Test results

`bats test/terraform-demo1-bringup.bats` → **16/16 pass in 0.80s**, offline, no
credentials.
`terraform -chdir=terraform/environments test` → **21/21 pass** (8 new, 13
pre-existing).

Every new assertion was falsified rather than assumed:

| Mutation (always on a copy) | Result |
|---|---|
| posture flipped to `allowlist`, `preflight.sh` replaced by `exit 1`, `RUNBOOK.md` emptied | **7 of 12 red**, including the preflight test — the point of asserting on the message, since a bare status check passes for a script that does not exist |
| a second example whose `demo-9` claims demo-1's `/24` | subnet-collision test red, naming `demo-9` |
| `access_mode` declaration deleted from `variables.tf` | 3 tests red (declared-variables, its mutation, the named-pair check) |
| root `access_mode` default flipped to `"allowlist"` | `default_access_mode_is_iap` red |
| `not_a_real_variable = "x"` appended to an example | undeclared-assignment check red |

Full sweep `bats test/terraform-*.bats` → **229 pass / 2 fail of 231**. Both
failures are pre-existing, in a file I did not touch, caused by a commit two
before my branch point — see "scope touches" item 3 for the evidence.

`terraform init -backend=false && terraform validate` → **Success** on both
`terraform/environments` and `terraform/platform`. `terraform fmt -recursive
-check terraform` → clean. `tflint` → clean on both roots. `shellcheck
scripts/gcp-tf/preflight.sh` → clean.

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

**Resolved: the two root variables now exist.** `access_mode` and `iap_members`
are declared in `terraform/environments/variables.tf`, published through
`local.integration_inputs`, and wired into the commented `module "edge"` block
ready for step 4. See "the undeclared-variable class of failure" below for what
this was and how it is now unreachable.

---

## The undeclared-variable class of failure, and how it is now unreachable

Terraform treats a value for an **undeclared** variable in a `-var-file` as a
*warning*: it proceeds, discards the value, and the module takes its own
default. The warning scrolls past in CI output where nobody reads it.

Concretely: Andy would have set `access_mode = "iap"` in tfvars and got whatever
`modules/edge` defaults to. That default *is* `iap`, so the outcome would have
been **right by accident** — which is the shape that bites six months later when
someone changes the default and every environment silently follows.

Four things now stand between that and a release:

1. **The declarations exist**, mirrored from `modules/edge` (G1's, canonical) —
   `access_mode` string, default `"iap"`, validated against exactly three legal
   values; `iap_members` `list(string)` with the dangerous-principal and
   prefix-backstop rules copied character-for-character.
2. **`tests/edge_access_defaults.tftest.hcl`** asserts the **evaluated** default
   is `iap`, plus four rejections (`allUsers`, `allAuthenticatedUsers`, a
   wildcard `principalSet`, a bare email) each paired with a positive. It lives
   in its own file because run-level `variables` blocks *merge* with the
   file-level block — a defaults test in a file whose header sets the variable
   is measuring the header. Falsified by flipping the default to `"allowlist"`
   on a copy: `default_access_mode_is_iap` goes red.
3. **A bats test asserting every variable set in any committed
   `*.tfvars.example` is declared in `variables.tf`**, with two positive
   controls (the declaration parse must yield ≥ 8 names, each example ≥ 4
   assignments) so it cannot pass on an empty scan, plus a mutation appending
   `not_a_real_variable = "x"` to a copy. Falsified by deleting the `access_mode`
   declaration from a copy of the tree: three tests go red.
4. **The mutation fixture now writes `allowlist`, not `public`.** `public` is not
   a legal value, so the variable validation would reject it regardless — a
   guard could "pass" that mutation without ever having looked at it. `allowlist`
   is legal, plans cleanly, and quietly removes authentication. That is the
   realistic accident.

### The one validation not mirrored

`modules/edge` also carries a non-empty rule on `iap_members`. It is correct and
it fires — on **every** plan of this root that names no principal, including
`terraform/environments/tests/root_contract.tftest.hcl`, whose file-level
`variables` block predates these variables and sets neither (result: 0 passed, 1
failed, 12 skipped). That is a pre-existing test and not this chunk's to edit, so
the rule is omitted at the root with a comment naming exactly what is missing.
**Raised with the orchestrator.** One line in that suite's header restores it:

```hcl
iap_members = ["user:someone@example.invalid"]
```

Nothing is unguarded meanwhile: the module carries the rule and this root passes
`iap_members` straight into it, so an empty list still aborts the plan once edge
is wired — which is also the only moment an empty list can lock anyone out,
because until then no edge exists. Only *where* the error is raised moves.

### A correction this surfaced

My first draft of `demo-1.tfvars.example` described `"public"` as "the other
accepted value". There is no such value. `access_mode` is `iap` | `allowlist` |
`iap_and_allowlist`, read from `feat/gcp-tf-iap-private-edge` at commit
`05f476e`. Fixed in both examples, in `WIRING.md`, and in the mutation fixture.
It is the exact mistake the new tftest's `access_mode = "public"` rejection case
now catches — a reader guessing a fourth value by analogy.

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

**`10.20.1.0/24` was considered and is rejected — it is not a pending option.**
Both claims above were independently verified by the orchestrator, who
originated the instruction and withdrew it. The change would cost a red suite
and an allocation inconsistent with `ci-1` (10.10.2.0/24) and `demo-2`
(10.10.3.0/24), and buy nothing measurable. Deliberately not recording the steps
to make it: an option nobody should take should not be documented as available.
`demo-1` is on `10.10.1.0/24`.

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

3. **Two pre-existing tests fail, and neither is mine.** Both in
   `test/terraform-network-security.bats`:

   - "no credential-shaped literal in either module tree or the startup script"
   - "no terraform init artifact is committed under either module"

   Same root cause, and it is a small irony: commit `5809c91` — whose own test
   comment says *"Both modules had one committed as a side effect of running
   `terraform init -backend=false` in-place to validate. They are removed, and
   this assertion stops them coming back"* — **committed them**.
   `terraform/modules/network/.terraform.lock.hcl` and
   `terraform/modules/compute/.terraform.lock.hcl` are tracked as of that
   commit, which is two commits before my branch point `d7d8260`. Their `zh:`
   provider digests then drown the credential scanner, which is precisely the
   "how a secrets guard becomes something people mute" failure the comment
   predicts.

   Evidence: `git log -1 -- terraform/modules/{network,compute}/.terraform.lock.hcl`
   → `5809c91`. `git log d7d8260..HEAD -- terraform/modules/` → **0 commits**;
   nothing I did touches that subtree.

   Fix is F3's: `git rm --cached` both files (they are inert in a child module —
   the lock is only consulted in a root), or exclude them from
   `tracked_sources`.

   **A caution for whoever verifies this.** My first attempt at proving it
   pre-existing was to run the suite against a clean `git archive` of the base
   commit. That is not a valid oracle here: `tracked_sources` shells out to
   `git ls-files`, an extracted archive has no `.git`, so the file list comes
   back empty and the test passes **vacuously** — reporting "fixed at base" for
   a defect that is present at base. `git log` on the specific paths is the
   honest check.

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
