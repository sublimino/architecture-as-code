---
task: Verify infra-only startup behavior across repository artifacts
slug: 20260726-235900_verify-infra-only-startup-contract
effort: advanced
phase: complete
progress: 25/25
mode: interactive
started: 2026-07-26T23:59:09+01:00
updated: 2026-07-27T00:07:20+01:00
---

## Context

The local lifecycle contract is that `make up` brings up only the shared Kind, Zot, signing, Flux, and shared infrastructure foundation. No demo application or demo-specific workload may deploy until an explicit `make demo-*-up` command is run. The final `make up` output must plainly give the next action. Align implementation, test coverage, root and component documentation, control-panel wording, the D2-BAO integration plan, and lifecycle errata.

### Risks

- A dry-run can prove the Make dependency graph but cannot prove a cluster's current residual workloads are absent.
- The D2-BAO plan previously treated OpenBao as part of `make up`; preserve it as an explicit demo lifecycle instead.
- Existing precise documentation should not be rewritten merely to restate the same contract.

### Plan

1. Make the final foundation status explicitly direct users to a single opt-in demo command.
2. Extend static lifecycle assertions to reject every demo entry point from root `up`.
3. Correct the control-panel wording, D2-BAO plan, and lifecycle errata.
4. Validate the Make graph, BATS suite, JSON syntax, and changed prose.

## Criteria

- [x] ISC-1: Root up target invokes only foundation targets.
- [x] ISC-2: Root up target invokes demo-help last.
- [x] ISC-3: Root up target invokes no demo startup target.
- [x] ISC-4: Root up target invokes no workload image build.
- [x] ISC-5: Demo help states that no demos run.
- [x] ISC-6: Demo help names every opt-in startup target.
- [x] ISC-7: Demo help contains an explicit next-step prompt.
- [x] ISC-8: Demo help separates startup guidance from foundation status.
- [x] ISC-9: Lifecycle test asserts foundation target execution.
- [x] ISC-10: Lifecycle test rejects OSRAMP startup from root up.
- [x] ISC-11: Lifecycle test rejects Signal Loom startup from root up.
- [x] ISC-12: Lifecycle test rejects Olly startup from root up.
- [x] ISC-13: Lifecycle test rejects Bao startup from root up.
- [x] ISC-14: Lifecycle test asserts the explicit next-step prompt.
- [x] ISC-15: Root README describes root up as infrastructure-only.
- [x] ISC-16: Root README names all opt-in demo commands.
- [x] ISC-17: OSRAMP README preserves explicit demo startup guidance.
- [x] ISC-18: Signal Loom lifecycle document preserves separate activation.
- [x] ISC-19: Setup script preserves post-startup demo guidance.
- [x] ISC-20: Control-panel UI labels root up as infrastructure startup.
- [x] ISC-21: Control-panel UI description excludes demo workload deployment.
- [x] ISC-22: Bao integration plan removes app-ready root-up expectation.
- [x] ISC-23: Bao integration plan defines explicit OpenBao demo activation.
- [x] ISC-24: Lifecycle errata records the corrected root-up contract.
- [x] ISC-A-1: Root up never deploys any demo application.

## Decisions

- Treat the Make dependency graph and inactive ResourceSet inputs as the executable contract.
- Update stale UI and D2-BAO planning language rather than broaden `make up`.

## Verification

- `make -n up` expands only `cluster`, `registry`, `signing-keys`, `push-local-foundation`, `bootstrap-local`, `wait`, `healthcheck`, and `demo-help`.
- `scripts/push-local.sh` documents that foundation mode excludes every demo artifact.
- Demo ResourceSets for OSRAMP, Olly, and both Signal Loom slices retain `inputs: []` defaults.
- `bats test/demo-lifecycle.bats` passes 10/10, covering root-up exclusions, demo-help guidance, and control-panel wording.
- `jq empty ui/steps.json` and `git diff --check` pass.
- Repository-wide targeted search found no remaining stale `make up` workload claim; remaining matches state the foundation-only contract.
- FirstPrinciples, Delegation, and Engineer-audit capabilities were invoked. CodeReview was invoked but `roborev` is unavailable in this environment.
