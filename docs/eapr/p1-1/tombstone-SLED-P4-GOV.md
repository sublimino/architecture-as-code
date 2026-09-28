
#### Errata — SLED-P4-GOV WITHDRAWN (2026-09-24)
**Created:** 2026-09-24 01:46:27+01:00
**Last Updated:** 2026-09-24 01:46:27+01:00
**Status:** fail — certificate withdrawn by EAPR-P1-1; governor row reads N/A — no session; predecessors SLED-P2-GOV and SLED-P3-GOV are status=fail
**Card ID / Role / Band:** `SLED-P4-GOV` / Governor / L
**Withdrawn by:** EAPR-P1-1 (D0, 2026-09-24)
**Original block:** `#### Errata — SLED-P4-GOV Final Mission Certification: Full lifecycle & auto-reaping release` above is left untouched as evidence of the hollow certificate. Its checkpoint `aac53d634fdf75b5c9a502acd2b5be48198ec6fe` is a governor-worktree checkpoint, not a certification.
**Reason:** The P4-GOV session produced zero assistant output (spend row reads `$0.00 / N/A — no session`), and the certificate was issued over two failed predecessors: SLED-P2-GOV `150404e0` (fail: SLED-P2-2 never delivered, D1 OpenMetrics blocking) and SLED-P3-GOV `6f0b1523` (fail: Stage 3/4 not established). done-check reads the last tag for a card ID, so this block supersedes the pass tag above.
**Re-certification:** EAPR-P4-3 (D8 governor chain criterion). Any Investor Diligence or Go-Live evidence citing SLED-P4-GOV must cite this withdrawal.
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
