# `test/fixtures/terraform/netcompute`

Deliberately broken Terraform, plus one deliberately clean control. These exist so
`test/terraform-network-security.bats` can prove its guards **fail** when they should.

**Nothing here is ever applied, validated, or formatted as part of the real tree.** These
files live outside `terraform/`, so `terraform fmt -recursive -check terraform/` and every
scanner scoped to `terraform/` ignore them by construction. Do not move them under
`terraform/` — a fixture carrying a real `access_config` would then be caught by the guard it
exists to test, and the suite would fail for the wrong reason.

| File | Carries | Proves |
|---|---|---|
| `broken-access-config.tf` | An `access_config {}` block on an instance | `scan_access_config` reports a violation |
| `broken-wide-firewall.tf` | A firewall `allow` rule sourced from `0.0.0.0/0` | `scan_wide_open_allow` reports a violation |
| `clean-control.tf` | Neither | Both scanners return clean — they are not always-fail |

The clean control is the one people forget. A guard that always fires is exactly as useless
as one that never does, and without a negative control you cannot tell the two apart from a
red test run.

## Do not "fix" these files

Each mutation test asserts its fixture **still contains** the violation before using it. A
well-meaning cleanup pass that removes the `access_config` from
`broken-access-config.tf` will fail that staleness assertion rather than silently disarming
the mutation check.

## Relationship to the generated mutations

The bats file also runs two mutations generated at test time by copying the live
`terraform/modules/*/main.tf` into `BATS_TEST_TMPDIR` and breaking the copy. Those can never
go stale, because they derive from whatever the module says today. These committed fixtures
are the chunk contract's explicit requirement and cover the case where the live modules are
restructured enough that the generated mutation's `sed` no longer matches — at which point
the generated test's positive control fails loudly, and these still hold the line.
