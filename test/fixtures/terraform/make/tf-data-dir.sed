# Mutation: drop the environment suffix from the per-environment data dir,
# reverting CONTRACT section 5a mechanism 2. Two environments then share one
# cached backend pointer again.
# Expected effect: terraform runs with TF_DATA_DIR=.terraform for every ENV.
s#^GCP_TF_DATA_DIR = $(TF_DATA_DIR_BASE)-$(ENV)#GCP_TF_DATA_DIR = $(TF_DATA_DIR_BASE)#
