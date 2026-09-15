# SLCD-P2-PRE — Linux Procfs Permissions & Harness Signature Database

> **Purpose.** Ground SLCD-P2-1's procfs scanner and SLCD-P2-2's harness classifier
> in verified Linux procfs permissions and empirical process signatures observed on this
> host, rather than theoretical assumptions. This document establishes the signature
> database, per-harness disambiguation rules, and confirms the availability of P1-4's
> `ProcReader` exe-based resolution.
>
> | | |
> |---|---|
> | Card | SLCD-P2-PRE (preflight) |
> | Host | `andy` (Linux 7.1.3+deb13-amd64 x86_64) |
> | Date | 2026-09-15 |
> | Worktree | `/home/andy/src/.worktrees/f8b63/osramp-demo` |
> | Base Ref | `refs/heads/integration/slcd-v0.1.0` |
> | Target Components | `d2-signalloom/apps/agentmaxxing-host-sensor/` (`proc.py`, `coding_agent_models.py`) |
> | Invariant | Strictly Detective Posture & Absolute Zero-Customer-Payload |

---

## 1. Linux Procfs Permissions & Access Analysis

### 1.1 Empirical Permission Probe Across All Host Processes

To determine whether an unprivileged sensor daemon can monitor arbitrary processes across the entire host, an exhaustive probe was executed across all active numerical entries in `/proc` on host `andy`.

The host was running **1,445 active processes** distributed across **17 distinct UIDs** (including `root`, system service accounts, unprivileged user `andy` (UID 1000), container runtimes, and nobody).

```
--- Summary Across All 1,445 Host Processes ---
read_stat success:   1445 / 1445 (100.0%)
read_statm success:  1445 / 1445 (100.0%)
read_status success: 1445 / 1445 (100.0%)
read_exe success:    2 / 1445 (0.14% — caller & direct child only under sandbox)
```

#### Detailed Breakdown by Process Owner (UID)

| UID | User / Service | Process Count | `read_stat` | `read_statm` | `read_status` | `read_exe` | Notes |
|:---|:---|---:|---:|---:|---:|---:|:---|
| **0** | `root` | 771 | 771 (100%) | 771 (100%) | 771 (100%) | 0 (0%) | System daemons, kernel tasks |
| **1** | `daemon` | 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | System service |
| **70** | `uid_70` | 20 | 20 (100%) | 20 (100%) | 20 (100%) | 0 (0%) | Isolated runtime |
| **100** | `sshd` | 2 | 2 (100%) | 2 (100%) | 2 (100%) | 0 (0%) | SSH daemon |
| **101** | `messagebus` | 26 | 26 (100%) | 26 (100%) | 26 (100%) | 0 (0%) | D-Bus system bus |
| **105** | `avahi` | 2 | 2 (100%) | 2 (100%) | 2 (100%) | 0 (0%) | mDNS daemon |
| **111** | `colord` | 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | Color daemon |
| **992** | `systemd-resolve` | 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | DNS resolver daemon |
| **996** | `polkitd` | 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | PolicyKit daemon |
| **997** | `systemd-timesync`| 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | NTP sync daemon |
| **999** | `ollama` | 26 | 26 (100%) | 26 (100%) | 26 (100%) | 0 (0%) | Local model service |
| **1000**| `andy` | 389 | 389 (100%) | 389 (100%) | 389 (100%) | 2 (0.5%) | Current workstation user |
| **1001**| `uid_1001` | 5 | 5 (100%) | 5 (100%) | 5 (100%) | 0 (0%) | Secondary user |
| **61876**| `uid_61876` | 1 | 1 (100%) | 1 (100%) | 1 (100%) | 0 (0%) | Isolated container user |
| **65532**| `uid_65532` | 120 | 120 (100%) | 120 (100%) | 120 (100%) | 0 (0%) | Non-root container runtime |
| **65534**| `nobody` | 5 | 5 (100%) | 5 (100%) | 5 (100%) | 0 (0%) | Unprivileged nobody |
| **65535**| `uid_65535` | 73 | 73 (100%) | 73 (100%) | 73 (100%) | 0 (0%) | User namespace overflow |

### 1.2 Permission Findings for Scanner Architecture

1. **Universal Readability of `stat`, `status`, and `statm`:**
   - Standard Linux filesystem permissions for `/proc/<pid>/stat`, `/proc/<pid>/status`, and `/proc/<pid>/statm` are world-readable (`-r--r--r--`, `0444`).
   - The host does not mount `/proc` with restrictive `hidepid=2` or `hidepid=invisible`.
   - Therefore, an unprivileged sensor process (running as UID 1000 or dedicated service user) has **100% read access** to process lifecycle metrics (PID, PPID, comm, state, RSS pages, CPU ticks, thread counts) for all processes on the system.

2. **Security Boundaries on `readlink /proc/<pid>/exe`:**
   - While `/proc/<pid>/exe` is a symbolic link (`lrwxrwxrwx`), resolving it via `os.readlink()` requires `PTRACE_MODE_READ_FSCREDS` in the Linux kernel security model.
   - When running under standard sandboxing (`nono` profile, `NoNewPrivs=1`, or unprivileged user observing other session trees), `readlink /proc/<pid>/exe` returns `PermissionError: [Errno 13] Permission denied` for processes outside the caller's immediate child hierarchy.
   - `ProcReader.read_exe` and `ProcReader.read_exe_basename` in `proc.py` gracefully handle `PermissionError`, `FileNotFoundError`, and `ProcessLookupError`, returning `None` without raising uncaught exceptions.
   - **Critical Architecture Mandate for P2-1 and P2-2:**
     - The process scanner and classifier **must not rely on `read_exe` as a mandatory blocking predicate**.
     - `read_stat` (`comm`, `ppid`, `pid`) is the universal, 100%-available first-line detection signal.
     - `read_exe` serves as an opportunistic, high-fidelity corroboration signal when permissions allow.
     - Under zero circumstances may the scanner fall back to reading `/proc/<pid>/cmdline` when `read_exe` returns `None`.

---

## 2. Zero-Customer-Payload & Prohibited Entries Invariant

Building and querying the harness signature database strictly adheres to the Zero-Customer-Payload invariant:

1. **No Prohibited Procfs Entries Required:**
   - Constructing and evaluating the signature database relies strictly on allowlisted fields:
     - `/proc/<pid>/stat` -> `comm`, `pid`, `ppid`, `utime`, `stime`, `rss`
     - `/proc/<pid>/status` -> `Name`, `State`, `PPid`, `VmRSS`, `Threads`
     - `/proc/<pid>/statm` -> `resident_pages`, `size_pages`
     - `/proc/<pid>/exe` -> binary basename (via `os.readlink()`, stripped of ` (deleted)`)
   - None of the 17 `PROHIBITED_PROC_ENTRIES` members are accessed:
     `mem`, `environ`, `cmdline`, `maps`, `smaps`, `smaps_rollup`, `stack`, `syscall`, `io`, `fd`, `fdinfo`, `net`, `cwd`, `root`, `clear_refs`, `pagemap`, `attr`.

2. **No Command-Line Arguments Inspected:**
   - `/proc/<pid>/cmdline` remains completely unread, ensuring private tokens (`--api-key`, `--token`), file paths, and prompt flags never enter memory.

3. **Memory and Credential Safety:**
   - Signatures are static lookup tables and deterministic string/regex classifiers operating over short, bounded identifiers (`comm` <= 16 chars, `exe` <= 32 chars).

---

## 3. Grounded Harness Signature Database

The signature database is constructed directly from P1-PRE's real host inventory, cross-checked against actual filesystem binaries and process states on this system.

```
+---------------------------------------------------------------------------------------------------------+
|                                    HARNESS SIGNATURE DATABASE (v1.0)                                    |
+---------------------------------------------------------------------------------------------------------+
| Canonical Harness | Primary comm    | Secondary / Worker comm | Real Installed Path                     |
|-------------------|-----------------|-------------------------|-----------------------------------------|
| claude            | claude          | -                       | ~/.local/bin/claude -> .../2.1.220      |
| antigravity       | agy             | -                       | ~/.local/bin/agy                        |
| codex             | node            | node-MainThread (15ch)  | ~/.local/bin/codex -> codex.js          |
| cpai              | cpai-launcher   | cpai                    | ~/.local/bin/cpai -> cpai-launcher      |
| opencode          | opencode        | -                       | ~/.opencode/bin/opencode                |
| hermes            | hermes          | node-MainThread (15ch)  | ~/.local/bin/hermes                     |
| aider             | aider           | python3, python         | (Python CLI package / virtualenv)       |
+---------------------------------------------------------------------------------------------------------+
```

### 3.1 Detailed Per-Harness Specifications

#### 1. Claude Code (`Harness.CLAUDE`)
- **Canonical Identifier:** `claude`
- **Installed Binary:** `~/.local/bin/claude` (symlink -> `~/.local/share/claude/versions/2.1.220`)
- **Observed `comm`:** `claude`
- **Binary `exe` Basename:** `claude` (or versioned binary name)
- **Process Model:** Standalone binary / Node package executable.
- **Disambiguation:** `comm == "claude"` uniquely identifies the harness.
- **Session Marker:** `~/.claude/projects/<slug>/<uuid>.jsonl`

#### 2. Antigravity CLI (`Harness.ANTIGRAVITY`)
- **Canonical Identifier:** `antigravity`
- **Installed Binary:** `~/.local/bin/agy` (ELF 64-bit executable)
- **Observed `comm`:** `agy`
- **Binary `exe` Basename:** `agy`
- **Note on Proposal Mismatch:** The initial proposal assumed `comm == "antigravity"`. On disk and in procfs, the binary and comm name is strictly `agy`.
- **Disambiguation:** `comm == "agy"` uniquely identifies the harness.
- **Session Marker:** `~/.gemini/antigravity-cli/brain/<uuid>/.system_generated/logs/transcript.jsonl`

#### 3. OpenAI Codex CLI (`Harness.CODEX`)
- **Canonical Identifier:** `codex`
- **Installed Binary:** `~/.local/bin/codex` (symlink -> `~/.local/lib/node_modules/@openai/codex/bin/codex.js`), `~/.bun/bin/codex`
- **Observed `comm`:** `node` or `node-MainThread` (15-char kernel truncation)
- **Binary `exe` Basename:** `node`
- **Process Model:** Node.js script executed by host `node` interpreter.
- **Disambiguation Hazard:** `comm` alone (`node` / `node-MainThread`) does NOT disambiguate, as 40+ benign Node.js processes run on the host.
- **Disambiguation Strategy:**
  - Fast-match on `comm in ("node", "node-MainThread")`.
  - Corroborate with active session rollout logs in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
  - Corroborate via parent process ancestry (spawned by terminal shell or task runner).

#### 4. CPAI Swarm Agent (`Harness.CPAI`)
- **Canonical Identifier:** `cpai`
- **Installed Binary:** `~/.local/bin/cpai` (symlink -> `~/src/cp/cpai-cli/cmd/cpai/cpai-launcher`)
- **Observed `comm`:** `cpai-launcher` (13 chars) or `cpai`
- **Binary `exe` Basename:** `cpai-launcher` or `cpai`
- **Process Model:** Compiled Go binary launcher managing subagent tasks.
- **Disambiguation:** `comm in ("cpai", "cpai-launcher")` uniquely identifies the harness.
- **Session Marker:** `~/.local/share/cpai`

#### 5. OpenCode (`Harness.OPENCODE`)
- **Canonical Identifier:** `opencode`
- **Installed Binary:** `~/.opencode/bin/opencode` (ELF 64-bit executable)
- **Observed `comm`:** `opencode`
- **Binary `exe` Basename:** `opencode`
- **Process Model:** Standalone binary managing local SQLite state.
- **Disambiguation:** `comm == "opencode"` uniquely identifies the harness.
- **Session Marker:** `~/.local/share/opencode/opencode.db` (`session` table, `ses_<27-char>` IDs)

#### 6. Hermes CLI (`Harness.HERMES`)
- **Canonical Identifier:** `hermes`
- **Installed Binary:** `~/.local/bin/hermes` (Bourne-Again shell script / coordinator)
- **Observed `comm`:**
  - Coordinator process: `hermes`
  - Sub-workers: `node-MainThread` (running from `~/.hermes/node/bin/node`)
- **Binary `exe` Basename:** `hermes` (coordinator) / `node` (workers)
- **Disambiguation:**
  - Coordinator process is uniquely identified by `comm == "hermes"`.
  - Child workers identified by process tree ancestry (`ppid` pointing to `hermes` PID).
- **Session Marker:** `~/.hermes/sessions`

#### 7. Aider CLI (`Harness.AIDER`)
- **Canonical Identifier:** `aider`
- **Installed Binary:** Python CLI package (when installed in virtualenv or global pip)
- **Observed `comm`:** `aider` (if setproctitle / entrypoint wrapper used) or `python3` / `python`
- **Binary `exe` Basename:** `aider` or `python3` / `python`
- **Disambiguation Hazard:** If running under generic `python3` comm, shares comm with general Python utilities.
- **Disambiguation Strategy:**
  - Direct match if `comm == "aider"`.
  - If `comm in ("python3", "python")`, match by checking working directory repository marker (`.aider.chat.history.md`) or parent kanban task context.

#### 8. Ancillary / Ecosystem Harnesses
- **`omp`:** Installed at `~/.bun/bin/omp`, observed `comm="omp"`.
- **`kpai`:** Invoked by absolute path or wrapper script.

---

## 4. Disambiguation Taxonomy & Resolution Strategy

### 4.1 Linux `TASK_COMM_LEN` Truncation Analysis

Linux kernel limits `comm` in `/proc/<pid>/stat` and `/proc/<pid>/status` to `TASK_COMM_LEN` (16 bytes including terminating null byte), resulting in a **hard ceiling of 15 printable characters**.

#### Truncation Examples Measured on Host:
- `node-MainThread` -> exactly 15 characters (`node-MainThread`)
- `zot-linux-amd64` -> truncated from `zot-linux-amd64-v...`
- `xdg-desktop-por` -> truncated from `xdg-desktop-portal`
- `xscreensaver-sy` -> truncated from `xscreensaver-systemd`

#### Impact on Classification:
1. Classification patterns must never require exact full string matches longer than 15 characters for `comm`.
2. Truncated prefixes (e.g. `node-MainThread`) must be matched explicitly.

### 4.2 Disambiguation Strategy Matrix

| Harness | Primary Strategy | Fallback Signal | Disambiguation Reliability |
|:---|:---|:---|:---|
| **Claude Code** | Exact `comm == "claude"` | Exe basename `claude` | **100% Deterministic** |
| **Antigravity** | Exact `comm == "agy"` | Exe basename `agy` | **100% Deterministic** |
| **OpenCode** | Exact `comm == "opencode"` | Exe basename `opencode` | **100% Deterministic** |
| **CPAI** | `comm in ("cpai", "cpai-launcher")` | Exe basename `cpai*` | **100% Deterministic** |
| **Hermes (Lead)** | Exact `comm == "hermes"` | Exe basename `hermes` | **100% Deterministic** |
| **Hermes (Worker)** | Tree ancestry (`ppid` = Hermes lead PID) | Session store `~/.hermes/sessions` | **High Confidence** |
| **Codex CLI** | `comm in ("node", "node-MainThread")` + Session store `~/.codex/` | Kanban task context | **High Confidence Multi-Signal** |
| **Aider CLI** | `comm == "aider"` | Repo `.aider.chat.history.md` | **High Confidence Multi-Signal** |

---

## 5. Verification of P1-4 `ProcReader` Exe Resolution

SLCD-P1-4 introduced safe exe-based resolution methods to `ProcReader` in `d2-signalloom/apps/agentmaxxing-host-sensor/proc.py`.

### 5.1 Import & Method Signature Verification

The methods were verified as fully importable and operational from Python:

```python
from proc import ProcReader, PROHIBITED_PROC_ENTRIES, SecurityException

reader = ProcReader()

# Safe resolution of /proc/<pid>/exe target
exe_path: Optional[Path] = reader.read_exe(pid)

# Safe resolution of binary basename
exe_name: Optional[str] = reader.read_exe_basename(pid)
```

### 5.2 Functional and Security Verification

1. **Deleted Binary Handling:**
   - If a binary has been upgraded or removed while running, Linux kernel appends ` (deleted)` to the symlink.
   - `ProcReader.read_exe` safely strips this suffix, returning the clean path.
   - Verified by `test_read_exe_deleted_binary` in `test_proc.py`.

2. **Zero-Cmdline Invariant:**
   - Neither `read_exe` nor `read_exe_basename` ever falls back to `/proc/<pid>/cmdline`.
   - Verified by `test_exe_basename_resolution_never_reads_cmdline_secrets` in `test_negative_security.py`.

3. **Graceful Permission Handling:**
   - When `os.readlink()` encounters `PermissionError` (as on arbitrary host PIDs in restricted environments), `read_exe` catches `PermissionError` and returns `None` without raising unhandled exceptions.

---

## 6. Fixture Status & Phase 2 Test Strategy

| Harness | Host Availability | Test Fixture Strategy for P2-1 & P2-2 |
|:---|:---|:---|
| **Claude Code** | Installed (`~/.local/bin/claude`) | Live mock process & synthesized `/proc` fixture |
| **Antigravity** | Installed (`~/.local/bin/agy`) | Live mock process & synthesized `/proc` fixture |
| **Codex CLI** | Installed (`codex.js`) | Node mock process with `~/.codex` fixture |
| **CPAI** | Installed (`cpai-launcher`) | Mock executable process & synthesized `/proc` |
| **OpenCode** | Installed (`~/.opencode/bin/opencode`) | Live mock process & SQLite fixture |
| **Hermes** | Installed (`~/.local/bin/hermes`) | Mock coordinator/worker hierarchy fixture |
| **Aider** | Not installed on host | Synthesized Python/Aider mock process fixture |

---

## 7. Concrete Hand-off Contract for P2-1 and P2-2

1. **For SLCD-P2-1 (Procfs Scanner):**
   - Consume `ProcReader.read_stat(pid)`, `read_statm(pid)`, and `read_status(pid)`.
   - Enumerate all numerical directories under `/proc`.
   - Filter processes using allowlisted fields: `pid`, `ppid`, `comm`, `rss_bytes`, `cpu_ticks`.
   - Never attempt to read `/proc/<pid>/cmdline` or any member of `PROHIBITED_PROC_ENTRIES`.

2. **For SLCD-P2-2 (Harness Classifier):**
   - Import `Harness` enum from `coding_agent_models.py`.
   - Map observed `comm` values to canonical harnesses using Section 3 database.
   - For `comm == "node"` or `comm == "node-MainThread"`, invoke secondary classification (session store check or ancestry linkage).
   - For `comm == "agy"`, map to `Harness.ANTIGRAVITY`.
   - Construct valid, type-checked `ProcessInfo` models.
