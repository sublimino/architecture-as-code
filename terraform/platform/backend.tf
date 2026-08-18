# The backend block is EMPTY on purpose. See terraform/CONTRACT.md section 5.
#
# A partially-configured backend makes it impossible to run anything in this
# root without having named a bucket and a prefix on the command line. That is
# what stops "I forgot to re-init after switching environments" from silently
# reusing the previous state — the failure mode that turns a demo teardown into
# a platform teardown.
#
# Initialised by `make gcp-tf-*`, which always passes both:
#
#   terraform -chdir=terraform/platform init -reconfigure \
#     -backend-config=bucket=<state-bucket> \
#     -backend-config=prefix=osramp/platform
#
# The bucket itself is created by terraform/bootstrap, which has no backend
# block at all and keeps local state. A root cannot own the bucket that holds
# its own state.
terraform {
  backend "gcs" {}
}
