# EAPR-P1-1 Part B — zero-output done cards: disposition (2026-09-24)

Source list: EAPR proposal `### Spec: Shared Patterns — Phase 1` → `SP-P1-3` (64 ids; the card text said "thirteen", P1-PRE named 64 and assigned all of them to P1-1).

Evidence per card (all probed 2026-09-24 00:50–01:10 BST): `task_runs` rows and `sessions` rows in `~/.cline/kanban/kanban.sqlite` (`task_id LIKE '<id>%'`), worktree directory under `~/.cline/worktrees/<id>/` or `~/src/.worktrees/<id>/`, `git worktree list` entry, any branch matching the id or card ID, and `git log --all --grep=<card-id>`. Positive control: `ls ~/src/.worktrees` lists 259 worktrees, so an empty result is a real absence, not a sandbox blank.

| Card | Task id | Board | runs | sessions | worktree | branch | commit naming the card | Action | Evidence |
| :--- | :--- | :--- | :-: | :-: | :-: | :-: | :--- | :--- | :--- |
| SLEA-P0 | `1a298` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 1a298 |
| SLEA-P1-PRE | `b3697` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task b3697 |
| SLEA-P1-1 | `dbbca` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task dbbca |
| SLEA-P1-2 | `e4237` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task e4237 |
| SLEA-P1-GOV | `b1033` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task b1033 |
| SLEA-P2-PRE | `79978` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 79978 |
| SLEA-P2-1 | `c1df3` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task c1df3 |
| SLEA-P2-2 | `6275e` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 6275e |
| SLEA-P2-GOV | `e09f6` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task e09f6 |
| SLEA-P3-PRE | `eb9e1` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task eb9e1 |
| SLEA-P3-1 | `d7d8f` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task d7d8f |
| SLEA-P3-2 | `bacb6` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task bacb6 |
| SLEA-P3-GOV | `d9e40` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task d9e40 |
| SLEA-P4-1 | `619fd` | SLEA | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 619fd |
| SLET-P0 | `6ab28` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 6ab28 |
| SLET-P1-PRE | `8b59c` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 8b59c |
| SLET-P1-1 | `5377e` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 5377e |
| SLET-P1-2 | `a4105` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task a4105 |
| SLET-P1-GOV | `05bc0` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 05bc0 |
| SLET-P2-PRE | `bd794` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task bd794 |
| SLET-P2-1 | `f3580` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task f3580 |
| SLET-P2-2 | `b21df` | SLET | 0 | 0 | none | none | 0 | archived on retry | first attempt hit a torn read of kanban-check.sh (sibling edit at 01:49); retry: ✓ Archived task b21df |
| SLET-P2-GOV | `31b19` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 31b19 |
| SLET-P3-PRE | `2e629` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 2e629 |
| SLET-P3-1 | `0ed34` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 0ed34 |
| SLET-P3-2 | `11867` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 11867 |
| SLET-P3-GOV | `1ad84` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 1ad84 |
| SLET-P4-1 | `3352c` | SLET | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 3352c |
| SLES-P0 | `0aa3a` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 0aa3a |
| SLES-P1-PRE | `4dd28` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 4dd28 |
| SLES-P1-1 | `3a86e` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 3a86e |
| SLES-P1-2 | `45aa8` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 45aa8 |
| SLES-P1-GOV | `ea80f` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task ea80f |
| SLES-P2-PRE | `51104` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 51104 |
| SLES-P2-1 | `77d79` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 77d79 |
| SLES-P2-2 | `65481` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 65481 |
| SLES-P2-GOV | `d16f3` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task d16f3 |
| SLES-P3-PRE | `c347a` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task c347a |
| SLES-P3-1 | `de3b9` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task de3b9 |
| SLES-P3-2 | `081b4` | SLES | 0 | 0 | none | none | 1 | kept in done | `5c74d7b9615c406952e1ebd42993b22c4a64888b` (osramp-demo, reachable from `integration/sles-v0.1.0`; SLES-P4-GOV governor commit that names this card) |
| SLES-P3-GOV | `5f58f` | SLES | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 5f58f |
| SLES-P4-1 | `eb830` | SLES | 0 | 0 | none | none | 1 | kept in done | `5c74d7b9615c406952e1ebd42993b22c4a64888b` (osramp-demo, reachable from `integration/sles-v0.1.0`; SLES-P4-GOV governor commit that names this card) |
| SLED-P0 | `a80fa` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task a80fa |
| SLED-P1-PRE | `71e41` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 71e41 |
| SLED-P1-1 | `6d3b8` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 6d3b8 |
| SLED-P1-2 | `ce0a6` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task ce0a6 |
| SLED-P1-GOV | `1189e` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 1189e |
| SLED-P2-2 | `d20eb` | SLED | 0 | 0 | none | none | 1 | kept in done | `150404e06c2653f070b1c1e529d634df1f987668` (osramp-demo, reachable from `integration/sled-v0.1.0`; SLED-P2-GOV commit that names this card) |
| SLED-P3-2 | `82535` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 82535 |
| SLED-P4-1 | `e4c60` | SLED | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task e4c60 |
| SLTE-P0 | `33ea0` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 33ea0 |
| SLTE-P1-PRE | `5dbbc` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 5dbbc |
| SLTE-P1-1 | `acf26` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task acf26 |
| SLTE-P1-2 | `f95e2` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task f95e2 |
| SLTE-P1-GOV | `d7bb0` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task d7bb0 |
| SLTE-P2-PRE | `f7a57` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task f7a57 |
| SLTE-P2-1 | `cbc9c` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task cbc9c |
| SLTE-P2-2 | `13dab` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 13dab |
| SLTE-P2-GOV | `d553f` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task d553f |
| SLTE-P3-PRE | `94f4d` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 94f4d |
| SLTE-P3-1 | `38b7c` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 38b7c |
| SLTE-P3-2 | `e53ce` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task e53ce |
| SLTE-P3-GOV | `a4c07` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task a4c07 |
| SLTE-P4-1 | `0fff3` | SLTE | 0 | 0 | none | none | 0 | archived (`kanban-check.sh archive --apply`, reason: zero-output) | ✓ Archived task 0fff3 |

Totals: 61 archived, 3 kept in done with commit evidence, 0 preservation branches needed (no untracked or unreffed work found). Reversal: `kanban-check.sh unarchive --task-id <id> --apply`.
