# Mutation: replace the bats glob with a hand-maintained list -- the exact
# regression that left 33 suites in this repo committed, documented and never
# executed.
# Expected effect: a terraform bats file on disk is no longer run by
# `make gcp-tf-validate`.
s#^GCP_TF_BATS = $(sort $(wildcard test/terraform-\*.bats))#GCP_TF_BATS = test/terraform-make-contract.bats#
