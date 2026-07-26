# Signalloom skeleton validation

`validate-topology.sh` verifies ownership boundaries, local-fleet composition,
and Kustomize render entry points without contacting a cluster. `topology.bats`
is its deterministic regression suite.

The repository-root `test/bao-spire-proof.bats` is a deterministic fake-kubectl
acceptance harness for the Phase 3 Bao/SPIRE proof. It covers the expected
positive identity, denied negative identity, terminal failure, and both log
markers without provisioning or changing a Kind cluster.
