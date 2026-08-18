# Mutation: make the post-init readback report the EXPECTED prefix regardless of
# what the backend actually resolved to, neutering CONTRACT section 5a mechanism 3.
# Expected effect: a backend prefix naming demo-9 no longer aborts an ENV=demo-1
# plan -- which is exactly the silent cross-environment write the mechanism
# exists to stop.
#
# This forges the full prefix, not the bare key. It used to forge `$(ENV)` alone,
# which was enough only because the real guard was a substring match
# (`case "$resolved" in *"$(ENV)"*`) -- a form that also passed for
# osramp/environments/demo-10 when ENV was demo-1. The guard is now exact
# equality against $(GCP_TF_PREFIX), so a mutation that wants to defeat it has to
# produce that exact string. Forging the key alone no longer neuters anything,
# which is the guard getting stronger rather than the mutation being wrong.
s#resolved="$$(sed#resolved="$(GCP_TF_PREFIX)"; unused="$$(sed#
