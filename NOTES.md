# F6 — observability, platform root, Make lifecycle, CI, docs

Branch `feat/gcp-tf-obs-make-docs`. Chunk F6 per `terraform/CONTRACT.md` §1.

---

## What was built

| Path | What |
|---|---|
| `terraform/modules/observability/` | Audit sink → dedicated bucket, data-access audit config, uptime checks, two alert policy families, billing budget. Pre-existing from an interrupted run; audited, kept, and completed. |
| `terraform/modules/observability/tests/observability.tftest.hcl` | 9 runs, `mock_provider`, `command = plan`. |
| `terraform/platform/` | The shared-foundation root: notification channels, DNS managed zone, a **live** `module "observability"` call, and a **commented** `module "identity"` wiring block. |
| `terraform/platform/tests/platform_wiring.tftest.hcl` | 9 runs. |
| `terraform/platform/WIRING.md` | Exactly what to uncomment at integration, in what order, with a check after each step. |
| `Makefile` | One delimited append-only block at the end: 9 `gcp-tf-*` targets plus discovery variables and four guard `define`s. |
| `test/terraform-make-contract.bats` | 35 tests. |
| `test/terraform-suite-registration.bats` | 14 tests. |
| `test/fixtures/terraform/make/*.sed` + `README.md` | 7 named single-guard mutations. |
| `.github/workflows/terraform-validate.yaml` | Offline PR gate, no credentials. |
| `terraform/RUNBOOK.md`, `SECURITY.md`, `COSTS.md` | Operator documentation. |

## Verified counts

| Check | Result |
|---|---|
| `terraform test` — `modules/observability` | **9 passed, 0 failed** (0.6 s) |
| `terraform test` — `platform` | **9 passed, 0 failed** (0.6 s) |
| `bats test/terraform-make-contract.bats` | **35/35** (~4 s) |
| `bats test/terraform-suite-registration.bats` | **14/14** (~7 s) |
| `make gcp-tf-validate` | **green, 49 bats + 18 tftest, ~14 s** |
| `make gcp-tf-validate` inside `unshare -rn` (no network interfaces at all) | **rc=0** |
| `terraform fmt -recursive -check terraform` | clean |
| `tflint` on `platform` and `modules/observability` | rc=0 |
| `make help` | parses; lists all 9 new targets |
| Shell scripts added | none — no `shellcheck` surface |

Mutation checks that demonstrably fail (each asserted red before the guard is restored):

- `key-regex` — widening `^(demo|ci)-…` lets `ENV=prod-1` through.
- `confirm-check` — neutering the confirmation lets `CONFIRM=demo-2` destroy `demo-1`.
- `prefix-assert` — neutering the readback lets `ENV=demo-1` plan against a `demo-9` prefix.
- `tf-data-dir` — unscoping `TF_DATA_DIR` lets two environments share a backend pointer.
- `bare-apply` — dropping the plan file turns apply into `-auto-approve`.
- `bats-hand-list` — reverting the glob to a hand list stops running a suite.
- `tftest-hand-list` — hand-listing test directories stops sweeping a module.

Two more, run manually against scratch copies of `modules/observability`: pointing the audit
bucket at the state bucket, and changing a budget threshold `0.8` → `0.9`. Both turn
`terraform test` red.

**Every mutation helper refuses to continue if its `sed` changed nothing.** A pattern that stops
matching would otherwise silently no-op, and the mutation check would then "pass" against an
unmutated Makefile — a green test measuring nothing, which is the exact failure mode this chunk
exists to prevent.

---

## ISCs claimed

**Observability (204–220):** 204, 205, 206, 207, 208, 209, 210, 211, 212, 213, 214, 215, 216,
217, 218, 219, 220.

**Make interface (221–247):** 221, 222, 223, 224, 225, 226, 227, 228, 229, 230, 231, 232, 233,
234, 235, 236, 237, 238, 239, 240, 241, 242, 243, 244, 245, 246, 247.

**Tests / CI / docs (248–275, partial — only F6-owned):** 254, 256, 257, 258, 259, 260, 261, 262,
263, 264, 265, 268, 269, 270, 271, 272, 273.

**Native terraform tests:** 323, 331, 332 (F6 files), 333, 334, 335, 346, 347, 353, 354, 355, 356,
357.

**Anti-criteria:** 276, 278, 279 — no `terraform apply`/`destroy`, no `gcloud` mutation, no
`gcloud auth` change; `scripts/ci/gcp-ci.sh` and `scripts/ci/vm-pipeline.sh` untouched (`git diff`
empty on both).

## ISCs NOT met, with reasons

| ISC | Why not |
|---|---|
| **266, 267** (`terraform/README.md` documents ordering and destroy path) | `terraform/README.md` is **F1's** exclusive path. The content exists in `terraform/RUNBOOK.md` §2 (ordering) and §3 (rollback per step). **F1 must add the pointer, or the orchestrator must move these two ISCs to RUNBOOK.md.** |
| **274, 275** (Obsidian project folder + folder note linking to the proposal) | Outside the repo. No agent should write to the Obsidian vault from a worktree; it needs `obsidian-project-new.sh` run interactively. **Andy or the orchestrator, not this chunk.** |
| **248–253, 255** (other chunks' bats files exist) | Other chunks' paths. My registration guard executes them automatically once merged — no second edit anywhere. |
| **322, 324–330** (other roots'/modules' `.tftest.hcl` exist) | Other chunks' paths. `gcp-tf-test-unit` discovers them on merge. |
| **336, 337, 338** (`terraform test` passes in bootstrap / every module / environments) | Those directories do not exist in this worktree. The sweep that will assert them is built and green on what exists. |
| **339–345, 348–352** (specific evaluated assertions in other chunks' modules) | Other chunks' `.tftest.hcl` files. `terraform-suite-registration.bats` enforces the *shape* (mock_provider present, no `command = apply`, every `expect_failures` paired) across all of them at merge. |
| **321** (first environment's plan produced and reviewable) | Requires a real apply-capable credential and Andy's approval gate. Correctly not done. |

---

## Contract objections

Recorded, not acted on. The contract is implemented as written.

### 1. `modules/observability` needs five inputs the contract does not list

CONTRACT §4 freezes eight inputs. The module also takes `name_prefix`,
`log_bucket_location`, `state_bucket_name`, `enable_alerts`, and `data_access_services`.

**All five carry defaults**, so a caller passing exactly the contract's eight inputs still plans —
the frozen interface is not broken, only extended. Two are load-bearing:

- `state_bucket_name` is what lets the module **prove** ISC-206/207 rather than assert it in a
  comment. Without it, "the audit bucket is not the state bucket" is unfalsifiable from inside the
  module.
- `enable_alerts` is what makes "reject an empty channel list" a *rule* rather than a blanket
  prohibition. Without it, there is no sanctioned way to omit alert policies, so the validation
  would have to be dropped.

**Proposal:** amend §4 to list all thirteen. No other chunk is affected.

### 2. `gcp-tf-bootstrap` is plan-only

ISC-221 requires the target to exist and be `.PHONY`. It does not say it applies. I made it
**plan-only**: it runs `init` + `plan -out=bootstrap.tfplan`, prints the exact hand-apply command,
and stops.

Reason: applying that root creates the bucket every other root's state lives in — the one action
in the estate with no state to roll back from. A one-word make target is exactly how that gets
typed absentmindedly. RUNBOOK §3.2 gives the manual apply.

It also sidesteps a genuine semantic conflict: the spec says every mutating target requires
`ENV=<key>`, and `gcp-tf-bootstrap` is project-scoped, so an `ENV` on it would be meaningless.
Plan-only makes it non-mutating and the question does not arise. **If the orchestrator wants it to
apply, it needs a `CONFIRM=bootstrap` gate, not an `ENV`.**

### 3. `gcp-tf-test ENV=<key>` currently always fails

It runs the offline unit sweep, then every `scripts/gcp-tf/edge-probe-*.sh`. **F4 owns those
scripts and they are absent here**, so the target exits 2 with a message naming F4.

That is deliberate. The alternative — warn and exit 0 — would report a pass from the offline sweep
alone while asserting nothing about a deployed environment. It goes green the moment F4 merges,
with no edit.

---

## What the orchestrator must know before merging

1. **`Makefile` is one contiguous appended block**, delimited by
   `# GCP Terraform platform — appended by chunk F6` … `# END GCP Terraform platform block`.
   Nothing above it is touched. `make -n help` emits no `overriding recipe` warning, and no
   `gcp-tf-*` or `ci-*` target is defined twice — both asserted by tests, not by inspection.

2. **`terraform/.gitignore` does not exist yet and is F1's path.** It must cover
   `.terraform/`, `.terraform-*/`, `*.tfstate*`, `*.tfplan`, `bootstrap.tfplan`. The root
   `.gitignore` has **no** terraform entries today, and the Make targets create
   `terraform/<root>/.terraform-<env>/` on every run. **Until F1 lands this, a careless
   `git add -A` commits provider binaries and possibly state.** I have committed neither; my
   worktree is clean.

3. **Module blocks to uncomment at integration** — full procedure in
   `terraform/platform/WIRING.md`, summarised:

   | Order | File | What |
   |---|---|---|
   | 1 | `terraform/platform/main.tf` | `variable "project_number"`, `"environment_keys"`, `"github_owner_id"`, `"github_repository"`, `"github_allowed_ref"` |
   | 2 | `terraform/platform/main.tf` | `module "identity"` — inputs `project_id`, `project_number`, `environment_keys`, `github_owner_id`, `github_repository`, `github_allowed_ref` |
   | 3 | `terraform/platform/outputs.tf` | `workload_identity_provider_name`, `ci_plan_service_account_email`, `ci_apply_service_account_email`, `runtime_service_account_emails` |
   | 4 | `terraform/platform/tests/platform_wiring.tftest.hcl` | `run "wif_provider_carries_a_non_empty_attribute_condition"` |

   `module "observability"` is **already live** — it is F6-owned and present. Nothing to uncomment.

4. **`scripts/ci/vm-pipeline.sh` still hand-lists its bats suites and is frozen.** No terraform
   suite is registered in the GCP-VM tier, and none should be added there without unfreezing it.
   **The compensating control is `.github/workflows/terraform-validate.yaml`**, which runs
   `make gcp-tf-validate` on every PR against `feat/signal-loop-and-bootstrap-refactor` with no
   credentials. If that workflow is dropped, the terraform suites run nowhere in CI.

5. **`make gcp-tf-validate` is offline in the sense that matters, with one honest exception.**
   Verified rc=0 inside `unshare -rn` with no network interfaces. The exception is
   `terraform init`, which resolves providers from `registry.terraform.io` on a cold checkout;
   the target runs it only when `.terraform/providers` is absent and says so when it does.
   `validate`, `test` and `tflint` are all genuinely offline. This is not a guard that repairs
   what it detects: nothing is corrected, and a stale provider set produces terraform's own
   "provider requirements have changed" error on the very next `validate`.

6. **Credential independence is asserted, not assumed.** Every offline invocation runs under
   `env -u GOOGLE_APPLICATION_CREDENTIALS -u GOOGLE_CREDENTIALS -u CLOUDSDK_CORE_ACCOUNT
   -u CLOUDSDK_AUTH_ACCESS_TOKEN -u GOOGLE_OAUTH_ACCESS_TOKEN`, and the contract suite sets those
   variables to bogus values and asserts the stub never saw them (ISC-357). The CI workflow adds a
   step that fails if any of them, or an ADC file, is present on the runner.

7. **The registration guard is the structural deliverable.** `make gcp-tf-validate` globs
   `test/terraform-*.bats`; `make gcp-tf-test-unit` discovers every directory holding
   `tests/*.tftest.hcl`. `terraform-suite-registration.bats` diffs *what actually ran* against
   *what exists on disk* and fails on any difference. **When five sibling branches merge, their
   suites execute on the first run with no edit to any list anywhere** — and if one of them ships
   a module with resources and no `tests/` directory, ISC-355 names it.

8. **No apply has been run.** No GCP resource, DNS record, state bucket, or IAM binding was
   created, modified, or deleted. No `gcloud` mutation was issued and no `gcloud auth` state was
   changed. Working credentials exist on this machine; they were not used.

9. **`terraform/RUNBOOK.md` §0 documents a live workstation fact** worth keeping current: the
   active gcloud account cannot reach the target project, and the account that can needs
   reauthentication. That is the first thing to fix and the last thing anyone thinks of, because
   it presents as "the project does not exist".
