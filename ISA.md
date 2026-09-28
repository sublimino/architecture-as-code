---
task: Fix degraded cluster resources and redeploy local Kind cluster
slug: fix-and-redeploy-local-cluster
effort: E3
phase: complete
progress: 36/36
mode: algorithm
started: 2026-09-28T23:53:30+01:00
updated: 2026-09-29T00:24:00+01:00
---

## Problem
In the local Kind cluster `osramp`, `make doctor` reports degraded cluster health with 8 non-ready Flux Kustomizations in `fe-signalloom-agents`:
1. ValidatingAdmissionPolicy `sl-agent-identity-state-protection` rejects pod creation for `swarm-governor`, `prod-deploy-gate`, `zulip-chat-agent`, `hosted-daytona-coder`, and `nono-containment-probe` because their pod templates lack the mandatory `signalloom.ai/framework` label.
2. `prompt-commit-summarizer` and `triage-ci-worker` fail dry-run due to missing Knative Serving CRD `services.serving.knative.dev` and strict schema rejection of `volumes[].csi`.
3. `agent-cardvault` was suspended in `fe-signalloom-agents` in a failed state due to missing `runAsUser` on the `openbao-agent` sidecar under `runAsNonRoot: true`.
4. `agent-nono-containment-probe` Job and PVC `nono-probe-workspace` stall in `WaitForFirstConsumer` because the probe pod was denied admission.
5. `agent-hosted-daytona-coder` suffered from a first-reconcile RBAC dependency ordering failure and admission denial.

## Vision
A completely healthy, stable local Kind cluster running the OSRAMP foundation and Signal Loom swarm with 0 non-ready Flux Kustomizations, 0 failing or crashing pods, verified OCI artifacts pushed to the in-cluster Zot registry, and clean passes for `make healthcheck` and `make doctor`.

## Out of Scope
- Modifying admission policy logic in `sl-agent-identity-state-protection` (manifests must conform to policy).
- Deploying unrelated external GCP lanes (`demo-1`, `ci-1`).
- Bypassing Knative scale-to-zero or changing agent core business logic.

## Principles
- Policy Conformance Over Policy Relaxation: Workload manifests must strictly comply with admission controls and security contexts.
- Explicit Non-Root Security: All containers with `runAsNonRoot: true` must declare an explicit non-root UID (`runAsUser: 65534` or `runAsUser: 100`).
- Self-Healing GitOps: Changes must be pushed and signed in the OCI registry (`signalloom/agent-swarm`) so Flux reconciles declaratively from source.
- Multi-Stage Diagnostic Proof: Every fix must be proven via live tool probes (`kubectl`, `flux`, `make doctor`).

## Constraints
- Conventional Commits (`fix(swarm): ...`) with `--no-gpg-sign`.
- `bun` / `bunx` always. Never `npm` or `npx`.
- Do not alter Nginx CSP or frame-ancestors headers.
- Respect all PAI and repository operational rules.

## Goal
Fix all manifest defects in `d2-signalloom/infra/agent-swarm/` and fleet definitions, patch Knative Serving CRD schema for CSI volumes, re-push/sign the `signalloom/agent-swarm` OCI artifact, and reconcile the cluster to achieve 0 failing Flux Kustomizations and passing healthchecks.

## Criteria
- [x] ISC-1: `swarm-governor/deployment.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-2: `swarm-governor/deployment.yaml` spec has `runAsUser: 65534` in pod securityContext.
- [x] ISC-3: `prod-deploy-gate/deployment.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-4: `prod-deploy-gate/deployment.yaml` spec has `runAsUser: 65534` in pod securityContext.
- [x] ISC-5: `zulip-chat-agent/deployment.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-6: `zulip-chat-agent/deployment.yaml` spec has `runAsUser: 65534` in pod securityContext.
- [x] ISC-7: `hosted-daytona-coder/deployment.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-8: `hosted-daytona-coder/deployment.yaml` template has `runAsUser: 65534` in pod securityContext.
- [x] ISC-9: `nono-containment-probe/job.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-10: `nono-containment-probe/job.yaml` has `runAsUser: 65534` in pod securityContext.
- [x] ISC-11: `prompt-commit-summarizer/knative-service.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-12: `prompt-commit-summarizer/knative-service.yaml` openbao-agent sidecar has `runAsUser: 100`.
- [x] ISC-13: `triage-ci-worker/knative-service.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-14: `triage-ci-worker/knative-service.yaml` openbao-agent sidecar has `runAsUser: 100`.
- [x] ISC-15: `agent-cardvault/deployment-overlay.yaml` openbao-agent sidecar has `runAsUser: 100`.
- [x] ISC-16: `kusari-agent/deployment.yaml` template has `signalloom.ai/framework: custom`.
- [x] ISC-17: `d2-osramp-fleet/tenants/base/agent-swarm.yaml` has `suspend: false` (or removes `suspend: true`) for `agent-cardvault`.
- [x] ISC-18: Knative Serving CRD `services.serving.knative.dev` has `csi` property defined in OpenAPI schema.
- [x] ISC-19: Knative Serving CRD `configurations.serving.knative.dev` has `csi` property defined in OpenAPI schema.
- [x] ISC-20: `Makefile` `swarm-infra-up` target applies Knative Serving CRDs and csi schema patch.
- [x] ISC-21: `kubectl kustomize d2-signalloom/infra/agent-swarm/prompt-commit-summarizer` validates cleanly via server-side dry run.
- [x] ISC-22: `kubectl kustomize d2-signalloom/infra/agent-swarm/triage-ci-worker` validates cleanly via server-side dry run.
- [x] ISC-23: `kubectl kustomize d2-signalloom/infra/agent-swarm/swarm-governor` validates cleanly via server-side dry run.
- [x] ISC-24: `kubectl kustomize d2-signalloom/infra/agent-swarm/prod-deploy-gate` validates cleanly via server-side dry run.
- [x] ISC-25: `kubectl kustomize d2-signalloom/infra/agent-swarm/zulip-chat-agent` validates cleanly via server-side dry run.
- [x] ISC-26: `kubectl kustomize d2-signalloom/infra/agent-swarm/hosted-daytona-coder` validates cleanly via server-side dry run.
- [x] ISC-27: `kubectl kustomize d2-signalloom/infra/agent-swarm/agent-cardvault` validates cleanly via server-side dry run.
- [x] ISC-28: `kubectl kustomize d2-signalloom/infra/agent-swarm/nono-containment-probe` validates cleanly via server-side dry run.
- [x] ISC-29: `scripts/push-local.sh signalloom` builds, packages, signs, and pushes `signalloom/agent-swarm` to Zot.
- [x] ISC-30: Flux OCIRepository `agent-swarm` in `fe-signalloom-agents` reconciles to the newly pushed artifact.
- [x] ISC-31: All 13 Kustomizations in `fe-signalloom-agents` reconcile to `Ready: True`.
- [x] ISC-32: Zero pods in `fe-signalloom-agents` or `fe-signalloom` are in `CrashLoopBackOff`, `FailedCreate`, or `Error`.
- [x] ISC-33: `make healthcheck` passes 100%.
- [x] ISC-34: `make doctor` reports zero failing Flux Kustomizations across all namespaces.
- [x] ISC-35: Anti: ValidatingAdmissionPolicy `sl-agent-identity-state-protection` must NOT be deleted, bypassed, or disabled.
- [x] ISC-36: Anti: No agent pods must run with unconfined root privileges where `runAsNonRoot: true` is violated.

## Test Strategy
- ISC-1..17 | static | `rg -rn 'signalloom.ai/framework: custom' d2-signalloom/infra/agent-swarm/` | 100% pass | Grep
- ISC-18..20 | k8s | `kubectl explain ksvc.spec.template.spec.volumes` | includes csi | Kubectl
- ISC-21..28 | dry-run | `kubectl apply --server-side --dry-run=server -f -` | 0 errors | Kubectl
- ISC-29..30 | oci | `scripts/push-local.sh signalloom && flux reconcile source oci agent-swarm -n fe-signalloom-agents` | 0 errors | Bash/Flux
- ISC-31..32 | live | `kubectl get kustomization -n fe-signalloom-agents` | 13/13 True | Kubectl
- ISC-33..36 | audit | `make healthcheck && make doctor` | 0 failing | Makefile

## Features
- feat-manifest-labels: Add `signalloom.ai/framework: custom` and non-root UIDs across all 8 agent manifests.
- feat-knative-schema: Ensure Knative Serving CRD permits `csi` volume specifications.
- feat-fleet-cardvault: Unsuspend `agent-cardvault` in fleet definitions.
- feat-oci-push: Package and cosign updated `agent-swarm` manifests to in-cluster Zot registry.
- feat-reconcile-verify: Trigger Flux reconciliation and verify cluster health with `make healthcheck` and `make doctor`.

## Decisions
- 2026-09-28: Fixed admission policy rejections at source in workload manifests by adding `signalloom.ai/framework: custom` rather than modifying the policy.
- 2026-09-28: Added `runAsUser: 65534` (nobody) and `runAsUser: 100` (openbao) to eliminate `container has runAsNonRoot and image will run as root` failures.
- 2026-09-28: Patched Knative Serving CRD to allow `csi` volumes for SPIFFE Workload API CSI projections.
- 2026-09-28: Delegation floor relaxed for E3 tier with show-your-math justification (self-contained GitOps manifest and cluster operations).
- 2026-09-29: Added `allow-inf-signalloom-egress` network policy in `fe-signalloom-agents` allowing port 8080 egress to `inf-signalloom` for cardvault access.
- 2026-09-29: Added `--interval=60s` support to `cardvault-agent` to eliminate pod restart churn when deployed as a continuous workload.

## Changelog
- 2026-09-28: Conjectured that 8 failing Kustomizations stemmed from diverse distinct root causes; refuted by investigation proving that admission policy `sl-agent-identity-state-protection` label omission was the common failure mode for 5 of them, with Knative CRD absence and non-root UID omission accounting for the remainder.
- 2026-09-29: Reconciled entire Flux estate across all 28 Kustomizations to `Ready: True`; verified `make healthcheck` and `make doctor` reported 0 unhealthy pods and 0 failing Kustomizations.

## Verification
- ISC-1..17: Verified via manifest audits across all swarm agents (`signalloom.ai/framework: custom` present; non-root UIDs 65534 / 100 applied).
- ISC-18..20: Knative Serving CRD OpenAPI schema patched to allow `csi` volumes; `Makefile` updated.
- ISC-21..28: Server-side dry runs passed cleanly across all 8 agent manifests.
- ISC-29..30: `./scripts/push-local.sh signalloom` and `./scripts/push-local.sh fleet` packaged, signed with cosign, pushed to in-cluster Zot registry at `localhost:5001`.
- ISC-31: `kubectl get kustomization -A` confirms 28/28 Kustomizations report `Ready: True` (14/14 in `fe-signalloom-agents`).
- ISC-32: `kubectl get pods -A` confirms 0 pods in `CrashLoopBackOff`, `FailedCreate`, or `Error`. All swarm pods running or completed cleanly.
- ISC-33: `make healthcheck` passed with 0 errors (node, Kustomization/flux-system, ResourceSet/policies, ResourceSet/infra all Ready).
- ISC-34: `make doctor` reports `✓ Cluster healthy`, 28/28 Kustomizations Ready, 0 unhealthy pods, 0 corrective actions.
- ISC-35: ValidatingAdmissionPolicy `sl-agent-identity-state-protection` confirmed active and intact.
- ISC-36: All agent workloads comply with PSS restricted and run as explicit non-root users. SuperCred identity chain verified end-to-end (`[step-1]` SPIFFE identity, `[step-2]` OpenBao token, `[step-3]` KV credentials, `[step-4]` Cardvault access, `[complete]` SuperCred identity chain verified).
