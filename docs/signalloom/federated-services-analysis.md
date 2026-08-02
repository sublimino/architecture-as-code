# Federated Services Page -- Analysis and A2A Compatibility Review

> Date: 2026-08-02
> Page: `d2-signalloom/apps/dashboard-signalloom/src/pages/FederatedServicesPage.tsx`

## What the page does today

The Federated Services page is a **read-only dashboard for SPIFFE/SPIRE trust
fabric visibility**, inspired by Cofide Connect. It renders four static tables
from inline mock data (no API calls, no auth dependency):

| Section              | Shows                                                        |
|----------------------|--------------------------------------------------------------|
| Trust Zones          | SPIFFE trust domains (eu, us, partner-acme) with cluster/server counts |
| Federations          | Cross-zone trust relationships (bidirectional, one-way, pending) |
| Federated Services   | Service routes crossing trust zone boundaries via xDS/Cofide SDK |
| Attestation Policies | SPIFFE workload selectors that gate federation eligibility     |
| Cofide Go SDK        | Code snippet showing secretless DialFederated usage            |

StatCards at the top summarise zone count, federation count, active services,
and policy count. All data is hardcoded -- the page is entirely self-contained.

## Relationship to SPIRE

**Direct and intentional.** The page models exactly what a Cofide Connect
deployment surfaces: SPIRE trust domains, SPIRE-issued SVIDs, workload
attestation selectors (`k8s:ns:`, `k8s:sa:`, `tpm:ek_sha256:`), and
cross-domain federation via bundle exchange.

The real infra in `inf-bao/` runs SPIRE Agent v1.11.1 as a DaemonSet with:
- Trust domain: `signalloom.demo`
- Node attestor: `join_token`
- Workload attestor: k8s (ServiceAccount-based)
- Socket: `/run/spire/sockets/agent.sock`

OpenBao validates SPIFFE JWT-SVIDs and issues Bao tokens against bound SPIFFE
subjects (`spiffe://signalloom.demo/ns/fe-signalloom/sa/fe-signalloom`). The
federated services page visualises the *multi-zone* extension of this
single-zone reality.

## Relationship to Smithy

**None.** AWS Smithy is a service framework for defining API shapes (IDL for
REST/RPC). The page has no Smithy references, no `.smithy` model files, no
generated API clients. The word "service" in "federated service" refers to
SPIFFE-attested workloads discoverable across trust zones -- not Smithy service
models. There is zero overlap.

## Relationship to Google A2A

**Conceptually adjacent but architecturally distinct.** Google's Agent-to-Agent
(A2A) protocol defines how AI agents discover, authenticate, and communicate
with each other:

| Concern          | A2A                                        | Federated Services (this page)              |
|------------------|--------------------------------------------|---------------------------------------------|
| Discovery        | `/.well-known/agent.json` (Agent Card)     | SPIRE registration entries + xDS            |
| Identity         | OAuth 2.0 / OpenID Connect                | SPIFFE SVIDs (X.509 + JWT)                  |
| Transport        | HTTP + JSON-RPC                            | mTLS (xDS/Envoy) or Cofide Go SDK           |
| Trust boundary   | OAuth scopes + Agent Card capabilities     | SPIFFE trust domains + attestation policies |
| Federation       | Implicit (any agent can call any other)    | Explicit bundle exchange between trust zones|

Key differences:
1. **A2A is protocol-level** -- it defines message formats (Task, Artifact,
   Message) and a JSON-RPC API. Federated Services is **infrastructure-level**
   -- it defines trust zones and identity attestation.
2. **A2A agents could run ON TOP of federated services** -- an A2A agent in
   trust zone A calling an A2A agent in trust zone B would use SPIFFE mTLS
   as the transport, with the A2A protocol riding above it.
3. **The existing AgentsPage** already models NHI (non-human identity) agent
   registration with lifecycle management. A2A Agent Cards could extend that
   model with capability declarations and supported content types.

## What integration would make sense

### Tier 1: Lightweight (ship now)

1. **SPIFFE ID browser** -- Add a section that lists concrete SPIFFE IDs from
   the demo's trust domain, showing the ID URI, workload type, namespace,
   service account, and SVID expiry. This bridges the abstract trust-zone view
   to the actual identities flowing through the system.

2. **Federation health timeline** -- Replace the static "connecting" status
   with a mini event log showing bundle exchange attempts, last-seen
   timestamps, and handshake state.

### Tier 2: Medium effort (next iteration)

3. **A2A Agent Card overlay** -- For each federated service, show what an A2A
   Agent Card would look like if the service exposed one
   (`/.well-known/agent.json`). This connects the SPIFFE identity layer to the
   A2A application layer.

4. **Cross-reference with AgentsPage** -- Link federated services to their
   registered NHI agents, showing which agent identities are attested by which
   trust zone.

### Tier 3: Heavier (future)

5. **Live SPIRE API integration** -- Replace mock data with calls to the SPIRE
   Server API (`/spire.api.server.entry.v1.Entry/ListEntries`) for real
   registration entries, trust bundles, and agent status.

6. **A2A discovery endpoint** -- Add a `.well-known/agent.json` endpoint to
   the dashboard's API that describes the SignalLoom platform as an A2A-capable
   agent, enabling external AI agents to discover and interact with it.

## Shipped improvements (this commit)

1. **SPIFFE ID browser section** -- New "SPIFFE Identities" section with mock
   SVIDs derived from the real `signalloom.demo` trust domain, showing URI,
   workload type, namespace, service account, and SVID type.

2. **Federation event log** -- New "Federation Events" section showing recent
   bundle exchanges and handshake events with timestamps.

3. **Enhanced test coverage** -- Tests updated to verify the new sections
   render correctly.
