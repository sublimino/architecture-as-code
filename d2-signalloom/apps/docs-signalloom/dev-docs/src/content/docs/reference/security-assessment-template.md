---
title: Security assessment template
description: Record scoped control evidence and proposed next steps without automatic remediation.
---

Use the [glossary](/dev-docs/reference/glossary/) and [security procedure](/dev-docs/onboarding/security-engineer/) before this template.
The report feeds a later remediation plan. It does not authorise changes.

## Report header

| Field | Required content |
| :--- | :--- |
| Assessment | Case identifier and responsible owner |
| Scope | Approved controls, namespaces, and exclusions |
| Environment | Environment alias, context alias, and deployment identity |
| Time | Observation time and timezone |
| Source | Repository revision and source references |
| Permissions | Approved read-only identity and access limits |
| Evidence handling | Restricted destination, redaction method, and retention period |

## Finding record

Create one record per control and environment.

| Field | Required content |
| :--- | :--- |
| Area / control | Identity, containment, data protection, supply chain, or exposure. Name the specific control. |
| Environment / time | Environment alias and observation time with timezone |
| Result | One result from the table below |
| Check | Exact safe command or source-review method |
| Redacted evidence | Selected output, source lines, test record, or restricted evidence reference |
| Consequence | What failure or residual exposure means for this environment |
| Priority | Urgent, high, medium, or low |
| Reasons | Impact, exposure, confidence, affected scope, and uncertainty |
| Proposed next step | Further evidence request or separately approved remediation proposal |
| Owner | Responsible component or incident owner |

## Result terms

| Result | Meaning |
| :--- | :--- |
| Confirmed protection | Evidence proves the named control in the stated scope and environment. |
| Confirmed gap | Evidence proves that the required control is absent or fails in the stated scope. |
| Known limit | Evidence establishes a control boundary or residual risk. |
| Unverified | Evidence or access is insufficient to decide. |

An empty response is not proof of absence. A source declaration is not deployment evidence.
An unavailable test is not a failed control.

## Example finding

| Field | Example |
| :--- | :--- |
| Area / control | Exposure / engineering documentation access |
| Environment / time | Checkout only / recorded review time |
| Result | Known limit |
| Check + redacted evidence | Source review of the `/dev-docs/` proxy block. No `auth_request` appears in that block. |
| Consequence | The source does not make the engineering portal an authentication boundary. Live exposure remains unverified. |
| Priority / reasons | Medium / content sensitivity and live reachability need owner confirmation. |
| Proposed next step | Request an approved external access check and content-classification review. |

## Safety check

1. Remove secret values and authentication headers.
2. Remove raw logs and customer payloads.
3. Replace sensitive resource names with case aliases.
4. Preserve the safe command text exactly.
5. Record withheld evidence and the reason.
6. Check that proposed changes require separate approval.

WARNING: Do not publish the completed report in this portal.
The current portal proxy is not an authentication boundary.
