# Reference: Multi-Agent Worktree Lifecycle & Branch Authority

## 1. Worktree Conventions in Signal Loom

Signal Loom utilizes parallel coding agents running in isolated Git worktrees to implement multi-step initiatives (e.g. SLCD, SLDP, SLER, SLES, AMXD).

### Directory Locations
- Primary worktrees: `~/src/.worktrees/<repo>/<branch>/`
- Cline / Kanban worktrees: `~/.cline/worktrees/<hash>/<repo>/`
- Repo-local worktrees: `.claude/worktrees/` (legacy/subagent)

### Critical Isolation Rules
- **NEVER execute implementation or mutation commands in `/home/andy/src/cp/osramp-demo`** — that is the principal's checkout.
- Automated tasks must verify `$PWD != /home/andy/src/cp/osramp-demo` before modifying files or running test mutations.

---

## 2. Rebase & Merge Discipline

Before merging any worktree branch into the main integration branch (`feat/signal-loop-and-bootstrap-refactor` or `integration/slsi-v0.1.0`):
1. **Commit cleanly**: Use scope-less Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`).
2. **Fetch and Rebase**:
   ```bash
   git fetch origin
   git rebase origin/<target-branch>
   ```
3. **Verify offline pyramid**: Run `make docs-lint` and `make test-all-offline` in the worktree.
4. **Merge down carefully**: Fast-forward or non-fast-forward merge according to governor instructions.
5. **Prune worktree**: `git worktree remove <path>`.

---

## 3. Kanban Controller Leases

- The Kanban controller records active mission state in `board.json` and lease files.
- If an agent crashes mid-turn, its lease may remain active (`state.lease.name`).
- Running `kanban-check.sh doctor --repo .` inspects and releases stranded leases safely.
