# Signal Loom skeleton validation

`validate-topology.sh` verifies ownership boundaries, local-fleet composition,
and Kustomize render entry points. It does not contact a cluster.
`topology.bats` is its deterministic regression suite.

The repository-root `test/bao-spire-proof.bats` is a deterministic fake-kubectl
harness for the Phase 3 Bao/SPIRE proof. It covers the positive identity,
denied negative identity, terminal failure, and both log markers. It does
not provision or change a Kind cluster.

## Multi-plane containment acceptance (SLER-P6-3)

The end-to-end acceptance suite for multi-plane containment is **not** in this
directory. Go requires a `package main` test to sit beside its package, so it
lives at `apps/fleet-manager/multiplane_acceptance_test.go`, selected by
`go test -run TestAcceptance`. Looking for it here is the obvious mistake, hence
this pointer.

It drives one containment decision across all five enforcement planes and
asserts each `PlaneResult` individually. Two things about it are worth knowing
before reading it:

- Its plane coverage is **derived** from `AllEnforcementPlanes()` in
  `apps/fleet-manager/schema.go`, never from a list. Adding a sixth plane fails
  the suite until a scenario claims it.
- Every latency bound is read from `docs/signalloom/sler-p5-2-denial-matrix.json`
  — P5-2's machine-readable export, not the prose sibling — so a re-benchmark
  flows through with no edit to the suite. The export keys OpenBao as `openbao`
  while its `plane` field is `bao`, so the index reads the **field**; keying on
  the object key leaves that plane unbound and its assertion silently skipped.

`test/sler-p6-3-multiplane-acceptance.bats` (repository root) is the wiring
guard: it re-derives the plane set from `schema.go` with an independent parser
and asserts the suite is reachable from a make target, a CI stage, the offline
lane and the red-team runner. Full design: `docs/signalloom/sler-p6-3-proof.md`.
