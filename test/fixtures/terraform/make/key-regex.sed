# Mutation: widen the environment-key regex so `prod-1` becomes a valid key.
# Minimal and exact — it changes nothing but the guard under test.
# Expected effect: `make gcp-tf-apply ENV=prod-1` stops aborting.
s#(demo|ci)-#(demo|ci|prod)-#
