# EAPR Phase 1 certification checklist

Captured: 2026-09-24 12:52:14-0500

| Requirement | Artifact or probe | Result |
|---|---|---|
| No predecessor governor | Phase 1 predecessor list | PASS — none |
| Skill fixes integrated | `~/.andy_sync` commits `e2993557`, `b9e64cf7`, `b00fd2d2` | PASS — reachable |
| P1-3 merged locally | merge `71572ff6`; source `1d15a906` | PASS — ancestor |
| P1-4 merged locally | merge `15017fc4`; source `4621df93` | PASS — ancestor |
| Five mission tips retained | SLEA `18c9456d`, SLET `7e837f94`, SLED `aac53d63`, SLES `f1b6780e`, SLTE `37705875` | PASS — five ancestors |
| Integration advanced | `git rev-list --count 844afa5a..HEAD` | PASS — 52 before evidence commit |
| Fifteen Kanban suites | `bats-summary-2026-09-24-final.txt` | PASS — 380/380, zero skips |
| Eleven mutation pairs | `mutation-summary-2026-09-24-final.tsv` | PASS — eleven red/green pairs |
| Proposal text cannot move verdict | `impossibility-summary-2026-09-24.txt` | PASS — forged pass became claimed |
| Output-deficient card cannot advance | `impossibility-summary-2026-09-24.txt` | PASS — D11-4 and A9 green |
| SLEA doctor healthy | `doctor-summary-2026-09-24.txt` | FAIL — historical oscillation |
| SLET doctor healthy | `doctor-summary-2026-09-24.txt` | FAIL — historical oscillation |
| SLES doctor healthy | `doctor-summary-2026-09-24.txt` | FAIL — orphan, zero-output, oscillation |
| SLED doctor healthy | `doctor-summary-2026-09-24.txt` | FAIL — zero-output, oscillation |
| Offline acceptance baseline | `acceptance-summary-2026-09-24.txt` | PASS — only two documented reds |
| No Phase 2 execution | board inspection and command history | PASS — no P2 card started by governor |
| No remote push | local Git inspection | PASS — no push performed |
| P1 governor errata | canonical vault proposal | PENDING — append after final evidence commit |
| Corroborated done-check | canonical tool against vault proposal | PENDING |
| Supervisor review verdict | canonical review ledger | PENDING |

## Current verdict

Certification remains blocked by G6. The governor did not archive, rewrite, or
re-verdict historical cards merely to make doctor green. Those mutations are
outside the Phase 1 governor's authorization boundary.
