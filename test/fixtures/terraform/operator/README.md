# `test/fixtures/terraform/operator/` — deliberately broken copies

Each directory below holds one `main.tf.fixture` with exactly **one** invariant
broken. `test/terraform-operator-access.bats` asserts that the corresponding
guard **fails** on the broken copy — which is the only thing that proves the
guard is capable of failing at all.

The `.fixture` suffix keeps them out of `terraform fmt -recursive`, `terraform
validate`, `tflint` and the `terraform test` discovery sweep. They are text for
a grep, not configuration.

| Directory | Invariant broken | Guard it must trip |
|---|---|---|
| `clean/` | none — this is the paired positive | every guard must stay **silent** here |
| `org-iam-member/` | declares organisation-scoped IAM | `org_iam_declarations` |
| `org-iam-commented/` | names the org resource **in a comment only** | `org_iam_declarations` must stay **silent** |
| `project-scoped-act-as/` | `roles/iam.serviceAccountUser` via `google_project_iam_member` | `project_scoped_act_as` |
| `service-account-key/` | declares `google_service_account_key` | `sa_key_declarations` |
| `estate-admin-role/` | `roles/compute.admin` in the operator role list | the forbidden-role loop |
| `legacy-role/` | a `roles/*legacy*` role | the legacy-role guard |

`clean/` and `org-iam-commented/` are as important as the broken ones. A guard
that fires on everything satisfies every mutation check above while being
useless on the real tree, and a guard that cannot tell a declaration from a
comment forbidding it gets deleted the first time it cries wolf.

These are written by hand. There is no `GENERATE.sh` here because none of them
is a mutation of a specific real file — each is the smallest possible HCL that
expresses one defect.
