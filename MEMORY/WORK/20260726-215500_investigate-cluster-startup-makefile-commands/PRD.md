---
task: Slim cluster startup and update demo lifecycle tests
slug: 20260726-215500_investigate-cluster-startup-makefile-commands
effort: advanced
phase: complete
progress: 24/24
mode: interactive
iteration: 1
started: 2026-07-26T21:55:00+01:00
updated: 2026-07-26T22:11:00+01:00
---

## Context

Make-based cluster startup must create only the shared cluster foundation; it must not reconcile olly, Signalloom, or OSRAMP demo workloads. Startup must print the available opt-in demo commands, prove cluster readiness through a health check, and preserve `make demo-signalloom-up` as the explicit Signalloom activation path. Existing tests must describe and verify this new lifecycle format.

### Risks

- Flux bootstrap may still reconcile workload ResourceSets after root prerequisites change.
- Existing lifecycle scripts may rely on resources formerly started implicitly.
- Fake-client tests may assert the legacy default bootstrap graph.

### Plan

1. Trace bootstrap, demo activation, and demo deactivation scripts.
2. Make the checked-in ResourceSet inputs empty by default.
3. Reduce root `up` to foundation bootstrap, focused readiness, and guidance.
4. Update lifecycle tests to assert the new startup contract.
5. Run static, unit, dry-run, and review gates.

## Criteria

- [x] ISC-1: Root `up` target creates the shared Kind cluster.
- [x] ISC-2: Root `up` target deploys the in-cluster registry.
- [x] ISC-3: Root `up` target creates required signing keys.
- [x] ISC-4: Root `up` target bootstraps Flux foundation resources.
- [x] ISC-5: Root `up` target excludes olly image builds.
- [x] ISC-6: Root `up` target excludes OSRAMP application image builds.
- [x] ISC-7: Root `up` target excludes Signalloom workload activation.
- [x] ISC-8: Root `up` target prints the olly activation command.
- [x] ISC-9: Root `up` target prints the OSRAMP activation command.
- [x] ISC-10: Root `up` target prints the Signalloom activation command.
- [x] ISC-11: Startup output identifies no demos run automatically.
- [x] ISC-12: Readiness check runs after cluster foundation setup.
- [x] ISC-13: Readiness check succeeds only for a healthy cluster.
- [x] ISC-14: Readiness check avoids waiting for demo workloads.
- [x] ISC-15: Flux bootstrap leaves olly ResourceSet inputs inactive.
- [x] ISC-16: Flux bootstrap leaves OSRAMP ResourceSet inputs inactive.
- [x] ISC-17: Flux bootstrap leaves Signalloom ResourceSet inputs inactive.
- [x] ISC-18: `demo-signalloom-up` activates Signalloom ResourceSet inputs.
- [x] ISC-19: `demo-signalloom-up` requests Signalloom reconciliation.
- [x] ISC-20: Existing demo teardown commands retain focused behaviour.
- [x] ISC-21: Lifecycle tests assert the slim root startup graph.
- [x] ISC-22: Lifecycle tests assert printed demo command guidance.
- [x] ISC-23: Lifecycle tests assert readiness before demo activation.
- [x] ISC-24: Relevant automated tests pass after lifecycle migration.

## Decisions

- Terminology follows Andrew's correction: olly and Signalloom.
- Preserve focused demo lifecycle commands rather than replacing them.

## Verification

- `bats test/bao-spire-proof.bats test/demo-lifecycle.bats test/healthcheck.bats test/signalloom-flux-integration.bats test/signalloom-local-lifecycle.bats test/zot-cache.bats` passed: 28 tests.
- Selected unaffected preflight assertions passed: 3 tests.
- `make test-demo-lifecycle`, `make test-demo-signalloom-lifecycle`, and `make test-zot-cache` passed.
- `bash -n` passed for changed shell scripts; `git diff --check` passed.
- `make -n up` shows only foundation setup, healthcheck, and demo guidance; `make -n demo-signalloom-up` health-checks before Signalloom artifact preparation and activation.
- Full `bats test/*.bats` has one pre-existing environment failure: the delivery-contract happy-path assertion requires `main` to be an ancestor of `integration/signalloom-d2-v2.0.0`, which is false in this checkout. It is unrelated to the lifecycle change.
- CodeReview capability invoked; roborev could not run because it is not installed in this environment.
