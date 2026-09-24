# EAPR-P1-1 — full kanban BATS suites against the staged copies (2026-09-24)

Ran `kanban-max-arg-strlen.bats` plus the 13 `ajm-auto-kanban-*.bats` / `ajm-cline-kanban-*.bats` suites twice on `/tmp` copies of the live `~/.andy_sync` tree (script sha `a1d453e4…` at copy time): once unpatched (baseline) and once with both patches applied. The suites could not be run in the real tree (Landlock); re-run there when the patch is applied.

| Copy | ok | not ok |
| :--- | :-: | :-: |
| orig | 298 | 47 |
| fix | 299 | 46 |

The single delta is the new static guard case (`not ok` unpatched → `ok` patched). Every other failure is identical between the two runs, i.e. pre-existing in the staged environment and not a regression from the patch:

| Suite | not ok (unpatched) | not ok (patched) |
| :--- | :-: | :-: |
| ajm-auto-kanban-mission-key.bats | 23 | 23 |
| ajm-auto-kanban-subscription-balancing.bats | 7 | 7 |
| ajm-cline-kanban-proposal-to-card.bats | 6 | 6 |
| ajm-cline-kanban-shortcode.bats | 10 | 10 |
| strlen | 1 | 0 |

Raw TAP lines: `suites-unpatched.tap`, `suites-patched.tap`.
