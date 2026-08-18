# `modules/ci-runner` — one suspendable CI VM per named lane

A CI lane is a disposable, IAP-only, shielded VM that `scripts/ci/gcp-tf-ci.sh`
resumes for a run and suspends afterwards. One instance per `ci-N` key, so `ci-1`
and `ci-2` never contend.

## Inputs

Frozen by `terraform/CONTRACT.md` §4: `project_id`, `environment_key`,
`name_prefix`, `labels`, `zone`, `machine_type`, `boot_disk_gb`,
`subnet_self_link`, `network_tag`, `service_account_email`,
`idle_suspend_minutes`. `boot_image` is an optional addition with a default.

## Outputs

`instance_name`, `instance_self_link`, and `ci_lane_label` — the last so callers
and tests can assert the reaper's selector matches what was actually built.

## The three things that are easy to get wrong

**`deletion_protection = false`.** Deliberately the opposite of the demo VM. A
lane that cannot be deleted outlives the branch that needed it and bills quietly.
Lanes are cattle.

**`service_account_email` is required and validated non-empty.** Omitting the
`service_account` block does not produce a VM with no identity — it produces one
running as the default Compute Engine service account, which holds `roles/editor`
on the entire project. An empty string here is therefore a privilege escalation,
not a no-op, which is why the validation rejects it rather than defaulting.

**`ci-lane = <key>` is load-bearing.** `scripts/ci/gcp-tf-reaper.sh` selects on
this label. It is merged *over* the contract's mandatory label set, and a
`lifecycle` precondition asserts the merge came out equal to the environment key.
`environment_key` itself is validated against `^ci-[1-9][0-9]*$`, so this module
is structurally incapable of building a demo environment that the reaper would
then be entitled to suspend.

## Hardening

No `access_config` (no external IP; ingress via IAP only). OS Login on,
project-wide SSH keys blocked — the second is what makes the first exclusive,
because without it a project key still gets in. Shielded VM with all three fields
set: secure boot, vTPM, and integrity monitoring.

`idle_suspend_minutes` is published as instance metadata rather than duplicated
as a constant in the reaper, so a lane cannot disagree with the reaper about its
own idle budget.

## Tests

`tests/ci_runner.tftest.hcl` — 16 runs, mocked providers, `command = plan` only,
asserting the evaluated instance. Verified failable against seven independent
mutations (external IP added, vTPM off, `ci-lane` label dropped, OS Login off,
project keys unblocked, deletion protection on, service account block removed) —
each was caught.
