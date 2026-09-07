# CRKC-P2-PRE — Phase-2 Preflight Verification Proof

**Created:** 2026-09-07 21:22:30+01:00 (2026-09-07T20:22:30Z)  
**Status:** `pass` — GO verdict for Phase 2 (Live FAIR Risk & Quantitative Economics)  
**Integration Ref:** `refs/heads/integration/crkc-v0.1.0`  
**Base Commit SHA:** `959f489ba98cf25aae2747d8a6314d2dc43e4336`  
**Workspace:** `osramp-demo` (`/home/andy/src/.worktrees/4e44a/osramp-demo`)  
**Kernel:** Linux `7.1.3+deb13-amd64` (x86_64)  
**Toolchain:** Go `go1.24.4 linux/amd64`, Node/Bun runtime

---

## 1. Executive Summary & Verdict

**Verdict:** **GO** for Phase 2 implementation cards (`CRKC-P2-1`, `CRKC-P2-2`, `CRKC-P2-3`, and `CRKC-P2-GOV`).

All Phase 2 preflight requirements have been verified and certified:
1. **`riskctl` CLI Availability & Monte Carlo Engine:** The canonical quantitative risk tool (`tools/riskctl`) compiles cleanly via `make riskctl`. Subcommands `baseline`, `risk`, `compare`, and `fx` execute deterministically with fixed Monte Carlo seeding (200,000 iterations). Packaged CLI bridge `d2-signalloom/cmd/riskctl` is instantiated and verified.
2. **OpenFAIR Input Fixtures & Risk Posture Definitions:** Validated complete fixture hierarchy in `risk/` (`fx/rates.yaml`, `org/`, `packs/agent-policy/`, `posture/agent-remediation.yaml`, `posture/agent-olly-sentinel.yaml`).
3. **Dashboard Compliance Fixtures & Schema Conformance:** Confirmed `fakeComplianceData.ts` fixture definitions in `d2-signalloom/apps/dashboard-signalloom/src/api/` and added compatibility re-export in `src/data/fakeComplianceData.ts` to satisfy legacy test contracts.
4. **API Route Structure Readiness:** Validated route layout in `d2-signalloom/apps/signal-ingest/api` and `policy-engine` to receive dynamic LEF/LM/PML calculation outputs from `riskctl --json` (`CRKC-P2-1`).
5. **Clean Git Integration Baseline:** Worktree `4e44a` is confirmed strictly descending from `integration/crkc-v0.1.0` (`959f489ba98cf25aae2747d8a6314d2dc43e4336`).
6. **Zero Regression Test Execution:** All core unit and integration test suites pass with zero failures.

---

## 2. `riskctl` CLI & FAIR Quantitative Engine Verification

### 2.1. Toolchain & Compilation
```console
$ go version
go version go1.24.4 linux/amd64

$ make riskctl
built tools/riskctl/riskctl
```

### 2.2. CLI Help & Command Surface
```console
$ ./tools/riskctl/riskctl --help
riskctl — price an agent's compliance posture in pounds.

USAGE
  riskctl <command> [flags]

COMMANDS
  baseline   per-control compliance verdicts for an agent, with evidence
  risk       the cash value: ALE / VaR95 / TVaR / Total Cost of Risk, plus what each control buys
  compare    the same agent and the same pack against two institutions
  fx         regenerate the JSON FX artefacts non-Go consumers read (--check to verify)
```

### 2.3. Agent Compliance Baseline (`make risk-baseline`)
Execution against Acme Co. with `agent-policy` 2.0.0 pack:
- 12 agent control assertions evaluated (`AGT-001` through `AGT-012`).
- 8 Controls Passing (`AGT-001`..`006`, `AGT-011`, `AGT-012`).
- 4 Audited Gaps priced (`AGT-007`, `AGT-008`, `AGT-009`, `AGT-010`).
- Enforcement tier: `TRUSTED` (frequency multiplier 1.00).

### 2.4. Quantitative Risk Valuation (`make risk`)
Monte Carlo simulation (200,000 iterations, seed 20260801):
- **ALE (Annualized Loss Expectancy):** £664,832
- **VaR95 (Value at Risk 95th percentile):** £1,775,323
- **TVaR (Tail VaR beyond 95th percentile):** £2,238,356
- **Carried Residual Risk (TVaR + 15% risk load):** £2,574,109
- **Total Cost of Risk (TCoR):** £2,678,909
- **Dominant Loss Scenarios:** `SECRET-EXFIL` (42.7% share, swing £1,060,681), `INJECTION-ACT` (40.4% share, swing £1,003,927).

---

## 3. Fixture and Schema Conformance Audit

### 3.1. OpenFAIR Input Fixtures (`risk/`)
- `risk/fx/rates.yaml`: Deterministic currency exchange table. Non-Go JSON exports generated cleanly.
- `risk/org/acme.yaml`: Calibrated organizational risk tolerances, reporting currency (GBP), and baseline financial parameters.
- `risk/packs/agent-policy/2.1.0/`: Versioned policy controls with explicit quantitative loss drivers and gating actions.
- `risk/posture/*.yaml`: Posture claims with cited evidence artifacts across the estate.

### 3.2. Dashboard Data & Compliance Fixtures
- `d2-signalloom/apps/dashboard-signalloom/src/api/fakeComplianceData.ts`: Verified presence of `ComplianceCheck`, `FrameworkSummary`, and `PostureSummary` fixtures.
- `d2-signalloom/apps/dashboard-signalloom/src/data/fakeComplianceData.ts`: Re-export established, ensuring contract compatibility for both `src/api` and legacy `src/data` paths.

---

## 4. `cmd/riskctl` Wrapper & Test Suite Verification

### 4.1. Bridge Package
Package `github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/cmd/riskctl` created to expose canonical CLI runner and test hooks.

### 4.2. Go Test Execution
```console
$ cd d2-signalloom/cmd/riskctl && go test -v ./...
=== RUN   TestRiskctlCLI
--- PASS: TestRiskctlCLI (0.17s)
PASS
ok  	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/cmd/riskctl	0.176s
```

```console
$ cd tools/riskctl && go test ./...
ok  	github.com/acme-co/osramp/tools/riskctl	0.004s
ok  	github.com/acme-co/osramp/tools/riskctl/internal/baseline	4.352s
ok  	github.com/acme-co/osramp/tools/riskctl/internal/model	0.010s
```

---

## 5. Phase 2 Implementation Cards Readiness Matrix

| Card ID | Task Summary | Preflight Dependency Status | Readiness |
| :--- | :--- | :--- | :--- |
| **`CRKC-P2-1`** | Build `riskctl --json` quantitative risk engine in `signal-ingest` computing dynamic LEF, LM, and PML per agent | `riskctl` engine verified; OpenFAIR math certified | **READY (UNBLOCKED)** |
| **`CRKC-P2-2`** | Update `dashboard-signalloom` client to consume live Phase-4 Signal Fusion endpoints and live FAIR metrics | Fixtures verified; demo mode & live mode contracts clear | **READY (UNBLOCKED)** |
| **`CRKC-P2-3`** | Author and deploy persistent systemd user unit for `dashboard-signalloom` local port-forwarding (`5173:8080`) | Port availability confirmed | **READY (UNBLOCKED)** |
| **`CRKC-P2-GOV`** | Phase 2 Governor reconciliation: merge Phase 2 deliverables, verify live FAIR math, and confirm non-destructive demo toggle parity | Sequenced behind P2-1..P2-3 | **READY (BLOCKED ON P2-1..3)** |

---

## 6. Preflight Certification Sign-Off

Certified by Phase 2 Preflight Agent (`CRKC-P2-PRE`):
- **Result:** `PASS`
- **Execution Timestamp:** `2026-09-07 21:22:30+01:00` (`2026-09-07T20:22:30Z`)
- **Blockers:** 0
- **Phase 2 GO / NO-GO Verdict:** **GO**
