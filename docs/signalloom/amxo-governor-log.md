# AMXO Shared Governor Log & Inter-Agent Coordination Ledger

**Mission Identity**: `AMXO` — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3)  
**Parent Proposal**: `docs/Proposal — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3).md`  
**Integration Branch**: `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Active Lease**: `ajm-auto-kanban-amxo-ee52cd034007`  
**Participating Autonomous Agents**:
- `opencode` (OpenCode GPT-5.6 Sol — primary task implementer in tmux `def:5.0`)
- `antigravity` (Google Antigravity Gemini 3.8 Flash — council reviewer & active coordinator in tmux `def:4.3`)
- `kpai` / `claude` (Anthropic Claude Code — council & doctrine reviewer)
- `cpai` / `codex` (OpenAI Codex / GPT — test & verification reviewer)

---

## 1. Operating Charter & Invariants

All participating autonomous agents operating on the `AMXO` mission adhere to the following invariants:

1. **SP-1 (Attributable OIDC Operator Identity & Soft Removal)**:
   - Individually attributable operator accounts keyed by verified OIDC issuer and subject (`iss` + `sub`).
   - Server-derived tenant scope; persisted admin/editor/viewer authorization roles.
   - Rejection of shared or anonymous identity headers.
   - Soft removal (`status = 'removed'`, `removed_at = NOW()`) with soft-delete preserves historical audit integrity.
   - Last-admin protection: concurrent removal requests fail-safe to guarantee at least one active tenant administrator remains.

2. **SP-2 (Closed Draft 2020-12 Host Policy & Privacy Boundary)**:
   - Frozen nono `0.73.0` profile (`agentmaxxing-linux-v1`), systemd unit `agentmaxxing-agent.service`.
   - Descriptor-relative resolution from pinned roots via `openat2()` with `RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`, and `RESOLVE_NO_XDEV`.
   - Inode, mount ID, link count, size, and timestamp pre/post comparison.
   - Strict export filtering before any persistence seam: zero export of commands, raw paths, raw errors, process memory, or network payloads.
   - SHA-256 candidate hashing capped at 16 MiB per file, 120 files / 64 MiB per 60s window.

3. **SP-3 (Early Delivery Tracking & Governor Reconciliation)**:
   - `AMXO-P1-1` delivered the end-to-end attributable operator lifecycle (FastAPI routes, migration 038, contract tests) early.
   - The reviewed proposal assigned decision freeze to P1-1 and implementation to P2-1.
   - Governor will reconcile this early delivery during Phase 1 closeout so `AMXO-P2-1` is credited without duplicate work or conflicting regressions.

4. **SP-4 (Dual-Persistence Review & Provenance Gate)**:
   - All card reviews require multi-agent council evaluation across implementation, tests, security, and integration.
   - Dual-persisted to `.kanban-review-ledger.json` and SQLite `task_run_reviews` / `task_runs`.
   - Explicit evaluating-model provenance recorded with every verdict.

5. **SP-5 (Dynamic Subscription Balancing & Rate Moderation)**:
   - Monitored via `~/.agents/bin/statusline-command.sh --usage`.
   - Active quotas as of 2026-09-13T10:15Z:
     - **Codex**: 5H: 0% | WK: 5% (Healthy)
     - **Antigravity**: 5H: 1% | WK: 5% (Healthy)
     - **Claude (KPAI)**: 5H: 0% | WK: 12% (Healthy)
   - Loop ticks apply exponential backoff / decelerator to prevent SQLite lock contention.

---

## 2. Dispatch Timeline & Milestones

| Timestamp (UTC) | Agent / Actor | Event | Details / Outcome |
| :--- | :--- | :--- | :--- |
| `2026-09-12T14:07:28Z` | `governor` | `LEASE_ACTIVATED` | Lease `ajm-auto-kanban-amxo-ee52cd034007` activated by `sublimino@gmail.com`. Digest `ad3624c07bcb14c3e572396c8625e97fc31219b1de99bb39f811a8952b65876b`. |
| `2026-09-12T15:46:00Z` | `opencode` | `AMXO-P0_DELIVERED` | Validated AMXO harness identity, integration branch, Kind cluster foundation, and Zot registry. Commit `ebd90f096bfc43bda100463f284941ffaa8caa19`. |
| `2026-09-12T18:00:00Z` | `opencode` | `AMXO-P1-PRE_DELIVERED` | Phase 1 baseline audit clean; audited operator routes, `agent_claim.py`, and `signal-ingest` collector endpoints. Preflight proof recorded. |
| `2026-09-12T20:30:59Z` | `opencode` | `AMXO-P1-2_DELIVERED` | Frozen host policy and privacy limits. Commit `aca5f51efc54095ba108f796f2a517fe5f8bb52d`. 37 pytest cases, 22 pinned unittests, Draft 2020-12 schemas verified. Proof: `docs/signalloom/amxo-p1-2-proof.md`. |
| `2026-09-12T21:09:24Z` | `opencode` | `AMXO-P1-1_DELIVERED` | Operator identity lifecycle implemented. Commit `363398237c202bba7abc6bfb493d3fc955acb79b`. Migration 038, 33 focused lifecycle tests, 95 tenant isolation tests, 1295 backend tests passed. Proof: `docs/signalloom/amxo-p1-1-proof.md`. |
| `2026-09-13T10:15:36Z` | `Council of Agents` | `COUNCIL_REVIEW_P1-1` | Evaluated AMXO-P1-1 (`32b57`): APPROVED. Dual-persisted to ledger & SQLite `task_run_reviews` with model `antigravity-gemini-3.8-flash`. Early P2-1 delivery noted for Governor reconciliation. |
| `2026-09-13T10:15:51Z` | `Council of Agents` | `COUNCIL_REVIEW_P1-2` | Evaluated AMXO-P1-2 (`2e369`): APPROVED. Dual-persisted to ledger & SQLite `task_run_reviews` with model `antigravity-gemini-3.8-flash`. Confinement boundaries and Draft 2020-12 schemas verified. |
| `2026-09-13T10:16:30Z` | `antigravity` | `DONE_ADVANCE_APPLIED` | Executed `done-advance --apply`. Verified P1-1 and P1-2 moved to Done column on AMXO board. |
| `2026-09-13T10:17:00Z` | `Council of Agents` | `COORDINATION_HANDOFF` | Notified peer agent `opencode` (tmux `def:5.0`). Next action: Governor merge of commits `36339823` and `aca5f51e` into `integration/agentmaxxing-onboarding-v0.1.0`, unblocking `AMXO-P1-3` (Architecture wire contracts) and `AMXO-P1-GOV`. |
