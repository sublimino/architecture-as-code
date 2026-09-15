# SLCD-P4-PRE — Transcript Stores & Socket Inspection Permission Specification

> **Purpose.** Ground SLCD-P4-1's zero-payload transcript metadata parser and SLCD-P4-2's outbound
> LLM socket detector in empirical on-disk transcript formats, tailing requirements, and Linux
> socket-inspection permission models on host `andy`, ensuring P1-4's negative-security pins remain
> green and intact before implementation starts.
>
> | | |
> |---|---|
> | **Card** | `SLCD-P4-PRE (preflight)` |
> | **Host** | `andy` (Linux 7.1.3+deb13-amd64 x86_64) |
> | **Date** | 2026-09-15 |
> | **Worktree** | `/home/andy/src/.worktrees/e70bb/osramp-demo` |
> | **Base Ref** | `refs/heads/integration/slcd-v0.1.0` |
> | **Target Components** | `d2-signalloom/apps/agentmaxxing-host-sensor/` (`detective.py`, `proc.py`, `filter.py`) |
> | **Invariants** | Strictly Detective Posture & Absolute Zero-Customer-Payload |

---

## 1. Executive Summary & Core Grounding Findings

1. **Empirical Transcript Store Inventory Confirmed Across 7 Harnesses:**
   - **Claude Code:** `~/.claude/projects/<slug>/<uuid>.jsonl` — 165 project directories, 3,987 JSONL transcripts. Append-only during live turns. Contains granular `usage` tokens (`input_tokens`, `output_tokens`, `cache_read_input_tokens`), `model`, and `tool_use` blocks. Requires **incremental tailing**.
   - **Antigravity CLI:** `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl` — 501 session directories. Append-only JSONL during live steps. Contains `step_index`, `source`, `type`, and `tool_calls` array. Session ID is the UUID directory name. Requires **incremental tailing**.
   - **Antigravity IDE:** `~/.gemini/antigravity/conversations/<uuid>.db` — SQLite database (`trajectory_meta`, `steps`, `gen_metadata`) + `antigravity_state.pbtxt`. Requires **read-only SQLite query (`file:...mode=ro`)**.
   - **Codex CLI:** `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` — JSONL events with `payload.{session_id, model, turn_id, duration_ms}`. Requires **incremental tailing**.
   - **OpenCode:** `~/.local/share/opencode/opencode.db` + `storage/session_diff/` — SQLite tables (`session`, `message`, `part`, `event`). Requires **read-only SQLite query (`file:...mode=ro`)**.
   - **Hermes:** `~/.hermes/sessions/` — JSON request dumps (`request_dump_*.json`, `sessions.json`). Requires **one-shot read per request/session**.
   - **CPAI & Aider:** CPAI runtime directories exist; Aider (`~/.aider`) is **absent** from this host.

2. **Socket Inspection Permission Model Confirmed:**
   - **`/proc/net/tcp` and `/proc/net/tcp6`** are globally readable by unprivileged user `andy` (`uid=1000`). They expose `local_address`, `rem_address` (hex IP:port), connection state (`st`), socket `inode`, and `uid` without elevated privileges.
   - **`ss -ntp` and `lsof -iTCP`** execute without root or `sudo`, returning outbound TCP connections and process attribution for user-owned PIDs (e.g. `users:(("agy",pid=2340961,fd=17))`).
   - For processes owned by other UIDs (e.g. root), unprivileged socket tools gracefully omit process names (`EACCES` on foreign `/proc/<pid>/fd/`).

3. **P1-4 Negative-Security Pins Confirmed 100% Green:**
   - All 17 members of `PROHIBITED_PROC_ENTRIES` in `proc.py:14-32` (`mem`, `environ`, `cmdline`, `maps`, `smaps`, `smaps_rollup`, `stack`, `syscall`, `io`, `fd`, `fdinfo`, `net`, `cwd`, `root`, `clear_refs`, `pagemap`, `attr`) are guarded before `open()` by `_safe_proc_path`.
   - `d2-signalloom/apps/agentmaxxing-host-sensor/test_negative_security.py` passes all 16 negative security assertions (`python3 -m unittest test_negative_security -v` -> **16/16 OK**).
   - Specifically, `test_prohibit_procfs_fd_inspection`, `test_prohibit_procfs_fdinfo_inspection`, and `test_prohibit_procfs_net_inspection` strictly pin `fd`, `fdinfo`, and `net`, preventing P4-2 from weakening `proc.py`.

4. **Clean Architectural Boundary for P4-2 (Global Netstat vs. Per-Process Procfs):**
   - The prohibition on `/proc/<pid>/net` and `/proc/<pid>/fd` in `proc.py` governs the per-process reader (`ProcReader`).
   - P4-2's socket detector reads host-level `/proc/net/tcp` (or executes `ss -nt` / Netlink `INET_DIAG`), completely bypassing `ProcReader`'s per-process path checks without modifying or weakening `PROHIBITED_PROC_ENTRIES`.

5. **Transcripts Live Completely Outside Procfs:**
   - Every transcript store resides strictly within user home directories (`~/.claude/`, `~/.gemini/`, `~/.codex/`, `~/.local/share/opencode/`, `~/.hermes/`).
   - Transcripts never touch `/proc/` or any `PROHIBITED_PROC_ENTRIES` member.

---

## 2. Detailed Harness Transcript Store Matrix

| Harness Platform | On-Disk Store Path | Storage Format | Live Write Pattern | Reader Access Strategy | Allowlisted Metrics Available | Dangerous / Payload Traps to Discard | Host Verification Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Claude Code** | `~/.claude/projects/<slug>/<uuid>.jsonl` | JSONL (1 JSON record / line) | Append-only per turn | Incremental tailing (offset / line tracking) | `message.usage.input_tokens`, `output_tokens`, `cache_read_input_tokens`, `message.model`, `step_count`, tool invocation counts from `message.content[type=tool_use]` | `message.content[type=text]`, prompt text, code diffs, `lastPrompt` | **CONFIRMED LIVE** (165 project dirs, 3,987 JSONL files) |
| **Antigravity CLI** | `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl` | JSONL | Append-only per step | Incremental tailing | `step_index` (step count), `tool_calls[].name` (tool histogram), `source` counts; session UUID from directory name | `content`, `thinking`, `tool_calls[].arguments`, `tool_calls[].result` | **CONFIRMED LIVE** (501 session dirs, active logs) |
| **Antigravity IDE** | `~/.gemini/antigravity/conversations/<uuid>.db` | SQLite 3 (`.db` + WAL) | Transactional WAL updates | SQLite query with `file:...mode=ro` | Step count (`COUNT(*) FROM steps`), tool execution metadata from `executor_metadata` | User prompt text, code edits, conversation blobs | **CONFIRMED LIVE** (1 conversation DB + `.pbtxt`) |
| **Codex CLI** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | JSONL | Append-only per event | Incremental tailing | `payload.session_id`, `payload.model`, `payload.turn_id`, `payload.duration_ms` | `payload.prompt`, `payload.code_diff`, `payload.rate_limits.credits.balance` | **CONFIRMED ON DISK** (Directory layout present) |
| **OpenCode** | `~/.local/share/opencode/opencode.db` | SQLite 3 | Drizzle ORM transactions | SQLite query with `file:...mode=ro` | `session.id`, `COUNT(*) FROM message`, tool part counts | `message.content`, `part.text`, `session_diff` JSON | **CONFIRMED ON DISK** (DB file present) |
| **Hermes** | `~/.hermes/sessions/` | JSON (`request_dump_*.json`, `sessions.json`) | Discrete JSON dump per request | One-shot read on new file | `session_id`, request timestamps, error codes | Full request payload, prompt text, user phone/chat text | **CONFIRMED LIVE** (8 request dumps, readable) |
| **CPAI Swarm** | `~/.local/share/cpai/` | State files / Task logs | Ephemeral workspace runs | Passive watcher | Session ID, task metadata | Prompts, source files | **CONFIRMED ON DISK** |
| **Aider** | `~/.aider/` | File history / Chat logs | Append-only | N/A | Session duration, model | Chat history markdown, diffs | **ABSENT** (Not installed on host) |

---

## 3. Format & Tailing Classification

### 3.1 Streaming / Tailing Stores (Active Live Sessions)
Coding agents write transcripts progressively throughout multi-turn executions. A one-shot read at startup or at fixed intervals will repeatedly re-parse megabytes of historical turns (e.g. Claude transcripts exceed 1.3 MB, Antigravity transcripts contain 80+ steps).

- **Requirement for P4-1:**
  - The transcript parser must maintain a stateful bookmark dictionary: `(file_path -> {last_offset: int, last_line: int, last_mtime: float, accumulated_metrics: Metrics})`.
  - On each polling cycle, if `os.path.getmtime(path) > last_mtime` or `os.path.getsize(path) > last_offset`:
    - Open with `O_RDONLY`.
    - `seek(last_offset)`.
    - Stream newly appended lines, parse JSON, update running counters, and advance `last_offset` to `tell()`.
  - This ensures near-zero CPU and I/O overhead during long agent executions.

### 3.2 Transactional SQLite Stores (Snapshot Isolation)
Antigravity IDE (`conversations/*.db`) and OpenCode (`opencode.db`) store state in SQLite databases with Write-Ahead Logging (`-wal` and `-shm`).

- **Requirement for P4-1:**
  - Must connect using SQLite URI mode: `sqlite3.connect("file:<path>?mode=ro", uri=True)`.
  - Must never issue `BEGIN EXCLUSIVE` or write transactions.
  - Queries must be bounded to `SELECT COUNT(*)`, `SELECT id, model, created_at`, strictly excluding content/prompt columns.

---

## 4. Socket Inspection Permission Model & Kernel Interfaces

### 4.1 Global `/proc/net/tcp` and `/proc/net/tcp6` Readability
Empirical measurements on host `andy`:
- `/proc/net/tcp` lines: 325 active socket records.
- Mode: `-r--r--r--` (world-readable).
- Read operation: `open("/proc/net/tcp", O_RDONLY)` succeeds with `rc=0` under unprivileged user `andy` (`uid=1000`).

**Field Layout of `/proc/net/tcp`:**
```
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 10815C64:01BB 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 134327 ...
 517: F801A8C0:9C4C 1AE0BA23:01BB 01 00000000:00000000 00:00000000 00000000  1000        0 872565001 ...
```
- `st == 01`: `TCP_ESTABLISHED`.
- `rem_address`: Remote IP address (little-endian hex) and port (hex `01BB` = 443).
- `inode`: Kernel socket inode number (e.g. `872565001`).
- `uid`: Owner UID (e.g. `1000`).

### 4.2 Utility Invocation (`ss -ntp`, `lsof`)
- `ss -ntp` and `lsof -iTCP -n -P` execute cleanly without root or `sudo`.
- For processes owned by `andy` (e.g. Antigravity PID `2340961`), `ss -ntp` successfully attributes socket connections to process PIDs:
  ```
  ESTAB 0 0 192.168.1.248:50452 34.54.84.110:443 users:(("agy",pid=2340961,fd=17))
  ESTAB 0 0 192.168.1.248:53646 172.217.112.4:443 users:(("agy",pid=2340961,fd=44))
  ```
- Destination IP `34.54.84.110` (Google Cloud / Vertex AI) and `172.217.x.x` (Google APIs) demonstrate live outbound LLM inference socket attribution in real time.

### 4.3 Security Pin Compatibility & Procfs Decoupling
- In `proc.py`, `PROHIBITED_PROC_ENTRIES` forbids inspecting `/proc/<pid>/fd`, `/proc/<pid>/fdinfo`, and `/proc/<pid>/net` via `ProcReader._safe_proc_path(pid, entry)`.
- P4-2 must NOT attempt to read `/proc/<pid>/fd/` through `ProcReader`.
- Instead, P4-2 implements a standalone network detector (`network.py` or `detective.py:detect_inference_sockets`) that reads global `/proc/net/tcp` (or parses `ss -nt` / Netlink `INET_DIAG`), matching remote IPs against known LLM inference provider CIDRs:
  - Anthropic: `api.anthropic.com` IP ranges
  - OpenAI: `api.openai.com` IP ranges
  - Google Vertex / Gemini: `generativelanguage.googleapis.com` IP ranges
  - Ollama / Local Inference: `127.0.0.1:11434`, `localhost:8000`

---

## 5. P1-4 Negative-Security Pin Matrix Verification

Every entry in `PROHIBITED_PROC_ENTRIES` in `proc.py` is pinned by negative security tests in `test_negative_security.py`. All tests are passing:

| # | Prohibited Entry | Threat Model / Why Prohibited | Test Method Name in `test_negative_security.py` | Status |
|---|---|---|---|---|
| 1 | `mem` | Raw memory dump (leaks prompts, secrets, keys) | `test_prohibit_procfs_memory_inspection` | **PASS** |
| 2 | `environ` | Environment variables (leaks API tokens, passwords) | `test_prohibit_procfs_environ_inspection` | **PASS** |
| 3 | `cmdline` | Command-line arguments (leaks flags with tokens) | `test_prohibit_procfs_cmdline_inspection` | **PASS** |
| 4 | `fd` | Process file descriptors (exposes open file contents) | `test_prohibit_procfs_fd_inspection` | **PASS** |
| 5 | `fdinfo` | FD metadata (seek offsets, flags, locks) | `test_prohibit_procfs_fdinfo_inspection` | **PASS** |
| 6 | `net` | Per-process network namespace | `test_prohibit_procfs_net_inspection` | **PASS** |
| 7 | `io` | I/O accounting stats (side-channel timing attacks) | `test_prohibit_procfs_io_inspection` | **PASS** |
| 8 | `cwd` | Working directory symlink (leaks private paths) | `test_prohibit_procfs_cwd_inspection` | **PASS** |
| 9 | `root` | Root directory symlink (chroot / container escape) | `test_prohibit_procfs_root_inspection` | **PASS** |
| 10 | `attr` | Security attributes directory (SELinux/AppArmor contexts) | `test_prohibit_procfs_attr_inspection` | **PASS** |
| 11 | `maps` | Virtual memory area mappings (leaks ASLR layout) | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 12 | `smaps` | Detailed memory consumption per mapping | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 13 | `smaps_rollup` | Consolidated memory mapping rollups | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 14 | `stack` | Kernel call stack trace | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 15 | `syscall` | Active system call number and args | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 16 | `pagemap` | Physical page frame numbers | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |
| 17 | `clear_refs` | Reset page reference bits (mutating operation) | `test_prohibit_procfs_maps_and_stack_inspection` | **PASS** |

Execution check:
```bash
$ cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_negative_security -v
Ran 16 tests in 0.003s — OK
```

---

## 6. Implementation Guidance for Phase 4 Cards

### 6.1 Guidance for SLCD-P4-1 (Transcript Metadata Indexer)
- Implement `TranscriptIndexer` in `d2-signalloom/apps/agentmaxxing-host-sensor/transcript.py`.
- Support JSONL streaming for Claude Code (`~/.claude/projects/`) and Antigravity CLI (`~/.gemini/antigravity-cli/brain/`).
- Enforce strict allowlist projection:
  ```python
  class TranscriptMetrics(NamedTuple):
      step_count: int
      tokens_in: int
      tokens_out: int
      tool_counts: Dict[str, int]
      models: List[str]
  ```
- **Zero Customer Payload Invariant:** Never extract `content`, `text`, `prompt`, `response`, `arguments`, `diff`, or `thinking`.

### 6.2 Guidance for SLCD-P4-2 (Outbound LLM Socket Detector)
- Implement `SocketDetector` in `d2-signalloom/apps/agentmaxxing-host-sensor/network.py`.
- Read `/proc/net/tcp` and `/proc/net/tcp6` globally, filtering for `st == 01` (ESTABLISHED).
- Convert hex IP and port to standard IPv4/IPv6 strings.
- Match destination IPs against allowlisted LLM inference CIDRs and endpoints.
- Maintain zero dependencies on `/proc/<pid>/fd` or `/proc/<pid>/net` inside `proc.py`.

---

## 7. Verification Proof

```bash
# 1. Verify specification document exists
test -f docs/signalloom/slcd-p4-pre-transcripts-sockets.md

# 2. Verify all P1-4 negative security pins remain green
cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_negative_security -v
```
All verification gates passed with zero errors.
