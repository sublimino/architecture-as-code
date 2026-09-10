# SLON-P2-4 Operator Guide — Rapid Demo Smoke Suite

**Mission ID**: `SLON-P2-4`  
**Target Command**: `make demo-signalloom-smoke`  
**Execution Budget**: Strictly < 90 seconds (Typical: 10–15 seconds)

---

## 1. Quick Start

Run the smoke test target from the repository root:

```bash
make demo-signalloom-smoke
```

### Expected Terminal Output

```text
════════════════════════════════════════════════════════════════════
  Signal Loom Demo Smoke Test Suite (SLON-P2-4)
  Target: User Onboarding & Dual-Agent Claim Verification
  SLA: < 90 seconds
════════════════════════════════════════════════════════════════════

==> [1/3] Probing cluster foundation & ingress readiness...
    ✓ Kubernetes API server reachable
    ✓ Ingress Gateway service discovered (envoy-ingress-cluster-6b24dc08)
    ✓ fe-signalloom backend deployment present
    ✓ Dex OIDC provider deployment present
==> [2/3] Verifying / establishing gateway & auth endpoints...
    ✓ Established Gateway port-forward on localhost:30754
    ✓ Started Dex port-forward on localhost:15556
    ✓ Started fe-signalloom port-forward on localhost:18000
==> [3/3] Executing Playwright smoke suite (smoke-onboarding-agents.spec.ts)...

Running 4 tests using 1 worker

     1 …oarding: skip flow records persistent status and transitions to overview
  ✓  1 …: skip flow records persistent status and transitions to overview (2.4s)
     2 …mplete 3-step wizard with validation, IdP test, consent, and celebration
  ✓  2 …3-step wizard with validation, IdP test, consent, and celebration (2.1s)
     3 … › dual-agent fleet: inventory discovery and comparative workload status
  ✓  3 …-agent fleet: inventory discovery and comparative workload status (1.4s)
     4 …emetry: claim verification, SPIFFE identity binding, and activity stream
  ✓  4 … claim verification, SPIFFE identity binding, and activity stream (2.0s)

  4 passed (8.3s)

════════════════════════════════════════════════════════════════════
  Smoke Suite Execution Summary
  Duration: 11s (SLA: <90s)
  Exit Code: 0
════════════════════════════════════════════════════════════════════
✅ DEMO SMOKE SUITE PASSED in 11s (strictly under 90s SLA).
==> Cleaning up background port-forwards...
```

---

## 2. Test Journey Coverage

| Journey | Spec Test Case | Verified Capabilities |
| :--- | :--- | :--- |
| **1. Skip Flow** | `user onboarding: skip flow records persistent status...` | Skip button action, skip state persistence in localStorage/API, seamless redirect to Overview. |
| **2. Guided Wizard** | `user onboarding: complete 3-step wizard...` | Step 1 tenant configuration & validation banners; Step 2 Dex OIDC provider testing; Step 3 Zero-Trust containment consent; Step 4 Celebration screen & redirect. |
| **3. Fleet Inventory** | `dual-agent fleet: inventory discovery...` | Agent roster loading, comparative workload status badges, discovery links. |
| **4. Claim & Telemetry** | `dual-agent claim & telemetry: claim verification...` | Operator claim verification, SPIFFE ID (`spiffe://...`) cryptographic binding, live Activity Timeline stream. |

---

## 3. Troubleshooting & Diagnostics

### Preflight Endpoint Issues
If the cluster or Gateway is unreachable:
1. Check Kind cluster state: `kubectl get nodes`
2. Check ingress namespace services: `kubectl -n ingress get svc`
3. Verify backend deployment: `kubectl -n fe-signalloom get deploy`

### Debugging Individual Journeys
Run single test with debug tracing:
```bash
cd test/acceptance
PW_CHANNEL=chromium bunx playwright test --config=playwright.config.ts smoke-onboarding-agents.spec.ts -g "wizard"
```
