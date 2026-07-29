---
task: inspect Zot push paths and registry readiness
slug: 20260727-204500_inspect-zot-push-registry-readiness
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T20:45:00+01:00
updated: 2026-07-27T20:55:00+01:00
---

## Context

Andrew requested a read-only inspection of every local Zot artifact or image push path, the current cluster registry readiness, likely failures, exact safe reproduction commands, and minimal fixes only for demonstrated issues. No repository, cluster, registry, or image state may be edited. This matters because local Flux artifacts and workload images depend on distinct Zot namespaces and a working port-forward.

### Risks

- A pre-existing local port-forward can make a new probe ambiguous.
- The configured Kind context may differ from the repository default cluster name.
- A Kubernetes API context can be unavailable despite local build recipes existing.
- Registry catalog access requires a temporary port-forward, which must be cleaned up.

## Criteria

- [x] ISC-1: Repository Zot push recipes are enumerated with source locations.
- [x] ISC-2: Artifact push recipes are distinguished from image pushes.
- [x] ISC-3: Active Kind cluster identity is observed without mutation.
- [x] ISC-4: Zot registry workload readiness is observed without mutation.
- [x] ISC-5: Zot service endpoint availability is observed without mutation.
- [x] ISC-6: Registry catalog response is observed through safe port-forward.
- [x] ISC-7: Demonstrated failures include reproducible command output evidence.
- [x] ISC-8: Proposed fixes change only demonstrated broken behavior.

## Decisions

- 2026-07-27 20:47: Use read-only Kubernetes and registry probes; do not build, push, apply, delete, or reset.
- 2026-07-27 20:49: Probe catalog through an ephemeral port-forward and terminate it reliably.

## Verification

- ISC-1: `rg -l` found Makefile, fleet Makefile, and four Zot-facing scripts.
- ISC-2: `scripts/push-local.sh` uses `flux push artifact`; root Makefile uses `crane push`.
- ISC-3: `kubectl config current-context` returned `kind-osramp`.
- ISC-4: Zot pod was `1/1 Running`; deployment status was `1/1 ready`.
- ISC-5: Service exposes 5000; EndpointSlice targets `10.244.0.78:5000`.
- ISC-6: Read-only catalog and tag calls returned both Signal Loom repositories at `latest`.
- ISC-7: No repository or cluster failure was demonstrated; temporary forward logs show successful forwarding.
- ISC-8: No code/config fix is warranted under the demonstrated evidence.
