# SLON-P2-4 Technical Design — Dedicated Demo Smoke Test Suite

**Mission ID**: `SLON-P2-4`  
**Card Title**: Create Dedicated Demo Smoke Test Target (`make demo-signalloom-smoke`)  
**Domain**: Signal Loom Agent Governance Platform  
**Target SLA**: < 90 seconds wall-clock runtime (Measured: 11 seconds)

---

## 1. Context & Motivation

Live partner walk-throughs, sales engineering demos, and rapid CI verification loops require high confidence that core end-user journeys function correctly. Running the complete 12-minute monolithic test pyramid (`make test` / `make acceptance-test`) introduces prohibitive latency during active evaluations.

`SLON-P2-4` introduces a targeted, lightweight demo smoke harness (`make demo-signalloom-smoke`) executing exclusively the critical path:
1. First user onboarding wizard walkthrough (with validation errors, IdP test, consent, celebration, and redirect).
2. Onboarding skip flow persistence.
3. Dual-agent discovery & inventory browsing.
4. Dual-agent claim, SPIFFE identity binding, and activity stream telemetry.

---

## 2. Architecture & Design Principles

```
  ┌──────────────────────────────────────────────────────────────┐
  │                 make demo-signalloom-smoke                   │
  └──────────────────────────────┬───────────────────────────────┘
                                 │
                                 ▼
  ┌──────────────────────────────────────────────────────────────┐
  │               scripts/demo-signalloom-smoke.sh               │
  │  • Phase 1: Ingress Gateway & Cluster Discovery              │
  │  • Phase 2: Dynamic Port-Forward Supervision & Probe         │
  │  • Phase 3: Playwright Runner + SLA Enforcement (<90s)       │
  └──────────────┬───────────────────────────────┬───────────────┘
                 │                               │
                 ▼                               ▼
  ┌──────────────────────────────┐ ┌─────────────────────────────┐
  │    Kubernetes Infrastructure │ │  Playwright Acceptance Spec │
  │ • Envoy Gateway (:30754)     │ │  test/acceptance/           │
  │ • Dex OIDC (:15556)          │ │  smoke-onboarding-agents    │
  │ • fe-signalloom API (:18000) │ │  .spec.ts                   │
  └──────────────────────────────┘ └─────────────────────────────┘
```

### 2.1 Non-Destructive Preflight & Port-Forward Management

The runner `scripts/demo-signalloom-smoke.sh` implements an intelligent 3-phase lifecycle:
1. **Cluster API Readiness**: Probes the Kubernetes API server and dynamically discovers the Envoy Gateway data-plane service (`gateway.envoyproxy.io/owning-gateway-name=cluster`).
2. **Socket Discovery & Reuse**:
   - Probes `localhost:30754` for an active Gateway listener using SNI `dashboard.osramp.acme.local`.
   - If an existing healthy listener is active, it reuses it; otherwise, it establishes a background `kubectl port-forward`.
   - Manages dedicated forwards for Dex OIDC (`15556`) and the Backend API (`18000`).
   - Uses a bash exit trap (`trap cleanup EXIT INT TERM`) to guarantee zero orphaned child processes.

### 2.2 Unprivileged Sandboxed Browser Isolation

Running automated browser tests inside Linux container sandboxes (e.g. nono/Landlock environments) imposes strict constraints:
- Hardware GPU acceleration is unavailable, and direct access to `/sys/bus/pci` is denied.
- Chromium renderer processes require complete software rendering bypass flags:
  `--no-sandbox`, `--disable-setuid-sandbox`, `--disable-gpu`, `--disable-gpu-compositing`, `--disable-gpu-rasterization`, `--disable-gpu-early-init`, `--disable-gpu-sandbox`, `--use-gl=disabled`, `--disable-software-rasterizer`, `--disable-dev-shm-usage`, `--ignore-certificate-errors`.
- `playwright.config.ts` centralizes these flags in the root `use.launchOptions.args`, ensuring consistent execution across all projects.

### 2.3 Idempotent Test Journey Sequencing

The test suite in `test/acceptance/smoke-onboarding-agents.spec.ts` is structured for serial reliability:
1. **Skip Flow Verification**: Validates immediate status persistence and navigation to the overview dashboard.
2. **Complete 3-Step Wizard**:
   - **Step 1 (Tenant & Identity)**: Asserts validation boundary behavior on empty organization input, then enters valid tenant metadata.
   - **Step 2 (IdP Linkage)**: Connects to Dex OIDC, triggers in-cluster connection probe, and verifies success feedback.
   - **Step 3 (Containment Consent)**: Verifies summary propagation, asserts zero-trust policy consents, and submits completion.
   - **Step 4 (Celebration Screen)**: Confirms celebration modal and executes overview redirection.
3. **Dual-Agent Fleet Inventory**: Navigates to `/agents`, asserts inventory grid mounting, and verifies workload count.
4. **Dual-Agent Claim & Telemetry**: Navigates to `/agents/agent-triage`, verifies SPIFFE workload identity cryptographic binding, and confirms live telemetry streaming in the Activity Timeline.

---

## 3. SLA Enforcement & Governance Integration

- **Strict SLA Timer**: The runner records `START_TIME` and `END_TIME`. If wall-clock elapsed time exceeds 90 seconds, the script exits with code 1 and emits an explicit `SLA VIOLATION` error.
- **Spec Registry Tracking**: Registered in `test/acceptance/SPEC-REGISTRY.tsv` under `make:demo-signalloom-smoke`.
- **CI Parity**: Validated by `bats test/acceptance-spec-coverage.bats` to guarantee registry integrity.
