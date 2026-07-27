---
task: Route dashboard and API through Gateway safely
slug: 20260727-070200_route-gateway-dashboard-api
effort: advanced
phase: complete
progress: 20/24
mode: interactive
started: 2026-07-27T07:02:00+01:00
updated: 2026-07-27T07:10:00+01:00
token_estimate: 20000
---

## Context

Route the Signalloom dashboard root and `/api` through the platform Gateway. Bind
each workload through a Kubernetes Service, enforce default-deny connectivity, and
prove backing dependencies are not browser-accessible. Work only in the designated
task worktree after confirming integration ancestry. Preserve unrelated dirty work,
do not edit `board.json`, do not push, and do not create a pull request. Commit
only card-owned repository changes. Record executable evidence and a machine-readable
`kanban-check` errata result in the specified proposal.

### Risks

- The worktree is already dirty from parallel cards; staging must be path-limited.
- Existing manifests may already implement part of this card; duplicate objects are invalid.
- Runtime cluster availability may block live DETIK evidence despite valid manifests.
- NetworkPolicy support may differ from Gateway reachability assumptions.

### Plan

Inspect existing Signalloom base manifests, overlays, and tests. Make the smallest
additive manifest and test edits consistent with local Gateway conventions. Validate
rendered YAML before running targeted BATS/DETIK/kubectl checks. Stage explicit
card-owned paths only, commit them, then write proposal errata through Obsidian-safe
mechanisms if available.

## Criteria

- [x] ISC-1: Integration branch is ancestor of task worktree HEAD.
- [x] ISC-2: Dashboard Service selects dashboard workload pods.
- [x] ISC-3: API Service selects API workload pods.
- [x] ISC-4: Gateway object targets the Envoy Gateway class.
- [x] ISC-5: Dashboard HTTPRoute attaches to the platform Gateway.
- [x] ISC-6: Dashboard HTTPRoute matches the root path.
- [x] ISC-7: Dashboard HTTPRoute forwards traffic to dashboard Service.
- [x] ISC-8: API HTTPRoute attaches to the platform Gateway.
- [x] ISC-9: API HTTPRoute matches the `/api` path prefix.
- [x] ISC-10: API HTTPRoute forwards traffic to API Service.
- [x] ISC-11: Dashboard namespace contains a default-deny ingress policy.
- [x] ISC-12: Dashboard namespace contains a default-deny egress policy.
- [x] ISC-13: Dashboard ingress permits the Gateway namespace selector.
- [x] ISC-14: API ingress permits the Gateway namespace selector.
- [x] ISC-15: Dashboard egress permits declared backend dependency ports.
- [x] ISC-16: API egress permits declared backend dependency ports.
- [ ] ISC-17: Browser route test confirms dashboard root availability.
- [ ] ISC-18: Browser route test confirms API path availability.
- [ ] ISC-19: Isolation test rejects direct browser access to dependencies.
- [x] ISC-20: BATS gateway test exits successfully.
- [ ] ISC-21: DETIK gateway test exits successfully.
- [x] ISC-22: Kubectl manifest validation exits successfully.
- [x] ISC-23: Card-owned changes are committed in the task repository.
- [x] ISC-24: Proposal errata contains machine-readable kanban-check status.

## Decisions

The existing `fe-signalloom` workload serves both dashboard and API paths, so two
Services select the same workload while preserving explicit Gateway contracts. The
Gateway exposes only these Services. The fake integration proxy receives a narrow
namespace-and-pod selected ingress edge on TCP 8080; it receives no HTTPRoute.

## Verification

- `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 346e830`: exit 0.
- `bats d2-signalloom/test/least-privilege.bats d2-signalloom/test/gateway-routing.bats`: exit 0; 5 assertions passed.
- `kubectl kustomize d2-signalloom/apps/fe-signalloom/local`: exit 0.
- `kubectl kustomize d2-signalloom/infra/inf-signalloom/configs/local`: exit 0.
- `bats d2-signalloom/test/runtime.bats`: exit 1; both runtime checks failed.
- `kubectl get ns fe-signalloom inf-signalloom`: exit 1; namespaces absent.
- Commit `346e830` contains exactly eight card-owned files.
- Proposal appends `kanban-check` with `status: fail`, `proceed: no`, and `blocking_drift: yes`.
- `code_review` was invoked for the commit, but roborev is not installed.
