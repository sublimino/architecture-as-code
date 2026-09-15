---
created: 2026-09-13
reviewers:
  - John Kjell
  - Andrew Martin
capabilities:
  - "#cap-kubernetes"
  - "#cap-networking"
  - "#cap-golang"
  - "#cap-threat-modelling"
  - "#cap-purple-team"
  - "#cap-secrets"
practice:
  - Cyber Resilience & Threat Assurance
  - AI & Data Security
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-07-signalloom-d2-platform-baseline/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - enhancement-proposals
  - proposal-2026-q3-signal-loom-coding-agent-and-harness-detective-telemetry
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q3-signal-loom-coding-agent-and-harness-detective-telemetry"
updated: 2026-09-13T22:00
---
# Proposal — Signal Loom Coding Agent & Harness Detective Telemetry (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-13) |
| Reviewer & Date: | John Kjell (2026-09-13) |
| Approver & Date: |  |

> [!important] Why this, why now
> Autonomous coding agents (Claude Code, Antigravity CLI, Codex CLI, CPAI Engineer, OpenCode, Hermes, Aider) are rapidly becoming standard engineering tools across software organizations. Today, security, platform, and compliance leaders have zero real-time visibility into which coding harnesses are active on developer workstations, what tasks they are executing, or which model endpoints they communicate with. Active in-band interception (e.g. forced MCP handshakes or proxy injection) faces fierce developer resistance, protocol churn, and risk of breaking local builds. Furthermore, capturing telemetry must never harvest customer source code, user prompts, or private credentials. Signal Loom requires a strictly **detective, non-intrusive telemetry sensor** that discovers running coding harnesses right now, pulls runtime telemetry from process trees, kanban wrappers, disk transcripts, and network sockets, and projects them into the Signal Loom governance topology — with guaranteed zero customer payload harvesting and zero active MCP handshakes.

## Press Release

**Signal Loom introduces real-time detective observability for autonomous coding agents — passively discovering active harnesses, task loops, and inference flows without active MCP handshakes or source code exposure.**

As autonomous AI agents write, test, and ship code, enterprise security teams must maintain visibility and governance without interrupting developer velocity. Signal Loom Coding Agent & Harness Detective Telemetry delivers passive, real-time observability across the engineering estate. Operating at the host level, the detective sensor dynamically discovers running coding agents — including Claude Code, Antigravity CLI, OpenAI Codex CLI, and CPAI swarms — by inspecting Linux process trees, cgroup attribution, and active socket connections. It correlates task progress directly from local Kanban execution wrappers and parses session performance metrics from disk logs, all while enforcing a strict zero-customer-payload privacy boundary that guarantees proprietary code and prompts never leave the workstation. For the first time, platform leaders gain end-to-end visibility into autonomous coding operations with zero configuration friction.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [ ] services engineering
- [ ] cost avoidance
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):** Enterprise security architects, regulated software engineering organizations, DevSecOps leaders, and organizations adopting autonomous AI coding tools.

|  |  |
| :---- | :---- |
| Our *…* | platform security engineers, CISOs, and engineering directors managing developer fleets |
| Have the problem/opportunity *…* | having zero visibility into what autonomous coding agents are running on developer nodes, what tools they execute, and what inference providers they contact |
| When *…* | developers adopt local coding agents (Claude Code, Antigravity, Codex) and organizations need passive, non-intrusive governance without breaking developer workflows or leaking proprietary IP |

**Urgency.** 2026-Q3. Enterprise demand for agentic visibility is surging, and competitors are proposing heavy, intrusive proxy models that developers reject. Delivering a pure detective sensor with zero payload harvesting establishes Signal Loom as the enterprise standard.

## Scope Summary

**Technology Readiness Level: 2+ (Alpha) → 3 (Beta).** Rationale: AMXO provided the host sensor foundation (`agentmaxxing-host-sensor`), and `tools/harness-dash` demonstrated offline adapter parsing. This proposal synthesizes them into a real-time, non-intrusive detective telemetry engine (TRL 3 Beta).

**MVP:** A lightweight detective daemon and telemetry pipeline that detects active coding harnesses right now from process ancestry, kanban wrappers, disk session transcripts, and outbound inference sockets, emitting structured metadata-only events to `signal-ingest` without active MCP handshakes.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Real-time Process Tree & Cgroup Detective Engine | Passively scan `/proc/<pid>/stat`, `/proc/<pid>/status`, and `/proc/<pid>/statm` to identify running coding harnesses (Claude Code, Antigravity, Codex, CPAI, OpenCode, Hermes) and link child compiler/tool processes to the parent harness without scraping `/proc/<pid>/cmdline` arguments. | Specific: identifies harness PIDs, comm names, RSS, CPU, and child trees<br/>Measurable: 100% of running target harnesses detected in <2s with 0 false positives<br/>Attainable: Linux procfs tree traversal<br/>Realistic: bounded system programming<br/>Time-Bound: 2026-Q3 | Integration test with simulated harness processes |
| Kanban Wrapper & Runner Telemetry Watcher | Passively observe active Kanban controller cycles, lockfiles, and task leases from `kanban-check.sh`, `Tools/CycleInput.ts`, `.cline/kanban/`, and local task runs; extract task ID, role, shortcode, elapsed time, turn counts, and retry counts. | Specific: watches kanban execution state without acquiring mutating locks<br/>Measurable: reflects current task state and turn counts in <1s<br/>Attainable: reads JSON/file status without mutation<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Contract tests against live and recorded kanban cycles |
| Disk & Session Transcript Metadata Indexer | Index session metadata from local transcript logs (`transcript.jsonl`, `~/.gemini/antigravity-cli/brain/`, `.claude/projects/`, `.codex/`); extract session UUID, timestamps, model identifiers, step indices, token usage totals, and tool invocation histograms. | Specific: extracts token totals and tool invocation counts without reading prompt text<br/>Measurable: 100% metadata extraction with 0 bytes of prompt/code payload emitted<br/>Attainable: stream parser on JSONL metadata fields<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Unit tests on transcript parsers + payload leak assertions |
| Outbound Inference Socket Detector | Inspect `/proc/net/tcp` and `ss -ntp` to detect outbound TCP connections originating from harness PIDs to known LLM inference provider endpoints (Anthropic, OpenAI, Google Vertex, Ollama, OpenBao) without TLS interception. | Specific: correlates socket destination IP/port to active harness PID<br/>Measurable: identifies active model egress with zero packet body decryption<br/>Attainable: socket inode mapping<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Socket correlation integration tests |
| Signal Ingest Pipeline & Topology Visualization | Stream standardized `CodingAgentTelemetry` events to `signal-ingest` (`/api/v1/telemetry/coding-agents`) and render detected harnesses in the Dashboard Topology and Agent Swarm views as external host coding agents. | Specific: telemetry events ingested and rendered with live status badges<br/>Measurable: end-to-end latency from host event to UI display <3s<br/>Attainable: integrates with existing Signal Loom ingestion spine<br/>Realistic: bounded<br/>Time-Bound: 2026-Q3 | Vitest UI tests + Playwright browser acceptance tests |
| Strict Zero-Customer-Payload & Zero-MCP Invariant | Enforce strict structural separation: zero MCP client/server handshakes, zero prompt harvesting, zero user message harvesting, and zero source code file collection. | Specific: automated regex and schema guards reject any payload containing code or prompt fields<br/>Measurable: 100% passing leak falsification tests<br/>Attainable: schema allowlist pattern<br/>Realistic: non-negotiable invariant<br/>Time-Bound: 2026-Q3 | Adversarial leak injection test suite |

### Out of Scope

* Active MCP client/server protocol negotiation or MCP proxy interception (strictly detective).
* Modifying agent configurations (`settings.json`, `claude.json`, environment variables).
* Deep packet inspection or TLS decryption of model inference payloads.
* Enforcing process termination or process blocking (covered in Proposal SLER).

### KPIs

| Metric | Current | Target | Measurement |
| :---- | :---- | :---- | :---- |
| Supported coding agent harnesses detected | 0 in real-time | 6+ (Claude, Agy, Codex, CPAI, OpenCode, Hermes) | Process classification test |
| Discovery latency for newly launched harness | Undetected | <2.0 seconds from process start | Latency benchmark |
| Customer code or prompt leakage rate | Unknown | Exactly 0 bytes (proven by automated leak guards) | Falsification audit |
| Overhead on developer workstation | Unknown | <1.0% CPU, <25 MB RSS | Resource monitoring test |
| End-to-end acceptance suite status | None | 100% green Playwright & BATS suite | `make demo-agentmaxxing-host-test` |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Zero Customer Payload Invariant | Adversarial test suite attempting to inject prompts/code into telemetry channel; asserts 100% rejection | AI & Data Security practice |
| Process classification accuracy | Test matrix across diverse Linux distributions, shell wrappers, and subshell trees | Delivery team |
| Non-intrusive runtime performance | Continuous 24h stress test measuring CPU, memory, and disk I/O on active developer machine | Cyber Resilience practice |
| Browser & Topology rendering | Playwright acceptance tests verifying live coding agent cards and telemetry streams | Delivery team |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Python / TypeScript | Lightweight host detective sensor daemon (`agentmaxxing-host-sensor` extension) | Monorepo host tooling standard |
| Linux procfs / cgroups v2 | Low-overhead process discovery and socket correlation | Native Linux kernel primitives |
| Go | Telemetry ingestion endpoint in `signal-ingest` | Signal Loom backend architecture |
| React / Tailwind | Topology and Agent Swarm rendering of host coding agents | Existing Signal Loom dashboard SPA |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Host Detective Sensor | `d2-signalloom/apps/agentmaxxing-host-sensor/` | Extends sensor with process tree & kanban telemetry |
| Ingestion Backend | `d2-signalloom/apps/signal-ingest/` | Receives and validates `CodingAgentTelemetry` events |
| Dashboard SPA | `d2-signalloom/apps/dashboard-signalloom/` | Renders detected agents in Topology and Agent Swarm |
| Documentation | `d2-signalloom/apps/docs-signalloom/` | Architecture and telemetry guide |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Accidental ingestion of developer prompts or source code | Critical | Strict allowlist schema: sensor only extracts token counts, tool names, and timestamps; zero message body parsing |
| Accidental scraping of API tokens from process command lines | High | Strictly avoid `/proc/<pid>/cmdline`; inspect only `/proc/<pid>/comm` and `/proc/<pid>/exe` basename |
| Performance degradation or battery drain on developer laptop | Medium | Polling interval capped at 2s; event-driven inotify on log files; CPU yield after process table sweep |
| False positive identification of non-agent developer tools | Medium | Strict multi-factor heuristic: requires both process binary match and active inference socket or transcript activity |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| Zero friction: developers install nothing, configure nothing, change nothing | Cannot inspect internal chain-of-thought without MCP (deliberate trade-off) |
| Provable privacy: zero code or prompt harvesting enables enterprise compliance | Relies on Linux procfs structures |

| Opportunities | Threats |
| :---- | :---- |
| First-to-market with non-intrusive enterprise coding agent governance | Agent harnesses altering process names or directory structures |
| Natural bridge to Signal Loom's downstream enforcement capabilities | Competitors claiming deep inspection via intrusive proxies |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: Detective telemetry architecture, event schema & zero-payload contract |  |  |  |  | #cap-architecture #cap-golang |
| M2: Real-time process tree & cgroup discovery engine |  |  |  |  | #cap-linux #cap-containers |
| M3: Kanban wrapper watcher & task loop telemetry |  |  |  |  | #cap-observability #cap-golang |
| M4: Disk transcript metadata indexer & inference socket detector |  |  |  |  | #cap-networking #cap-threat-modelling |
| M5: Signal Ingest pipeline & Dashboard Topology visualization |  |  |  |  | #cap-kubernetes #cap-testing-pyramid |
| M6: End-to-end acceptance suite, documentation & Monorepo certification |  |  |  |  | #cap-sdlc-tooling #cap-documentation |
| Mid-project review: demo of progress, evaluation of further milestones, raising of current and new risks | 0.25 | 2 | 0.5 |  | #cap-project-management |
| Signoff |  |  |  |  | #cap-project-management |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**

* Sensor discovers running Claude Code, Antigravity, Codex, and CPAI harnesses in <2s.
* Kanban cycle state and disk transcript metrics are indexed and streamed without payload leaks.
* Outbound inference sockets are correlated to harness PIDs without TLS decryption.
* Zero customer payload invariant is verified by automated leak-falsification tests.
* Full test suite passes via `make demo-agentmaxxing-host-test`.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | AI & Data Security practice lead ([Andrew Martin](mailto:andy@control-plane.io)) |
| Responsible | Signal Loom telemetry and agent security delivery team |
| Consulted | Cyber Resilience & Threat Assurance (John Kjell); Cloud Native Transformation |
| Informed | [Andrew Martin](mailto:andy@control-plane.io) [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

Funded under Signal Loom Agentic Governance platform investment.

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| Workstation performance benchmarking | Minimal | One Off | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-13 | AJM | Mandate strictly detective posture with NO active MCP handshakes | In-band interception creates developer friction and fragile integration; detective observability is reliable and immediate | Zero deployment friction and broad harness compatibility |
| 2026-09-13 | AJM | Enforce strict Zero-Customer-Payload Invariant across all telemetry collectors | Enterprise customers will not allow source code or prompts to leave developer machines | Ironclad privacy and regulatory compliance |
| 2026-09-13 | AJM | Combine process tree heuristics with inference socket correlation | Eliminates false positives when developers run standard compilers or IDEs | High-fidelity detection without false alarms |

## Appendix

### A. Useful Links

* Parent: [[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]
* Sibling: [[Proposal — Signal Loom Enforcement and Response (2026-Q3)]]
* Related: [[Proposal — Signal Loom AgentMaxxing Interactive Demo Console (2026-Q3)]]
* Code: `d2-signalloom/apps/agentmaxxing-host-sensor/`, `tools/harness-dash/`

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `SLCD`
- Integration branch: `refs/heads/integration/slcd-v0.1.0`
- Target components: `d2-signalloom/apps/agentmaxxing-host-sensor/`, `d2-signalloom/apps/signal-ingest/`, `d2-signalloom/apps/dashboard-signalloom/`
- Acceptance commands: `make demo-agentmaxxing-host-test`, `bats test/acceptance-spec-coverage.bats`

#### Architectural constitution
- **Strictly Detective Posture (Zero MCP Handshakes)**: The telemetry collector operates exclusively in passive, observer mode. It never negotiates MCP client/server connections, never injects RPC commands, never modifies agent configurations, and never interferes with running processes.
- **Absolute Zero-Customer-Payload Invariant**: Under no circumstances shall prompt text, user inputs, assistant responses, source code diffs, file contents, or API authentication tokens be collected or transmitted. Every telemetry record is strictly constrained to allowlisted metadata:
  ```json
  {
    "harness": "claude|antigravity|codex|cpai|opencode|hermes|aider",
    "session_id": "ses_uuid",
    "timestamp": "2026-09-13T22:00:00Z",
    "process": { "pid": 1234, "ppid": 1, "comm": "claude", "rss_bytes": 104857600, "cpu_ticks": 450 },
    "kanban": { "task_id": "SLCD-P1-1", "shortcode": "SLCD", "role": "implementation", "elapsed_s": 120 },
    "metrics": { "step_count": 14, "tokens_in": 125000, "tokens_out": 4200, "tool_counts": { "view_file": 8, "run_command": 3 } },
    "network": { "inference_endpoint": "api.anthropic.com", "egress_bytes": 45000 }
  }
  ```
- **Procfs Bounded Extraction**: The sensor reads `/proc/<pid>/stat`, `/proc/<pid>/status`, and `/proc/<pid>/statm`. Reading `/proc/<pid>/cmdline` is prohibited except for bounded binary basename resolution, preventing credential leaks from command-line flags.
- **Non-blocking Kanban Watcher**: Inspects task files and lockfiles with read-only shared descriptors, never acquiring exclusive locks or blocking kanban controller loops.
- **Socket Inode Attribution**: Outbound model traffic is detected by matching local socket inodes from `/proc/net/tcp` to process file descriptors under `/proc/<pid>/fd/`, comparing destination IPs against known inference provider CIDR ranges without TLS packet interception.

#### Canonical locations
- `d2-signalloom/apps/agentmaxxing-host-sensor/detective.py` — Host process, kanban, and socket discovery engine
- `d2-signalloom/apps/signal-ingest/telemetry_handler.go` — Go ingestion endpoint
- `d2-signalloom/apps/dashboard-signalloom/src/components/CodingAgentsTab.tsx` — Dashboard UI component
- `d2-signalloom/test/coding-agent-telemetry.bats` — BATS integration test suite

#### Testing standards
- Unit & Zero-Payload Leak Tests: `cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py'`
- Ingestion Contract Tests: `cd d2-signalloom/apps/signal-ingest && go test ./...`
- Full Estate Integration Test: `make demo-agentmaxxing-host-test`
- Acceptance Spec Coverage Gate: `bats test/acceptance-spec-coverage.bats`

#### Anti-patterns
- Never harvest prompt bodies, user chat messages, or model generation text.
- Never dump raw `/proc/<pid>/cmdline` strings or `/proc/<pid>/environ` into logs or payloads.
- Never initiate active MCP JSON-RPC handshakes or inject hooks into agent configurations.
- Never take exclusive file locks on kanban state or session log directories.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; ripwire-before-you-build | Baseline engineer | S | 45m | fast | Validate SLCD harness identity, detective tooling, and monorepo baseline. |
| P1-PRE | FirstPrinciples; ripwire-before-you-build | Schema architect | S | 45m | daily | Inventory running harness processes, session log formats, and kanban wrappers. |
| P1-1 | ripwire-write-tests; Security | Telemetry architect | M | 90m | daily | Define CodingAgentTelemetry event schema and metadata-only dictionary. |
| P1-2 | ripwire-write-tests; Security | Privacy architect | M | 90m | daily | Formulate strict zero-customer-payload validator and leak falsification tests. |
| P1-3 | ripwire-before-you-build; Security | Contract architect | L | 150m | deep | Freeze wire contract for host detective probe and signal-ingest consumer. |
| P1-4 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | antigravity | proc.py:14-32 prohibits fd, fdinfo and net, but no test pins those three. Only mem, environ and cmdline are individually pinned, so P4-2's socket detector could silently remove them and every test would still pass. The pins must exist before the detector is written. |
| P1-5 | ripwire-write-tests; ripwire-security-scan | Implementation | M | 90m | kpai | Collecting from developer workstations is employee monitoring under GDPR regardless of security purpose, and nothing in the plan establishes a lawful basis. A retrospective assessment cannot justify collection that already happened, so this is the one item in the mission that cannot be retrofitted. Article 88 and works-council consultation are a separate instrument from the Article 6(1)(f) balancing test. |
| P1-GOV | CodeReview; ripwire-change-check | Architecture Governor | M, P1-4, P1-5 | 90m | deep | Approve contract freeze and certify zero-payload invariants. |
| P2-PRE | ripwire-before-you-build; ripwire-reuse-first | System pre-flight engineer | S | 45m | daily | Confirm Linux procfs permissions and harness signature database. |
| P2-1 | ripwire-write-tests; Security | Procfs engineer | L | 150m | daily | Implement non-intrusive procfs process scanner without argument dumping. |
| P2-2 | ripwire-write-tests; Security | Ancestry classifier engineer | L | 150m | daily | Build harness process ancestry classifier for Claude, Agy, Codex, CPAI. |
| P2-GOV | CodeReview; ripwire-change-check | System Governor | M | 90m | deep | Merge process tree detective engine and verify zero false-positive collisions. |
| P3-PRE | ripwire-before-you-build; ripwire-reuse-first | Kanban pre-flight engineer | S | 45m | daily | Confirm kanban lockfiles, lease formats, and task cycle markers. |
| P3-1 | ripwire-write-tests; Security | Kanban watcher engineer | L | 150m | daily | Implement passive watcher for active kanban controller cycles and task leases. |
| P3-2 | ripwire-write-tests; SystemsThinking | Metrics engineer | M | 90m | daily | Extract cycle telemetry (task ID, role, shortcode, turn count, elapsed time). |
| P3-GOV | CodeReview; ripwire-change-check | Kanban Governor | M | 90m | deep | Merge kanban wrapper telemetry and verify non-interfering read locks. |
| P4-PRE | ripwire-before-you-build; ripwire-reuse-first | Transcript pre-flight engineer | S | 45m | daily | Confirm transcript file paths and socket inspection permissions. |
| P4-1 | ripwire-write-tests; Security | Transcript indexer engineer | L | 150m | deep | Implement zero-payload transcript metadata parser (tokens, tools, steps). |
| P4-2 | ripwire-write-tests; ripwire-security-scan | Network telemetry engineer | L | 150m | deep | Build outbound LLM network socket detector via procfs without TLS interception. |
| P4-GOV | CodeReview; ripwire-change-check | Telemetry Governor | L | 150m | deep | Merge transcript and socket detectors and prove zero payload harvesting. |
| P5-PRE | ripwire-before-you-build; Browser | Ingestion pre-flight engineer | S | 45m | daily | Confirm signal-ingest API endpoints and Topology UI agent models. |
| P5-1 | ripwire-write-tests; Security | Ingestion backend engineer | L | 150m | daily | Wire telemetry dispatcher into Signal Loom ingestion pipeline. |
| P5-2 | Browser; ripwire-write-tests | UI visualization engineer | M | 90m | daily | Render detected coding agents in Dashboard Topology and Agent Swarm views. |
| P5-GOV | CodeReview; Browser; ripwire-change-check | Integration Governor | M | 90m | deep | Merge ingestion and UI rendering and prove end-to-end telemetry streaming. |
| P6-PRE | ripwire-before-you-build; Browser | Acceptance pre-flight engineer | S | 45m | daily | Confirm end-to-end fixture harnesses, test runners, and SPEC-REGISTRY. |
| P6-1 | ripwire-write-tests; ripwire-security-scan | Test automation engineer | L | 150m | daily | Build unit, integration, and security test suites for detective telemetry. |
| P6-2 | Drawio; Browser | Technical author | M | 90m | daily | Create documentation and detection runbook in apps/docs-signalloom. |
| P6-3 | Browser; ripwire-write-tests | Acceptance engineer | L | 150m | deep | Build Playwright browser acceptance test for coding agent topology rendering. |
| P6-4 | ripwire-write-tests; ripwire-security-scan | Implementation | S | 45m | antigravity | P6-PRE only confirms the registry and P6-3 writes a spec, but nothing produces the row or the testMatch entry. That registry already records four specifications that matched no testMatch and were therefore silently never run, so this is a demonstrated failure mode rather than a hypothetical one. |
| P6-GOV | CodeReview; Browser; ripwire-change-check | Acceptance Governor | L, P6-4 | 150m | deep | Reconcile acceptance wiring, run full test suite, and certify SLCD delivery. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | preflight | Validate SLCD harness identity and clean detective monorepo baseline | None | `scripts/kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode SLCD`; repository and board evidence only | S | fast | **Pass (qualified)** — board checks green, doctor exits 1 on a workspace-wide fast-exit sweep no SLCD card can clear (Q2); baseline at `docs/signalloom/slcd-p0-baseline.md`; branch not pushed per Safety Rules (Q1); 2 architectural contradictions escalated (E1 socket/`fd`, E2 `cmdline`) | $0.00 | N/A | N/A | N/A |
| P1-PRE | preflight | Inventory running harness processes, session log formats, and kanban wrappers | P0 | Process snapshot; session log schema inventory | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-1 | implementation | Define CodingAgentTelemetry event schema and metadata-only dictionary | P1-PRE | JSON schema tests; metadata dictionary validation | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-2 | implementation | Formulate strict zero-customer-payload validator and leak falsification tests | P1-PRE | Adversarial leak tests; prompt/code detection negative assertions | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P1-3 | implementation | Freeze wire contract for host detective probe and signal-ingest consumer | P1-1, P1-2 | Versioned Go/Python schemas; OpenAPI contract freeze | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P1-4 | implementation | Pin every prohibited procfs entry before a detector touches them | P1-PRE | `cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest discover -p 'test_*.py'` | M | antigravity | Pending | $0.00 | N/A | N/A | N/A |
| P1-5 | implementation | Legitimate Interest Assessment and works-council position for workstation telemetry | P1-PRE | `test -f docs/signalloom/slcd-lawful-basis.md` | M | kpai | Pending | $0.00 | N/A | N/A | N/A |
| P1-GOV | governor | Approve contract freeze and certify zero-payload invariants | P1-1, P1-2, P1-3, P1-4, P1-5 | Architecture review; zero kickoff gate exceptions | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P2-PRE | preflight | Confirm Linux procfs permissions and harness signature database | P1-GOV | Procfs access check; harness signatures inventory | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-1 | implementation | Implement non-intrusive procfs process scanner without argument dumping | P2-PRE | Pytest procfs scanner tests; verify `/proc/<pid>/cmdline` is not dumped | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-2 | implementation | Build harness process ancestry classifier for Claude, Agy, Codex, CPAI | P2-PRE | Heuristic classifier tests; tree resolution accuracy assertions | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P2-GOV | governor | Merge process tree detective engine and verify zero false-positive collisions | P2-1, P2-2 | Multi-process stress test; zero false-positive assertions | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P3-PRE | preflight | Confirm kanban lockfiles, lease formats, and task cycle markers | P2-GOV | Kanban filesystem inspection; lease format check | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-1 | implementation | Implement passive watcher for active kanban controller cycles and task leases | P3-PRE | Shared read-lock tests; zero controller loop interference check | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-2 | implementation | Extract cycle telemetry (task ID, role, shortcode, turn count, elapsed time) | P3-PRE | Cycle metrics parsing tests; live task status reflection check | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P3-GOV | governor | Merge kanban wrapper telemetry and verify non-interfering read locks | P3-1, P3-2 | Concurrent kanban run tests; lock contention assertions | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P4-PRE | preflight | Confirm transcript file paths and socket inspection permissions | P3-GOV | Transcript file readability check; socket query test | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P4-1 | implementation | Implement zero-payload transcript metadata parser (tokens, tools, steps) | P4-PRE | JSONL parser tests; token and tool histogram extraction assertions | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P4-2 | implementation | Build outbound LLM network socket detector via procfs without TLS interception | P4-PRE | Socket mapping tests; IP/endpoint correlation checks | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P4-GOV | governor | Merge transcript and socket detectors and prove zero payload harvesting | P4-1, P4-2 | End-to-end leak audit; zero prompt/code emission verified | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P5-PRE | preflight | Confirm signal-ingest API endpoints and Topology UI agent models | P4-GOV | API schema check; UI model contract verification | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-1 | implementation | Wire telemetry dispatcher into Signal Loom ingestion pipeline | P5-PRE | Ingestion contract tests; event deduplication and tenant isolation checks | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-2 | implementation | Render detected coding agents in Dashboard Topology and Agent Swarm views | P5-PRE | Vitest UI component tests; coding agent card and status badge assertions | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P5-GOV | governor | Merge ingestion and UI rendering and prove end-to-end telemetry streaming | P5-1, P5-2 | Full ingestion -> UI render integration test; latency assertions | M | deep | Pending | $0.00 | N/A | N/A | N/A |
| P6-PRE | preflight | Confirm end-to-end fixture harnesses, test runners, and SPEC-REGISTRY | P5-GOV | Fixture verification; runner command availability check | S | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-1 | implementation | Build unit, integration, and security test suites for detective telemetry | P6-PRE | `make demo-agentmaxxing-host-test`; 100% pass across all tiers | L | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-2 | implementation | Create documentation and detection runbook in apps/docs-signalloom | P6-PRE | Astro docs build check; runbook clarity verification | M | daily | Pending | $0.00 | N/A | N/A | N/A |
| P6-3 | implementation | Build Playwright browser acceptance test for coding agent topology rendering | P6-PRE | Playwright spec passes; live agent cards and metrics verified | L | deep | Pending | $0.00 | N/A | N/A | N/A |
| P6-4 | implementation | Add the SLCD SPEC-REGISTRY row, testMatch entry and Makefile target | P6-PRE | `bats test/acceptance-spec-coverage.bats` | S | antigravity | Pending | $0.00 | N/A | N/A | N/A |
| P6-GOV | governor | Reconcile acceptance wiring, run full test suite, and certify SLCD delivery | P6-1, P6-2, P6-3, P6-4 | `bats test/acceptance-spec-coverage.bats` passes; all SLCD tests green | L | deep | Pending | $0.00 | N/A | N/A | N/A |

### Spec: Errata

#### Errata — SLCD-P0 (preflight)
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-15T00:01:57+01:00
**Last Updated:** 2026-09-15T00:19:02+01:00

##### Task identity
- Card: `SLCD-P0`
- Shortcode: `SLCD`
**Status:** pass
**Commit:** `cb0d3a645041a314625feb0115e0f29a3e6e3206`
- Base commit: `2fedff0610b16682128cbcfac42eff9025320a53`
- Deliverable commit: `cb0d3a645041a314625feb0115e0f29a3e6e3206` (task worktree, detached; merge to `integration/slcd-v0.1.0` is the phase Governor's, not P0's — lifecycle boundary is create-only)
- Integration ref: `refs/heads/integration/slcd-v0.1.0` = `2fedff0610b16682128cbcfac42eff9025320a53`
- Branch label at run time: `(detached)`
- Result: Baseline established; two architectural contradictions escalated; nothing pushed.
**Phase 0 can proceed:** yes

##### Deliverable verification
- Baseline document: `docs/signalloom/slcd-p0-baseline.md` — full evidence, cited by later cards.
- Fast-exit baseline set: `docs/signalloom/slcd-p0-fast-exit-baseline.txt` (29 task IDs).
- Component paths confirmed present: `d2-signalloom/apps/{agentmaxxing-host-sensor,signal-ingest,dashboard-signalloom}`.
- The four canonical locations the proposal names are absent, as expected — this mission creates them.
- Acceptance commands **run, not read**: `bats test/acceptance-spec-coverage.bats` exit 0 (7/7);
  `python3 -m unittest discover -p 'test_*.py'` in the sensor exit 0 (41 tests, OK);
  `cd d2-signalloom/apps/signal-ingest && go test ./...` exit 0 (24 packages);
  `make demo-agentmaxxing-host-test` exit 2 then exit 0 on re-run (see Q3).
- Go module topology recorded: **no root `go.mod`, no `go.work`**; 20 module roots under
  `d2-signalloom/`. Control run from the repository root fails
  `pattern ./...: directory prefix . does not contain main module`, exit 1. Every later Go test
  command in this mission MUST `cd d2-signalloom/apps/signal-ingest` first.
- Export-surface baseline: `filter.py:33-47` allow-lists bounded integers and enums only;
  **zero free-text fields**. Recorded explicitly as a *point-in-time starting condition* that
  SLCD is about to invalidate, not as a permanent property of the collector.

##### Qualifications
- **Q1 — the branch was NOT pushed, deliberately.** The Deliverables asked for
  `integration/slcd-v0.1.0` to be "created from the fetched remote tip and pushed", while the
  Safety Rules state `never push to a remote`. Per the card's own Precedence section, Safety
  Rules outrank Deliverables, so the push was not performed.
  `git rev-parse origin/integration/slcd-v0.1.0` returns `fatal: Needed a single revision` —
  the branch is local-only. The *provenance* half of the deliverable is met and verified:
  after `git fetch origin --prune`,
  `git merge-base --is-ancestor origin/main integration/slcd-v0.1.0` exits 0, with
  `origin/main` = `df65bb2e767fe5f0585e23da57a7756d876c98cc`. **A human must decide whether to
  push**; until then every downstream worktree must branch from the local ref.
- **Q2 — the doctor exits 1, and no SLCD card can make it green.** Both board-scoped checks are
  green (`link-check`: all six rules pass, `CRITICAL=0 FAIL=0 WARN=0`; `inversions`: no inverted
  edges; board `HEALTH: ✓ healthy`). The single exception is check 3, duration/fast-exit, which
  `scripts/kanban-check.sh:90` invokes **without forwarding `--shortcode`**. It sweeps
  `~/.cline/kanban/workspaces/osramp-demo/sessions.json` (302 entries) across every mission ever
  run in this workspace. Positive evidence it is not ours: **0** of 302 session keys match
  `/SLCD/`; **0** fast-exit entries match `/SLCD/`; the population spans 2026-09-01 → 2026-09-13,
  all predating SLCD; and the count moved **29 → 32** between two derivations minutes apart
  because sibling missions are running concurrently. The "Loop on these until green" instruction
  is therefore **unsatisfiable as written** and was not looped on. Downstream Governors must test
  *containment* against `docs/signalloom/slcd-p0-fast-exit-baseline.txt`, not exit status — a
  genuine new SLCD crash would also exit 1, masked behind the inherited ones. **This argument
  expires the moment the first SLCD card reaches a finished state.**
- **Q3 — `make demo-agentmaxxing-host-test` is flaky from shared state, not from a repo defect.**
  First run exit 2 at `test/signalloom/file-validator-anti-escape.bats` test 9; re-run at the
  same commit exit 0. Cause: `.pytest_cache` in every task worktree is a **symlink to
  `/home/andy/src/cp/osramp-demo/.pytest_cache`**, so ~40 concurrent worktrees contend for one
  cache directory (`PytestCacheWarning … [Errno 13] Permission denied … v/cache/nodeids`). That
  bats test invokes pytest without the `-o cache_dir=…` override the sibling Makefile recipes
  use. No fix applied — adding the override touches a P6-owned surface. A single red run of this
  target is not evidence of a regression.
- **Q4 — `go test ./...` in signal-ingest mutates a git-tracked fixture.** Package `correlation`
  rewrites `d2-signalloom/apps/signal-ingest/correlation/redteam_cascade_ceiling.json`
  (12 insertions / 12 deletions). Expected, reverted before staging; the committed tree excludes it.

##### Escalations — architectural contradictions found at P0 (STOP and report)
Both were falsified by executing the guard, not by reading it. Neither is P0's to fix; both are
recorded so the owning card does not resolve them by weakening the invariant.

- **E1 — Socket Inode Attribution is unbuildable through `ProcReader` as specified (owner: P4-2).**
  Shared Patterns specifies matching socket inodes from `/proc/net/tcp` to descriptors under
  `/proc/<pid>/fd/`. `proc.py:14-32` lists `fd`, `fdinfo` **and** `net` in
  `PROHIBITED_PROC_ENTRIES`, and `_safe_proc_path` (`proc.py:103-110`) raises
  `SecurityException` on each — verified by direct invocation, all three BLOCKED. Removing an
  entry from that set is a declared hard blocker for this mission. P4-2 must either use a
  different mechanism or escalate for an explicit, separately-reasoned exception.
- **E2 — the `cmdline` basename carve-out exists in the constitution but not in code (owner: P2-2).**
  Shared Patterns permits reading `/proc/<pid>/cmdline` "for bounded binary basename resolution".
  `cmdline` is in the prohibited set and `_safe_proc_path` raises on it unconditionally
  (verified BLOCKED). Harness identification therefore has only `comm` from `/proc/<pid>/stat`.
  P2-2 must establish empirically whether the harnesses it must tell apart stay distinguishable.

##### Boundary note
`proc.py` is a **pre-collection** chokepoint (raises before `open()`); `filter.py` is
**post-hoc** — `collector.py` reads into objects first and filters on export. The two are not
interchangeable, and `filter.py` alone cannot stop a payload already read into memory.

#### Errata — SLCD-P1-PRE (preflight)
##### Task identity
- Card: `SLCD-P1-PRE`
- Shortcode: `SLCD`
- Commit: Pending
- Result: Pending

##### Deliverable verification
- Verification: Seam inventory and kick-off gates verified.

#### Errata — SLCD-P1-4 (bootstrap)
##### Task identity
- Card: `SLCD-P1-4`
- Shortcode: `SLCD`
- Commit: Pending
- Result: Pending

#### Errata — SLCD-P1-5 (bootstrap)
##### Task identity
- Card: `SLCD-P1-5`
- Shortcode: `SLCD`
- Commit: Pending
- Result: Pending

#### Errata — SLCD-P6-4 (bootstrap)
##### Task identity
- Card: `SLCD-P6-4`
- Shortcode: `SLCD`
- Commit: Pending
- Result: Pending

