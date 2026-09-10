# Signal Loom Activity Timeline & Cryptographic Proof Integration (SFAS-P2-2)

## Overview

The Activity Tab (Tab 5) in the Agent Dossier (`/agents/:id?tab=activity`) provides operators with a tamper-evident audit ledger correlating:
1. Declarative lifecycle and governance events (`agent.created`, `agent.transitioned`, `agent.stunned`)
2. Cryptographic credential lifecycle actions (`credential.issued`, `credential.revoked`, SPIRE SVID issuing)
3. eBPF kernel telemetry observations (`socket.ebpf_traced`, `egress.traffic_allowed`)
4. Policy violation evaluations and real-time alerts

Under SFAS-P2-2, every attributable timeline audit event is wired to an interactive cryptographic verification workflow.

## Key Features

### 1. Interactive Proof Drill-Down (`AuthorizationProofDrawer`)
- Operators click **'🛡️ View Proof'** on any timeline row.
- The dashboard queries the authorization endpoint (`/api/v1/authorization?action_id={id}` or `/signals/authorization?action_id={id}`).
- Opens a slide-out side drawer in <100ms with hardware-accelerated CSS transforms.
- Displays the complete 7-hop cryptographic authorization proof:
  1. Observed Action
  2. Executing Agent Identity
  3. Acts-On-Behalf-Of Delegation Hierarchy
  4. Authorizing Human/System Principal
  5. Policy Decision & Evaluation
  6. Confidence Score & Evidence References (FrostDB, Audit Webhook)
  7. Attestation GitOID with Rekor Transparency Log Verification link

### 2. Attestation & Landlock Verification (`DelegationAttestationDrawer`)
- Operators click **'🔏 Attestation & Landlock'** to inspect kernel containment status.
- Displays:
  - Cosign Detached Signature (ECDSA P-256)
  - Landlock ABI ruleset and active sandbox containment profile (`agent-nono-evidenced`)
  - Raw event JSON payload with one-click clipboard copying

### 3. Delegation Event Filtering (`DelegationEventFilter`)
- Dedicated filtering toolbar allowing operators to filter timeline items by:
  - Event type (`agent.created`, `agent.transitioned`, `credential.issued`, etc.)
  - Minimum delegation hop count (`minHops >= N`)
- Quick reset button restoring baseline timeline visibility.

### 4. Accessibility & Navigation
- Keyboard navigation with instant `Escape` key dismissal.
- Full ARIA compliance (`role="dialog"`, `aria-modal="true"`, `aria-labelledby`).
- Standardized UTC timestamps with full ISO 8601 tooltip strings.
