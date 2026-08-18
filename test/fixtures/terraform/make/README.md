# Makefile mutation fixtures

Each `.sed` file is a **single, minimal, named mutation** to the repository
Makefile. `test/terraform-make-contract.bats` and
`test/terraform-suite-registration.bats` copy the real Makefile into a temporary
directory, apply one of these programs, and assert that the guard they exercise
then *fails*. The real tree is never modified.

Two properties make these fixtures trustworthy, and both are enforced in code:

1. **The mutation must actually apply.** A `sed` program whose pattern no longer
   matches silently no-ops and prints nothing — the mutation check would then
   run against an unmutated Makefile and pass, which is a green test measuring
   nothing. The `apply_mutation` helper diffs the result and fails if it is
   identical to the original. So if a Makefile edit breaks one of these
   patterns, the suite goes red and names the fixture, rather than quietly
   ceasing to test anything.

2. **The mutation must be minimal.** Each program changes one guard. A mutation
   that broke the Makefile outright would make every target fail, and "the
   target failed" would no longer be evidence about the guard.

| Fixture | Guard it disables |
|---|---|
| `key-regex.sed` | The `^(demo\|ci)-[1-9][0-9]*$` environment-key regex. |
| `confirm-check.sed` | `gcp-tf-destroy`'s typed-confirmation match. |
| `prefix-assert.sed` | CONTRACT §5a mechanism 3, the post-init backend-prefix readback. |
| `tf-data-dir.sed` | CONTRACT §5a mechanism 2, the per-environment `TF_DATA_DIR`. |
| `bare-apply.sed` | `gcp-tf-apply`'s saved-plan-file requirement. |
| `bats-hand-list.sed` | The `test/terraform-*.bats` glob (reverts to a hand list). |
| `tftest-hand-list.sed` | The `tests/*.tftest.hcl` directory discovery. |

To add a mutation: write the `.sed`, add a row above, and add the bats case that
asserts the guard fails under it. A fixture with no test that consumes it is
dead weight; `terraform-suite-registration.bats` asserts every fixture here is
referenced by at least one suite.
