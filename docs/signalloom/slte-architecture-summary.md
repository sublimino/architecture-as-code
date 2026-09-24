# Signal Loom External Webhook Ingestion & Trigger Engine (`SLTE`) — Architecture Summary

**Mission Shortcode:** `SLTE`  
**Delivery Baseline:** `integration/slte-v0.1.0`  
**Parent Capability:** `SLEA` (Signal Loom On-Demand EAP Environment Routing & Tailscale Provisioning Engine)  
**Status:** Certified & Production Ready

---

## 1. Executive Summary & Capabilities

The **Signal Loom External Webhook Ingestion & Trigger Engine (`SLTE`)** enables external CI/CD pipelines, automated testing orchestrators, and enterprise customers to declaratively manage the lifecycle of on-demand Early Access Program (EAP) preview environments via cryptographically authenticated webhooks.

### Core Capabilities
- **Multi-Protocol Webhook Ingestion:** First-class ingestion support for GitHub pull request events (`/api/v1/webhooks/github`) and standardized generic CI/CD webhooks (`/api/v1/webhooks/generic`).
- **Cryptographic Signature Verification:** Strict HMAC-SHA256 signature verification over raw request bytes using constant-time comparison (`hmac.compare_digest`) to protect against side-channel and timing attacks.
- **Replay Attack & Jitter Defense:** Enforces a strict 300-second timestamp freshness window (`X-SignalLoom-Timestamp`) alongside delivery deduplication IDs (`X-GitHub-Delivery`, `X-SignalLoom-Event-ID`).
- **Automated Lifecycle Dispatching:** Direct integration with the `fe-signalloom` environment engine (`environment_routing.py`) mapping PR actions (`opened`, `synchronize`, `closed`) to deterministic provisioning, TTL extension, and graceful teardown operations.
- **Deterministic Customer Hashing:** Derives salted SHA-256 hashes for enterprise tenants (e.g., pilot customer `kurasi` -> `6f82ad81`), provisioning isolated Tailscale mesh endpoints (`https://sl-eap-6f82ad81.tailscale`).

---

## 2. End-to-End Architecture Flow

```mermaid
flowchart TD
    subgraph EXTERNAL["External Client / CI Pipeline"]
        GHA["GitHub Actions / GitLab CI<br/>(External Runner)"]
        EMITTER["CLI Emitter<br/>(emit-eap-webhook.sh)"]
    end

    subgraph INGRESS["Ingress & Gateway Layer"]
        ENVOY["Envoy Gateway Ingress<br/>(HTTPRoute: /api/v1/webhooks/*)"]
        NETPOL["NetworkPolicy Isolation<br/>(fe-signalloom:8080)"]
    end

    subgraph ENGINE["fe-signalloom Engine"]
        RAW["Raw Body Cache Middleware<br/>(request.state.raw_body)"]
        AUTH["HMAC-SHA256 Signature Verifier<br/>& Replay Defense (300s window)"]
        DISPATCH["Webhook Event Dispatcher<br/>(GitHub & Generic Handlers)"]
        ROUTING["Environment Lifecycle Registry<br/>(GLOBAL_ENVIRONMENT_REGISTRY)"]
    end

    subgraph TAILSCALE["Tailscale Mesh & Control Plane"]
        TS["Tailscale Serve & Mesh Router<br/>(sl-eap-6f82ad81.tailscale)"]
    end

    GHA -->|POST with HMAC-SHA256 & Timestamp| ENVOY
    EMITTER -->|POST with HMAC-SHA256 & Timestamp| ENVOY
    ENVOY --> NETPOL --> RAW
    RAW --> AUTH
    AUTH -->|401 Unauthorized if invalid/expired| ENVOY
    AUTH -->|200 / 202 if valid| DISPATCH
    DISPATCH -->|provision / extend / teardown| ROUTING
    ROUTING -->|bind / release| TS

    classDef client fill:#f3e5f5,stroke:#4a148c,color:#12005e;
    classDef ingress fill:#e8f5e9,stroke:#1b5e20,color:#003300;
    classDef engine fill:#e3f2fd,stroke:#0d47a1,color:#002171;
    classDef ts fill:#fff3e0,stroke:#e65100,color:#4a1400;

    class GHA,EMITTER client;
    class ENVOY,NETPOL ingress;
    class RAW,AUTH,DISPATCH,ROUTING engine;
    class TS ts;
```

---

## 3. Webhook Ingestion Engine Specifications

### 3.1 Raw Body Caching for Non-Destructive Parsing
FastAPI consumes request streams destructively. To allow HMAC-SHA256 signature verification over exact payload bytes prior to Pydantic JSON deserialization, the ingestion layer caches raw request bytes in `request.state.raw_body`.

### 3.2 Authentication & Signature Schemes

| Protocol | Signature Header | Timestamp Header | Signature Algorithm |
| :--- | :--- | :--- | :--- |
| **GitHub** | `X-Hub-Signature-256` | N/A (GitHub event delivery ID used) | `sha256=<hex(HMAC-SHA256(secret, raw_body))>` |
| **Generic** | `X-SignalLoom-Signature` | `X-SignalLoom-Timestamp` | `<hex(HMAC-SHA256(secret, timestamp + "." + raw_body))>` |

All signature checks utilize `hmac.compare_digest` ensuring execution time is invariant to mismatched prefix lengths.

### 3.3 Replay Attack Protection
For generic webhooks, `X-SignalLoom-Timestamp` is validated against server UTC time. Requests where `|client_time - server_time| > 300 seconds` are rejected immediately with HTTP 401 Unauthorized.

### 3.4 Ingress Routing via Gateway API
Ingress traffic is routed via Envoy Gateway using `webhook-httproute.yaml`:
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: webhook-httproute
  namespace: fe-signalloom
spec:
  parentRefs:
    - name: envoy-gateway
      namespace: envoy-gateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/v1/webhooks
      backendRefs:
        - name: fe-signalloom
          port: 8080
```

---

## 4. Tenant Environment Lifecycle Engine

### 4.1 Pilot Tenant: Kurasi Conformance Vector
- **Company Name:** `kurasi`
- **Salted SHA-256 Hash:** `6f82ad81`
- **Internal Hostname:** `sl-eap-6f82ad81`
- **Mesh URL:** `https://sl-eap-6f82ad81.tailscale`
- **External FQDN:** `https://sl-eap-6f82ad81.ts.net`

### 4.2 Lifecycle Event Mapping

```mermaid
stateDiagram-v2
    [*] --> Provisioning: pull_request.opened
    Provisioning --> Ready: Provision Complete
    Ready --> Ready: pull_request.synchronize (Extend TTL)
    Ready --> Terminated: pull_request.closed (Teardown)
    Ready --> Terminated: TTL Expired
    Terminated --> [*]
```

1. **`opened` / `reopened`:** Dynamically provisions a fresh preview environment container, registers mesh routing, and returns HTTP 200 OK with endpoint metadata.
2. **`synchronize`:** Refreshes commit SHA references and extends environment expiration TTL (+60 minutes).
3. **`closed`:** Triggers immediate graceful teardown, unbinds Tailscale proxy ports, and marks state as `terminated`. Subsequent teardown calls are fully idempotent.

---

## 5. Security & Isolation Matrix

1. **Boundary Isolation:** Webhook ingestion routes (`/api/v1/webhooks/*`) operate on decoupled worker contexts with no access to cluster admin or OpenBao master key derivations.
2. **Fail-Closed Secrets:** If `SIGNAL_LOOM_WEBHOOK_SECRET` is unset or invalid, all webhook verification calls fail closed with HTTP 401.
3. **Constant-Time Verification:** Zero timing leakage across secret verification boundaries.
4. **Log Sanitization:** Raw webhook signatures, authorization tokens, and enterprise customer payload bodies are scrubbed from system log streams.
