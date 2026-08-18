# Mutation fixtures for `test/terraform-identity.bats`

Each subdirectory holds one deliberately-broken copy of a fragment of
`terraform/modules/identity`. The bats suite runs the *same* guard function it
runs against the real tree, and asserts it FAILS here. Without that, a guard
that greps for a forbidden construct is indistinguishable from a guard whose
`find` matched no files at all.

`clean/` is the control: the same guards must PASS against it, which proves the
mutation failures come from the injected defect and not from the fixture
mechanism itself.

Every file carries a `.fixture` suffix (`main.tf.fixture`, not `main.tf`) on
purpose. These files contain `roles/owner`, `google_service_account_key`, and
`command = apply` — exactly the strings other chunks' whole-tree guards scan
for. The suffix keeps them invisible to any `*.tf` / `*.tftest.hcl` glob while
the bats suite addresses them explicitly.

Nothing here is ever applied, validated, or initialised.
