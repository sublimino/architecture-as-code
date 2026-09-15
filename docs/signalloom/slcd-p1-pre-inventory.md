# SLCD-P1-PRE — Harness, Transcript and Kanban-Wrapper Inventory

> **Purpose.** Ground SLCD-P1-1's telemetry schema in what this host actually
> exposes, rather than in the proposal's example envelope. `detective.py`,
> `telemetry_handler.go` and `CodingAgentsTab.tsx` do not exist in the tree
> (verified below), so **every field name in the proposal's Shared Patterns JSON
> envelope is a proposed name, not an observed one.** P1-1 must cite this
> document, not that envelope, as prior art.
>
> | | |
> |---|---|
> | Card | SLCD-P1-PRE (preflight) |
> | Observed on | 2026-09-15, host `andy` (Linux 7.1.3+deb13-amd64) |
> | Worktree HEAD | `53f1559835c5875af190ed4f7b289bdd20b5b273` |
> | Integration ref | `refs/heads/integration/slcd-v0.1.0` @ `10b7bf8db0c6d1806b455bda48da3ba9e47e0fcf` |
> | Collection posture | Read-only. No process was signalled, attached to, or configured. |

**Method note.** Every claim below was produced by a probe run this session and
is cited to a path, a `file:line`, or a reproducible command. Where a probe could
not see something, this document says **DENIED** rather than "absent" — under the
`nono` sandbox a denied read returns byte-for-byte what an empty one returns, and
conflating the two is how a sensor comes to report zero sessions for a harness
that is running. Field *names* only were extracted from transcripts; no field
*values* were read into the analysis context, in keeping with the
Zero-Customer-Payload invariant.

---

## 0. Target-component baseline

| Path in proposal § Canonical locations | State |
|---|---|
| `d2-signalloom/apps/agentmaxxing-host-sensor/detective.py` | **ABSENT** |
| `d2-signalloom/apps/signal-ingest/telemetry_handler.go` | **ABSENT** |
| `d2-signalloom/apps/dashboard-signalloom/src/components/CodingAgentsTab.tsx` | **ABSENT** |
| `d2-signalloom/test/coding-agent-telemetry.bats` | **ABSENT** |

All four are to be created by later P1 cards. The pre-mission export surface this
mission extends is therefore entirely in `filter.py` and `proc.py`:

- **`filter.py:34-40`** — `ALLOWLISTED_PROCESS_ATTRIBUTES` = `health_state`,
  `cpu_time_ms`, `resident_memory_bytes`, `exit_code`, `restart_count`.
- **`filter.py:43-48`** — `EXTENDED_PROCESS_ATTRIBUTES` adds `cpu_percent`,
  `pid`, `ppid`.
- **`filter.py:51-65`** — `ALLOWLISTED_ENVELOPE_FIELDS` (16 keys:
  `schema_version`, `session_id`, `sequence`, `observed_at`, `source`,
  `evidence_type`, `observation_state`, `integrity_state`, `agent_id`,
  `actor_id`, `host_id`, `attributes`, `tenant_id`).
- **`filter.py:68-105`** — `PROHIBITED_EXPORT_KEYS`, 38 keys, applied by
  `AllowlistFilter.contains_prohibited_data` (`filter.py:201-219`) recursively.
- **`filter.py:222-230`** — `filter_attributes` selects `EXTENDED_…` or
  `ALLOWLISTED_…` and **drops** unlisted keys. This is the allow-list, and it is
  the load-bearing control.

**Confirmed:** every field in `ALLOWLISTED_PROCESS_ATTRIBUTES` is a bounded
integer except `health_state`, which is a closed `HealthState` enum. There are
zero free-text fields on this path. This mission converts that into a
string-carrying surface, which is the core risk and the reason for §5.

**`proc.py` is a genuine pre-`open()` chokepoint.**
`PROHIBITED_PROC_ENTRIES` (`proc.py:14-32`, 18 entries) is consulted by
`_safe_proc_path` (`proc.py:103-110`), which **raises `SecurityException` before
constructing the path**, so no `open()` is ever reached. Confirmed by reading the
call order: every reader (`read_stat:132`, `read_statm:210`, `read_status:238`)
obtains its path from `_safe_proc_path` first.

---

## 1. Process-tree inventory (observed, not documented)

Method: walked `/proc/<pid>/stat` and `/proc/<pid>/status` directly. `pgrep` was
deliberately not used — the Bash tool wraps each call in `bash -c`, so the
pattern appears in the probing shell's own `cmdline` and matches itself.

### 1.1 What each named harness actually looks like

| Proposal `harness` value | Installed binary | Real `comm` observed | Live count | Note |
|---|---|---|---|---|
| `claude` | `~/.local/bin/claude` → `~/.local/share/claude/versions/2.1.220` | **`claude`** | 1 | comm matches |
| `antigravity` | `~/.local/bin/agy` | **`agy`** | 13 | **`antigravity` is not a binary on this host at all** |
| `codex` | `~/.local/bin/codex` → `~/.local/lib/node_modules/@openai/codex/bin/codex.js` | **not `codex`** — a Node script, so `node` / `node-MainThread` | 0 live | see §1.2 |
| `cpai` | `~/.local/bin/cpai` → `~/src/cp/cpai-cli/cmd/cpai/cpai-launcher` | none live | 0 | Go launcher |
| `opencode` | `~/.opencode/bin/opencode` | **`opencode`** | 3 | comm matches |
| `hermes` | `~/.local/bin/hermes` | **`hermes`** | 1 | comm matches |
| `aider` | **not installed** | — | 0 | see §4 |

Also present and relevant: `omp` → `~/.bun/bin/omp`, and `node-MainThread` × 42,
of which at least 4 resolve to `~/.hermes/node/bin/node`.

`kpai` is referenced by the kanban launcher but is **not on `PATH`**
(`command -v kpai` → not found); it is invoked by absolute path or via a wrapper.

### 1.2 Finding P1-PRE-F1 — `comm` is a 15-byte truncated field and is not a harness discriminator

Measured across **934 userspace processes**: maximum `comm` length is exactly
**15** characters (`TASK_COMM_LEN - 1`). Observed truncations on this host include
`zot-linux-amd64`, `xdg-desktop-por`, `xscreensaver-sy`. Kernel threads are
stored by a different path and do exceed it (max 37, e.g.
`kworker/R-amdgpu_dm_hpd_rx_offload_wq`), so a naive length check on a mixed
sample will conclude wrongly that there is no ceiling.

Two consequences for P1-1:

1. **`node-MainThread` is itself exactly 15 characters** and is what Node-based
   harnesses present. `codex` is `codex.js` under Node, so a detective keying on
   `comm == "codex"` finds **zero** Codex sessions while Codex is running. The
   same hazard applies to any harness shipped as a Node entry-point.
2. A harness whose name exceeds 15 bytes is silently truncated, so `comm` can
   never be compared for equality against a long name.

**Recommendation.** `process.comm` may be *recorded* (it is bounded and
non-sensitive) but must not be the *attribution key*. See F2 for why the obvious
alternative is also unavailable.

### 1.3 Finding P1-PRE-F2 — `/proc/<pid>/exe` is denied under the sandbox, and `cmdline` is prohibited by design

The proposal's § Procfs Bounded Extraction permits "reading
`/proc/<pid>/cmdline` … for bounded binary basename resolution". Two independent
obstacles:

- **`cmdline` is in `PROHIBITED_PROC_ENTRIES` (`proc.py:17`)** and
  `_safe_proc_path` raises before opening it. Removing that entry is a **declared
  hard blocker** for this mission, so this route is closed, not merely
  discouraged.
- **`readlink /proc/<pid>/exe` fails for every process except the caller's own**
  under the active `nono` profile (`NONO_CAP_FILE=/tmp/.nono-fd7ae022…json`
  present; `NoNewPrivs=1`). Disambiguated deliberately: `readlink /proc/self/exe`
  → `/usr/bin/bash` (**succeeds**), while the same call against 60+ other PIDs
  returns a denial. This is a **sandbox-profile fact, not a host fact** — an
  unsandboxed sensor would resolve these.

**Recommendation.** P1-1 must state which of the two it depends on and test in
the matching context. If the sensor is to run confined, attribution cannot come
from `exe` and must not come from `cmdline`; the remaining lawful signals are
`comm` (weak, per F1), the cgroup path already resolved by
`collector.py:128-130`, and the session-log path itself (§2), which names the
harness by directory. **The session-log path is the strongest available
attribution key and costs nothing extra to collect.**

### 1.4 Finding P1-PRE-F3 — `/proc/<pid>/fd` and `/proc/net` are prohibited, so § Socket Inode Attribution is not implementable as written

The proposal's § Socket Inode Attribution requires "matching local socket inodes
from `/proc/net/tcp` to process file descriptors under `/proc/<pid>/fd/`".

Both are blocked: **`fd` (`proc.py:24`) and `net` (`proc.py:26`) are members of
`PROHIBITED_PROC_ENTRIES`.** Enabling that pattern requires removing an entry
from that set, which the card lists as a hard blocker.

**This is a design-level conflict between two sections of the proposal, not an
implementation detail, and it is the single item most likely to derail P1-1.** It
cannot be resolved inside P1-1's scope. Escalated to the phase Governor in the
errata block; the `network.{inference_endpoint,egress_bytes}` fields of the
proposed envelope have no lawful source on this host until it is resolved.

---

## 2. Transcript-format inventory (real field names)

Existence probe of every candidate root:

| Harness | Path | State |
|---|---|---|
| Claude Code | `~/.claude/projects/<slug>/<uuid>.jsonl` | **DIR**, 3,921 transcripts |
| Antigravity CLI | `~/.gemini/antigravity-cli/brain/` | **DIR**, 500 session dirs |
| Antigravity IDE | `~/.gemini/antigravity/conversations/<uuid>.db` | **DIR**, SQLite + `.pbtxt` |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | **DIR**, 1,871 files |
| OpenCode | `~/.local/share/opencode/` (`opencode.db` + `storage/`) | **DIR** |
| CPAI | `~/.local/share/cpai` | **EXISTS but DENIED** |
| Hermes | `~/.hermes`, `~/.hermes/sessions` | **EXISTS but DENIED** |
| Aider | `~/.aider`, `~/.aider.input.history` | **ABSENT** (not installed) |

> **Trap recorded for P3-1.** For both CPAI and Hermes, `test -r` returns **YES**
> while `ls` returns `Permission denied`. `access(2)` and the subsequent `open`
> disagree under this sandbox, so **`test -r` is not a usable readability gate** —
> only an attempted read is. A watcher that gates on `test -r` will conclude the
> directory is readable and then silently collect nothing.

### 2.1 Claude Code — `~/.claude/projects/<slug>/<uuid>.jsonl`

36 top-level keys observed over 400 sampled records:
`aiTitle, attachment, attributionMcpServer, attributionMcpTool, attributionSkill,
backup, cwd, effort, entrypoint, gitBranch, isMeta, isSidechain,
isSnapshotUpdate, lastPrompt, leafUuid, message, messageId, mode, parentUuid,
permissionMode, promptId, promptSource, requestId, sessionId, session_id,
snapshot, snapshotMessageId, sourceToolAssistantUUID, sourceToolUseID, timestamp,
toolUseResult, trackingPath, type, userType, uuid, version`

`type` values: `ai-title, assistant, attachment, file-history-delta,
file-history-snapshot, last-prompt, mode, permission-mode, user`.

Token accounting (the real names):
`message.usage.input_tokens`, `message.usage.output_tokens`,
`message.usage.cache_read_input_tokens`,
`message.usage.cache_creation_input_tokens`,
`message.usage.cache_creation.ephemeral_5m_input_tokens`,
`message.usage.cache_creation.ephemeral_1h_input_tokens`,
`message.usage.service_tier`, `message.model`, `attachment.durationMs`.

> **Note both `sessionId` and `session_id` occur in the same file.** A parser that
> reads only one spelling drops records. Which spelling appears depends on record
> `type`.

### 2.2 Codex CLI — `~/.codex/sessions/2026/09/15/rollout-<ISO>-<uuid>.jsonl`

Only **3** top-level keys: `payload`, `timestamp`, `type`. Everything is nested
under `payload`. `type` values: `event_msg, response_item, session_meta,
turn_context, world_state`.

Identity/metric keys: `payload.session_id`, `payload.turn_id`, `payload.model`,
`payload.model_provider`, `payload.model_context_window`, `payload.cli_version`,
`payload.cwd`, `payload.duration_ms`, `payload.timezone`,
`payload.multi_agent_version`, `payload.context_window.window_id`.

**No token-count fields exist.** What is present instead is commercial:
`payload.rate_limits.plan_type`, `payload.rate_limits.credits.balance`,
`payload.rate_limits.credits.has_credits`, `payload.rate_limits.credits.unlimited`,
`payload.rate_limits.spend_control_reached`, `payload.rate_limits.limit_name`.

> **Do not collect the `rate_limits` subtree.** `credits.balance` and `plan_type`
> are commercial-account attributes about an identifiable person; they are
> outside the stated purpose and would widen the lawful-basis assessment.

### 2.3 Antigravity CLI — the proposal's path is the right root but three levels too shallow

`~/.gemini/antigravity-cli/brain/` contains 500 UUID-named session dirs. Each has
this shape — **there are no files at depth 1**, which is where a parser pointed at
`brain/` would look:

```
brain/<session-uuid>/
├── .user_uploaded/
├── .system_generated/
│   ├── logs/transcript.jsonl          ← the transcript
│   ├── logs/transcript_full.jsonl     ← larger variant (12MB vs 15MB observed)
│   ├── messages/<uuid>.json
│   ├── messages/read.json
│   ├── steps/<N>/                     ← numeric step dirs
│   └── tasks/task-<N>.log
└── scratch/
```

`transcript.jsonl` has **9** top-level keys: `content, created_at, source, status,
step_index, thinking, tool_calls, truncated_fields, type`. `type` values:
`GENERIC, PLANNER_RESPONSE, SYSTEM_MESSAGE, USER_INPUT`.

- `step_index` is the **only** real source for the proposed `metrics.step_count`
  (corroborated by the numeric `steps/<N>/` dirs).
- `tool_calls[].name` is the **only** real source for `metrics.tool_counts`; it
  must be derived by counting, as no count field exists.
- **There are no token, usage, model, or session-id fields at all.** The session
  ID exists only as the directory name.

Extension histogram under `brain/` (depth 4): `6970 json, 5097 log, 998 jsonl,
235 png, 109 jpg, 57 md, 50 env, 33 ts, 23 py, 3 sh, 2 yaml, 2 js`.

### 2.4 OpenCode — SQLite, not JSONL

`~/.local/share/opencode/opencode.db` plus
`~/.local/share/opencode/storage/session_diff/ses_<id>.json`.

Tables: `__drizzle_migrations, account, account_state, control_account,
credential, data_migration, event, event_sequence, message, migration,
permission, part, project, project_directory, session, session_context_epoch,
session_input, session_message, session_share, sqlite_sequence, workspace, todo`.

Session-ID form observed: `ses_1ecf76f95ffebZU4fJSODKJjDP`. The proposal writes
`"session_id": "ses_uuid"`; the `ses_` prefix is right but the body is **not a
UUID** — it is a 27-character opaque identifier. A UUID-shaped validator will
reject every real OpenCode session ID.

`kanban-check.sh:1701-1713` already reads this DB read-only
(`OPENCODE_DB`, `file:$db?mode=ro`) joining `session`+`message`+`part` — an
existing, working precedent P1-1 should reuse rather than reinvent.

---

## 3. Kanban-wrapper lock-safety inventory

The card asks specifically which artefacts are safe to poll with a shared read
descriptor and which acquire a lock even on a read path. Answer, per artefact:

| Artefact | Lock behaviour | Safe for a watcher? |
|---|---|---|
| `Tools/kanban-check.sh` **read** subcommands | `sqlite3 -readonly -bail`, `file:$db?mode=ro` (`:367`, `:372`, `:976`, `:1022`, `:1142`, `:1423`, `:1707`) | **Yes** — read-only by construction |
| `Tools/kanban-check.sh` **mutation** path | `exec 9>"$MUTATION_LOCK_FILE"` then `flock -n 9` (`:913-917`); `mkdir` lock-dir fallback (`:921-926`); released by `trap … EXIT` (`:935`) | **No — do not invoke.** See F4 |
| `Tools/CycleInput.ts` | **No advisory lock anywhere.** Writes via `mkdirSync(…, mode 0o700)` → `writeFileSync(tmp, mode 0o600)` → `renameSync` (`:273-275`) | Read is safe; see F5 |
| `~/.cline/kanban/kanban.sqlite` (+`-wal`, `-shm`) | SQLite WAL, live (125 MB main, 1.3 MB WAL, both mtime-current) | **Yes with `mode=ro`** — see F6 |
| `~/.cline/kanban/board.json` (per workspace) | Plain file, read-only per `:306-309` | Yes |
| `~/.cline/kanban/supervisor-log.ndjson` | Append-only NDJSON | Yes |
| `~/.cline/kanban/kanban.db` | **0 bytes — dead file.** The live DB is `kanban.sqlite` | Ignore |
| `~/.codex/thread-writer-locks/.coordination.lock` | 0-byte coordination lock, Codex-owned | Never touch |
| `~/.cline/kanban/{ai-usage-cache.json, auto-controller/}` | mode `0600` / `0700` | Owner-only; a non-`andy` sensor gets EACCES |

No `*.lock` files exist anywhere under `~/.cline/kanban` — the only flock target
is in `/tmp`.

### 3.1 Finding P1-PRE-F4 — the kanban lock is mutation-only and non-blocking, but the lockfile is opened for **write**

The card's stated worry was that a wrapper "still takes an advisory `flock` on a
read path". It does **not**: the `flock` at `kanban-check.sh:914-917` sits inside
the mutation branch and uses `-n`, so it *defers* rather than blocks
(`DEFER: another scaffold or supervisor mutation holds …`). The concern is
therefore **not confirmed** in the form stated.

The real hazard is one line earlier. `exec 9>"$MUTATION_LOCK_FILE"` opens the
lockfile `O_WRONLY|O_CREAT|O_TRUNC` **before** `flock` is attempted. So invoking
`kanban-check.sh` on a mutation subcommand *creates and truncates* a lockfile as
a side effect. A detective must never invoke the wrapper at all; it must read the
underlying artefacts directly. (Confirmed live: 100+ such lockfiles from prior
sessions are resident in `/tmp`, one per canonical repo path, all 0 bytes.)

### 3.2 Finding P1-PRE-F5 — `CycleInput.ts` uses atomic rename, so a held descriptor goes stale silently

`CycleInput.ts` takes no lock, which makes it *look* trivially safe to poll. But
it writes by `renameSync` over the target (`:273-275`), which **replaces the
inode**. A watcher holding an open fd keeps reading the old, now-unlinked
content indefinitely, with no error and no short read. P3-1 must re-`open()` by
path each poll and compare `st_ino`, not hold a descriptor.

### 3.3 Finding P1-PRE-F6 — `immutable=1` is the wrong SQLite read mode for the live kanban DB

`kanban.sqlite` has an active WAL (`-wal` 1.3 MB, `-shm` 64 KB, both current).
Opening it with `immutable=1` tells SQLite the file cannot change and **the WAL is
not consulted**, yielding a stale or torn read with no error. The correct form is
the one the existing code already uses: `sqlite3 -readonly` with
`file:…?mode=ro`. (`immutable=1` *is* acceptable for a quiesced snapshot — it was
used safely against `opencode.db` during this inventory — but must not be
generalised.)

---

## 4. Harnesses with no live fixture here

Per the card's fifth deliverable, these cannot be inventoried from this host and
must be specified from their own upstream source before P4-1 writes a parser:

| Harness | Status | What P4-1 needs and where to get it |
|---|---|---|
| **Aider** | **Not installed.** `command -v aider` → not found; `~/.aider` and `~/.aider.input.history` both absent. Verified through a channel the sandbox cannot blank (`command -v` plus process-table walk), so this is a genuine absence, not a denied read. | Upstream `aider/history.py` and `aider/analytics.py`. Aider writes `.aider.chat.history.md` (Markdown, **not** JSONL) and `.aider.input.history` **into the working repo, not `$HOME`** — a per-project path, which is a different discovery shape from every other harness here. |
| **Hermes** | **Installed and running** (`~/.local/bin/hermes`, `comm=hermes`, 1 live process, plus 4 `node-MainThread` under `~/.hermes/node/bin/node`). Its store `~/.hermes/sessions` exists but every read is **DENIED** under this sandbox profile. | Re-run this inventory unconfined, or from a profile granting `~/.hermes`. **Do not record its schema as absent** — it exists and was merely unreadable here. |
| **CPAI** | Installed (`~/src/cp/cpai-cli/cmd/cpai/cpai-launcher`), no live process, `~/.local/share/cpai` **DENIED**. | Same remedy as Hermes; the `cpai-cli` source is local and readable. |

### 4.1 Finding P1-PRE-F7 — the card's premise about the swarm fixture does not hold

The card states that the `fe-signalloom-agents` swarm demo is "the only live
multi-harness fixture in this repository today" and asks for CPAI and OpenCode
process names to be cross-checked against it.

**That cross-check cannot be performed: `d2-signalloom/apps/fe-signalloom/src`
contains zero references to `cpai`, `opencode`, `antigravity`, `agy`, `codex`,
`hermes` or `aider`** (case-insensitive search returns no matching file). The
only harness literal in that tree is `"claude-code"`, plus the default
`"nono-0.73.0"`. It is a **single-harness** fixture. P1-1 must not expect
multi-harness test data to already exist; it has to be created.

### 4.2 Finding P1-PRE-F8 — a free-text `harness` field already reaches a persisted record, under a name P1-1 wants to reuse

`external_agent_registration.py:141`:

```python
harness: str = Field(default="nono-0.73.0", min_length=1, max_length=128)
```

This is a **128-character free-text string**, and it is persisted —
`INSERT INTO public.agent_claims (…, harness, model, …)` at
`external_agent_registration.py:672-687`.

This refines the card's baseline statement that "the widest field that can reach a
persisted record today is a bounded integer". That is exactly true of the
**host-sensor export path** (`filter.py`), which is the surface this mission
widens. It is **not** true of the estate: fe-signalloom already persists free
text, under the identifier `harness`, which is the same name the proposed
envelope uses for a closed enum of seven values. P1-1 must decide deliberately
whether its `harness` is the enum it describes or the free-text column that
already exists, because a collision between the two will not fail loudly.

**The good precedent to copy is on the line above it:**
`model_config = ConfigDict(extra="forbid")` (`:139`) — a Pydantic
structurally-enforced allow-list that *rejects* unknown keys rather than
filtering them. That is the shape the card's hard blocker demands.

---

## 5. The finding that most constrains P1-1

### 5.1 Finding P1-PRE-F9 — every transcript file is a payload-bearing artefact, and the prohibited-key list does not spell the keys they use

The Zero-Customer-Payload invariant is currently enforced on `/proc` reads, where
the raw material is numeric. **Transcripts are the opposite: prompt text, source
code, diffs, absolute paths and full shell command lines sit in the same records,
often the same objects, as the metrics P1-1 wants.**

Observed payload-bearing keys, by harness:

| Harness | Keys carrying customer payload |
|---|---|
| Claude Code | `lastPrompt`, `message.content[].text`, `toolUseResult.content`, `toolUseResult.file.content`, `toolUseResult.originalFile`, `toolUseResult.oldString`, `toolUseResult.newString`, `toolUseResult.structuredPatch[].lines`, `toolUseResult.stdout`, `toolUseResult.stderr`, `toolUseResult.filePath`, `cwd` |
| Antigravity | `content`, `thinking`, `tool_calls[].args.CommandLine`, `tool_calls[].args.ReplacementContent`, `tool_calls[].args.TargetContent`, `tool_calls[].args.AbsolutePath`, `tool_calls[].args.TargetFile`, `tool_calls[].args.Cwd`, `tool_calls[].args.Instruction` |
| Codex | `payload.content[].text`, `payload.base_instructions.text`, `payload.state.agents_md.text`, `payload.text_elements`, `payload.cwd` |
| OpenCode | tables `message`, `part`, `session_input` — **and a `credential` table in the same DB** |

Two specific consequences, both sharp:

1. **`tool_calls[].args.CommandLine` is the command line.** The prohibition on
   `/proc/<pid>/cmdline` (`proc.py:17`) exists to stop credentials leaking from
   process arguments. Antigravity's transcript contains that same data as a JSON
   string. **Reading the transcript therefore reaches around the `proc.py`
   chokepoint** and lands in a field whose name (`CommandLine`) is **not** in
   `PROHIBITED_EXPORT_KEYS` — that set spells `command_line` and `cmdline`
   (`filter.py:71,74`), not `CommandLine`. The deny-list would not catch it.
2. **The deny-list is spelled in `snake_case`; the transcripts are
   `camelCase` and `PascalCase`.** `newString`, `oldString`, `originalFile`,
   `structuredPatch`, `lastPrompt`, `ReplacementContent`, `TargetContent`,
   `AbsolutePath` — none of the 38 `PROHIBITED_EXPORT_KEYS` entries match any of
   them. `PROHIBITED_EXPORT_KEYS` is defence-in-depth and **must not be treated
   as the control here**; only `ALLOWLISTED_*` can be relied on, which is also
   what the card's hard blocker requires. This inventory found the concrete
   reason that blocker is right.

### 5.2 Finding P1-PRE-F10 — the Antigravity session tree contains credential and binary artefacts

Inside `~/.gemini/antigravity-cli/brain/`, by name only (no contents read):

- **50 `*.env` files**, named `<uuid>.env`
- **344 `.png`/`.jpg`** images (screenshots — file contents by another route)
- **61 `.ts`/`.py`/`.sh`/`.js`** source files

A sensor that walks `brain/` recursively to find transcripts will traverse all of
these. **Any credential-detection logic must work from the path, never by opening
the file to look for a secret** — the card's third hard blocker forbids recording
a credential value in order to detect it, and the safe reading is that `*.env`
must be excluded by glob before `open()`, in the same pre-`open()` style as
`proc.py:103-110`. Reject-by-extension, do not scan-and-redact.

---

## 6. Direct field-mapping table for P1-1

Proposed envelope field → observed source. **`NONE` means no source exists on
this host and the field cannot be populated without new instrumentation.**

| Proposed field | Claude Code | Antigravity | Codex | OpenCode |
|---|---|---|---|---|
| `harness` | derive from path | derive from path | derive from path | derive from path |
| `session_id` | `sessionId` **and** `session_id` | dir name only | `payload.session_id` | `ses_<27-char>` |
| `timestamp` | `timestamp` | `created_at` | `timestamp` | DB column |
| `process.pid`/`ppid` | `/proc` (`EXTENDED_…`) | same | same | same |
| `process.comm` | `/proc/<pid>/stat` — **15-byte truncated, F1** | same | same | same |
| `process.rss_bytes` | `resident_memory_bytes` | same | same | same |
| `process.cpu_ticks` | `cpu_time_ms` | same | same | same |
| `metrics.tokens_in` | `message.usage.input_tokens` | **NONE** | **NONE** | DB (unverified) |
| `metrics.tokens_out` | `message.usage.output_tokens` | **NONE** | **NONE** | DB (unverified) |
| `metrics.step_count` | **NONE** (derive by counting) | `step_index` | **NONE** | **NONE** |
| `metrics.tool_counts` | count `message.content[].tool_use_id` | count `tool_calls[].name` | **NONE** | count `part` rows |
| `network.inference_endpoint` | **BLOCKED — F3** | BLOCKED | BLOCKED | BLOCKED |
| `network.egress_bytes` | **BLOCKED — F3** | BLOCKED | BLOCKED | BLOCKED |
| `kanban.task_id` / `shortcode` / `role` | §3 artefacts, not transcripts | same | same | same |
| `kanban.elapsed_s` | `kanban.sqlite` (`kanban-check.sh:1419-1423`) | same | same | same |

**Three of the proposed envelope's field groups have no lawful source on this
host as written**: both `network.*` fields (F3), and `tokens_in`/`tokens_out` for
Antigravity and Codex. P1-1 must either drop them, mark them nullable-by-harness,
or escalate F3.

---

## 7. Baseline verification for this card

| Check | Result |
|---|---|
| `git status --porcelain` at start | clean, 0 lines |
| `HEAD` derives from integration branch | `git merge-base --is-ancestor HEAD refs/heads/integration/slcd-v0.1.0` → **rc=0** |
| `test -f docs/signalloom/slcd-p1-pre-inventory.md` | **pass** (this file) |
| `rg -n 'ALLOWLISTED_PROCESS_ATTRIBUTES' …/filter.py` | **pass** — `34`, `44`, `230` |
| `python3 -m unittest discover -p 'test_*.py'` | **pass** — Ran 41 tests, OK |
| `make test` | **pass** — exit 0; 8 ok / 0 not ok / 1 skip; `assert-bats-ran-something` confirmed the suite executed |
| `make demo-agentmaxxing-host-test` | **initially exit 2**; repaired (§7.1); now exit 0, 26 ok / 0 not ok / 0 skip |

### 7.1 Baseline repair applied

`make demo-agentmaxxing-host-test` failed at baseline — before any change by this
card — at `test/signalloom/file-validator-anti-escape.bats:88`
(`not ok 9 pytest suite for file validator …`). The wrapper's exit code was
initially masked: the recipe's own `EXIT=` line reported `2` while the enclosing
shell reported `0`, because the last command in the pipeline was `tail`.

Root cause: `pytest` was left to infer its `rootdir`, walked up past the worktree
and settled on `/home/andy`, then `os.scandir`'d it and hit
`PermissionError: [Errno 13] Permission denied: '/home/andy'` — `$HOME` is denied
under the `nono` profile. Result: `found no collectors`, `collected 0 items /
1 error`. The suite itself was never at fault; run directly it is **16 passed**.

Fix: pin `--rootdir` and `-o cache_dir` on that one invocation, matching the
`cache_dir` pinning the Makefile already applies to the fe-signalloom pytest
targets (`Makefile:855,861,862,869`). This is a test-harness environment repair
with no production-code change, and it makes the result deterministic in both
confined and unconfined contexts. Verified: that test now passes, the other 8 in
the file still pass, and the full target is green.

---

## 8. Escalations for the phase Governor

1. **F3 (blocking for the socket-attribution deliverable).** § Socket Inode
   Attribution requires `/proc/<pid>/fd` and `/proc/net/tcp`; both are in
   `PROHIBITED_PROC_ENTRIES`, and removing an entry is a declared hard blocker.
   Needs a decision above P1-1: drop the capability, or design an alternative
   that does not enumerate another process's descriptors.
2. **Lawful basis remains a gate, not paperwork.** No Legitimate Interest
   Assessment and no works-council position was found in the tree. Per the card's
   fifth hard blocker, workstation collection must not be enabled until both
   exist. This inventory is read-only host reconnaissance and does not enable
   collection, so it does not cross that line — but P1-1 onwards will.
3. **F8 naming collision.** `harness` already exists as a persisted 128-char free
   text column. Confirm which definition wins before the schema lands.
4. **F7.** The multi-harness fixture the card assumes does not exist; P1-1's
   estimate should account for building it.
5. **Base-ref direction.** The prescribed check
   `git merge-base --is-ancestor integration/slcd-v0.1.0 HEAD` returns rc=1 here,
   because the integration tip advanced by two commits (both unrelated **AMXD**
   proposal work) after this worktree was created. The reverse direction passes,
   proving derivation. Details in the errata block.
