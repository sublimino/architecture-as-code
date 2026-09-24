# EAPR-P1-1 — D0 evidence bundle (2026-09-24)

Everything this card produced that is not in the Obsidian vault or the kanban runtime lives here. Nothing under `docs/eapr/p1-1/` is product code.

## Why there are patches instead of a `~/.andy_sync` commit

`~/.andy_sync` was Landlock-denied for writes and for `git` in the session that ran this card (`touch` → `Permission denied`, `git -C ~/.andy_sync status` → `fatal: not a git repository`; the same with the harness sandbox disabled). The tooling change was therefore built and proven on a `/tmp` copy of the live tree and is shipped as two unified diffs. Apply from a write-enabled session:

```bash
cd ~/.andy_sync
git status --porcelain -- confExt/skills/ajm-auto-kanban test   # must be empty (sibling cards edit this tree live)
patch -p1 < /path/to/osramp-demo/docs/eapr/p1-1/kanban-check-cost-envp.patch
patch -p1 < /path/to/osramp-demo/docs/eapr/p1-1/kanban-max-arg-strlen.bats.patch
bats test/kanban-max-arg-strlen.bats
git -c log.showSignature=false log --pretty='%h %G? %s' -6           # match the signing practice you see
git add confExt/skills/ajm-auto-kanban/Tools/kanban-check.sh test/kanban-max-arg-strlen.bats
git commit --no-gpg-sign -m 'fix: delete COST_BOARD_CARDS envp fallback in cost; file is the only transport' 
```

`patch --dry-run -p1` was verified against the live script at sha256 `2d2ad8f2…` (hunk applies at an offset because P1-2 is editing the same file concurrently). Re-run the dry-run before applying.

## Files

| File | What it proves |
| :--- | :--- |
| `kanban-check-cost-envp.patch` | Surgical deletion of the `elif 'COST_BOARD_CARDS' in os.environ:` branch and its 4-line body in `cmd_cost`; nothing else. |
| `kanban-max-arg-strlen.bats.patch` | Three new cases: env payload ignored (behavioural, drives the embedded Python with the file absent), single-transport static guard, 200 KiB env kills `execve` of the script itself. |
| `bats-mutation-red-unpatched.txt` | The three cases against the unpatched script: case 2 (static guard) fails — the mutation is killed by that case. Cases 1 and 3 pass on both, because the env branch was already unreachable through the CLI (the file is always created), which is exactly why it was dead code. |
| `bats-mutation-green-patched.txt` | The three cases against the patched script: 3/3 ok. |
| `cost/cost-<SC>.json` | `kanban-check.sh cost --json` output for SLEA, SLET, SLES, SLED after the archive step; every figure in the vault tables traces to these files. |
| `cost/cost-ZZZZ-control.json` | Nonexistent shortcode: rc=0 with `tasks: []`. Exit 0 is NOT a verdict for `cost`; the content is. |
| `cost/update-table-apply-<SC>.txt` | `cost --update-table --apply` run on a temp copy of each proposal (rc=0 ×4). SLET/SLES: 0 rows changed (tables already equal tool output). |
| `cost/table-diff-<SC>.diff` | Exact line diffs the tool produced (SLEA 2 lines, SLED 6 lines + one insertion into the WITHDRAWN tombstone that was deliberately not applied). |
| `zero-output-disposition.md` | 64 rows: 61 archived, 3 kept in done with commit SHAs. |
| `archive-dryrun.log`, `archive-apply.log` | Dry-run preceded every apply; one torn-read failure and its retry. |
| `leases.md` | Part C: every MissionState verb refuses all five capsules (`mission digest integrity check failed`); root cause is a 2026-09-23 22:12 proposal-path rewrite that skipped re-digesting. Nothing mutated. |
| `tombstone-<ID>.md` | The two errata blocks appended through the Obsidian bridge (the `**Original block:**` line was later rewritten to drop the literal `#### Errata —` text, which `done-check`'s block splitter treats as a heading). |
| `done-check-<ID>-after.json` | `status=fail proceed=no blocking_drift=yes source=tag` for both certificates. |
| `doctor.md` | Doctor on the four boards after archiving plus the EAPR positive control. |

## Second envp site (finding, not changed)

`cmd_cost` carries a twin fallback `elif 'COST_TASKS' in os.environ: raw = os.environ['COST_TASKS']` a few lines above the deleted one. It has the same shape and the same dead-code status. It was left in place because the card scoped the deletion to `COST_BOARD_CARDS` and asked for a diff that touches nothing else. P1-2 or P1-GOV should decide whether to remove it under the same guard pattern.
