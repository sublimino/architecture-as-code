# MUTANT of base.tfvars. The environments map is empty.
#
# Written by hand rather than generated, because the mutation deletes a
# structure rather than changing a value.
#
# An empty map is not an inert no-op in a mutating root. Every module call
# for_eaches over the resolved map, so an empty map means zero resources are
# declared — and against a populated state file, zero declared resources is a
# plan that destroys every resource in the environment. Expect ENV-RULE-12 and
# ENV-RULE-13 (target_env cannot name a key of an empty map).

project_id = "sl-demo-platform"
target_env = "demo-1"

environments = {}
