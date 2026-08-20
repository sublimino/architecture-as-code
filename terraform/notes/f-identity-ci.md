# F5 — identity + CI lifecycle

> **HISTORICAL — partly superseded on 2026-08-20.** This file records what chunk F5 built at
> the time and is kept for its reasoning, not as a description of the current tree.
>
> `terraform/modules/ci-runner/` **no longer exists.** It was absorbed into
> `terraform/modules/compute`, which now serves both lane kinds; CI lane instances are named
> `sl-<key>-vm` rather than `sl-<key>-runner`. Consequently
> `scripts/ci/gcp-tf-reaper.sh` no longer selects on the instance name — it selects on the
> `ci-lane` label, and the gate list at the head of that script is the current description.
>
> Current interfaces: `terraform/CONTRACT.md` §4 and `terraform/modules/compute/README.md`.

Branch `feat/gcp-tf-identity-ci`. Chunk: the cloud identity boundary and the CI lane lifecycle.

## What was built

| Path | What |
|---|---|
| `terraform/modules/identity/` | GitHub WIF pool + OIDC provider, per-environment runtime SAs, distinct CI plan/apply SAs, additive least-privilege IAM |
| `terraform/modules/identity/tests/identity.tftest.hcl` | 24 runs, mocked providers, plan only |
| `terraform/modules/ci-runner/` | One suspendable, IAP-only, shielded CI VM per `ci-N` lane |
| `terraform/modules/ci-runner/tests/ci_runner.tftest.hcl` | 16 runs, mocked providers, plan only |
| `scripts/ci/gcp-tf-ci.sh` | resume → test → suspend, per lane, suspend from an EXIT trap |
| `scripts/ci/gcp-tf-reaper.sh` | suspends lanes running past `--idle-minutes`, four gates |
| `test/terraform-identity.bats` | 31 tests — whole-tree absence properties + 9 mutation fixtures |
| `test/terraform-ci-lifecycle.bats` | 25 tests — fake-client lifecycle and reaper |
| `test/fixtures/terraform/identity/**` | mutation fixtures, `.fixture` suffix, plus a `clean/` control |
| `test/fixtures/gcp-tf-ci/**` | stub `gcloud`, stub test runners, adversarial instance list, script digests |

Commits: `7feab3c` (modules + tftests), `d02e3ba` (scripts + bats + fixtures + READMEs),
`d020506` (these notes), `346eeda` (home-path guard fix — finding 3).

## Verification actually run

```
terraform fmt -recursive -check terraform/modules/{identity,ci-runner}   clean
terraform init -backend=false && terraform validate                      both modules: valid
tflint                                                                   both modules: exit 0
terraform test  (identity)                                               24 passed, 0 failed
terraform test  (ci-runner)                                              16 passed, 0 failed
shellcheck scripts/ci/gcp-tf-{ci,reaper}.sh                              clean
bats test/terraform-identity.bats                                        31 passed  (1.1s)
bats test/terraform-ci-lifecycle.bats                                    25 passed  (4.5s)
```

Nothing touched GCP. No `apply`, no `destroy`, no `init` against a real backend, no real
`gcloud` invocation. Every `gcloud` in the tests is `test/fixtures/gcp-tf-ci/stub-gcloud`,
placed on `PATH` inside `BATS_TEST_TMPDIR` for the duration of a test.

## Proof the tests can fail

Green is the suspicious state for a suite built entirely out of guards. Each of the following
was applied to a **temporary copy** — the real tree was never mutated, and every scripted edit
asserted its pattern matched before writing.

**identity tftest, 7 mutations, all caught:** tautological `attribute_condition`; pool-wide
`principalSet` wildcard; `roles/owner` in the apply role set; `roles/storage.admin` on the state
bucket; wrong issuer URI; `repository_owner` (string name) pinned instead of
`repository_owner_id`; plan and apply sharing a role.

**ci-runner tftest, 7 mutations, all caught:** `access_config` added; vTPM off; `ci-lane` label
dropped; OS Login off; project SSH keys unblocked; deletion protection on; `service_account`
block removed.

**identity bats, 8 mutation fixtures + a clean control**, wired so the same guard function runs
against the real tree and the fixture. The `clean/` control is the one that matters: without it,
a `guard_absent` broken so that it always returns non-zero would make all eight mutation tests
pass while measuring nothing.

**lifecycle bats:** removing the suspend from the EXIT trap fails 7 tests; removing the
`SSH_AUTH_SOCK` guard fails 2; making the lock global rather than per-lane fails 2; replacing the
trap's closing `exit "$rc"` with a false conditional (the exact shape of the 2026-08-14 bug)
turns a passing run red, and that mutation is itself a committed test.

## Findings the orchestrator should know

**1. The reaper's demo protection is redundant by design, and single-gate mutation is invisible.**
Removing *any one* of the four gates changes no test outcome, because each of the others still
catches every adversarial row. Two gates must be removed before a demo VM reaches a suspend call
(`label`+`name` → the demo test fails; `name`+`denylist` → the legacy `signalloom-ci` test fails;
all three → both fail). This is the redundancy working, not a hole, but it does mean the bats
suite proves the *conjunction* is load-bearing rather than each gate individually. Recorded here
because "I removed the allowlist and nothing failed" is otherwise a very reasonable thing to
conclude is a gap.

**2. A first draft of the SIGINT test was green and measuring nothing.** bash sets `SIGINT` to
`SIG_IGN` in asynchronous children, and a non-interactive shell cannot reset it. `setsid … &`
therefore produced a process tree that ignored the signal entirely; the run completed normally
after its sleep expired and the suspend assertion passed for the wrong reason. The committed test
runs `setsid --wait` in the **foreground** with the killer in the background, and asserts
`status == 130` so a non-interrupted run cannot pass.

**3. A guard written as the literal it searches for matched its own source.** The
"no `/home/andy` in any committed file" check greps a file list that includes the bats file
holding the pattern, so it fired on itself — indistinguishable, in the output, from a real leak.
Rewritten to assemble the forbidden path from two literals. Narrowing it then surfaced a second
point worth knowing: `scripts/ci/gcp-tf-ci.sh` carries `/home/ci/osramp-demo` as the **remote**
work directory, matching `gcp-ci.sh`'s existing convention. That is legitimate and is explicitly
carved out; the prohibition is on a developer's machine leaking into a committed file. The
carve-out has its own test asserting it has not widened into "any home path is fine", and the
guard is proven to still bite by injecting a leak into a throwaway copy of the tree.

**4. `"idle"` in the reaper means uptime since last start, not keystroke idleness.** That is the
honest description and it is documented in the script header. It is the right measure here only
*because* `gcp-tf-ci.sh` suspends on every completed run, so a lane still RUNNING past the
threshold is by construction abandoned. If a future change lets lanes stay up legitimately, this
proxy stops being valid.

**5. `.terraform/` and `.terraform.lock.hcl` are not gitignored anywhere in this repo.** They are
produced by the `terraform init -backend=false` that `terraform test` requires. I removed mine
before hand-off rather than editing `.gitignore`, which F1 owns. **F1 should add `.terraform/`,
`.terraform.lock.hcl`, and `*.tfstate*`** — otherwise the first person to run the Make target
commits a provider binary.

**6. `test/fixtures/gcp-tf-ci/untouched-scripts.sha256` pins `gcp-ci.sh`, `ci-lock.sh`, and
`vm-pipeline.sh` (ISC-203).** If any of those is ever legitimately changed, refresh it with
`sha256sum scripts/ci/gcp-ci.sh scripts/ci/ci-lock.sh scripts/ci/vm-pipeline.sh > test/fixtures/gcp-tf-ci/untouched-scripts.sha256`
in the same commit. A stale digest reads as tampering.

**7. Mutation fixtures carry a `.fixture` suffix on purpose.** They contain `roles/owner`,
`google_service_account_key`, `google_project_iam_policy`, `access_config`, and `command = apply`
— exactly the strings other chunks' whole-tree guards scan for. The suffix keeps them invisible
to any `*.tf` / `*.tftest.hcl` glob. **A guard that greps every file in the repo regardless of
extension will still trip on them**; if F1's `terraform-conventions.bats` does that, it needs to
exclude `test/fixtures/`.

**8. `terraform test` requires `terraform init -backend=false` to have run in the module
directory first.** F6's Make target must do that for `terraform/modules/identity` and
`terraform/modules/ci-runner` before invoking `terraform test`, or the target fails on a clean
checkout.

## Contract objections

Implemented as written; recorded here per CONTRACT §preamble.

**O1 — `modules/identity` needs an input the frozen §4 table does not have.** §5c requires the
CI principals to hold `roles/storage.objectAdmin` on the state bucket, but §4's identity
interface has no way to name that bucket. Added `state_bucket_name` with default `""`, which
disables the binding, so no §4-conformant caller breaks. **The platform root must pass it or §5c
is unenforced at runtime** — the tftest covers both the bound and unbound paths.

**O2 — §4 has no input for the named principals ISC-177/178 require.** "IAP TCP tunnel access is
granted to named principals" needs a list of principals. Added `operator_members` (default `[]`,
validated to reject `allUsers`/`allAuthenticatedUsers`) and `operator_roles`. The per-environment
runtime SAs get the same two roles unconditionally, so the ISCs hold even with the default.

**O3 — §3 and §4 disagree about naming for `modules/identity`.** §3 says every resource names
itself `"${var.name_prefix}-<role>"`, but §4 gives identity neither `name_prefix` nor `labels`
because it is map-aware. Identity therefore derives its own deterministic ids (`sl-rt-<key>`,
`sl-ci-plan`, `sl-ci-apply`) from a single local, so the account ids, the IAM member strings and
the outputs cannot drift. Service accounts also cannot carry labels, so the §3 labelling rule is
inapplicable to most of this module. Suggest §4 gain `name_prefix` for identity, or §3 gain an
explicit carve-out.

**O4 — `modules/ci-runner` cannot set `labels = var.labels` verbatim.** ISC-184 requires
`ci-lane = <key>`, which is not in §3's mandatory set. It sets
`merge(var.labels, { ci-lane = var.environment_key })` and a `lifecycle` precondition asserts the
merge came out equal to the key. Suggest §3's `mandatory_labels` gain `ci-lane` for `kind == "ci"`.

**O5 — other additive, defaulted inputs.** `runtime_roles`, `ci_plan_roles`, `ci_apply_roles`,
`pool_id` (identity) and `boot_image` (ci-runner). All defaulted; all validated against
owner/editor/storage.admin/osAdminLogin. They exist so the role sets are testable data rather
than literals buried in resource bodies.

**O6 — six chunks writing a root `NOTES.md` will collide at merge.** Written as instructed.
Suggest the orchestrator rename on merge, or ask for `NOTES-<chunk>.md` next time.

## ISCs claimed

**155–182, 184–202** — satisfied and tested.
**203** — satisfied via the committed digest check (finding 5).
**329, 330, 332, 334, 346, 350** — satisfied. Every `expect_failures` run in both files is paired
with an adjacent positive run proving the corrected input passes (ISC-346): 6 pairs in identity,
3 in ci-runner.

## ISCs not fully met

**ISC-183 — "each CI lane gets its own service account": satisfied only across a module
boundary.** `modules/identity` creates one SA per environment key, including every `ci-N`;
`modules/ci-runner` consumes an email and validates it non-empty (an empty value would silently
attach the default Compute Engine SA, which holds `roles/editor` — a privilege escalation, not a
no-op). Nothing in *my* two modules forces the root to wire lane `ci-1` to
`runtime_service_account_emails["ci-1"]` rather than to some other lane's SA. **The environments
root — F2/F6 — must make that wiring, and it should carry a tftest asserting the lane's SA email
embeds the lane key.** My ci-runner tftest asserts that property on the value it is given, which
catches a wrong-lane wiring only if the root passes something lane-shaped.

**ISC-194 — reaper exists as a script, not as Cloud Scheduler config.** The ISC permits either.
A scheduled invocation belongs in `terraform/platform` or `.github/workflows/`, both F6's. F6
should schedule `scripts/ci/gcp-tf-reaper.sh --idle-minutes N`; until then the reaper only runs
when somebody runs it, and the KPI rests on `gcp-tf-ci.sh`'s trap alone.

**ISC-179 — documented, not executed.** `terraform/modules/identity/README.md` gives the exact
steps (throwaway repo under a different org, wrong ref, right ref, plus the `gcloud logging read`
that confirms the refusals). It cannot run before the first real apply, and the proposal's
approval gate has not been passed. **Do not treat the WIF pinning as verified until all three
outcomes in that section have been observed and recorded in `terraform/SECURITY.md`** — steps 1
and 2 alone are indistinguishable from a provider that refuses everything, which is a broken
deployment rather than a secure one.
