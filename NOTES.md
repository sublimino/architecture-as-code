# F1-foundation — build notes

Chunk F1, branch `feat/gcp-tf-foundation`. Scope: `terraform/bootstrap/**`,
`terraform/versions.tf`, `terraform/README.md`, the `.gitignore` block,
`test/terraform-conventions.bats`, `test/terraform-state-protection.bats`,
`test/fixtures/terraform/bootstrap/**`.

Nothing was applied. No `gcloud` command of any kind was run. Verification was limited to
`terraform fmt`, `terraform init -backend=false`, `terraform validate`, `tflint`, `bats`,
`shellcheck`, and `git` on this branch.

## What was built

| Path | Purpose |
|---|---|
| `terraform/bootstrap/{versions,main,variables,outputs}.tf` | The state-bucket root. No `backend` block of any kind. |
| `terraform/bootstrap/tests/state-bucket.tftest.hcl` | 16 native `terraform test` runs, mocked provider, plan-only. |
| `terraform/bootstrap/{backend.hcl.example,terraform.tfvars.example}` | Copyable shapes, `CHANGEME-` placeholders only. |
| `terraform/bootstrap/README.md` | One-time procedure, IAM-vs-config argument, state recovery rehearsal. |
| `terraform/bootstrap/.terraform.lock.hcl` | Committed on purpose. |
| `terraform/versions.tf` | Canonical version-pin reference copy. |
| `terraform/README.md` | Three-root layout, ordering, prefixes, destroy exclusions. |
| `.gitignore` | Append-only delimited block. |
| `test/terraform-conventions.bats` | 30 tests (5 skip). |
| `test/terraform-state-protection.bats` | 28 tests (4 skip). |
| `test/fixtures/terraform/bootstrap/` | 14 broken fixtures + `GENERATE.sh`. |

## Verification actually run

```
terraform fmt -recursive -check terraform/                        exit 0
terraform init -backend=false && terraform validate  (bootstrap)  exit 0, "Success!"
tflint --chdir terraform/bootstrap                                exit 0
bats test/terraform-conventions.bats           30 tests, 0 fail, 5 skip, 1.0s
bats test/terraform-state-protection.bats      28 tests, 0 fail, 4 skip, 0.9s
shellcheck test/fixtures/terraform/bootstrap/GENERATE.sh          exit 0
terraform test  (bootstrap, no credentials)      16 passed, 0 failed
```

Provider resolved to `hashicorp/google` and `google-beta` 6.50.0 under the `~> 6.8` pin.

## ISCs claimed (1–46)

**Satisfied: 1, 2, 3, 7–15, 17, 18, 20–39, 44, 45.**

Notes on the ones where the wording deserves a comment:

- **ISC-8** — implemented as `*.tfvars` plus negations for **both** `*.tfvars.example` and
  `*.example.tfvars`. The ISC names the second spelling, the orchestrator brief named the first.
  Both are ignored-exempt, so either convention works. Verified by behaviour with
  `git check-ignore`, not by grepping `.gitignore`.
- **ISC-13** — satisfied for `bootstrap`, the only root that exists. `.terraform.lock.hcl` is
  explicitly *not* gitignored, and a test asserts `git check-ignore` fails for it.
- **ISC-25** — `location` is required with no default at all, which is stronger than "no
  real-project default".
- **ISC-32** — the log/audit bucket is **deferred**, with the reasoning in a comment block in
  `main.tf`. CONTRACT §5b assigns the audit bucket and log sink to `terraform/platform`;
  declaring one here would duplicate F6's ownership, and bootstrap runs before platform exists.
  The decisive reason is in the comment: the log bucket must never *be* the state bucket, because
  co-locating audit logs with the state they describe means one deletion destroys both the record
  and the evidence. ISC-32 explicitly permits documented deferral.

## ISCs NOT met, with reasons

- **ISC-4, ISC-5, ISC-6** — `terraform/platform/`, `terraform/environments/`, `terraform/modules/`
  are owned by F6, F2 and F3–F5. Not mine to create. Tests for them **skip with a named reason
  and go live automatically** the moment the directory appears (see below).
- **ISC-16** — `terraform/AGENTS.md`, or a terraform section in the repo `AGENTS.md`. The repo
  `AGENTS.md` is a shared pre-existing file outside my declared paths, and CONTRACT §1 makes
  creating files outside my subtree a merge conflict by definition. `terraform/README.md` carries
  the conventions content (version pins, committed lock file, variable typing, modules never
  declaring providers). **Orchestrator decision needed:** either accept `terraform/README.md` as
  satisfying ISC-16, or assign the `AGENTS.md` edit to a single chunk at merge time.
- **ISC-19, ISC-39, ISC-40, ISC-41, ISC-42, ISC-43** — all concern roots that do not exist yet.
  Written as live guards that currently `skip`.
- **ISC-46** — the `make` target for bootstrap. `Makefile` is owned exclusively by F6 per
  CONTRACT §1 and is append-only. **F6 must add it**, and the brief requires it be distinct from
  every other apply target. `terraform/bootstrap/README.md` documents the manual procedure the
  target should wrap.
- **ISC-33 caveat** — `terraform validate` passes, but only because the provider schema is
  downloaded from the public registry during `init -backend=false`. It needs registry network
  access, not cloud credentials. In a fully air-gapped CI this step would need a provider mirror.

## Skip-now-live-later: verified, not assumed

The nine skipping assertions were falsified rather than trusted. In a throwaway copy of the tree
under `/tmp` (never the real tree), I materialised `terraform/platform/` and
`terraform/environments/` containing a `google_storage_bucket`, a wrong backend prefix
(`osramp/platform-staging`) and `versions.tf` files missing the provider pins, and a
`terraform/modules/` holding only three module directories. Every previously-skipping test went
live and **failed**. They are live guards on a timer, not permanent silent passes.

**F6 and F2 should know:** the prefix guard searches the platform root's `.tf` files *and* the
repo `Makefile`, because CONTRACT §5 puts the prefix in a `-backend-config=` argument rather than
in HCL. If F6 spells the prefix anywhere else, or spells it `osramp/platform/` with a trailing
slash, test 27 of the state-protection suite will fail. That is intended.

## Section N (ISC-322–357) landed mid-build — partially absorbed

Commit `573eda8` ("docs(terraform): sync contract + ISA for native terraform tests") was pushed
onto this branch at 01:51, *after* I had read CONTRACT.md and started work. It added CONTRACT §7a
and ISA section N (ISC-322–357), making `terraform test` the primary correctness surface. My
brief assigned me ISC-1–46, so section N is outside my range — but several of its criteria fall
inside `terraform/bootstrap/`, which is my exclusive path and which **no other chunk may write
to**. I built those rather than leave them unbuildable.

**Claimed from section N:** ISC-322, 332, 333, 334, 335, 336, 339, 340, 341, 346, 347, 355, 357.

- `terraform/bootstrap/tests/state-bucket.tftest.hcl` — 16 runs, all `command = plan`, both
  providers mocked. Asserts evaluated `public_access_prevention`, `force_destroy`,
  `uniform_bucket_level_access`, versioning, the lifecycle rule's retention condition, the
  mandatory labels, the IAM role and members, and label-merge direction; then 12 `expect_failures`
  negatives against the variable validations, after an explicit baseline run.
- `terraform test` passes 16/16 with `CLOUDSDK_CORE_ACCOUNT` unset and
  `GOOGLE_APPLICATION_CREDENTIALS` pointed at a nonexistent path (ISC-357), in ~4s (ISC-356 for
  this root).
- Four whole-tree bats guards added to the conventions suite for the absence properties
  `terraform test` structurally cannot see: mock_provider present (ISC-333), no `command = apply`
  (ISC-335), every `expect_failures` file has a positive baseline run (ISC-347), every
  resource-declaring directory ships `tests/` (ISC-355).

**Not mine from section N:** ISC-323–331 and 337–338 (other chunks' roots and modules),
ISC-342–345 (F2's environment-map validations), ISC-348–352 (F3/F4/F5 module attributes),
ISC-353–354 (F6's Make targets).

**ISC-336 caveat:** `terraform test` requires `terraform init -backend=false` to have run in that
directory first, which needs registry network access. Credentials are not needed; the network is.

## Finding that every chunk writing `expect_failures` needs

**`expect_failures` cannot tell you which validation fired — only that one did.** Where an input
violates two rules at once, the run cannot attribute the rejection, and a test named after the
rule it does not isolate is a coverage claim with nothing behind it.

Proven here, not theorised. I deleted the public-principal validation from a scratch copy of
`variables.tf` and re-ran. The runs feeding bare `["allUsers"]` and `["allAuthenticatedUsers"]`
**still passed** — the principal-prefix rule rejects an unprefixed string on its own, so those
runs never exercised the public-principal rule at all. Only the prefixed forms (`user:allUsers`,
`principalSet:allAuthenticatedUsers`) went red, because a valid prefix leaves the public-principal
rule as the only thing that can reject them.

The suite now carries both, named for what each actually proves. **F2 has eleven validation
blocks on the environment map and is the chunk most exposed to this**: an input that trips the key
regex *and* the CIDR rule will pass `expect_failures` whichever rule you deleted. The general
rule: each negative input must violate exactly one rule, and the way to confirm that is to delete
the rule and watch the test go red.

Related tool behaviour worth knowing: **a failing run stops the rest of the file.** An early
failure reported `0 passed, 1 failed, 14 skipped` — a suite can look almost-clean while measuring
nothing after line one. Read the skip count, not just the fail count.

## Two defects found and fixed during the build

1. **The public-principal guard had a hole.** The first draft matched only
   `members = ...allUsers...` on a single line. `terraform fmt` renders any list with more than
   one entry across multiple lines, so the realistic spelling of the mistake evaded it. Confirmed
   the hole was real by running the old regex against a multi-line fixture; it missed. The guard
   now matches the *quoted* literal across all lines, which stays precise because `variables.tf`
   legitimately names both principals inside a validation regex and error message in order to
   reject them, and neither spelling puts a quote against the name. Fixture
   `broken-public-principal-multiline` exists so the fix is tested rather than asserted.
2. **A mutation check could fail for the wrong reason.** The absolute-path guard asserted its
   two-file exclusion list still existed *inside* the path-scanning guard, so deleting
   `CONTRACT.md` turned the MUTATION test red while proving nothing about path detection. The
   exclusion-liveness check is now its own guard and its own test.

## Contract objections (implemented as written, per CONTRACT §1)

1. **`terraform/versions.tf` makes `terraform/` look like a fourth root.** The brief and CONTRACT
   §2 require the pin block at `terraform/versions.tf`. A lone `terraform` block at that level is
   valid HCL and harmless, but `terraform init` run from `terraform/` will treat the directory as
   a root and succeed, which is a small trap for anyone who cds one level too high. Implemented
   as specified; mitigated with a header comment saying `terraform/` is not a root. Suggested
   alternative for the orchestrator: rename it `versions.tf.reference` or move the canonical copy
   into the README. Not done unilaterally.

2. **"No committed file contains an absolute `/home/andy` path" cannot be enforced repo-wide.**
   34 tracked files already contain that literal, including `AGENTS.md`, `Makefile`,
   `.dockerignore`, `.github/workflows/signalloom-ci.yaml`, and five pre-existing `test/` files —
   plus `terraform/CONTRACT.md` and `terraform/ISA.md` themselves, which quote the prohibition.
   A repo-wide guard would have been red on arrival and I am forbidden from modifying any of
   those files. The guard is therefore scoped to tracked files under `terraform/` plus the two
   bats files this chunk owns, with `CONTRACT.md` and `ISA.md` named exclusions that have their
   own liveness test. **Sibling chunks: your files are not covered by this guard.** If the
   orchestrator wants repo-wide enforcement it needs a separate cleanup of the 34 existing files,
   which is out of scope here.

3. **`prevent_destroy` blocks a legitimate teardown too.** With `prevent_destroy = true` on the
   state bucket, `terraform destroy` in the bootstrap root fails outright rather than skipping the
   bucket — the operator has to edit the config to tear down the demo estate. That is the correct
   trade for a state bucket and CONTRACT §5c is right that IAM is the real control, but the
   friction is real and belongs in the runbook F6 owns.

## For the orchestrator, before merging

- Section N (`terraform test`) landed mid-build; see the section above for what I absorbed.
- `.gitignore` was edited **append-only** inside `# >>> terraform (F1-foundation) >>>` markers.
  No existing line was reordered or touched.
- No pre-existing file under `test/` was modified. Both bats files are new.
- `test/fixtures/terraform/bootstrap/GENERATE.sh` regenerates the broken fixtures and **refuses
  to emit a fixture identical to its source**. It is run by a human when the real files change,
  never by the suite: a suite that regenerated its own fixtures would repair the drift the
  fidelity checks exist to detect, and would then always pass. If a fidelity test fails after a
  merge, run the script and inspect its diff — do not widen the bound.
- Commits are unsigned (`--no-gpg-sign`), matching this branch's history.
- Worktree is clean; four commits on `feat/gcp-tf-foundation`, no other branch touched.
