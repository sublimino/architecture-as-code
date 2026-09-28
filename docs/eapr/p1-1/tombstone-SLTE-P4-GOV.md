
#### Errata — SLTE-P4-GOV WITHDRAWN (2026-09-24)
**Created:** 2026-09-24 01:46:27+01:00
**Last Updated:** 2026-09-24 01:46:27+01:00
**Status:** fail — certificate 37705875 withdrawn by EAPR-P1-1; the provisioning capability it certified is deleted by D10
**Card ID / Role / Band:** `SLTE-P4-GOV` / Governor / L
**Withdrawn by:** EAPR-P1-1 (D0, 2026-09-24)
**Original block:** `#### Errata — SLTE-P4-GOV Final Mission Certification (2026-09-23 03:34:30+01:00)` above is left untouched as evidence. Its merge commit `377058754c9b119d107d6403fb6f02f7227c6fd9` remains reachable from `integration/slte-v0.1.0` but does not certify anything.
**Reason:** The P4-GOV session produced zero assistant output (spend rows P4-1/P4-2/P4-GOV read `N/A — no session`). SLTE-P4-PRE `3c0a3c63` audited the implementation as NO-GO as a security boundary (G9: unauthenticated `/api/v1/environments/*`), and the RE-SCOPE block (2026-09-23) already declares the third-party provisioning premise withdrawn; EAPR D10 deletes that capability. done-check reads the last tag for a card ID, so this block supersedes the pass tag above.
**Re-certification:** EAPR-P3-4 (D10 re-scope) then EAPR-P4-3 (D8). Any evidence citing SLTE-P4-GOV must cite this withdrawal.
<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
