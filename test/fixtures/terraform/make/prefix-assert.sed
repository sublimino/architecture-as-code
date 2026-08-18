# Mutation: make the post-init readback report ENV regardless of what the
# backend actually resolved to, neutering CONTRACT section 5a mechanism 3.
# Expected effect: a backend prefix naming demo-9 no longer aborts an ENV=demo-1
# plan -- which is exactly the silent cross-environment write the mechanism
# exists to stop.
s#resolved="$$(sed#resolved="$(ENV)"; unused="$$(sed#
