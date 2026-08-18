# `vm-profile` fixtures

Mutation inputs for `test/terraform-vm-profile.bats`.

Each file here is a *deliberately broken* startup script: it does something the
real `terraform/modules/compute/startup/demo-vm.sh` must never do. They exist so
the guard can be proven to fail, on a copy, without ever mutating the real tree
(`terraform/CONTRACT.md` §7).

One file per forbidden verb rather than one file containing all of them. A
single combined fixture would still fire if four of the five patterns worked and
the fifth had a typo in it — which is precisely the defect a mutation check is
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
naming `make demo-signalloom-up` in prose; a guard that matched raw text would
fire on that documentation and report the correctly-written script as broken.
`hides-it-in-a-comment.sh` must produce ZERO findings.
