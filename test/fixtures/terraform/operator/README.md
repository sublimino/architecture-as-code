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
| `instance-admin-role/` | `roles/compute.instanceAdmin.v1` — 529 permissions to deliver one verb | the instance-admin guard |
| `overreaching-custom-role/` | extra permissions inside the custom role, role COUNT unchanged | `lifecycle_role_mutating_permissions` |

`clean/` carries a **well-formed** `google_project_iam_custom_role` as well as the
two predefined grants. That is deliberate: `lifecycle_role_mutating_permissions`
must stay silent on a legitimate suspend/resume role, and a guard that fired on
every custom role would satisfy the `overreaching-custom-role/` mutation check
while being useless on the real module.

`overreaching-custom-role/` is the case no *role* count can reach. It declares
exactly one custom role, so the budget in
`terraform/modules/operator-identity/tests/operator_identity.tftest.hcl` still
reads three project roles and four total. Only the permission list inside the
role changed — which is why that suite pins the permission list by exact count
and exact membership as well.

`clean/` and `org-iam-commented/` are as important as the broken ones. A guard
that fires on everything satisfies every mutation check above while being
useless on the real tree, and a guard that cannot tell a declaration from a
comment forbidding it gets deleted the first time it cries wolf.

These are written by hand. There is no `GENERATE.sh` here because none of them
is a mutation of a specific real file — each is the smallest possible HCL that
expresses one defect.
