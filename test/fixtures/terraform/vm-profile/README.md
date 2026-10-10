# `vm-profile` fixtures

Mutation inputs for `test/terraform-vm-profile.bats`.

Each file here is a *deliberately broken* startup script: it does something the
real `terraform/modules/compute/startup/demo-vm.sh` must never do. They exist so
the guard can be shown to fire on each forbidden verb in isolation.

**They are not a substitute for mutating the real file.** `terraform/CONTRACT.md`
§7b used to mandate fixture-only mutation and now says the opposite. That
rule produced three dead assertions in a single task on 2026-08-20. A fixture
mutation only asks whether a scanner detects a string in a written file. It
can never ask whether the guarded item exists in the shipped code. Fixtures like
these remain the right tool for a scanner's edge cases. They also test defects
that cannot exist in the real tree, such as `hides-it-in-a-comment.sh` below.
But the guard is not proven until the real file is mutated. The right test must
fail for the right reason. Follow the procedure in §7b. Copy to a path outside
the repository. Restore from that copy rather than `git checkout`. Check that
the mutation applied before you trust the result.

One file per forbidden verb rather than one file containing all of them. A
single combined fixture would still fire if four of the five patterns worked and
the fifth had a typo in it. That is precisely the defect a mutation check is
supposed to find, and precisely the one it would then hide.

| File | The line that must be caught |
|---|---|
| `creates-a-cluster.sh` | `kind create cluster` |
| `runs-a-make-demo-target.sh` | `make demo-…` |
| `deploys-signalloom.sh` | `demo-signalloom` |
| `installs-a-helm-release.sh` | `helm upgrade --install` |
| `bootstraps-flux.sh` | `flux bootstrap` |
| `hides-it-in-a-comment.sh` | *nothing* — every verb, all commented out |

The last one is the inverse control and it is the reason the guard strips
comments before matching. The real script's own header documents the split by
naming `make demo-signalloom-up` in prose. A guard that matched raw text would
fire on that documentation and report the correctly-written script as broken.
`hides-it-in-a-comment.sh` must produce ZERO findings.
