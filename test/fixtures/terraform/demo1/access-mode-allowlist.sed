# Mutation fixture: flip demo-1 from IAP-gated to allowlist-only.
#
# `allowlist` is one of the three LEGAL values of access_mode, and that is what
# makes it the right mutation. An illegal value ("public", which this fixture
# used to write, is not a value at all) would be caught by the variable
# validation regardless, so a guard could pass it without ever having looked.
# `allowlist` plans cleanly and quietly removes authentication, leaving an IP
# allowlist that admits anyone on an allowlisted network as anyone.
#
# It is also the change most likely to be made by accident — by someone
# debugging a 403 they believe is a broken deploy when it is IAP working.
#
# The suite applies this to a COPY and asserts the posture check goes red. A
# guard that has never been observed failing is a guard nobody has tested.
s/^access_mode = "iap"$/access_mode = "allowlist"/
