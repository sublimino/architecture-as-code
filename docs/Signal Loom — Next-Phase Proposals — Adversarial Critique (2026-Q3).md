---
created: 2026-09-13
reviewers:
  - John Kjell
  - Andrew Martin
tags:
  - adversarial-critique
  - partner-signal-loom
  - osramp
aliases:
  - "#adversarial-critique-2026-q3-signal-loom-proposals"
updated: 2026-09-13T22:15
---
# Signal Loom — Next-Phase Proposals — Council of Adversarial Experts Critique (2026-Q3)

|  |  |
| :---: | :---- |
| Date: | 2026-09-13 |
| Council Panel: | Principal Red Team Lead, Principal Security Architect, Enterprise CISO Reviewer, Autonomous Systems Safety Specialist |
| Proposals Reviewed: | 1. [[Proposal — Signal Loom Enforcement and Response (2026-Q3)]] (`SLER`)<br/>2. [[Proposal — Signal Loom AgentMaxxing Interactive Demo Console (2026-Q3)]] (`AMXD`)<br/>3. [[Proposal — Signal Loom Coding Agent & Harness Detective Telemetry (2026-Q3)]] (`SLCD`) |

---

## Executive Summary & Panel Mandate

The Council of Adversarial Experts convened to pressure-test the three 2026-Q3 execution proposals for the Signal Loom agent governance platform. Following the successful completion and certification of the AMXO baseline (Phases 0–6 certified, 7 test suites passing), the platform faces three distinct scaling vectors:
1. **Enforcement and Response (`SLER`)**: Making the headline "kill switch" real, multi-plane, and purple-team proven.
2. **Interactive Demo Console (`AMXD`)**: Turning low-level host governance into an executive-facing interactive stepping suite.
3. **Coding Agent Detective Telemetry (`SLCD`)**: Discovering active coding harnesses on developer machines in real time without active MCP handshakes or proprietary payload collection.

The panel examined each proposal under adversarial assumptions: **compromised dependencies, malicious host actors, race conditions in active revocation, developer pushback, and regulatory scrutiny**.

---

## Adversarial Findings & Remediation Matrix

### 1. Proposal A — Signal Loom Enforcement and Response (`SLER`)

| # | Finding | Sev | Remediation |
| :-: | :---- | :---: | :---- |
| A1 | **The "Multi-Plane Fallback" Trap**: In distributed systems, if one plane fails to enforce (e.g. OpenBao network partition during credential revocation), does the enforcer report success or block? Reporting partial success invites race conditions where the agent continues operating via cached credentials. | **Critical** | Implement strict atomic orchestration: an enforcement action is marked `PartialEnforcementDegraded` until all registered planes acknowledge. If any plane fails, the local host freezer (`cgroup.freeze`) executes immediately as the fail-safe backstop. |
| A2 | **Asynchronous SPIRE SVID Cache Residuals**: SPIRE agent SVID caches can remain valid locally up to their rotation threshold (~15-30s) even if the server entry is evicted, allowing in-flight mTLS connections to persist. | **High** | Combine SPIRE server entry eviction with dynamic Cilium/Istio network policy enforcement cutting in-flight TCP sessions at the eBPF/mesh layer (<2s). The denial matrix must document the 0s guaranteed mesh cut alongside the 15s SPIRE cache residual. |
| A3 | **Forensic State Corruption on Container Freeze**: Freezing a container with `SIGSTOP` or `cgroup.freeze` can trigger Kubernetes liveness/readiness probe failures, causing `kubelet` to kill the pod before memory forensic snapshots can be acquired. | **High** | Coordinate freeze signaling with `node-capability-guard` admission controller to temporarily mask liveness probe failures during forensic acquisition, preventing kubelet restart races. |
| A4 | **Reversible Unstun Authentication Bypass**: If the governance resume token (`unstun`) does not require multi-party authorization or cryptographic attribution, an attacker who compromised operator credentials could unfreeze a contained agent. | **High** | Require Ed25519-signed dual-operator authorization tokens for `unstun` operations, and enforce mandatory credential rotation upon unfreezing before network policies are relaxed. |
| A5 | **Denial Matrix Measurement Authenticity**: If latency numbers in the denial matrix are based on local unit tests rather than purple-team adversarial injection under high cluster load, enterprise buyers will reject them during audit. | **Medium** | Enforce automated latency benchmarking under 80% cluster load in `make demo-signalloom-purple-test`, reporting p95 and p99 guaranteed times. |

---

### 2. Proposal B — AgentMaxxing Interactive Demo Console (`AMXD`)

| # | Finding | Sev | Remediation |
| :-: | :---- | :---: | :---- |
| B1 | **Mock/Live Bridge Divergence**: If the demo console relies purely on hardcoded client-side mocks, subtle breaking changes in backend APIs (`/api/v1/agentmaxxing/...`) will go unnoticed, leading to embarrassing demo failures before customers. | **High** | Implement a shared TypeScript contract package between `dashboard-signalloom` and `fe-signalloom`. Ensure the demo console supports both `simulation` mode (for offline browser tests) and `live` mode against the real running cluster. |
| B2 | **Visual Zero-Payload Proof Tamperability**: An enterprise CISO reviewing the demo could argue that the "Zero-Payload Inspector" simply hides text in the UI while the backend still transmits source code. | **High** | Include a cryptographic verification panel in the console that displays the raw JSON-LD network packet received from the backend, with an automated client-side JSON-schema validator proving zero prompt/code fields exist. |
| B3 | **State Machine Race Conditions in Auto-Play**: Rapid clicking or fast-forwarding during Auto-Play mode (e.g. jumping from Stage 1 to Stage 4 before enrollment settles) can corrupt local session storage and deadlock the UI stepper. | **Medium** | Implement an immutable Redux/zustand state reducer with transition guards that cancel in-flight async promises and gracefully fast-forward stage prerequisites. |
| B4 | **Demo Estate Pollution**: Repeated runs of the demo console could create orphaned operator tokens and host records in the PostgreSQL/SQLite database, slowing down queries and breaking multi-tenant isolation tests. | **Medium** | Provide an idempotent "Reset Estate" endpoint (`POST /api/v1/agentmaxxing/demo/reset`) that purges ephemeral demo tenant records without impacting persistent configuration. |

---

### 3. Proposal C — Coding Agent & Harness Detective Telemetry (`SLCD`)

| # | Finding | Sev | Remediation |
| :-: | :---- | :---: | :---- |
| C1 | **Accidental Secret Scraping from `/proc/<pid>/cmdline`**: Many developers pass API keys, tokens, or repo URLs containing credentials via CLI arguments (`claude --api-key sk-...`, `git clone https://token@...`). Reading cmdline introduces critical privacy liability. | **Critical** | Strictly ban reading or logging `/proc/<pid>/cmdline` arguments! The detective sensor must inspect ONLY `/proc/<pid>/comm` and the resolved basename of `/proc/<pid>/exe`. All options and arguments must be rejected at the descriptor level before parsing. |
| C2 | **Heuristic Process Collision (False Positives)**: Generic Node.js or Python processes (e.g. `node server.js` or `python main.py`) could be misclassified as coding agents, polluting the security dashboard with non-agent workloads. | **High** | Enforce multi-factor correlation for harness classification: a process is only classified as an active coding agent if its process ancestry (PPID tree), local workspace markers (`.claude/`, `.kanban/`, `brain/`), or active outbound LLM inference sockets match the harness profile. |
| C3 | **Transcript Ingestion Code Leakage Risk**: Session transcripts (`transcript.jsonl`) contain raw prompt strings, user chat messages, and file edit diffs. A naive line-based JSON reader could accidentally extract code blocks into telemetry payloads. | **Critical** | Build a streaming projection parser that explicitly drops `content`, `thinking`, `diff`, and `prompt` fields at the byte deserialization boundary. Only scalar metadata (`step_index`, `created_at`, `token_counts`, `tool_name`) is deserialized. |
| C4 | **Lock Contention on Kanban Controller Loops**: Inspecting `kanban-check.sh` lockfiles or task directories while an autonomous loop is running could cause filesystem lock contention or delay time-sensitive governor cycles. | **High** | The kanban watcher must use purely read-only, non-exclusive descriptor reads (`open(O_RDONLY | O_NONBLOCK)`). Never invoke mutating commands or take flock locks on kanban state. |
| C5 | **Host Daemon Resource Creep on Developer Laptops**: A continuous procfs polling loop scanning all PIDs can consume significant CPU cycles and drain battery life, causing developers to kill the daemon. | **Medium** | Cap the procfs scan interval at 2000ms, use Linux `inotify` on known session directories instead of polling disk, and introduce CPU-yield backoffs when the process table is idle (<1% CPU budget). |

---

## Recommended Sequence of Execution

1. **Phase 1 (Immediate Prioritization)**:
   - Formally approve Proposal C's strict detective boundaries (zero MCP handshakes, zero prompt/code collection) to establish telemetry across local and developer nodes.
   - Author the dedicated PAI/ControlPlane skill (`cp-coding-agent-telemetry`) codifying the detective protocol.
2. **Phase 2 (Automation & Board Bootstrapping)**:
   - Validate all three proposals through `kanban-check.sh proposal-check`.
   - Run `/ajm-auto-kanban` auto-approve to generate and approve the mission capsules.
3. **Phase 3 (Delivery Execution)**:
   - Launch execution using the conservative capacity ceiling (max 7 concurrent tasks).
   - Enforce the Council's remediations across all governor gates (`P1-GOV` through `P6-GOV`).

---

*Authored by the Council of Adversarial Experts, 2026-09-13. Grounded in ControlPlane Security Standards and Signal Loom Architecture Constitution.*
