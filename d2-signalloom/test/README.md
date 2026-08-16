# Signal Loom skeleton validation

`validate-topology.sh` verifies ownership boundaries, local-fleet composition,
and Kustomize render entry points. It does not contact a cluster.
`topology.bats` is its deterministic regression suite.

The repository-root `test/bao-spire-proof.bats` is a deterministic fake-kubectl
harness for the Phase 3 Bao/SPIRE proof. It covers the positive identity,
denied negative identity, terminal failure, and both log markers. It does
not provision or change a Kind cluster.
