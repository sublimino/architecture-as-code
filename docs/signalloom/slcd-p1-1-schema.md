# SLCD-P1-1: CodingAgentTelemetry Schema and Closed Metadata Dictionary

**Specification Version:** `1.0.0`  
**Mission:** Signal Loom Coding Agent & Harness Detective Telemetry (`SLCD`)  
**Status:** Approved & Implemented  
**Canonical Schema Definition:** `d2-signalloom/apps/agentmaxxing-host-sensor/schemas/coding-agent-telemetry.v1.schema.json`  
**Go Module:** `d2-signalloom/apps/signal-ingest/codingagent/telemetry.go`  
**Python Package:** `d2-signalloom/apps/agentmaxxing-host-sensor/coding_agent_models.py`

---

## 1. Executive Summary & Design Invariants

Prior host telemetry exported by `agentmaxxing-host-sensor` allowed strictly bounded numeric/enum process metrics (`health_state`, `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count`, `cpu_percent`, `pid`, `ppid`) with zero free-text fields.

The `CodingAgentTelemetry` schema introduces essential operational identifiers (`comm`, `session_id`, `harness`, `task_id`, `shortcode`, `role`, and `inference_endpoint`). Because free-text and map-key channels represent potential data exfiltration vectors, this schema enforces five non-negotiable structural constraints:

1. **Closed, Structurally-Enforced Allow-List**: Every single property at the envelope and sub-object levels is declared with `additionalProperties: false`. Dynamic keys are completely prohibited.
2. **Hard Length and Charset Bounds**: Every string field has an explicit maximum byte/character length and a strict regex whitelist.
3. **Fixed-Arity Tool Vector with Overflow Routing**: The open-ended `tool_counts` dictionary is replaced by a fixed 14-field struct. All customer-defined MCP server tools (`mcp__<server>__<tool>`) and unrecognised tool names are strictly routed to the `other_count` integer counter.
4. **SLDP Pseudonym Identity Reuse**: The `session_id` field reuses the SLDP HMAC-SHA256 pseudonym primitive (`Domain: "signalloom/identity/alias-pseudonym/v1"`, `HexLen: 64`) rather than an arbitrary user or session string.
5. **Fail-Closed Validation (Rejection Over Truncation)**: Any payload containing an over-length string, off-enum value, forbidden character, or prohibited key raises an immediate validation failure and is rejected at ingestion. Truncation is strictly forbidden.

---

## 2. Complete Field Dictionary & Bounded Classifications

### 2.1 Top-Level Envelope

| Field | Type | Bounds / Format | Classification | Security Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `schema_version` | String (const) | `"1.0.0"` | Bounded Enum | Locks wire protocol; prevents unversioned schema drift. |
| `harness` | String (enum) | `{"claude", "antigravity", "codex", "cpai", "opencode", "hermes", "aider", "unknown"}`<br/>Max: 32 chars, `^[a-z0-9_-]{1,32}$` | Bounded Enum | Closed set of known coding harnesses. Unrecognised harnesses map to `unknown` rather than an arbitrary user-controlled string. |
| `session_id` | String | Exactly 64 chars, `^[a-f0-9]{64}$` | Bounded Pseudonym | Reuses SLDP pseudonym primitive (`pseudonym.go`). Enforces strict 64-char lowercase hex string; blocks raw IDs. |
| `timestamp` / `observed_at` | String (datetime) | Max: 35 chars, RFC3339 / ISO8601 | Bounded Datetime | Standard monotonic timestamp with timezone; rejects arbitrary string text. |
| `tenant_id` | String (optional) | 3..63 chars, `^[a-z][a-z0-9-]{2,63}$` | Bounded Identifier | Standard Signal Loom tenant namespace identifier. |
| `agent_id` | String (optional) | 3..63 chars, `^[a-z][a-z0-9-]{2,63}$` | Bounded Identifier | Workstation host agent identifier. |
| `host_id` | String (optional) | 3..63 chars, `^[a-z][a-z0-9-]{2,63}$` | Bounded Identifier | Workstation node identifier. |
| `process` | Object | Ref: `process_info` | Struct | Bounded process metrics. |
| `kanban` | Object | Ref: `kanban_info` | Struct | Bounded task execution state. |
| `metrics` | Object | Ref: `metrics_info` | Struct | Bounded step, token, and tool counts. |
| `network` | Object | Ref: `network_info` | Struct | Bounded egress metrics. |

---

### 2.2 Process Metrics (`process`)

Extracted passively from `/proc/<pid>/stat`, `/proc/<pid>/status`, and `/proc/<pid>/statm`.

| Field | Type | Bounds / Format | Classification | Security Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `pid` | Integer | `[1, 4194304]` | Bounded Numeric | Linux `/proc/sys/kernel/pid_max` ceiling. Rejects negative/zero/excessive PIDs. |
| `ppid` | Integer | `[0, 4194304]` | Bounded Numeric | Parent PID ceiling (0 for init/kthreadd). |
| `comm` | String | Max: 16 chars, `^[a-zA-Z0-9_.-]{1,16}$` | Bounded Identifier | Linux procfs `comm` field is kernel-capped at 16 bytes. Regex blocks control characters, newlines, semicolons, and spaces. |
| `rss_bytes` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Non-negative resident memory bytes. |
| `cpu_ticks` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Non-negative cumulative user+system CPU clock ticks. |

---

### 2.3 Kanban Task Execution (`kanban`)

Extracted passively by the non-intrusive kanban watcher without holding mutating locks.

| Field | Type | Bounds / Format | Classification | Security Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `task_id` | String | 1..64 chars, `^[A-Z0-9_-]{1,64}$` | Bounded Identifier | Namespaced task ID (e.g. `SLCD-P1-1`). Rejects arbitrary markdown, spaces, or script injections. |
| `shortcode` | String | 2..16 chars, `^[A-Z0-9]{2,16}$` | Bounded Identifier | Project shortcode (e.g. `SLCD`, `AMXD`). |
| `role` | String | 1..32 chars, `^[a-z0-9_-]{1,32}$` | Bounded Identifier | Kanban task role (e.g. `implementation`, `preflight`, `governor`, `acceptance`). |
| `elapsed_s` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Non-negative wall-clock execution duration in seconds. |

---

### 2.4 Session Metrics & Fixed-Arity Tool Vector (`metrics`)

Extracted from session transcript metadata (`step_count`, tokens, tool invocations).

| Field | Type | Bounds / Format | Classification | Security Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `step_count` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Non-negative sequence step counter. |
| `tokens_in` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Unsigned 64-bit integer to prevent silent negative integer overflow on long agent sessions (> 2^31 tokens). |
| `tokens_out` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Unsigned 64-bit integer for cumulative output tokens. |
| `tool_counts` | Object (fixed arity) | Exactly 14 predefined integer fields | Fixed-Arity Struct | **Prevents MCP Key Schema Expansion.** Replaces open dynamic map. |

#### Fixed-Arity Tool Vector Fields (`tool_counts`)
Every field is a non-negative integer (`[0, 9007199254740991]`):
1. `view_file` — Reads/inspects file content.
2. `write_to_file` — Creates/overwrites files.
3. `replace_file_content` — Surgical file modifications/diffs.
4. `run_command` — Shell command execution (bash/sh/exec).
5. `grep_search` — Pattern searches (ripgrep/grep).
6. `find_by_name` — Directory file/glob lookups (fd/glob/find).
7. `list_dir` — Directory listing.
8. `read_url_content` — HTTP web page extraction.
9. `search_web` — Web search engine queries.
10. `invoke_subagent` — Agent/subagent spawning.
11. `send_message` — Inter-agent messaging.
12. `manage_task` — Background task management.
13. `ask_question` — Interactive user prompts.
14. `other_count` — **Overflow Bucket:** All custom MCP server tools (e.g. `mcp__postgres__query`, `mcp__github__pr`) and unrecognised tool names increment this single counter.

---

### 2.5 Outbound Inference Network (`network`)

Extracted passively from `/proc/net/tcp` socket inode correlation without TLS packet interception.

| Field | Type | Bounds / Format | Classification | Security Rationale |
| :--- | :--- | :--- | :--- | :--- |
| `inference_endpoint` | String | 1..128 chars, `^[a-zA-Z0-9.-]{1,128}$` | Bounded Hostname/IP | Hostname or IP of LLM provider (e.g. `api.anthropic.com`, `api.openai.com`, `127.0.0.1`). Regex strictly forbids URLs, paths (`/v1/...`), query parameters, and auth credentials. |
| `egress_bytes` | Integer (uint64) | `[0, 9007199254740991]` | Bounded Numeric | Non-negative byte counter for outbound traffic to the inference endpoint. |

---

## 3. Cryptographic Identity & Session Pseudonymization

Rather than creating an ad-hoc session hash or sending raw UUIDs, `session_id` is derived using the established SLDP pseudonym primitive:
- **Package:** `d2-signalloom/apps/signal-ingest/pseudonym/`
- **Domain Label:** `"signalloom/identity/alias-pseudonym/v1"`
- **Algorithm:** Keyed HMAC-SHA256 using tenant-and-epoch HKDF-SHA256 derived keys.
- **Output:** Exact 64-character lowercase hex string (`^[a-f0-9]{64}$`).
- **Cross-Language Equivalence:** Validated to produce identical pseudonyms in Go and Python for all test vectors.

---

## 4. Prohibited Payload Keys & Anti-Exfiltration Guarantees

Under the **Zero-Customer-Payload Invariant**, the following keys are prohibited from appearing anywhere in serialized telemetry events:
- `prompt_text`, `completion_text`, `user_data`, `input_payload`, `output_payload`
- `file_contents`, `memory_contents`, `memory_dump`, `streamed_payload_contents`
- `cmdline`, `argv`, `cli_arguments`, `command`, `command_line`
- `env`, `environ`, `environment`
- `credentials`, `secret`, `password`, `token`, `api_key`

If any prohibited key or unexpected dynamic property is encountered during parsing, the record is immediately rejected with a validation error. Truncation is disallowed to ensure that attempts to inject malicious or oversized payloads are surfaced as security violations.
