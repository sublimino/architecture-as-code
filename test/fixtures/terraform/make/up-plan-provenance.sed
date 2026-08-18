# Mutation: point gcp-tf-up's freshness comparison at a sentinel path that is
# never created, which is what a typo'd or dropped `touch` would produce.
# Expected effect: `test FILE -nt MISSING` is true whenever FILE exists, so the
# check degrades into a bare existence test — and any plan file at all, including
# one left over from a previous run or restored by an editor, gets applied.
s#-nt '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/.up-sentinel'#-nt '$(TF_ROOT_ENV)/$(GCP_TF_DATA_DIR)/.sentinel-that-is-never-created'#
