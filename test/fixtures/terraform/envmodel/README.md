# `envmodel` fixtures

Inputs for `test/terraform-environment-keys.bats`. Nothing here is applied, planned against a
real backend, or referenced by any shipping Terraform code.

## Shape

`tfvars/base.tfvars` is the valid baseline: two environments, `demo-1` and `ci-2`, with
documentation-range addresses and a placeholder-free project ID. Every other file is
`base.tfvars` with **one** thing changed, and the change is stated in the file's own header.
`diff tfvars/base.tfvars tfvars/<mutant>.tfvars` is the readable statement of what each fixture
tests.

Two files are hand-written rather than mutated, because their mutation deletes a structure
rather than changes a value:

- `tfvars/environments-empty.tfvars` — the map is `{}`.
- `tfvars/two-environment.tfvars` and `tfvars/two-environment-target-demo-2.tfvars` — valid
  inputs proving a second environment costs no Terraform source change, and that `target_env`
  actually selects between them.

## Why the fixtures are committed rather than generated at test time

A generator would be shorter. It would also mean the mutation lives in a shell expression that
can stop matching: a renamed field or a reindented line turns a targeted mutation into a silent
no-op, the fixture becomes a copy of the baseline, and the test that was supposed to prove a
rejection is now asserting against valid input. That direction fails loudly here (the plan
succeeds where a rejection was expected), but only because the suite happens to check the exit
code — it is not a property worth relying on. Committed fixtures make each mutation visible in
review and in `git log`.

The suite defends the remaining risk directly: one test asserts every mutant differs from the
baseline by at least one and at most four non-comment lines, so a fixture that has quietly
drifted away from being a single mutation is caught rather than trusted.

## The rule tag contract

Each validation block's `error_message` opens with a stable tag — `ENV-RULE-04-HOSTNAME-UNIQUE`,
`PROJECT-RULE-01-PLACEHOLDER`, and so on. The tests assert on the tag, not on prose, and each
negative test declares the **exact set** of tags it expects rather than merely requiring one to
be present. A mutant that trips a second, unrelated rule has stopped testing the rule it is
named for, and the suite says so.

Renaming a tag is therefore a test-visible change. That is deliberate: the tags are the only
thing standing between "the plan failed for the reason we think" and "the plan failed".
