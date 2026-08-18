# Mutation fixture: flip demo-1 from IAP-gated to publicly reachable.
#
# This is the one-line change that turns "secure, routable, not publicly
# accessible" into "publicly accessible", and it is the change most likely to be
# made by accident — by someone debugging a 403 they believe is a broken deploy
# when it is IAP working correctly.
#
# The suite applies this to a COPY and asserts the posture check goes red. A
# guard that has never been observed failing is a guard nobody has tested.
s/^access_mode = "iap"$/access_mode = "public"/
