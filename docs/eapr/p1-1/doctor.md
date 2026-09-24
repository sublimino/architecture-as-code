# EAPR-P1-1 Part E — kanban-check.sh doctor on the four legacy EAP boards (2026-09-24, after archiving)

Command per board: `kanban-check.sh doctor --repo /home/andy/src/cp/osramp-demo --shortcode <SC> --proposal '<vault path>'`. Script at the time: sha256 `a1d453e4…` (P1-2's live edits; P1-PRE's pin `1e4f3dba…` was already superseded).

Positive control (a board with a *different* exception class): `doctor --shortcode EAPR` → rc=1, `DANGLING / UNREFERENCED COMMITS (DOC-7) — 2 unreferenced commit(s)`, `Doctor Status: UNHEALTHY (1 exception(s))`. Doctor prints exceptions when they exist, so a clean ZERO-OUTPUT check below is a verdict, not silence.

## SLEA

```
5:[!] ERRATA 1-TO-1 MISMATCH (DOC-1) — 14 card(s) in done lack matching errata block in proposal:
22:[!] STATE OSCILLATION DETECTED (DOC-6):
24:  ✗ Task cc2a3      | SLEA-P4-GOV: Final mission certification: end-to-end kurasi EAP environment spin… | Oscillation: running: 4x, awaiting_review: 2x, 
27:[!] DANGLING / UNREFERENCED COMMITS (DOC-7) — 2 unreferenced commit(s) created within active card/process timeframe risk permanent loss on git gc:
32:Doctor Status: UNHEALTHY (3 exception(s) require remediation)
```

## SLET

```
5:[!] ERRATA 1-TO-1 MISMATCH (DOC-1) — 14 card(s) in done lack matching errata block in proposal:
22:[!] STATE OSCILLATION DETECTED (DOC-6):
24:  ✗ Task 7744e      | SLET-P4-GOV: Final Mission Certification: Full tenant isolation & identity relea… | Oscillation: running: 4x, awaiting_review: 2x, 
27:[!] DANGLING / UNREFERENCED COMMITS (DOC-7) — 2 unreferenced commit(s) created within active card/process timeframe risk permanent loss on git gc:
32:Doctor Status: UNHEALTHY (3 exception(s) require remediation)
```

## SLES

```
5:[!] GRAPH INTEGRITY FAIL:
15:[!] ZERO-OUTPUT CARD(S) DETECTED:
17:  ✗ Task eb830    | Agent: unknown            | State: done            | Output Lines: 0
18:  ✗ Task 081b4    | Agent: unknown            | State: done            | Output Lines: 0
20:[!] ERRATA 1-TO-1 MISMATCH (DOC-1) — 14 card(s) in done lack matching errata block in proposal:
37:[!] STATE OSCILLATION DETECTED (DOC-6):
39:  ✗ Task ade77      | SLES-P4-GOV: Final Mission Certification: Full scenario & audit seeding release | Oscillation: running: 4x, awaiting_review: 2x, fail
42:[!] DANGLING / UNREFERENCED COMMITS (DOC-7) — 2 unreferenced commit(s) created within active card/process timeframe risk permanent loss on git gc:
47:Doctor Status: UNHEALTHY (5 exception(s) require remediation)
```

## SLED

```
5:[!] ZERO-OUTPUT CARD(S) DETECTED:
7:  ✗ Task d20eb    | Agent: unknown            | State: done            | Output Lines: 0
9:[!] ERRATA 1-TO-1 MISMATCH (DOC-1) — 13 card(s) in done lack matching errata block in proposal:
25:[!] STATE OSCILLATION DETECTED (DOC-6):
27:  ✗ Task 255ff      | SLED-P4-GOV: Final Mission Certification: Full lifecycle & auto-reaping release | Oscillation: running: 3x, awaiting_review: 2x (5 tr
29:  ✗ Task 90790      | SLED-P2-GOV: Certify Phase 2 background task stability and resource isolation | Oscillation: running: 2x, failed: 2x (5 transitions)
32:[!] DANGLING / UNREFERENCED COMMITS (DOC-7) — 2 unreferenced commit(s) created within active card/process timeframe risk permanent loss on git gc:
37:Doctor Status: UNHEALTHY (4 exception(s) require remediation)
```

## ZERO-OUTPUT check (:5451 in the pinned script; cmd_output_check)

| Board | ZERO-OUTPUT before (P1-PRE) | ZERO-OUTPUT after | Remaining ids | Why remaining |
| :--- | :-: | :-: | :--- | :--- |
| SLEA | 14 | 0 | — | all 14 archived |
| SLET | 14 | 0 | — | all 14 archived |
| SLES | 14 | 2 | `eb830` SLES-P4-1, `081b4` SLES-P3-2 | kept in done: named in reachable commit `5c74d7b9` (card rule: commit exists → keep, record SHA) |
| SLED | 8 | 1 | `d20eb` SLED-P2-2 | kept in done: named in reachable commit `150404e0` |

Other exception classes (ERRATA 1-TO-1 MISMATCH DOC-1, STATE OSCILLATION DOC-6, DANGLING COMMITS DOC-7, SLES GRAPH INTEGRITY) are pre-existing and outside this card (P1-2 doctor scope fix, P4-2 re-audit).
