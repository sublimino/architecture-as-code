# Mutation: make gcp-tf-handoff's "did every required field resolve?" test always
# false, so an incomplete hand-off is written instead of refused.
# Expected effect: deploy/gcp/<env>.handoff.json appears with blank fields. The
# test suite then parses it successfully and reports on an estate it never
# reached, which is strictly worse than having no hand-off at all.
s#-n "$$missing"#-n ""#
