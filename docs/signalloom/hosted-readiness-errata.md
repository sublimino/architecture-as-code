# Hosted-readiness integration errata

<!-- machine-tag: SIGNALLOOM-HOSTED-READINESS-ERRATA-2026-07-26T09:44:46+01:00 -->
<!-- integration-ref: integration/signalloom-d2-v2.0.0 -->
<!-- scope: design-consistency-and-decision-request-only -->

This repository-local record integrates the existing runtime contract and
demo-to-hosted threat model. It is a reversible design decision record only:
it does not provision infrastructure, use credentials or production data,
change runtime manifests, or authorize a release.

## Integrated hosted landing decision

The candidate landing shape remains a dedicated `signalloom-discovery`
namespace with a non-root, single-replica portal `Deployment` and `Service`.
It must be exposed only through the approved TLS/authenticated gateway, use
dependency-aware readiness, receive secrets through an approved external
secret mechanism, and start with default-deny network policy plus explicit
egress for enabled dependencies. This reconciles the runtime contract's
recommended Kubernetes shape with the threat model's G-2, G-3, and G-4 gates.

The first hosted pilot is **not ready to provision**. The runtime contract
identifies absent tenant/principal binding, process-local scan execution,
customer credentials in request bodies, fail-open Redis rate limiting, and
out-of-band secret/configuration drift. The threat model independently marks
the corresponding authorization, secret/storage, ingress, egress, and
resilience risks as promotion gates. No statement here upgrades D2 static
checks or fake-provider tests into hosted acceptance evidence.

| Integrated gate | Source consistency finding | Required evidence before provisioning |
| --- | --- | --- |
| Identity and isolation (G-1 / TM-01) | Both records require an authenticated principal/tenant boundary; the observed schema and reads are session-ID-only. | Approved pilot scope plus tenant/principal model; cross-tenant session, agent, and report-denial tests. |
| Secrets and report storage (G-2 / TM-02-03) | Both require private storage and scoped identity; the runtime record also identifies undocumented configuration drift. | Named external-secret owner, rotation/retention plan, private storage authorization, and a no-values render check. |
| Ingress and providers (G-3 / TM-04,07) | Both require gateway-only ingress and allowlisted egress; no hosted provider approval exists. | Gateway/auth design, default-deny policy, enabled-provider list, minimum scopes, egress destinations, and disable-switch tests. |
| Resilience (G-4 / TM-05,08) | Both require dependency-aware readiness and bounded/recoverable work; `BackgroundTasks` is not durable. | Readiness/degradation tests, owner-approved one-replica restart-loss exception or durable-job design, resource limits, alerts, rollback runbook. |
| Release integrity (G-5 / TM-06,09,10) | The delivery contract already requires immutable digest, signature, SBOM, provenance, and the deployment guard. | Candidate digest evidence, admission/GitOps review, static checks, and signed promotion approval. |

## Required provisioning decision request

**Decision requested from the named application, platform-security,
networking, SRE, and release owners:**

> Do you approve a tightly scoped, non-sensitive, one-replica development
> pilot only after the five evidence rows above are accepted and the listed
> controls are implemented and tested? If not, select one explicit disposition:
> **defer provisioning until G-1 through G-5 close**, or **fund the missing
> identity/durable-job design before any hosted pilot**.

This request is required because the source-backed records leave material
owner, authorization, secret-delivery, egress, durability, and release
approval decisions unresolved. A response must name accountable owners,
approved enabled integrations, the data classification/retention boundary,
and whether restart-loss is acceptable. Silence, partial approval, or a local
D2 test pass is not authorization to provision.

## Re-baselined authority and evidence freeze

This erratum confirms the **role-level** authority model from the threat model;
it does not invent or delegate individual production permissions. The named
people, backup delegates, and approval records still have to be supplied by the
responsible organisation before any hosted decision is actionable.

| Decision area | Accountable owner role | Authority boundary and required confirmation |
| --- | --- | --- |
| Production promotion | Release manager (G-5) | Final promotion authority only after G-1 through G-5 evidence is complete; immutable candidate digest, attestation/provenance, SBOM, admission/GitOps review, and signed approval must identify the approver. |
| Customer data | Signal Loom data owner, with the application and security owners | Owns classification, retention/deletion, redaction, and the tenant/principal access boundary; the approved data boundary and RLS/equivalent isolation evidence must be recorded before any real data is considered. |
| Hosted provisioning | The five gate owners jointly: application, platform security, networking/integration, SRE, and release | No single local test, provider credential holder, or implementer may authorize provisioning. The decision request must record each named owner, delegation, disposition, and date. |

The evidence set is frozen at the following minimum contract for this
re-baseline: (1) approved non-production pilot scope and data classification;
(2) tenant/principal isolation and report-boundary tests; (3) external-secret,
rotation, private-storage, retention, and no-values render evidence; (4)
gateway-only ingress, default-deny/allowlisted egress, approved provider
scopes, and disable-switch tests; (5) bounded resilience, resource, alert,
rollout, and rollback evidence; and (6) candidate digest, signature,
provenance/SBOM, admission/GitOps review, static checks, and signed promotion
approval. Every item must name its owner, source revision or artifact digest,
execution environment, timestamp, and result. A missing owner or stale,
mutable, fake-provider-only, or production-derived artifact fails the freeze.

The freeze is a design gate, not hosted acceptance. Any change to the landing
shape, owner authority, data boundary, provider set, or evidence contract
invalidates this freeze and requires a new ISO-offset erratum and a new
kanban-check result. No production credentials, production data, cloud
resources, external scans, or release actions are permitted under this record.

<!-- machine-tag: SIGNALLOOM-HOSTED-READINESS-REBASELINE-2026-07-26T09:55:19+01:00 -->

## Consistency and local verification errata

The following non-production checks validate the integration's repository
references and delivery guard. They do not contact a cluster or cloud service.

```text
env LC_ALL=C LANG=C make signalloom-contract-check
git diff --check
```

<!-- kanban-check: status=pass proceed=no blocking_drift=yes owner_authority=role-confirmed evidence_freeze=pass -->

`status=pass` means the documentation and static contract checks are
consistent. `proceed=no` records the deliberate no-provision decision until
the requested accountable-owner response and gate evidence exist.
