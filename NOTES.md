# F2-envmodel — chunk notes

Branch `feat/gcp-tf-envmodel`. Owns `terraform/modules/env-contract/**`,
`terraform/environments/**`, `test/terraform-environment-keys.bats`,
`test/fixtures/terraform/envmodel/**`.

## What was built

- **`terraform/modules/env-contract/`** — a pure contract module: the `environments` object type
  verbatim from `CONTRACT.md` §3, the eleven mandatory validation rules as eleven separate
  `validation` blocks, one extension rule (6B, below), and the `name_prefix` / `mandatory_labels`
  locals. No resource, no provider, no `provider` block. Outputs the resolved per-environment
  values under the exact input names from `CONTRACT.md` §4, so a root can `for_each` over the
  output map directly and reference `each.value.<input>` with no lookup tables.
- **`terraform/environments/`** — `versions.tf` (pins verbatim), `backend "gcs" {}` in its own
  file, providers from `var.project_id`, the live `env_contract` module call, the `target_env`
  filter, and five commented-out sibling module blocks with `WIRING.md` giving the uncommenting
  order.
- **Three worked examples** — `demo-1.tfvars.example`, `ci-1.tfvars.example`, and
  `demo-1-and-demo-2.tfvars.example` (the extensibility proof: purely additive against the first).
- **`terraform/modules/env-contract/tests/environment_contract.tftest.hcl`** — 28 native
  `terraform test` runs, 0.6s. The eleven rules plus 6B, each negative preceded by its corrected
  positive, plus assertions on the resolved outputs every sibling module consumes.
- **`terraform/environments/tests/root_contract.tftest.hcl`** — 12 native runs, 0.5s. `target_env`
  selection, `project_id` validation, the empty-map rule, and the extensibility proof.
- **`test/terraform-environment-keys.bats`** — 37 tests, ~3s, offline. Executes the rules and
  covers the whole-tree absence properties `terraform test` cannot reach.

### CONTRACT.md §7a arrived mid-chunk

§7a (native `.tftest.hcl` as the primary correctness surface) landed on this branch in commit
`a74278b`, after this chunk's brief was written and while it was being built. Both native suites
above were added in response. The bats suite was **kept, not replaced**, because §7a's own routing
table puts three things this chunk needs in bats:

- **whole-tree absence** (`access_config`, `/home/andy`, a committed `.tfvars`) — `terraform test`
  can only see what a given plan evaluated, never what no configuration anywhere contains;
- **which rule fired** — `expect_failures` names the *variable* that rejected, not the rule.
  Eleven rules guard `var.environments`, so a mutant that trips the wrong rule is invisible to
  `expect_failures` and visible to the bats tag-set assertions;
- **file layout and documentation content**.

Neither surface subsumes the other, and the overlap is deliberate.

## ISCs claimed

ISC-47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 62, 63, 64, 65, 66, 67, 68, 69, 70,
71, 72, 73, 74, 75.

ISC-62/63/64 are claimed **at the contract layer only**: `local.mandatory_labels` computes
`environment = <key>`, `managed-by = "terraform"` and `component = "signalloom"` for every
environment and the root publishes them. Whether every *resource* carries them is a property of
the modules that own resources (F3, F4, F5, F6) consuming `each.value.labels`. The bats file
asserts the contract half and says so in the test name.

## ISCs not met

- **ISC-61** ("every resource name in the environment module interpolates the environment key").
  Not claimable here. `modules/env-contract` declares no resources — it is a type, its rules and
  its derived names. The mechanism that satisfies ISC-61 is `local.name_prefix[k] = "sl-${k}"`,
  which is built and tested, but the criterion is discharged by the modules that name resources
  `"${var.name_prefix}-<role>"`. **Reassign to F3/F4/F5/F6, or restate as "every resource name is
  derived from `name_prefix`".** Flagging rather than silently claiming it.

## Contract objections and deviations

1. **`terraform validate -var-file=<bad>.tfvars` cannot work, and a suite built on it would be
   vacuously green.** The chunk brief specifies that call. Measured on Terraform v1.15.8: the
   flag is accepted, the file is **ignored**, and the command exits 0 even when the tfvars
   violates a rule. `validate` does not evaluate variables at all, so it cannot evaluate a
   `validation` block. Twenty negative tests built that way would all pass while asserting
   nothing.

   Implemented with **`terraform plan`** against a throwaway, provider-free copy of the root
   under `$BATS_FILE_TMPDIR`. `plan` evaluates variables, exits non-zero, and names the rule.
   It is safe here because the copy deliberately omits `versions.tf`, `providers.tf` and
   `backend.tf`: no provider, no backend, no resource, so nothing is reachable and no credential
   is read. The suite proves that property rather than asserting it — it configures a
   `provider_installation` block naming only a non-existent filesystem mirror, so if the fixture
   ever needs a plugin, `init` fails instead of quietly reaching the network. **Orchestrator: the
   same substitution applies to any sibling chunk told to use `validate -var-file`.**

2. **Rule 6B added: `subnet_cidr` must be a `/24`.** Not one of the eleven. Contract rule 5
   requires subnet CIDRs to be *unique*, which is string uniqueness — it does not reject
   `10.10.0.0/16` alongside `10.10.1.0/24`, two distinct strings describing overlapping address
   space. The type comment already says "RFC1918 /24", so this makes the stated intent
   enforceable; with it, uniqueness implies non-overlap, because two `/24`s intersect if and only
   if they are identical. The alternative — 32-bit containment arithmetic inline in a condition
   that may not reference locals — is unreadable and easy to get subtly wrong. **If the
   orchestrator wants non-`/24` subnets, 6B must be replaced by real containment arithmetic, not
   simply dropped: dropping it reopens the overlap hole.**

3. **Rules 12 and 13 added at the root** (`ENV-RULE-12-NON-EMPTY`, `ENV-RULE-13-TARGET-ENV-EXISTS`).
   13 is mandated by §5a. 12 exists because an empty map in a mutating root is not a no-op — every
   module `for_each`es over the resolved map, so zero entries against a populated state file is a
   plan that destroys the environment.

4. **`local.target_environments` filters `module.env_contract.environments`, not
   `var.environments`.** §5a writes the filter over `var.environments`. The key set is identical
   by construction (the resolved map is a projection over the same keys), but the resolved map is
   the one carrying `name_prefix` and the merged label set, so filtering it is what lets the
   sibling modules read `each.value.<input>` directly. Same semantics, same single selected entry.

5. **`identity` is deliberately NOT filtered by `target_env`** in the commented wiring. It is
   map-aware by contract (§4) and owns project-level singletons; filtering it would mean an apply
   for demo-1 deletes demo-2's runtime service account. Called out because it is the one block
   where the §5a narrowing must *not* be applied.

## Dependency the Makefile chunk (F6) must close

`CONTRACT.md` §5a needs three mechanisms and this chunk owns one. Mechanism 1 (`target_env` plus
its existence validation) is built and tested. **Mechanisms 2 and 3 are F6's and are not
implemented here:**

- export `TF_DATA_DIR=.terraform-$(ENV)` for every terraform invocation, so two environments
  cannot share a cached backend pointer;
- after `init`, read the resolved backend prefix back from `$(TF_DATA_DIR)/terraform.tfstate` and
  assert it contains `$(ENV)`, aborting non-zero on mismatch.

`output "target_env"` is published for exactly that comparison
(`terraform output -raw target_env` vs `$(ENV)` vs the prefix suffix). **Until all three exist,
`target_env` narrows the blast radius but does not guarantee the state file being written belongs
to the environment named in the tfvars.** This is the highest-risk open item in the chunk.

## Verification actually run

| Check | Result |
|---|---|
| `terraform fmt -recursive -check` on both owned trees | clean |
| `terraform init -backend=false && terraform validate` on `terraform/modules/env-contract` | Success |
| `terraform init -backend=false && terraform validate` on `terraform/environments` | Success (with all sibling blocks commented) |
| `tflint --chdir` on both | rc=0, no findings |
| `terraform test` in `terraform/modules/env-contract` | 28/28 passing, 0.6s, mocked providers |
| `terraform test` in `terraform/environments` | 12/12 passing, 0.5s, mocked providers |
| `bats test/terraform-environment-keys.bats` | 37/37 passing, ~3s, offline |

**Falsification — the suite was proven able to fail**, five ways, each against a throwaway copy
of the tree under `/tmp` (never the real tree, which would risk reverting in-progress work):

| Mutation | Result |
|---|---|
| Delete the rule-9 (`0.0.0.0/0`) validation block | test 17 red: "expected ipv4-any.tfvars to be REJECTED, but the plan succeeded" |
| Rename rule 4's error tag | test 11 red |
| Weaken rule 13 to `var.target_env != ""` | test 26 red: "rule tags fired: [] / wanted: [ENV-RULE-13-TARGET-ENV-EXISTS]" |
| Drop `if k == var.target_env` from the for_each | test 27 red |
| Plant `access_config` in committed source | test 33 red |
| Modify (not just add) a line in the two-environment example | test 29 red |
| Retype `environments` as `map(any)` | test 35 red |
| Unmutated control | 37/37 green |

The native suites were falsified the same way, also against a throwaway copy: deleting rule 9,
weakening rule 11's upper bound, breaking the `target_env` filter, and making `name_prefix` drop
the key each produced a precise red; the control stayed 28/28 and 12/12.

### One finding worth carrying to the other chunks

**Three assertions in the bats file were dead, and the suite was green because of it.** Under bash
`errexit` (which bats enables), a command whose exit status is inverted with `!` is *exempt* from
erroring out. So a bare `! grep forbidden_thing file` that is not the last line of a test never
fails: grep finds the forbidden thing, `!` turns that into a non-zero status, and the test carries
on to the next line and passes. The three affected assertions were the forbidden-construct check,
the purely-additive check, and the `map(any)` check — three of the anti-criteria checks, i.e.
exactly the ones whose whole job is to catch a violation.

They were found only by planting violations and watching the suite stay green. Every negation in
the file now carries an explicit `|| { echo …; return 1; }` and each was re-falsified individually.
**Any sibling chunk writing `! grep …` in a bats test has the same latent bug.** Worth a sweep
before merge.

A second, smaller one: the same test originally ran `grep -r` over `terraform/environments`, which
walks `.terraform/` — and the downloaded google provider binary contains the literal string
`access_config`. The guard's verdict therefore depended on whether anyone had recently run `init`.
Now scoped with `--include='*.tf' --include='*.tftest.hcl' --exclude-dir='.terraform'`.

Related, from the native suites: `terraform test` **skips every remaining `run` block after the
first failure** in a file (observed: one failure, six skipped). A single red therefore hides the
status of everything below it — read the first failure, not the pass count.

## Prohibitions honoured

No `apply`, no `destroy`, no `init` against a real backend, no `gcloud` invocation of any kind.
No real project ID, domain or IP anywhere — RFC5737 (`192.0.2.0/24`, `198.51.100.0/24`), RFC3849
(`2001:db8::/32`) and RFC2606 (`.invalid`) only, asserted by two tests. No `/home/andy` path in
any committed file, asserted. No file created under `terraform/bootstrap`, `terraform/platform`,
or any `terraform/modules/` directory other than `env-contract`. `Makefile`, `scripts/ci/*` and
every pre-existing file under `test/` untouched. Commits unsigned (`--no-gpg-sign`).

`.gitignore` needs a `.terraform/` entry — F1 owns that file, so this chunk did not add one and
instead removed the generated `.terraform/` directories before committing.

## Known gaps

- The chunk brief predates §7a and asked only for the bats surface. The native suites cover the
  eleven rules, `target_env`, `project_id` and extensibility; they do **not** yet cover the
  `.tfvars.example` files themselves (those are text, checked by bats) and cannot cover the
  commented-out module wiring, which by definition evaluates to nothing until it is uncommented.
- `shellcheck` was not run on the bats file. `.bats` is not POSIX shell — `@test` is bats syntax
  and shellcheck cannot parse it. No shell script was added by this chunk, so §9's shellcheck
  criterion has no subject here.
- The `terraform/environments` root validates in its **commented** state only. That is the
  intended hand-off state, but it means the commented blocks' input names are checked against
  `CONTRACT.md` §4 by eye, not by Terraform. `WIRING.md` step 1-5 with a `validate` after each is
  what converts that from eye to machine, and it must be done one block at a time.
