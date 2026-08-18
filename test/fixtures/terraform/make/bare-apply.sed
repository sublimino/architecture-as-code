# Mutation: apply without the reviewed plan file.
# Expected effect: `terraform apply -auto-approve` re-plans at apply time, so
# what a human reviewed and what Terraform executes are two different plans.
s#apply $(GCP_TF_PLAN_FILE)#apply -auto-approve#
