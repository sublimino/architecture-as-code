---
title: Engineering glossary
description: Shared terms for development, support, and read-only security assessment.
---

Use these terms throughout [engineering onboarding](/dev-docs/onboarding/).
Product names and source identifiers retain their exact spelling.

| Term | Meaning |
| :--- | :--- |
| Assessment | Read-only review of a named control in an approved environment. |
| Authentication | Check of the identity that requests access. |
| Authorisation | Decision about the actions an identity may perform. |
| Backend | Service behind the dashboard proxy. |
| Containment | Restrictions on an agent across workload, network, identity, or host boundaries. |
| Context | Selected Kubernetes environment and access identity. |
| Customer payload | Customer message, prompt, response, file content, or other business data. |
| Digest | Content-derived identifier for an image or artifact. |
| EndpointSlice | Kubernetes object that records Service endpoints and their readiness. |
| Erasure | Approved removal of personal data or its recoverable linkage, within a stated scope. |
| Evidence | Observation that supports a scoped finding. |
| Finding | Result, evidence, consequence, priority, and proposed next step for one control. |
| Flux | Controller system that applies declared deployment state. |
| GitOps | Delivery through declared state and controller reconciliation. |
| Ingress | Entry path from an external caller to a service. |
| Kind | Tool that runs Kubernetes nodes in containers for local development. |
| Landlock | Linux security mechanism that restricts permitted host operations. |
| Least privilege | Minimum information and permissions required for the approved task. |
| Legal hold | Restriction that can prevent destruction of evidence or personal data. |
| Metadata | Selected descriptive fields without secret values or customer payloads. |
| NetworkPolicy | Kubernetes declaration of permitted network traffic. Enforcement depends on the network plugin. |
| OpenBao | Service for secret storage, access policies, and credential leases. |
| Operator | Identity with approved authority for operational actions. |
| Provenance | Evidence about how an artifact was built and its inputs. |
| RBAC | Role-based access control. Permissions assigned through roles and bindings. |
| Read-only | No change to the assessed environment and no destructive or active mutation test. |
| Reconciliation | Controller action that brings resources towards declared state. |
| Redaction | Removal or replacement of sensitive fields before evidence leaves its restricted source. |
| ResourceSet | Flux Operator resource that defines a set of managed resources. |
| Retention | Rules and actions that limit how long stored data remains. |
| SBOM | Software bill of materials. Inventory of software components in an artifact. |
| SLSA | Supply-chain Levels for Software Artifacts. Framework for supply-chain assurance. |
| SPA | Single-page application. Browser application with client-side page navigation. |
| SPIFFE | Secure Production Identity Framework for Everyone. Standard for workload identity. |
| SPIRE | SPIFFE Runtime Environment. System that issues workload identities. |
| Stun | Operational containment action against an agent. It is not a read-only check. |
| Unverified | Insufficient evidence to confirm protection or a gap. |

The [assessment template](/dev-docs/reference/security-assessment-template/) defines the four result categories.
