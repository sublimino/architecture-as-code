# The backend block is EMPTY on purpose. See `terraform/CONTRACT.md` §5.
#
# An empty `backend "gcs" {}` cannot be initialised without
# `-backend-config=bucket=<x> -backend-config=prefix=osramp/environments/<key>`
# on the command line. That is the whole point: this root is applied once per
# environment, and the failure mode it prevents is "forgot to re-init between
# environments", which silently reuses the previous environment's state and
# then proposes destroying everything in it. With no prefix baked in, the
# operator cannot reach `apply` without having named the environment.
#
# It lives in its own file rather than in versions.tf so that versions.tf stays
# byte-identical to the pinned block in CONTRACT.md §2, which F1's conventions
# test greps for. Terraform merges multiple `terraform` blocks; only
# `required_providers` is restricted to a single occurrence.
#
# `terraform init -backend=false` — the only init form agents may run — skips
# this block entirely, which is why validate works here with no credentials.

terraform {
  backend "gcs" {}
}
