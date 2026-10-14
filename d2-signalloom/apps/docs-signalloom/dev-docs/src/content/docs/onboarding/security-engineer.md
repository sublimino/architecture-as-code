---
title: Security engineer onboarding
description: Assess Signal Loom controls through read-only evidence and propose separately approved next steps.
---

Read the [glossary](/dev-docs/reference/glossary/) first. The outcome is a report for later remediation planning.

## Assessment boundary

WARNING: Do not mutate the assessed environment.
Stuns, rotation, seeding, reconciliation, patches, deletion, and erasure change the evidence or destroy data.

Do not dump authentication secrets or customer payloads. Do not request elevated credentials to complete a check.
The assessment permits no automatic remediation.

1. Record the approved environment and control scope.
2. Confirm a read-only identity with the owner.
3. Select only the source files required for each control.
4. Agree safe evidence fields and a restricted destination.
5. Inspect command recipes before any command.
6. Record each finding in the [assessment template](/dev-docs/reference/security-assessment-template/).

Source code shows intended behaviour. A test result shows behaviour in its test environment.
Neither proves that the assessed deployment enforces the control.

## Safe metadata checks

These checks return selected fields, not credentials or payloads.
Resource names can still identify tenants and need redaction before sharing.

1. Check the approved context.

   ```bash
   kubectl config current-context
   ```

2. Check NetworkPolicy names in the agent namespace.

   ```bash
   kubectl -n fe-signalloom-agents get networkpolicy -o custom-columns='NAME:.metadata.name,TYPES:.spec.policyTypes'
   ```

3. Check Flux suspension state.

   ```bash
   kubectl -n flux-system get kustomizations -o custom-columns='NAME:.metadata.name,SUSPENDED:.spec.suspend'
   ```

4. Check ResourceSet reconciliation annotations.

   ```bash
   kubectl -n flux-system get resourcesets -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{index .metadata.annotations "fluxcd.controlplane.io/reconcile"}}{{"\n"}}{{end}}'
   ```

5. Check dashboard image identity.

   ```bash
   kubectl -n fe-signalloom get deployment dashboard-signalloom -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[*].image'
   ```

An image tag is not signature evidence. A policy object is not proof of network enforcement.
Unavailable permissions or missing custom resource definitions leave the relevant checks unverified.

## Control review

| Area | Read-only review | Required evidence and limits |
| :--- | :--- | :--- |
| Identity | Compare SPIFFE IDs and SPIRE selectors with the approved workload inventory. | Owner-approved registration metadata. Registration alone does not prove current identity issuance. |
| Identity | Review OpenBao role audiences, bound identities, policies, and lease limits in source. | Redacted policy comparison and existing access evidence. Never read secret values or perform an exchange. |
| Identity | Review operator access and role-based access control (RBAC). | Scoped permission evidence and authentication contracts. Navigation visibility is not authorisation. |
| Containment | Compare existing stun records with Flux suspension and ResourceSet annotations. | Redacted state evidence. Do not stun or resume an agent. |
| Containment | Compare NetworkPolicy selectors with workload labels and the active network plugin. | Existing enforcement evidence. Kind without an enforcing plugin cannot prove isolation. |
| Containment | Review host confinement configuration and existing Landlock results. | Host-specific kernel and policy evidence. Container readiness does not prove confinement. |
| Data protection | Review payload boundaries and collection fields. | Redacted schema or field inventory. Do not inspect customer payloads. |
| Data protection | Review retention settings, legal holds, and existing per-copy receipts. | Receipt dispositions and residual-state summaries. A retention setting alone does not prove deletion. |
| Data protection | Review erasure gates and prior approved erasure evidence. | Redacted decisions and scope. Never submit an erasure request. |
| Supply chain | Compare deployed digest with existing signature, SBOM, and provenance evidence. | Trusted signer and subject-digest match. File presence alone proves no protection. |
| Exposure | Review ingress, docs routes, authentication checks, and backend proxy rules. | Source comparison and approved body-free checks. Do not assume the docs portal requires authentication. |

## Source map

| Review | Source |
| :--- | :--- |
| SPIRE and OpenBao | [Identity manifests](https://github.com/controlplaneio-in-toto/osramp-demo/tree/main/d2-signalloom/infra/inf-bao/) |
| Operator contracts | [Operator identity tests](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/test/signalloom/operator-identity.bats) |
| Containment | [Fleet Manager](https://github.com/controlplaneio-in-toto/osramp-demo/tree/main/d2-signalloom/apps/fleet-manager/) |
| Network and RBAC | [Agent swarm manifests](https://github.com/controlplaneio-in-toto/osramp-demo/tree/main/d2-signalloom/infra/agent-swarm/) |
| Host confinement | [Host confinement tests](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/test/signalloom/agentmaxxing-host-confinement.bats) |
| Payload privacy | [Payload boundary guidance](/docs/security/zero-customer-payload/) |
| Retention and erasure | [Privacy source](https://github.com/controlplaneio-in-toto/osramp-demo/tree/main/d2-signalloom/apps/signal-ingest/privacy/) and [retention source](https://github.com/controlplaneio-in-toto/osramp-demo/tree/main/d2-signalloom/apps/signal-ingest/retention/) |
| Supply chain | [Build and sign script](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/build-sign-dashboard.sh) |
| Exposure | [Dashboard proxy](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/dashboard-signalloom/nginx.conf) |

The retention source distinguishes retained attested bytes from removed identity linkage. This distinction requires a residual-risk assessment, not a blanket erasure claim.

## Misleading target names

WARNING: Do not treat an evidence or test target as a safe assessment command.
Its recipe can read secrets, start probes, or change cluster resources.

`make demo-signalloom-supercred-evidence` calls [credential probes](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/supercred-evidence.sh), including OpenBao value reads.
It is not an approved command for this assessment.

`make demo-agent-trust-network-test` calls the [Agent Trust script](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/agent-trust-local.sh).
An active network test is outside this read-only procedure.

The developer start targets create keys and workloads. They are not assessment prerequisites.

## Finish or stop

1. Classify each result with the template terms.
2. State the consequence and priority reasons.
3. Propose the smallest next step.
4. Request separate approval for any later remediation.
5. Check that the report contains no credentials or payloads.

Stop if a check needs mutation, secret output, raw logs, wider privileges, or an unapproved destination.
Record the blocked check as unverified with its reason.
Escalate an immediate exposure through the incident process without changing the environment.
