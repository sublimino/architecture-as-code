# preserve fixtures

A miniature module graph used by `test/terraform-preserve-guards.bats` to prove the
destroy-preservation scanner can go RED.

The scanner walks the transitive local-module closure of a Terraform root and reports every
`google_storage_bucket`, `google_secret_manager_secret` and `google_secret_manager_secret_version`
resource it finds. Run against `terraform/environments` it must find nothing. That is an
absence assertion, and an absence assertion passes hardest when the thing doing the looking is
broken — so these fixtures give it something to find.

* `root/` calls all three modules below, exactly as the real environments root calls its modules.
* `leaky-bucket/` declares a bucket. Two decoys sit beside it: a `google_storage_bucket_iam_member`
  and a commented-out bucket, neither of which may be reported.
* `leaky-secret/` declares a secret and a secret version. Its decoy is
  `google_secret_manager_secret_iam_member` — the resource type the real `modules/compute` uses,
  which binds IAM on a secret it does not own and must never be flagged.
* `clean-module/` declares neither, and reads the auth key through a `data` source the way
  `modules/compute` really does.

These are never planned, validated or formatted: they live outside `terraform/`, which is the
only tree `make gcp-tf-validate` discovers.
