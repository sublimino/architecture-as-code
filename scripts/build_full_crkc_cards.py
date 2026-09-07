#!/usr/bin/env python3
import json
import os
import sys
import subprocess

REPO = "/home/andy/src/cp/osramp-demo"
sys.path.insert(0, f"{REPO}/scripts")
from compile_crkc_cards import run_create, verify_spec

cards = [
    # ─── PHASE 2 ─────────────────────────────────────────────────────────────
    {
        "logical_id": "P2-PRE",
        "role": "preflight",
        "title": "Phase 2 preflight: verify riskctl CLI binary availability, OpenFAIR input fixtures, and API route structure",
        "size": "S",
        "agent": "fast",
        "depends_on": ["P1-GOV"],
        "spec": {
            "objective": "Perform comprehensive preflight verification for Phase 2 (Live FAIR Risk and Live Data Parity). Confirm that the riskctl CLI binary builds cleanly from source or is accessible in PATH, verify existing OpenFAIR input schema fixtures and Loss Event Frequency (LEF) / Loss Magnitude (LM) test parameters, inspect signal-ingest and dashboard-signalloom API route structures for FAIR telemetry ingestion, and author the certified preflight proof artifact docs/signalloom/crkc-p2-preflight-proof.md with complete command outputs.",
            "approach": (
                "Step 1: Inspect local Go compiler toolchain and verify riskctl command availability or compilation prerequisites in d2-signalloom/cmd/riskctl/.\n"
                "Step 2: Inspect d2-signalloom/apps/dashboard-signalloom/src/data/ fixtures to map existing mock FAIR risk calculations, models, and distribution shapes.\n"
                "Step 3: Validate API route definitions in d2-signalloom/apps/signal-ingest/ covering agent risk observations, telemetry streams, and who-authorized endpoints.\n"
                "Step 4: Verify network connectivity between dashboard port-forward target and backend API services across cluster namespaces.\n"
                "Step 5: Author certified preflight proof artifact docs/signalloom/crkc-p2-preflight-proof.md with execution timestamps and checksums.\n"
                "Step 6: Check git baseline status to confirm that integration/crkc-v0.1.0 is completely clean and ready for Phase 2 implementation branches."
            ),
            "deliverables": [
                "Preflight capability audit report for OpenFAIR engine prerequisites and build dependencies",
                "Verification log confirming riskctl binary compilation and CLI flag schema options",
                "Schema map of live FAIR API endpoints versus dashboard mock fixtures in fakeComplianceData.ts",
                "Certified preflight proof artifact recorded in docs/signalloom/crkc-p2-preflight-proof.md with execution timestamps",
                "Clean environment checklist verifying zero uncommitted working tree modifications on integration/crkc-v0.1.0"
            ],
            "evidence": [
                "Preflight proof artifact recorded in docs/signalloom/crkc-p2-preflight-proof.md with UTC timestamp",
                "Successful dry-run invocation of riskctl --help or build verification log from go build",
                "Zero lint or schema errors across OpenFAIR fixture definitions in dashboard data folder",
                "Clean exit code 0 on all read-only preflight diagnostic checks",
                "Git status confirmation proving working tree cleanliness on integration/crkc-v0.1.0"
            ],
            "keyFacts": [
                "OpenFAIR quantitative risk modeling calculates Value at Risk using Loss Event Frequency (LEF) and Loss Magnitude (LM)",
                "Signal Loom currently features a DemoToggle switching between fakeComplianceData.ts and live endpoints",
                "Rule SP-3 dictates non-destructive demo parity: DemoToggle fixtures must remain functional when demoMode is true",
                "Phase 2 integrates live mathematical risk scoring into live dashboard telemetry"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-GOV certified Phase 1 Tier 0 and Tier 1 containment baseline"
            ],
            "outOfScope": [
                "Modifying riskctl calculation engine (assigned to CRKC-P2-1)",
                "Updating React dashboard UI components (assigned to CRKC-P2-2)",
                "Authoring systemd port-forward unit (assigned to CRKC-P2-3)",
                "Modifying cluster ingress NetworkPolicies or Gateway API routing"
            ],
            "priorErrata": [
                "CRKC-P1-GOV: Phase 1 certified; in-kernel stun and GitOps drift preservation active"
            ],
            "sharedFileRisks": [
                "Card writes exclusively to docs/signalloom/crkc-p2-preflight-proof.md"
            ],
            "failureModes": [
                "riskctl build failure due to missing math or stats dependencies: verify Go toolchain version",
                "Fixture schema mismatch: reconcile JSON schema definitions in signal-ingest",
                "Go compiler version outdated: verify go version reports 1.22 or higher",
                "Network unreachable for internal service discovery: verify CoreDNS pods in cluster"
            ],
            "loopOn": [
                "Poll go build ./d2-signalloom/cmd/riskctl/... until binary compiles cleanly",
                "Check test -f docs/signalloom/crkc-p2-preflight-proof.md"
            ],
            "stopAndReport": [
                "Missing Go compiler toolchain",
                "CRKC-P1-GOV governor certification missing from integration branch"
            ],
            "testSurface": [
                "test -f docs/signalloom/crkc-p2-preflight-proof.md",
                "go test ./d2-signalloom/cmd/riskctl/...",
                "test -f d2-signalloom/apps/dashboard-signalloom/src/data/fakeComplianceData.ts",
                "go version"
            ],
            "mergeBoundary": "Fast-forward merges cleanly into integration/crkc-v0.1.0 without modifying application code."
        }
    },
    {
        "logical_id": "P2-1",
        "role": "implementation",
        "title": "Build riskctl --json quantitative risk engine in signal-ingest computing dynamic LEF, LM, and PML per agent",
        "size": "L",
        "agent": "deep",
        "deep_rationale": "Requires complex statistical OpenFAIR quantitative risk modeling, Monte Carlo simulation math in Go, dynamic LEF/LM parameter derivation from live agent telemetry, and FrostDB time-series integration with zero drift tolerance.",
        "depends_on": ["P2-PRE"],
        "spec": {
            "objective": "Build the riskctl --json quantitative risk engine in Go integrated within signal-ingest, implementing the OpenFAIR risk standard to dynamically compute Loss Event Frequency (LEF), Loss Magnitude (LM), and Probable Maximum Loss (PML) per agent from real-time operational telemetry and security findings. Expose high-performance REST and gRPC endpoints delivering mathematically sound Value at Risk (VaR) percentiles with sub-50ms p95 latency.",
            "approach": (
                "Step 1: Implement OpenFAIR mathematical model in d2-signalloom/apps/signal-ingest/pkg/fair/engine.go supporting lognormal and PERT distributions for Threat Event Frequency and Vulnerability.\n"
                "Step 2: Build Monte Carlo simulation runner executing 10,000 trials per risk evaluation within a strict 20 millisecond computational ceiling.\n"
                "Step 3: Map live agent telemetry (runtime violations, credential state, network anomalies, CVE findings) to dynamic LEF and LM distribution parameters.\n"
                "Step 4: Implement CLI utility d2-signalloom/cmd/riskctl outputting formatted JSON risk summaries including LEF, LM, PML (95th percentile loss), and Annualized Loss Expectancy (ALE).\n"
                "Step 5: Expose API endpoint GET /api/v1/risk/agents/{id} in signal-ingest returning live FAIR calculations with caching and FrostDB persistence.\n"
                "Step 6: Author comprehensive mathematical unit tests in pkg/fair/engine_test.go validating statistical convergence against verified OpenFAIR benchmarks.\n"
                "Step 7: Build contract test asserting 0% divergence between signal-ingest REST API output and riskctl --json command-line ground truth.\n"
                "Step 8: Implement concurrency benchmarks in test/bench-fair-engine.sh proving p95 evaluation latency under 50ms under 500 concurrent requests.\n"
                "Step 9: Document OpenFAIR calculation methodology, input parameter mapping, and distribution formulas in docs/signalloom/openfair-quantitative-risk.md.\n"
                "Step 10: Implement Prometheus metrics instrumentation exposing risk_calculation_duration_seconds and agent_pml_loss_dollars.\n"
                "Step 11: Add input parameter bounds checking to reject negative values, NaN, and infinite numbers in loss distributions.\n"
                "Step 12: Implement deterministic seed control via --seed flag for reproducible audit and testing verification.\n"
                "Step 13: Build integration test fixtures simulating diverse agent threat profiles ranging from clean to compromised."
            ),
            "deliverables": [
                "OpenFAIR calculation engine package in d2-signalloom/apps/signal-ingest/pkg/fair/engine.go",
                "Monte Carlo simulation runner with PERT and lognormal distribution support",
                "riskctl CLI tool supporting --json, --agent, --trials, and --seed flags in d2-signalloom/cmd/riskctl/",
                "REST API endpoint GET /api/v1/risk/agents/{id} serving dynamic FAIR metrics",
                "Mathematical validation unit test suite with 100% distribution coverage in pkg/fair/engine_test.go",
                "Parity contract test test/fair-api-parity.bats verifying 0% divergence between API and CLI",
                "Benchmark harness measuring Monte Carlo throughput in test/bench-fair-engine.sh",
                "Comprehensive quantitative risk architecture specification docs/signalloom/openfair-quantitative-risk.md",
                "Prometheus metrics instrumentation for risk calculation latency and loss metrics",
                "Input parameter validation library rejecting NaN, Inf, and negative loss parameters",
                "Audit trail logger recording risk score transitions and parameter derivations"
            ],
            "evidence": [
                "Go test run log verifying 100% pass rate on mathematical and statistical convergence tests",
                "Test output from test/fair-api-parity.bats showing exact JSON key and value parity",
                "Benchmark report demonstrating 10,000 Monte Carlo trials completed in < 20ms",
                "Sample riskctl --json output showing valid LEF, LM, ALE, and PML distributions",
                "Prometheus metrics output showing risk calculation latency p95 < 50ms",
                "Recorded evidence artifact in docs/signalloom/evidence/openfair-engine-proof.json",
                "Statistical validation report confirming convergence to theoretical lognormal percentiles within 1%",
                "Zero divergence report between signal-ingest REST endpoint and riskctl CLI across 50 sample agent fixtures",
                "Clean Go benchmark output showing memory allocations under 2MB per 10,000 trials"
            ],
            "keyFacts": [
                "OpenFAIR defines risk as the probable frequency and probable magnitude of future loss",
                "Threat Event Frequency (TEF) and Vulnerability (V) combine to form Loss Event Frequency (LEF)",
                "Loss Magnitude (LM) captures primary and secondary loss factors in currency units",
                "Probable Maximum Loss (PML) typically represents the 95th percentile of the annualized loss distribution",
                "Deterministic PRNG seeding in tests ensures reproducible Monte Carlo simulation outcomes"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P2-PRE verified riskctl build environment and OpenFAIR schema definitions",
                "signal-ingest agent telemetry pipelines and FrostDB storage"
            ],
            "outOfScope": [
                "Modifying React dashboard UI components (assigned to CRKC-P2-2)",
                "Deploying systemd port-forward unit (assigned to CRKC-P2-3)",
                "Host-level Landlock policy enforcement (Phase 3)",
                "Modifying kernel eBPF packet drop filters (Phase 1)",
                "Implementing third-party proprietary risk framework adapters (e.g. NIST CSF 2.0 scoring mappings)",
                "Altering database storage schema outside FrostDB time-series tables"
            ],
            "priorErrata": [
                "CRKC-P2-PRE: OpenFAIR fixtures and compilation prerequisites verified"
            ],
            "sharedFileRisks": [
                "signal-ingest router and server initialization files are touched; coordinate route registration without breaking existing API routes"
            ],
            "failureModes": [
                "Simulation divergence: unseeded Monte Carlo trials producing stochastic test assertion failures; enforce deterministic seed in unit tests",
                "CPU starvation from excessive simulation trials: enforce max trial limit of 20,000 and implement worker pool",
                "Zero division in lognormal parameters: validate non-zero standard deviation on loss magnitude inputs",
                "Memory allocation pressure in Monte Carlo trial loops: pre-allocate float64 result slices to avoid GC churn",
                "API timeout on cold cache: implement background parameter precomputation for active agents",
                "Numerical overflow on large loss calculations: clamp values to valid float64 ranges",
                "Stale agent telemetry cache: invalidate cache when new runtime security findings are ingested",
                "Concurrent map write panic during parallel Monte Carlo trial execution: utilize thread-safe sync primitives"
            ],
            "loopOn": [
                "Run go test ./d2-signalloom/apps/signal-ingest/pkg/fair/... until all statistical assertions pass",
                "Poll curl http://localhost:8080/api/v1/risk/agents/test-agent until HTTP 200 is returned"
            ],
            "stopAndReport": [
                "Mathematical divergence exceeding 0.1% against standard OpenFAIR benchmark vectors",
                "p95 calculation latency exceeds 50ms SLA under benchmark load",
                "signal-ingest crashes or leaks memory during Monte Carlo simulation"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/apps/signal-ingest/pkg/fair/...",
                "bats test/fair-api-parity.bats",
                "scripts/test-riskctl.sh",
                "test/bench-fair-engine.sh",
                "curl -s http://localhost:8080/api/v1/risk/agents/test-agent",
                "go test -bench=BenchmarkMonteCarlo ./d2-signalloom/apps/signal-ingest/pkg/fair/..."
            ],
            "mergeBoundary": "Isolates to d2-signalloom/apps/signal-ingest/pkg/fair/, cmd/riskctl/, and test/fair-api-parity.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P2-2",
        "role": "implementation",
        "title": "Update dashboard-signalloom client to consume live Phase-4 Signal Fusion endpoints and live FAIR metrics when demoMode === false",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P2-PRE"],
        "spec": {
            "objective": "Update dashboard-signalloom Single Page Application (SPA) client to consume live Phase-4 Signal Fusion endpoints, real-time agent observation streams, and dynamic OpenFAIR quantitative risk metrics when demoMode is false, while preserving 100% functional parity with offline mock fixtures (fakeComplianceData.ts) when demoMode is true per Rule SP-3.",
            "approach": (
                "Step 1: Inspect dashboard-signalloom API client hooks in src/hooks/ and src/services/ to identify all mock data branching points.\n"
                "Step 2: Update useComplianceData, useAgentRisk, and useAgentEvidence hooks to query live backend endpoints (/api/v1/who-authorized, /api/v1/observations, /api/v1/risk/agents/{id}) when demoMode is toggled off.\n"
                "Step 3: Integrate live FAIR risk metrics (LEF, LM, PML, ALE) into agent inventory cards, detail drawers, and risk summary widgets.\n"
                "Step 4: Implement graceful fallback and visual error indicators when live API endpoints are temporarily unreachable without breaking UI rendering.\n"
                "Step 5: Verify that the DemoToggle widget in the navigation bar cleanly switches between live data and mock fixtures without requiring page reload.\n"
                "Step 6: Author comprehensive Vitest component tests in src/pages/AgentsPage.test.tsx and src/components/RiskWidget.test.tsx verifying both live and demo rendering modes.\n"
                "Step 7: Add Playwright acceptance test test/acceptance/demo-live-parity.spec.ts testing interactive toggle switching and data validation in headless Chromium.\n"
                "Step 8: Document client data-flow architecture and live API configuration options in docs/signalloom/dashboard-live-data-integration.md.\n"
                "Step 9: Validate accessibility and ARIA labeling across all new risk visualizations and dynamic gauges."
            ),
            "deliverables": [
                "Updated API service client and custom React hooks supporting live FAIR risk queries in d2-signalloom/apps/dashboard-signalloom/src/services/api.ts",
                "Enhanced agent evidence and risk display components rendering live PML and LEF metrics in AgentEvidenceDrawer",
                "Zero-regression preservation of fakeComplianceData.ts fixtures under demoMode === true",
                "Unit and component test suite in src/pages/AgentsPage.test.tsx with 100% pass rate",
                "Playwright browser test suite test/acceptance/demo-live-parity.spec.ts validating live and demo toggle states",
                "User documentation in docs/signalloom/dashboard-live-data-integration.md",
                "Component snapshot tests verifying visual fidelity across both operating modes",
                "Type definitions for live FAIR API responses in src/types/fair.ts"
            ],
            "evidence": [
                "Vitest run output showing all dashboard test suites passing cleanly with zero failed assertions",
                "Playwright test report verifying interactive toggle operation and live API responses in Chrome",
                "DOM snapshot confirming live FAIR loss figures rendered when demoMode is false",
                "DOM snapshot confirming static fixture values rendered when demoMode is true",
                "Clean TypeScript typecheck (bun run tsc --noEmit) without type errors",
                "Evidence artifact recorded in docs/signalloom/evidence/dashboard-live-parity-proof.json"
            ],
            "keyFacts": [
                "Rule SP-3 dictates Non-Destructive Demo Mode Parity: offline demo toggle fixtures must remain completely functional",
                "dashboard-signalloom uses React, Vite, and Vitest for testing",
                "AgentEvidenceDrawer renders deep inspection evidence for selected agents",
                "API routes are proxied via Vite dev server or production Nginx gateway to backend services",
                "Vitest suite contains 149 test files with over 2,800 unit and component tests"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P2-PRE verified API schemas",
                "CRKC-P2-1 exposed live FAIR risk endpoints in signal-ingest",
                "Existing dashboard-signalloom SPA codebase"
            ],
            "outOfScope": [
                "Building the backend FAIR calculation engine (handled in CRKC-P2-1)",
                "Configuring systemd port-forward service (assigned to CRKC-P2-3)",
                "Host Landlock admission profiles (Phase 3)",
                "Modifying server-side database schema or FrostDB collectors"
            ],
            "priorErrata": [
                "CRKC-P2-PRE: API schema and route structure verified"
            ],
            "sharedFileRisks": [
                "AgentsPage.tsx and App.tsx are modified; preserve 7-column layout and existing route definitions"
            ],
            "failureModes": [
                "Live API network error breaking UI: wrap fetch calls in try/catch and render accessible ErrorState banner",
                "State desynchronization on toggle: cache invalidation issues on toggle switch; trigger React Query / SWR cache refresh",
                "TypeScript type mismatch between wire format and component props: share canonical TypeScript interfaces",
                "Memory leak in SSE telemetry subscribers: ensure clean useEffect cleanup on component unmount",
                "Stale UI rendering on fast toggle switching: implement abort controller for in-flight fetch requests",
                "Broken CSS styling when displaying large currency loss values: implement responsive truncation"
            ],
            "loopOn": [
                "Run bun test in dashboard-signalloom until all suites pass",
                "Check browser console logs during Playwright run for unhandled promise rejections"
            ],
            "stopAndReport": [
                "Demo toggle mode broken or fails to render fixtures",
                "TypeScript compiler reports errors in dashboard components",
                "Vitest test suites regress"
            ],
            "testSurface": [
                "bun run --cwd d2-signalloom/apps/dashboard-signalloom test --run",
                "bun run --cwd d2-signalloom/apps/dashboard-signalloom typecheck",
                "npx playwright test test/acceptance/demo-live-parity.spec.ts",
                "scripts/test-dashboard-parity.sh"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/apps/dashboard-signalloom/src/ and test/acceptance/demo-live-parity.spec.ts. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P2-3",
        "role": "implementation",
        "title": "Author and deploy persistent systemd user unit for dashboard-signalloom local port-forwarding (5173:8080)",
        "size": "S",
        "agent": "fast",
        "depends_on": ["P2-PRE"],
        "spec": {
            "objective": "Author, install, and supervise a robust systemd user service unit (signalloom-portforward.service) that maintains durable, auto-restarting local port-forwarding from localhost:5173 to envoy gateway / dashboard service (8080), eliminating broken developer and browser connections across cluster restarts and pod rollouts.",
            "approach": (
                "Step 1: Inspect systemd user unit directory ~/.config/systemd/user/ and author signalloom-portforward.service definition.\n"
                "Step 2: Configure ExecStart to execute kubectl port-forward with exponential backoff restart policy (Restart=always, RestartSec=3).\n"
                "Step 3: Ensure unit binds to default.target with proper environment variables (KUBECONFIG, PATH).\n"
                "Step 4: Reload systemd daemon via systemctl --user daemon-reload and enable unit.\n"
                "Step 5: Verify port 5173 availability via curl -I http://localhost:5173.\n"
                "Step 6: Author verification script in scripts/verify-portforward-service.sh testing service resilience across simulated pod deletion.\n"
                "Step 7: Document port-forwarding architecture, troubleshooting, and lifecycle commands in docs/signalloom/durable-port-forwarding.md."
            ),
            "deliverables": [
                "Systemd user unit manifest ~/.config/systemd/user/signalloom-portforward.service",
                "Installation and lifecycle management script scripts/manage-portforward-service.sh",
                "Automated verification test script scripts/verify-portforward-service.sh",
                "Operational documentation in docs/signalloom/durable-port-forwarding.md",
                "Systemd drop-in configuration for customized local port overrides"
            ],
            "evidence": [
                "systemctl --user status signalloom-portforward showing active (running)",
                "curl http://localhost:5173 returning HTTP 200",
                "Test log showing port-forward recovering automatically after target pod restart",
                "Clean exit code 0 from scripts/verify-portforward-service.sh",
                "Recorded evidence artifact in docs/signalloom/evidence/portforward-service-proof.json"
            ],
            "keyFacts": [
                "kubectl rollout restart terminates existing port-forward connections",
                "systemd user services provide process supervision, auto-restart, and journal logging without root privileges",
                "systemd-run --user allows spawning processes outside sandbox boundaries"
            ],
            "consumesFromEarlierPhases": [
                "Running Kind cluster and Envoy gateway ingress"
            ],
            "outOfScope": [
                "Modifying cluster ingress NetworkPolicies",
                "Modifying dashboard React source code",
                "Configuring global systemd system units requiring sudo"
            ],
            "priorErrata": [
                "CRKC-P2-PRE: Confirmed cluster API and Gateway availability"
            ],
            "sharedFileRisks": [
                "Writes to ~/.config/systemd/user/ without modifying system-wide configuration"
            ],
            "failureModes": [
                "Port 5173 already in use by stale process: script must detect and stop stale listeners",
                "systemd user daemon unavailable in container: shell out via systemd-run or fallback to supervised loop",
                "KUBECONFIG environment variable missing in systemd context: explicitly declare Environment=KUBECONFIG in unit"
            ],
            "loopOn": [
                "Poll curl -s -o /dev/null -w '%{http_code}' http://localhost:5173 until 200 is returned",
                "Check systemctl --user is-active signalloom-portforward until active"
            ],
            "stopAndReport": [
                "Port 5173 cannot be bound after 5 retries",
                "Kubernetes API server unreachable"
            ],
            "testSurface": [
                "curl -I http://localhost:5173",
                "systemctl --user status signalloom-portforward",
                "scripts/verify-portforward-service.sh",
                "journalctl --user -u signalloom-portforward --no-pager -n 20"
            ],
            "mergeBoundary": "Isolates to scripts/ and user systemd unit. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P2-GOV",
        "role": "governor",
        "title": "Phase 2 Governor reconciliation: merge Phase 2 deliverables, verify live FAIR math, and confirm non-destructive demo toggle parity",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P2-1", "P2-2", "P2-3"],
        "spec": {
            "objective": "Perform Phase 2 Governor reconciliation by merging all Phase 2 deliverables into integration/crkc-v0.1.0, executing comprehensive mathematical validation of the live OpenFAIR risk calculation engine, proving 100% demo toggle parity across live and fixture modes, certifying systemd port-forward stability, and authoring the Phase 2 Governor Certification proof artifact.",
            "approach": (
                "Step 1: Verify clean completion and test passes for all Phase 2 implementation cards (CRKC-P2-1, CRKC-P2-2, CRKC-P2-3).\n"
                "Step 2: Merge deliverable branches into integration/crkc-v0.1.0 without regressions.\n"
                "Step 3: Execute full suite of mathematical risk tests asserting zero divergence between riskctl --json and live API responses.\n"
                "Step 4: Execute Playwright acceptance tests verifying that switching DemoToggle renders live data when false and mock fixtures when true.\n"
                "Step 5: Verify that the systemd port-forward service recovers seamlessly from simulated pod restarts.\n"
                "Step 6: Author certified Phase 2 governance proof artifact docs/signalloom/crkc-p2-governor-proof.md.\n"
                "Step 7: Update Obsidian proposal errata section with Phase 2 completion ledger and stop in Review state per Rule SP-5.\n"
                "Step 8: Reconcile code coverage reports across Go and React suites ensuring no test regression.\n"
                "Step 9: Publish Phase 2 verification summary to the kanban review ledger."
            ),
            "deliverables": [
                "Unified Phase 2 integration on integration/crkc-v0.1.0 with all Phase 2 tests passing",
                "Phase 2 Governor Certification proof artifact in docs/signalloom/crkc-p2-governor-proof.md",
                "Mathematical verification report confirming OpenFAIR calculation accuracy and zero divergence",
                "Demo mode parity test execution log verifying zero regressions in offline fixtures",
                "Updated proposal errata ledger in Obsidian documenting Phase 2 milestone certification",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off",
                "Pre-flight verification checklist for Phase 3 readiness"
            ],
            "evidence": [
                "Full test execution log of test/fair-api-parity.bats with 100% pass rate",
                "Playwright test report verifying interactive demo toggle operation across views",
                "Vitest dashboard test run confirming 100% pass rate across all 149 test files",
                "Recorded proof artifact docs/signalloom/crkc-p2-governor-proof.md with execution timestamps",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off",
                "Obsidian proposal document updated with Phase 2 certification status"
            ],
            "keyFacts": [
                "Rule SP-3 dictates Non-Destructive Demo Mode Parity",
                "Rule SP-5 mandates that Phase Governors strictly stop in Review and never auto-advance to Done without human operator sign-off",
                "Phase 2 unblocks Phase 3 preflight cards upon certification",
                "Monte Carlo risk simulation must converge within 0.1% of ground truth"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P2-PRE preflight proof",
                "CRKC-P2-1 riskctl engine",
                "CRKC-P2-2 dashboard live client",
                "CRKC-P2-3 systemd port-forward service"
            ],
            "outOfScope": [
                "Executing Phase 3 CEL policy compiler implementation",
                "Authoring Landlock confinement profiles (Phase 3)",
                "Auto-advancing past Review state into Done",
                "Modifying production Gateway API routing rules"
            ],
            "priorErrata": [
                "CRKC-P2-PRE: Preflight verification completed",
                "CRKC-P2-1: OpenFAIR engine verified with zero divergence",
                "CRKC-P2-2: Dashboard live data and demo parity verified",
                "CRKC-P2-3: Systemd user port-forward unit deployed and verified"
            ],
            "sharedFileRisks": [
                "Governor reconciles all Phase 2 files; ensure zero merge conflicts across frontend and backend packages"
            ],
            "failureModes": [
                "Mathematical divergence between API and CLI risk metrics: re-run simulation with fixed seed",
                "Demo mode regression: mock fixtures failing to render when demoMode === true",
                "Port-forward service connection refusal during tests",
                "Merge conflicts between React components and Go API routes"
            ],
            "loopOn": [
                "Run bats test/fair-api-parity.bats until pass",
                "Run bun test in dashboard-signalloom until all pass"
            ],
            "stopAndReport": [
                "Any Phase 2 implementation card fails acceptance criteria",
                "Demo mode fails to render mock data cleanly",
                "Live FAIR engine produces mathematical divergence > 0.1%"
            ],
            "testSurface": [
                "bats test/fair-api-parity.bats",
                "bun run --cwd d2-signalloom/apps/dashboard-signalloom test --run",
                "curl -s http://localhost:5173/api/v1/risk/agents/test-agent",
                "scripts/test-phase2-governor.sh"
            ],
            "mergeBoundary": "Merges Phase 2 deliverables into integration/crkc-v0.1.0. Governor card stops in Review state awaiting operator sign-off."
        }
    },

    # ─── PHASE 3 ─────────────────────────────────────────────────────────────
    {
        "logical_id": "P3-PRE",
        "role": "preflight",
        "title": "Phase 3 preflight: verify Kubernetes cluster VAP admission support and Linux Landlock kernel support (nono)",
        "size": "S",
        "agent": "fast",
        "depends_on": ["P2-GOV"],
        "spec": {
            "objective": "Perform preflight verification for Phase 3 (CEL & Landlock Confinement Mesh). Verify that the Kind Kubernetes cluster has ValidatingAdmissionPolicy (VAP) feature enabled and accessible via admissionregistration.k8s.io/v1, confirm Linux host kernel Landlock LSM support via /sys/kernel/security/lsm and nono CLI capabilities, verify that local git commit operations succeed without GPG signing, and author the certified preflight proof artifact docs/signalloom/crkc-p3-preflight-proof.md with complete command outputs.",
            "approach": (
                "Step 1: Query Kubernetes API server for ValidatingAdmissionPolicy and ValidatingAdmissionPolicyBinding CRD/API support.\n"
                "Step 2: Inspect host kernel LSM configuration in /sys/kernel/security/lsm to verify presence of 'landlock'.\n"
                "Step 3: Test nono CLI profile parsing and sandbox execution capabilities.\n"
                "Step 4: Verify that git commit --no-gpg-sign executes cleanly without invoking interactive pinentry prompts.\n"
                "Step 5: Author certified preflight proof artifact docs/signalloom/crkc-p3-preflight-proof.md with execution timestamps.\n"
                "Step 6: Check git baseline status on integration/crkc-v0.1.0 to ensure a clean working tree before Phase 3 implementation cards begin."
            ),
            "deliverables": [
                "Audit report verifying Kubernetes VAP API registration and cluster compatibility",
                "Host kernel Landlock LSM verification log",
                "nono sandbox profile inspection report",
                "Certified preflight proof artifact recorded in docs/signalloom/crkc-p3-preflight-proof.md",
                "Verification log confirming unsigned local git commit permissions"
            ],
            "evidence": [
                "kubectl api-resources output confirming ValidatingAdmissionPolicy support",
                "Kernel security/lsm inspection containing landlock",
                "Recorded proof artifact docs/signalloom/crkc-p3-preflight-proof.md with execution timestamps",
                "Exit code 0 on all preflight validation commands",
                "Git status log confirming clean baseline on integration/crkc-v0.1.0"
            ],
            "keyFacts": [
                "ValidatingAdmissionPolicy uses Google Common Expression Language (CEL) to enforce in-tree admission rules",
                "Linux Landlock allows unprivileged processes to restrict their own file and network access rights",
                "Rule SP-1 dictates that coding agents must be permitted to execute git commit --no-gpg-sign while blocking unauthorized network push",
                "Rule SP-4 dictates that all admission rules must be expressed in standard Google CEL without external process calls"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P2-GOV certified Phase 2 baseline"
            ],
            "outOfScope": [
                "Building CEL policy compiler (assigned to CRKC-P3-1)",
                "Configuring Landlock profile manifests (assigned to CRKC-P3-2)",
                "Deploying admission webhook (assigned to CRKC-P3-3)",
                "Modifying host network firewall rules directly"
            ],
            "priorErrata": [
                "CRKC-P2-GOV: Phase 2 certified; live FAIR risk and demo parity verified"
            ],
            "sharedFileRisks": [
                "Card writes exclusively to docs/signalloom/crkc-p3-preflight-proof.md"
            ],
            "failureModes": [
                "VAP not enabled in Kubernetes API: verify Kind cluster featureGates configuration",
                "Landlock LSM missing: verify kernel boot arguments and config",
                "nono CLI command missing or outdated: verify path to nono binary"
            ],
            "loopOn": [
                "Poll kubectl api-resources until ValidatingAdmissionPolicy appears",
                "Check grep landlock /sys/kernel/security/lsm"
            ],
            "stopAndReport": [
                "Kubernetes cluster does not support ValidatingAdmissionPolicy",
                "Host kernel lacks Landlock LSM support"
            ],
            "testSurface": [
                "kubectl api-resources --api-group=admissionregistration.k8s.io",
                "cat /sys/kernel/security/lsm",
                "test -f docs/signalloom/crkc-p3-preflight-proof.md",
                "git status"
            ],
            "mergeBoundary": "Fast-forward merges cleanly into integration/crkc-v0.1.0 without modifying application code."
        }
    },
    {
        "logical_id": "P3-1",
        "role": "implementation",
        "title": "Build declarative CEL-to-Landlock policy compiler translating security invariants into Kubernetes VAP and nono profiles",
        "size": "L",
        "agent": "deep",
        "deep_rationale": "Requires authoring a multi-target policy compilation engine translating high-level declarative security invariants YAML into Kubernetes ValidatingAdmissionPolicy CEL expressions and Linux Landlock nono JSON confinement profiles with formal semantic equivalence.",
        "depends_on": ["P3-PRE"],
        "spec": {
            "objective": "Build a declarative security policy compiler in Go (policy-compiler) that ingests unified security invariant definitions (invariants.yaml) and compiles them into Kubernetes ValidatingAdmissionPolicy (VAP) CEL expressions for in-cluster governance and nono profile configurations for local host Landlock process confinement, guaranteeing formal semantic equivalence across execution tiers.",
            "approach": (
                "Step 1: Define canonical declarative policy schema in d2-signalloom/pkg/policy/schema.go supporting filesystem, process execution, and network access rules.\n"
                "Step 2: Implement CEL code generator in pkg/policy/cel_generator.go transforming invariant rules into standard Google CEL validation expressions conforming to Kubernetes VAP constraints.\n"
                "Step 3: Implement Landlock profile generator in pkg/policy/landlock_generator.go transforming invariant rules into nono JSON configuration profiles with filesystem.allow, filesystem.deny, and network policies.\n"
                "Step 4: Build CLI tool d2-signalloom/cmd/policy-compiler supporting compile, validate, and verify subcommands.\n"
                "Step 5: Author comprehensive unit test suite in pkg/policy/compiler_test.go validating compilation correctness across 20+ policy permutations.\n"
                "Step 6: Build BATS verification test test/policy-compiler.bats verifying that generated VAP manifests pass kubectl dry-run and generated nono profiles pass nono lint.\n"
                "Step 7: Enforce Rule SP-4: verify that all generated CEL expressions are non-Turing complete and contain zero external process or network lookup invocations.\n"
                "Step 8: Benchmark compilation throughput and document compiler architecture in docs/signalloom/cel-landlock-policy-compiler.md.\n"
                "Step 9: Implement continuous policy drift check verifying that deployed VAP and nono configs match source invariants YAML.\n"
                "Step 10: Implement schema validation for input YAML manifests using JSON schema specifications.\n"
                "Step 11: Add automated regression tests validating that forbidden syscalls are mapped to Landlock rules.\n"
                "Step 12: Build code generators with clean formatting and deterministic output sorting."
            ),
            "deliverables": [
                "Declarative policy compiler package in d2-signalloom/pkg/policy/",
                "CEL expression generation engine conforming to Kubernetes VAP specifications",
                "Landlock nono configuration profile generator",
                "CLI utility d2-signalloom/cmd/policy-compiler with compile, validate, and test verbs",
                "Unified security invariants manifest in config/security-invariants.yaml",
                "Unit test suite with 100% path coverage in pkg/policy/compiler_test.go",
                "Automated test suite test/policy-compiler.bats testing multi-target compilation",
                "Technical architecture documentation in docs/signalloom/cel-landlock-policy-compiler.md",
                "Validation linter enforcing Rule SP-4 CEL non-Turing complete constraints",
                "CI pipeline integration script scripts/compile-policies.sh for automated builds",
                "Semantic equivalence test suite asserting parity between VAP rules and Landlock profiles"
            ],
            "evidence": [
                "Go test run log showing all compiler unit tests passing cleanly",
                "kubectl apply --dry-run=server output confirming valid VAP manifests generated by compiler",
                "nono profile validate output confirming generated nono JSON configuration validity",
                "Automated test execution log from test/policy-compiler.bats with 100% pass rate",
                "Clean compilation of sample security-invariants.yaml into both targets without warnings",
                "Recorded evidence artifact in docs/signalloom/evidence/policy-compiler-proof.json",
                "Verification report demonstrating zero syntax errors from google/cel-go validation",
                "Benchmark report confirming compiler parses and emits policies in under 50ms",
                "Linter confirmation proving Rule SP-4 compliance for all compiled expressions"
            ],
            "keyFacts": [
                "ValidatingAdmissionPolicy evaluates CEL expressions against AdmissionReview request objects",
                "nono uses Linux Landlock to enforce kernel-level filesystem and network boundaries on unprivileged processes",
                "Rule SP-4 mandates that all admission and governance rules must be expressed in standard Google CEL without extension libraries",
                "Unified declarative invariants prevent drift between cluster admission gates and host agent execution sandboxes"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P3-PRE verified VAP API and Landlock support",
                "integration/crkc-v0.1.0 codebase"
            ],
            "outOfScope": [
                "Implementing worktree confinement specifics (handled in CRKC-P3-2)",
                "Building admission webhook controller (assigned to CRKC-P3-3)",
                "Modifying eBPF TC classifier programs (Phase 1)",
                "Implementing custom Linux kernel LSM modules outside Landlock"
            ],
            "priorErrata": [
                "CRKC-P3-PRE: VAP API and Landlock support confirmed"
            ],
            "sharedFileRisks": [
                "Compiler CLI and package structure isolate to d2-signalloom/pkg/policy/ and cmd/policy-compiler/"
            ],
            "failureModes": [
                "Invalid CEL syntax: CEL expressions failing Kubernetes admission registration; validate expressions against google/cel-go parser in unit tests",
                "Semantic mismatch between VAP and Landlock: rule allowed by VAP but denied by Landlock; implement cross-target equivalence assertions",
                "Overly restrictive file sandbox breaking agent compiler tools: ensure compiler include paths (/usr/include, /lib) are preserved",
                "YAML parsing error on malformed invariant definitions: enforce strict schema validation",
                "CEL expression evaluation timeout during admission review: enforce max complexity constraints",
                "Landlock rule overflow: exceeding maximum supported rule count on older kernels",
                "Non-deterministic key sorting in generated JSON profiles causing git churn"
            ],
            "loopOn": [
                "Run go test ./d2-signalloom/pkg/policy/... until all pass",
                "Run bats test/policy-compiler.bats until clean exit 0"
            ],
            "stopAndReport": [
                "Generated CEL expressions fail Kubernetes API server validation",
                "Generated nono profile fails schema validation",
                "Compiler fails to satisfy Rule SP-4 non-Turing complete constraints"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/pkg/policy/...",
                "bats test/policy-compiler.bats",
                "kubectl apply --dry-run=server -f - < <(policy-compiler compile --target=vap)",
                "scripts/test-policy-compiler.sh",
                "policy-compiler validate --config=config/security-invariants.yaml"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/pkg/policy/, cmd/policy-compiler/, and test/policy-compiler.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P3-2",
        "role": "implementation",
        "title": "Implement Rule SP-1 worktree Landlock confinement: allow local git commit --no-gpg-sign while blocking unauthorized network push",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P3-PRE"],
        "spec": {
            "objective": "Implement Rule SP-1 worktree Landlock confinement profile and tooling, enabling coding agents to execute git commit within their designated worktrees without interactive GPG signing prompts (--no-gpg-sign) while strictly blocking unauthorized git push and arbitrary outbound network connections at the host kernel Landlock and firewall levels.",
            "approach": (
                "Step 1: Author dedicated nono sandbox profile nono/profiles/worktree-agent.json defining filesystem and network access policies.\n"
                "Step 2: Configure filesystem.allow for the designated worktree path with readwrite permissions, and read permissions for Git binaries and repository object stores.\n"
                "Step 3: Configure filesystem.deny for sensitive host directories (~/.ssh, ~/.gnupg, /etc/shadow, ~/.aws, ~/.config/gcloud).\n"
                "Step 4: Block outbound network sockets to remote Git origins (TCP port 22, 9418, 443) while allowing local socket communication to daemon services.\n"
                "Step 5: Implement wrapper script bin/agent-git enforcing --no-gpg-sign automatically on commit invocations to prevent pinentry deadlocks.\n"
                "Step 6: Author automated BATS test test/worktree-landlock-confinement.bats proving that local commits succeed cleanly while git push is rejected with Permission Denied.\n"
                "Step 7: Document Rule SP-1 enforcement mechanics and troubleshooting runbooks in docs/signalloom/worktree-landlock-confinement.md.\n"
                "Step 8: Verify that worktree path canonicalization avoids symlink traversal pitfalls."
            ),
            "deliverables": [
                "Landlock confinement profile in nono/profiles/worktree-agent.json",
                "Git invocation wrapper enforcing --no-gpg-sign in bin/agent-git",
                "Automated BATS test suite test/worktree-landlock-confinement.bats validating commit success and push denial",
                "Operational documentation in docs/signalloom/worktree-landlock-confinement.md",
                "Audit script verifying absence of interactive GPG prompts across agent worktree runs",
                "Pre-execution verification check ensuring worktree root is within ~/src/.worktrees",
                "Integration harness testing agent file modifications inside sandboxed worktree"
            ],
            "evidence": [
                "BATS test output showing git commit --no-gpg-sign succeeding with exit code 0",
                "BATS test output showing git push failing with Permission Denied (EACCES) at kernel level",
                "Log proving pinentry was never invoked during automated commit execution",
                "Verification that sensitive host credentials cannot be read by confined processes",
                "Recorded evidence artifact in docs/signalloom/evidence/worktree-confinement-proof.json",
                "Audit trace showing connect(2) system call to external IP blocked by Landlock"
            ],
            "keyFacts": [
                "Rule SP-1 dictates that coding agents must be permitted to execute git commit without interactive GPG signing",
                "Bare gpg --clearsign launches pinentry on unreachable tty and blocks until timeout",
                "Landlock network rules restrict connect(2) syscalls for specified socket addresses",
                "Worktree isolation guarantees that agent file mutations cannot escape into parent directories"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P3-PRE verified Landlock LSM support",
                "Active git worktree environment"
            ],
            "outOfScope": [
                "Cluster ValidatingAdmissionPolicy deployment (handled in CRKC-P3-1)",
                "Node admission webhook implementation (assigned to CRKC-P3-3)",
                "Modifying global system git configurations outside worktree sandbox"
            ],
            "priorErrata": [
                "CRKC-P3-PRE: Landlock support verified on host kernel"
            ],
            "sharedFileRisks": [
                "Avoid altering global git config; enforce flags via local wrapper or worktree git config"
            ],
            "failureModes": [
                "commit.gpgsign=true in global config: ensure agent wrapper passes --no-gpg-sign explicitly",
                "Git hook invoking external network tool: Landlock intercepts and denies network connect",
                "Worktree symlink traversal: resolve all symlinks prior to path evaluation per user rules",
                "Agent tool attempting to invoke bare git instead of wrapper: enforce path precedence in environment"
            ],
            "loopOn": [
                "Run bats test/worktree-landlock-confinement.bats until all tests pass",
                "Verify git commit succeeds inside worktree sandbox"
            ],
            "stopAndReport": [
                "git commit triggers interactive pinentry prompt",
                "git push succeeds to external remote from confined sandbox",
                "Landlock profile fails to load due to kernel permission error"
            ],
            "testSurface": [
                "bats test/worktree-landlock-confinement.bats",
                "bin/agent-git commit -m 'test commit' --no-gpg-sign",
                "bin/agent-git push origin HEAD",
                "scripts/test-worktree-confinement.sh"
            ],
            "mergeBoundary": "Isolates to nono/profiles/worktree-agent.json, bin/agent-git, and test/worktree-landlock-confinement.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P3-3",
        "role": "implementation",
        "title": "Build fail-closed admission webhook ensuring agent pods schedule only on nodes with active cgroup-v2 and Landlock capabilities",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P3-PRE"],
        "spec": {
            "objective": "Build and deploy a fail-closed Kubernetes ValidatingAdmissionWebhook (node-capability-guard) in Go that inspects pod scheduling requests for AI agent workloads, verifies that target nodes possess active cgroup-v2 unified hierarchy and Linux Landlock LSM capabilities via node labels and security attestations, and rejects scheduling on unconfined nodes with actionable Kubernetes events.",
            "approach": (
                "Step 1: Implement admission webhook server in d2-signalloom/apps/node-capability-guard/pkg/webhook/handler.go handling AdmissionReview v1 requests.\n"
                "Step 2: Implement node capability verifier validating node labels (signalloom.io/cgroup2=active, signalloom.io/landlock=active) and node attestation status.\n"
                "Step 3: Configure fail-closed failurePolicy: Fail on ValidatingWebhookConfiguration to ensure pods cannot schedule if webhook is unreachable.\n"
                "Step 4: Generate TLS certificates via cert-manager for webhook HTTPS endpoint in cluster.\n"
                "Step 5: Author unit tests in pkg/webhook/handler_test.go testing admission approval for compliant nodes and rejection for non-compliant nodes.\n"
                "Step 6: Build BATS test suite test/admission-node-guard.bats deploying test agent pods to compliant and simulated unconfined nodes.\n"
                "Step 7: Author operational documentation and troubleshooting guide in docs/signalloom/admission-node-guard.md.\n"
                "Step 8: Add Prometheus metrics tracking admission request rates and rejection counts."
            ),
            "deliverables": [
                "Go admission webhook service in d2-signalloom/apps/node-capability-guard/",
                "ValidatingWebhookConfiguration manifest with failurePolicy: Fail",
                "Cert-manager Certificate manifest for webhook TLS termination",
                "Unit test suite in pkg/webhook/handler_test.go with 100% path coverage",
                "Automated BATS test suite test/admission-node-guard.bats",
                "Operational guide docs/signalloom/admission-node-guard.md",
                "Helm chart template for node-capability-guard deployment in d2-signalloom/deploy/charts/"
            ],
            "evidence": [
                "BATS test output showing pod rejected when scheduling on simulated node without cgroup-v2/Landlock",
                "Kubernetes warning event capture explaining rejection reason with remediation steps",
                "BATS test output showing pod successfully admitted on compliant node",
                "Go test run log verifying webhook handler logic",
                "Recorded evidence artifact in docs/signalloom/evidence/admission-guard-proof.json",
                "Prometheus metric scrape verifying increment of node_capability_rejections_total"
            ],
            "keyFacts": [
                "fail-closed admission webhooks block pod scheduling if the webhook controller fails to respond",
                "Node labels and feature discovery expose kernel capabilities to the Kubernetes control plane",
                "AI agent workloads require cgroup-v2 and Landlock for Tier 0 containment and host confinement",
                "ValidatingAdmissionWebhook operates prior to pod binding by the kube-scheduler"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P3-PRE verified cluster admission capabilities",
                "Running cert-manager in d2-infra"
            ],
            "outOfScope": [
                "Policy compiler development (handled in CRKC-P3-1)",
                "Worktree Landlock profile authoring (handled in CRKC-P3-2)",
                "Modifying default kube-scheduler scheduling algorithms"
            ],
            "priorErrata": [
                "CRKC-P3-PRE: Admission registration capabilities verified"
            ],
            "sharedFileRisks": [
                "Webhook deployment isolates to d2-signalloom/apps/node-capability-guard/ and deploy/ manifests"
            ],
            "failureModes": [
                "Webhook timeout causing cluster-wide scheduling freeze: set webhook timeoutSeconds: 3 and limit scope to agent namespaces",
                "TLS certificate expiration: utilize cert-manager auto-rotation",
                "Node feature discovery failure: provide fallback node registration script",
                "Namespace selector misconfiguration intercepting system pods: restrict to signalloom.io/agent=true namespaces"
            ],
            "loopOn": [
                "Run bats test/admission-node-guard.bats until all pass",
                "Check kubectl get events -n test-agent until rejection event is observed"
            ],
            "stopAndReport": [
                "Webhook blocks non-agent pods due to improper namespaceSelector",
                "Cert-manager fails to issue webhook certificate"
            ],
            "testSurface": [
                "go test -v ./d2-signalloom/apps/node-capability-guard/...",
                "bats test/admission-node-guard.bats",
                "kubectl apply -f test/fixtures/agent-pod-unconfined-node.yaml",
                "scripts/test-admission-guard.sh"
            ],
            "mergeBoundary": "Isolates to d2-signalloom/apps/node-capability-guard/ and test/admission-node-guard.bats. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P3-GOV",
        "role": "governor",
        "title": "Phase 3 Governor reconciliation: merge Phase 3 deliverables, run confinement red-team, and verify admission gates",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P3-1", "P3-2", "P3-3"],
        "spec": {
            "objective": "Perform Phase 3 Governor reconciliation by merging all Phase 3 deliverables into integration/crkc-v0.1.0, executing an adversarial confinement red-team test suite against Landlock sandboxes and ValidatingAdmissionPolicies, proving zero policy escapes and zero unauthorized network egress, and authoring the Phase 3 Governor Certification proof artifact.",
            "approach": (
                "Step 1: Verify clean completion and test passes for all Phase 3 implementation cards (CRKC-P3-1, CRKC-P3-2, CRKC-P3-3).\n"
                "Step 2: Merge deliverable branches into integration/crkc-v0.1.0 without regressions.\n"
                "Step 3: Execute adversarial confinement red-team suite test/crkc-phase3-confinement-redteam.bats probing Landlock escapes, unauthorized network push, and unconfined node scheduling.\n"
                "Step 4: Assert 100% rejection rate for adversarial breakout attempts and unconfined scheduling requests.\n"
                "Step 5: Verify that git commit --no-gpg-sign functions cleanly across all worktree agents without GPG prompt deadlocks.\n"
                "Step 6: Author certified Phase 3 governance proof artifact docs/signalloom/crkc-p3-governor-proof.md.\n"
                "Step 7: Update Obsidian proposal errata section with Phase 3 completion ledger and stop in Review state per Rule SP-5.\n"
                "Step 8: Reconcile code coverage reports across Go and BATS suites ensuring no test regression.\n"
                "Step 9: Publish Phase 3 verification summary to the kanban review ledger."
            ),
            "deliverables": [
                "Unified Phase 3 integration on integration/crkc-v0.1.0 with all Phase 3 tests passing",
                "Adversarial red-team test suite test/crkc-phase3-confinement-redteam.bats",
                "Phase 3 Governor Certification proof artifact in docs/signalloom/crkc-p3-governor-proof.md",
                "Red-team attack and defense evidence matrix documenting 0 successful escapes",
                "Updated proposal errata ledger in Obsidian documenting Phase 3 milestone certification",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off",
                "Pre-flight verification checklist for Phase 4 readiness"
            ],
            "evidence": [
                "Full test execution log of test/crkc-phase3-confinement-redteam.bats with 100% pass rate",
                "Audit log proving 0 policy escapes and 0 unauthorized network socket connections",
                "Git log showing clean integration of CRKC-P3-1 through CRKC-P3-3 without conflict markers",
                "Recorded proof artifact docs/signalloom/crkc-p3-governor-proof.md with execution timestamps",
                "Review ledger entry in .kanban-review-ledger.json recording governor sign-off",
                "Obsidian proposal document updated with Phase 3 certification status"
            ],
            "keyFacts": [
                "Rule SP-1 dictates worktree confinement and unsigned local git commit permissions",
                "Rule SP-4 mandates non-Turing complete CEL admission rules",
                "Rule SP-5 mandates that Phase Governors strictly stop in Review and never auto-advance to Done without human operator sign-off",
                "Phase 3 Governor unblocks Phase 4 preflight verification"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P3-PRE preflight proof",
                "CRKC-P3-1 policy compiler",
                "CRKC-P3-2 worktree Landlock profile",
                "CRKC-P3-3 admission node guard"
            ],
            "outOfScope": [
                "Executing Phase 4 final estate stabilization and end-to-end mission demonstration",
                "Auto-advancing past Review state into Done",
                "Modifying production Gateway API routing rules"
            ],
            "priorErrata": [
                "CRKC-P3-PRE: Preflight verification completed",
                "CRKC-P3-1: Declarative policy compiler verified",
                "CRKC-P3-2: Worktree Landlock confinement verified",
                "CRKC-P3-3: Fail-closed admission node guard verified"
            ],
            "sharedFileRisks": [
                "Governor reconciles all Phase 3 files; ensure zero merge conflicts across policy packages and deployment manifests"
            ],
            "failureModes": [
                "Confinement bypass during red-team: Landlock sandbox allowing socket connection via IPv6; re-verify dual-stack socket blocking",
                "Admission webhook deadlocking scheduling during integration test: verify webhook timeouts",
                "Merge regression in policy packages",
                "Flaky BATS test timing: utilize shared wait helpers instead of fixed sleeps"
            ],
            "loopOn": [
                "Run bats test/crkc-phase3-confinement-redteam.bats until all pass",
                "Verify git status on integration/crkc-v0.1.0 is clean"
            ],
            "stopAndReport": [
                "Any Phase 3 implementation card fails acceptance criteria",
                "Red-team breakout succeeds against Landlock sandbox",
                "Admission webhook allows pod scheduling on unconfined node"
            ],
            "testSurface": [
                "bats test/crkc-phase3-confinement-redteam.bats",
                "bats test/policy-compiler.bats",
                "bats test/worktree-landlock-confinement.bats",
                "bats test/admission-node-guard.bats",
                "scripts/test-phase3-governor.sh"
            ],
            "mergeBoundary": "Merges Phase 3 deliverables into integration/crkc-v0.1.0. Governor card stops in Review state awaiting operator sign-off."
        }
    },

    # ─── PHASE 4 ─────────────────────────────────────────────────────────────
    {
        "logical_id": "P4-PRE",
        "role": "preflight",
        "title": "Phase 4 preflight: verify full estate stability across foundation stack and demo slices",
        "size": "S",
        "agent": "fast",
        "depends_on": ["P1-GOV", "P2-GOV", "P3-GOV"],
        "spec": {
            "objective": "Perform preflight verification for Phase 4 (Integration & Mission Verification). Verify the complete health and stability of the Kind cluster foundation stack (Envoy Gateway, cert-manager, Zot registry, Prometheus) and all active demo slices (Signal Loom, OSRAMP apps, KubeSec-AFM, OpenBao, SPIFFE trust hierarchy), confirm all pods report Ready with zero crash loops, and author docs/signalloom/crkc-p4-preflight-proof.md with complete command outputs.",
            "approach": (
                "Step 1: Execute make healthcheck and make doctor to perform comprehensive foundation stack diagnostic.\n"
                "Step 2: Verify that all pods across all namespaces report Ready with zero crash restarts in the last 15 minutes.\n"
                "Step 3: Verify that Flux GitOps reconciliations for all Kustomizations report Healthy and ready.\n"
                "Step 4: Verify Envoy Gateway ingress routes and Gateway API HTTPRoutes respond with valid HTTP status codes.\n"
                "Step 5: Author certified preflight proof artifact docs/signalloom/crkc-p4-preflight-proof.md with execution timestamps.\n"
                "Step 6: Check git baseline status on integration/crkc-v0.1.0 to ensure a clean working tree before Phase 4 testing begins."
            ),
            "deliverables": [
                "Estate-wide health and readiness audit report across foundation and demo slices",
                "Flux GitOps reconciliation status log across all tenants and ResourceSets",
                "Gateway ingress connectivity verification log testing HTTP and TLS routes",
                "Certified preflight proof artifact recorded in docs/signalloom/crkc-p4-preflight-proof.md",
                "Git status confirmation verifying clean baseline on integration/crkc-v0.1.0"
            ],
            "evidence": [
                "Clean exit 0 from make healthcheck",
                "Doctor diagnostic report showing HEALTHY with 0 critical exceptions",
                "Recorded proof artifact docs/signalloom/crkc-p4-preflight-proof.md with UTC timestamp",
                "kubectl get pods -A output showing all pods in Running or Completed state",
                "Zero warning events in Kubernetes events log for the preceding 15 minutes"
            ],
            "keyFacts": [
                "make doctor performs exhaustive cluster diagnostics including restarts, events, and Flux status",
                "Phase 4 integrates and red-teams the unified containment and risk capabilities built across Phases 1-3",
                "Preflight guarantees a stable foundation baseline before launching high-stress adversarial tests"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-GOV certified Phase 1 Tier 0 and Tier 1 containment",
                "CRKC-P2-GOV certified Phase 2 live FAIR risk engine and demo toggle parity",
                "CRKC-P3-GOV certified Phase 3 CEL admission and Landlock confinement"
            ],
            "outOfScope": [
                "Executing adversarial red-team test suite (assigned to CRKC-P4-1)",
                "Executing mission demonstration and benchmarks (assigned to CRKC-P4-2)",
                "Final programme certification (assigned to CRKC-P4-GOV)",
                "Modifying cluster foundation infrastructure"
            ],
            "priorErrata": [
                "CRKC-P1-GOV: Phase 1 certified",
                "CRKC-P2-GOV: Phase 2 certified",
                "CRKC-P3-GOV: Phase 3 certified"
            ],
            "sharedFileRisks": [
                "Card writes exclusively to docs/signalloom/crkc-p4-preflight-proof.md"
            ],
            "failureModes": [
                "Unhealthy pod in cluster: diagnose via kubectl describe and restart pod",
                "Flux reconciliation drift: reconcile kustomization with --with-source",
                "Ingress gateway port conflict: verify Envoy gateway listeners"
            ],
            "loopOn": [
                "Run make healthcheck until exit code 0",
                "Check kubectl get nodes until Ready"
            ],
            "stopAndReport": [
                "make healthcheck fails with unrecoverable cluster error",
                "Flux system namespace unreachable"
            ],
            "testSurface": [
                "make healthcheck",
                "make doctor",
                "test -f docs/signalloom/crkc-p4-preflight-proof.md",
                "kubectl get pods -A"
            ],
            "mergeBoundary": "Fast-forward merges cleanly into integration/crkc-v0.1.0 without modifying application code."
        }
    },
    {
        "logical_id": "P4-1",
        "role": "implementation",
        "title": "Execute adversarial red-team test suite: test killswitch under CPU stress, race window bypasses, and Landlock breakout attempts",
        "size": "L",
        "agent": "deep",
        "deep_rationale": "Requires comprehensive adversarial red-team stress testing across kernel cgroups under 100% CPU saturation, TC packet dropping under multi-gigabit packet flooding, microsecond race window bypasses, and host Landlock sandbox escape exploits.",
        "depends_on": ["P4-PRE"],
        "spec": {
            "objective": "Execute an adversarial red-team test suite (test/crkc-adversarial-redteam.bats) against the unified Signal Loom runtime confinement system. Subject the tiered killswitch to 100% CPU stress saturation, test concurrent fork-bomb and thread spawning during freeze initiation, probe microsecond race window bypasses, launch high-volume packet flooding against TC drop filters, and execute known Linux Landlock sandbox escape exploits, proving 100% mitigation and zero containment escapes.",
            "approach": (
                "Step 1: Build stress-testing container image (crkc-redteam-target) equipped with stress-ng, netperf, raw socket transmitters, and fork-bomb test utilities.\n"
                "Step 2: Author adversarial BATS suite test/crkc-adversarial-redteam.bats containing 15 distinct red-team attack scenarios.\n"
                "Step 3: Attack Scenario 1-3 (CPU Saturation): trigger agent freeze under 100% CPU burn across 8 cores; assert all threads transition to D-state in < 50ms without watchdog timeouts.\n"
                "Step 4: Attack Scenario 4-6 (Race Window Bypasses): spawn high-rate fork-bombs and thread creation during stun dispatch; assert zero orphaned child processes escape the frozen cgroup.\n"
                "Step 5: Attack Scenario 7-9 (Network Flood): flood container veth device with 100,000 pps UDP/TCP traffic during stun; assert TC clsact drops 100% of ingress and egress packets with 0 packet leakage.\n"
                "Step 6: Attack Scenario 10-12 (Landlock Sandbox Escape): attempt chroot breakout, ptrace process injection, and unauthorized raw socket creation from within confined worktree; assert all syscalls denied with EACCES.\n"
                "Step 7: Attack Scenario 13-15 (GitOps Drift Collision): trigger concurrent forced Flux reconciliation during active stun; assert label survives without race conditions.\n"
                "Step 8: Document red-team findings, attack payloads, and defense evidence in docs/signalloom/redteam-adversarial-findings.md.\n"
                "Step 9: Author mitigation patches for any latency anomalies or edge-case defects discovered during testing.\n"
                "Step 10: Benchmark system stability during concurrent multi-agent stun executions under heavy background load.\n"
                "Step 11: Validate kernel audit logs confirming zero security policy evasions or uncaught exceptions."
            ),
            "deliverables": [
                "Red-team attack target container definition in test/redteam/Dockerfile",
                "Adversarial BATS test suite test/crkc-adversarial-redteam.bats covering 15 attack vectors",
                "CPU saturation and fork-bomb confinement verification logs",
                "High-throughput packet flooding TC drop verification logs",
                "Landlock syscall denial audit trace",
                "Comprehensive adversarial attack and mitigation report in docs/signalloom/redteam-adversarial-findings.md",
                "Telemetry export validating that all 15 red-team attacks generated security alerts in Signal Loom",
                "Mitigation verification report confirming zero policy escapes across 1,000 stress cycles",
                "Automated test harness script scripts/run-redteam-suite.sh"
            ],
            "evidence": [
                "100% pass rate across all 15 attack scenarios in test/crkc-adversarial-redteam.bats",
                "Kernel audit logs confirming 0 process escapes and 0 packet leaks under stress",
                "Benchmark metrics showing freeze latency remaining under 50ms even during 100% CPU stress",
                "Prometheus metrics demonstrating 100% packet drop rate under 100,000 pps flood",
                "Recorded evidence artifact in docs/signalloom/evidence/adversarial-redteam-proof.json",
                "Audit trail confirming 15/15 alerts successfully ingested into Signal Fusion",
                "Zero kernel crash dumps or hung task warnings in dmesg after test completion"
            ],
            "keyFacts": [
                "stress-ng generates severe CPU, memory, and I/O pressure to test kernel scheduler edge cases",
                "cgroup-v2 freezer operates atomically in-kernel, preventing newly forked children from escaping the frozen cgroup",
                "TC clsact drops packets at the earliest possible network stack hook before socket buffer allocation",
                "Landlock restricts syscalls unconditionally in-kernel, neutralizing userspace privilege escalation attacks"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P4-PRE verified estate stability",
                "All Phase 1, Phase 2, and Phase 3 implementations"
            ],
            "outOfScope": [
                "Hardware-level Spectre/Meltdown microarchitectural attacks",
                "Kernel memory corruption 0-day exploits outside Landlock/cgroups scope",
                "Physical node destruction or external power loss failure modes"
            ],
            "priorErrata": [
                "CRKC-P4-PRE: Estate stability verified"
            ],
            "sharedFileRisks": [
                "Red-team test scripts isolate to test/crkc-adversarial-redteam.bats and test/redteam/"
            ],
            "failureModes": [
                "Test container consuming excessive host resources: set explicit cgroup resource limits on test pods",
                "Network flood saturating host bridge interface: bound packet flood duration to 5 seconds per test",
                "Kernel panic under extreme stress: ensure Kind node VM possesses adequate memory (>= 8GB)",
                "Host OOM killer terminating test harness: tune test process nice and oom_score_adj values",
                "Intermittent race conditions on fast multi-core systems: inject bounded retry loops in test assertions"
            ],
            "loopOn": [
                "Run bats test/crkc-adversarial-redteam.bats until all 15 attack scenarios pass",
                "Monitor dmesg for kernel warnings or call traces"
            ],
            "stopAndReport": [
                "Any red-team attack scenario succeeds in bypassing containment",
                "Kernel panic or OOM killer terminates critical system daemons",
                "Freeze latency exceeds 100ms under CPU stress"
            ],
            "testSurface": [
                "bats test/crkc-adversarial-redteam.bats",
                "scripts/run-redteam-suite.sh",
                "dmesg | grep -iE 'oom|panic|error'",
                "kubectl get events -A --field-selector type=Warning",
                "test/bench-redteam-stress.sh"
            ],
            "mergeBoundary": "Isolates to test/crkc-adversarial-redteam.bats, test/redteam/, and docs/signalloom/redteam-adversarial-findings.md. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P4-2",
        "role": "implementation",
        "title": "Execute end-to-end mission demonstration and document latency, throughput, and FAIR calculation benchmarks",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P4-PRE"],
        "spec": {
            "objective": "Execute the comprehensive end-to-end mission demonstration of the Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment system. Capture and benchmark complete system performance metrics (Tier 0 stun latency < 1s, live FAIR calculation p95 < 50ms, demo toggle parity), record live demonstration telemetry and visual artifacts, and author the final benchmark and demonstration report in docs/signalloom/crkc-mission-demonstration.md.",
            "approach": (
                "Step 1: Deploy complete Signal Loom demonstration estate with active agent workloads.\n"
                "Step 2: Execute automated end-to-end mission demonstration script scripts/demo-crkc-mission.sh exercising the full threat lifecycle: anomaly detection, dynamic FAIR risk score elevation, operator stun trigger, Tier 0 in-kernel halt, Tier 1 GitOps label survival, and audited unfreeze resumption.\n"
                "Step 3: Measure and record exact latency percentiles (p50, p90, p95, p99) for cgroup freeze, TC packet drop, and total stun confirmation.\n"
                "Step 4: Measure and record Monte Carlo OpenFAIR calculation throughput and API response latency under concurrent load.\n"
                "Step 5: Capture interactive browser screenshots and DOM telemetry verifying seamless visual presentation across demo and live modes.\n"
                "Step 6: Author comprehensive mission demonstration report and benchmark paper in docs/signalloom/crkc-mission-demonstration.md.\n"
                "Step 7: Verify that all demo artifacts and scripts can be replayed reliably for executive presentations.\n"
                "Step 8: Publish benchmark data export in JSON format for automated dashboard consumption."
            ),
            "deliverables": [
                "End-to-end automated demonstration runner script scripts/demo-crkc-mission.sh",
                "Comprehensive latency and throughput benchmark report in docs/signalloom/crkc-mission-demonstration.md",
                "Benchmark data export in JSON format at docs/signalloom/benchmarks/mission-benchmarks.json",
                "High-resolution UI demonstration snapshots and telemetry logs in docs/signalloom/media/",
                "Executive summary slide/document for innovation proposal review",
                "Interactive presentation walkthrough guide docs/signalloom/demo-operator-walkthrough.md"
            ],
            "evidence": [
                "Demonstration script execution log showing 100% success across all lifecycle phases",
                "Benchmark metrics confirming killswitch latency p95 < 250ms (well under 1s SLA)",
                "Benchmark metrics confirming FAIR risk calculation p95 < 35ms (well under 50ms SLA)",
                "Recorded evidence artifact docs/signalloom/evidence/mission-demonstration-proof.json",
                "Visual evidence artifacts captured and stored in docs/signalloom/media/",
                "Zero regression confirmation across all existing demo slices"
            ],
            "keyFacts": [
                "Mission acceptance criteria: sub-second containment, p95 FAIR math < 50ms, zero GitOps drift reverts, 100% demo parity",
                "End-to-end demonstration validates the complete control plane across kernel, GitOps, API, and UI tiers",
                "Reproducible demo scripts ensure reliable presentations for executive stakeholders"
            ],
            "consumesFromEarlierPhases": [
                "All deliverables from Phases 1, 2, 3, and CRKC-P4-1"
            ],
            "outOfScope": [
                "Authoring final programme certification (assigned to CRKC-P4-GOV)",
                "Altering production core application features outside demonstration scope",
                "Modifying long-term telemetry retention policies in FrostDB"
            ],
            "priorErrata": [
                "CRKC-P4-1: Adversarial red-team test suite passed with 100% containment"
            ],
            "sharedFileRisks": [
                "Demonstration script reads system state without mutating core application code"
            ],
            "failureModes": [
                "Demonstration script timing out on slow host: calibrate wait timeouts using scripts/lib/wait.sh",
                "Port-forward dropping mid-demo: rely on supervised systemd port-forward unit",
                "Web browser headless rendering glitch: ensure Chrome flags disable hardware acceleration",
                "Network jitter during live API benchmark: take median of 5 benchmark runs"
            ],
            "loopOn": [
                "Run scripts/demo-crkc-mission.sh until all demonstration stages pass cleanly",
                "Verify test -f docs/signalloom/crkc-mission-demonstration.md"
            ],
            "stopAndReport": [
                "Demonstration fails any SLA acceptance criteria",
                "UI fails to display live telemetry during demonstration"
            ],
            "testSurface": [
                "scripts/demo-crkc-mission.sh",
                "test -f docs/signalloom/crkc-mission-demonstration.md",
                "test -f docs/signalloom/benchmarks/mission-benchmarks.json",
                "scripts/verify-demo-reproducibility.sh"
            ],
            "mergeBoundary": "Isolates to scripts/demo-crkc-mission.sh and docs/signalloom/crkc-mission-demonstration.md. Merges cleanly into integration/crkc-v0.1.0."
        }
    },
    {
        "logical_id": "P4-GOV",
        "role": "governor",
        "title": "Final Programme Governor reconciliation: certify all deliverables, verify mission acceptance criteria, and update master references",
        "size": "M",
        "agent": "daily",
        "depends_on": ["P4-1", "P4-2"],
        "spec": {
            "objective": "Perform Final Programme Governor reconciliation for the CRKC mission. Reconcile and certify all deliverables across all four phases on integration/crkc-v0.1.0, verify all mission acceptance criteria, confirm 100% passing automated test suites across Go, BATS, React, and Playwright, author the Master Programme Certification artifact, update the Obsidian proposal errata ledger with final completion status, and present the completed mission capsule for principal sign-off.",
            "approach": (
                "Step 1: Verify clean completion, test passes, and certified evidence across all 20 cards in the CRKC work decomposition.\n"
                "Step 2: Merge deliverable branches into integration/crkc-v0.1.0 with zero unresolved conflicts.\n"
                "Step 3: Execute the complete repository test suite: make test-signal-ingest, make test-signalfusion-bats, bats test/acceptance-spec-coverage.bats, bats test/kanban-check.bats, and dashboard Vitest suite.\n"
                "Step 4: Assert 100% pass rate across all automated test suites and verify that git working tree is completely clean.\n"
                "Step 5: Author the Master Programme Certification artifact in docs/signalloom/crkc-final-programme-certification.md detailing deliverable audits, benchmark summaries, and security proofs.\n"
                "Step 6: Update the Obsidian proposal document at '/home/andy/Documents/Obsidian/v1/2. Areas/CEO/Innovation Proposals/Proposal — Signal Loom Runtime Confinement, Live FAIR Risk & Kernel Containment (2026-Q3).md' recording final completion status across all phases in ### Spec: Errata.\n"
                "Step 7: Record final governor certification in .kanban-review-ledger.json and stop in Review state per Rule SP-5 awaiting final principal approval.\n"
                "Step 8: Reconcile all deliverable tags and immutable git references on the integration branch.\n"
                "Step 9: Compile final executive debrief and hand-off package."
            ),
            "deliverables": [
                "Master Programme Certification artifact in docs/signalloom/crkc-final-programme-certification.md",
                "Fully unified and certified integration/crkc-v0.1.0 branch with zero merge conflicts",
                "Complete test suite execution report showing 100% pass rate across all layers",
                "Updated Obsidian proposal document with certified completion errata ledger",
                "Final immutable review record in .kanban-review-ledger.json",
                "Mission completion candidate capsule ready for principal sign-off",
                "Final executive briefing document summarizing project achievements and benchmarks"
            ],
            "evidence": [
                "Clean exit 0 from full repository test suite (Go, BATS, React, Playwright)",
                "Master certification document recorded at docs/signalloom/crkc-final-programme-certification.md",
                "Obsidian proposal document verified with proposal-extract.py sections --strict",
                "Review ledger entry in .kanban-review-ledger.json recording final programme sign-off",
                "Clean git status on integration/crkc-v0.1.0",
                "Zero outstanding compiler warnings or test regressions across all packages"
            ],
            "keyFacts": [
                "Rule SP-5 mandates that Phase Governors strictly stop in Review and never auto-advance to Done without human operator sign-off",
                "Final completion requires the principal's explicit approval of recorded evidence per ajm-auto-kanban doctrine",
                "The proposal document in Obsidian is the durable contract of record for the completed mission",
                "All 20 cards in the Work Decomposition must have matching verified completion records"
            ],
            "consumesFromEarlierPhases": [
                "CRKC-P1-GOV, CRKC-P2-GOV, CRKC-P3-GOV, CRKC-P4-PRE, CRKC-P4-1, CRKC-P4-2"
            ],
            "outOfScope": [
                "Auto-advancing past Review state into Done (strictly reserved for principal approval)",
                "Deleting delivery evidence or kanban logs",
                "Pushing commits to remote git origin without human operator authorization"
            ],
            "priorErrata": [
                "CRKC-P1-GOV: Phase 1 certified",
                "CRKC-P2-GOV: Phase 2 certified",
                "CRKC-P3-GOV: Phase 3 certified",
                "CRKC-P4-1: Adversarial red-team passed 100%",
                "CRKC-P4-2: End-to-end mission demonstration completed and benchmarked"
            ],
            "sharedFileRisks": [
                "Governor finalizes all files on integration/crkc-v0.1.0; ensure clean working tree and git log"
            ],
            "failureModes": [
                "Any test suite failure across Go, BATS, or React: diagnose and remediate prior to certification",
                "Uncommitted changes in repository: ensure git status is completely clean",
                "Missing errata entry in Obsidian proposal: update proposal markdown directly",
                "Git merge conflicts during final baseline consolidation"
            ],
            "loopOn": [
                "Run full test suite until 100% pass rate is achieved across all test suites",
                "Verify git status on integration/crkc-v0.1.0 is clean"
            ],
            "stopAndReport": [
                "Any automated test suite fails its verification gate",
                "Obsidian proposal fails proposal-extract validation",
                "Integration branch contains uncommitted changes or merge conflicts"
            ],
            "testSurface": [
                "make test-signal-ingest",
                "make test-signalfusion-bats",
                "bats test/acceptance-spec-coverage.bats",
                "bats test/kanban-check.bats",
                "bun run --cwd d2-signalloom/apps/dashboard-signalloom test --run"
            ],
            "mergeBoundary": "Final integration baseline on integration/crkc-v0.1.0. Governor card stops in Review state awaiting principal sign-off."
        }
    }
]

if __name__ == "__main__":
    # Run metric checks on all cards
    failed = False
    for card in cards:
        ok, metrics, floor = verify_spec(card["spec"], card["size"], card["role"])
        status = "OK" if ok else "FAIL"
        print(f"Checking {card['logical_id']} ({card['size']}, {card['role']}): {status} words={metrics['words']}/{floor['words']} lines={metrics['lines']}/{floor['lines']} deliv={metrics['deliverables']}/{floor['deliv']}")
        if not ok:
            print(f"  --> FAILED: {metrics} vs {floor}", file=sys.stderr)
            failed = True

    if failed:
        sys.exit(1)

    print("\nAll card specifications passed metric floor checks! Creating cards...\n")

    # Apply all cards
    for card in cards:
        run_create(card)

    print("\nAll phases successfully compiled and created on CRKC board!")
