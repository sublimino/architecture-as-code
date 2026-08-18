# Mutation: replace the terraform-test directory discovery with a hand-written
# list, so a module that ships a tests/ directory is silently never swept.
# Expected effect: `make gcp-tf-test-unit` runs one directory instead of all.
s#^GCP_TF_TEST_DIRS = .*#GCP_TF_TEST_DIRS = terraform/platform#
