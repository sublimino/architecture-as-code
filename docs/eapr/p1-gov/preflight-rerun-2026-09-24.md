# EAPR Phase 1 Governor independent preflight rerun — 2026-09-24

Created: 2026-09-24 08:49:58-05:00  
Result: certification refused before integration  
Decision: `status=fail proceed=no blocking_drift=yes`

## Contract identity

- Governor worktree: `/home/andy/src/.worktrees/osramp-demo/eapr-v0.1.0/governor`
- Checked-out branch: `integration/eapr-v0.1.0`
- Clean starting status: yes
- Starting integration HEAD: `cc8f16674ba378c0051eb9fa8d721ec54451497e`
- P1-4 card tip: `4621df93ed63e085abb90478a544e1904bad1ad4`
- `git merge-base --is-ancestor EAPR-P1-4 HEAD`: rc `1`
- P1-3 card tip: `1d15a906bcb4632d148f2f56468f3caefa336454`
- `git merge-base --is-ancestor EAPR-P1-3 HEAD`: rc `1`
- Phase 1 tag before this run: absent

The card's explicit hard-stop fired because the integration branch moved beyond
the P1-4 recorded base without containing the P1-4 reconciliation tip. The
governor therefore did not merge P1-4 or P1-3, run acceptance gates, or create
`integration/eapr-v0.1.0-p1`.

## Boundary chronology

The initial board snapshot reported `EAPR-P1-GOV` in progress while
`EAPR-P2-1` was already in progress. This governor did not start, restart,
approve, rebalance, or otherwise mutate any Phase 2 card. The observed state is
a pre-signature boundary violation; it is not a waiver of the human gate.

## Independent review

- Cato executable probe: unavailable, rc `127`.
- Same-family Architect review independently reproduced both ancestry failures.
- Same-family Algorithm review concluded certification must remain failed.
- Cross-vendor independence was therefore unavailable and is not claimed.

## Correct-repository doctor evidence

These commands used the required principal repository identity as the read-only
board lookup key while execution remained in the dedicated governor worktree.

| Shortcode | rc | Verdict | Prohibited evidence |
| :-------- | -: | :------ | :------------------ |
| SLEA | 1 | UNHEALTHY | state oscillation on task `cc2a3` |
| SLET | 1 | UNHEALTHY | state oscillation on task `7744e` |
| SLES | 1 | UNHEALTHY | two ZERO-OUTPUT cards; graph failure; state oscillation |
| SLED | 1 | UNHEALTHY | one ZERO-OUTPUT card; two oscillating tasks |
| ZZZZ | 0 | HEALTHY | invalid-shortcode positive control unexpectedly accepted |

The four required boards therefore fail the explicit no-`UNHEALTHY`,
no-`ZERO-OUTPUT` gate. The invalid-shortcode positive control also fails its
expected nonzero requirement.

## Mechanical cost evidence

The exact required `cost --update-table --apply` invocation returned rc `0`.
It updated one decomposition row plus two Governor spend tables in the canonical
Obsidian proposal. Relevant Phase 1 rows printed by the command were:

| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| EAPR-P1-PRE | $0.00 | N/A — subscription | 8m | `cpai-opencode-fast` |
| EAPR-P1-1 | $0.00 | N/A — subscription | 3m01s | `kpai://open?id=eaee6&dir=/home/andy/.cline/worktrees/eaee6/osramp-demo&host=fortuna&model=claude-3-7-sonnet` |
| EAPR-P1-2 | $0.00 | N/A — subscription | 9m46s | `kpai://open?id=6c8e4&dir=/home/andy/.cline/worktrees/6c8e4/osramp-demo&host=fortuna&model=claude-3-7-sonnet` |
| EAPR-P1-3 | $0.00 | N/A — subscription | 11m23s | `kpai://open?id=027af&dir=/home/andy/.cline/worktrees/027af/osramp-demo&host=fortuna&model=claude-3-7-sonnet` |
| EAPR-P1-4 | $0.00 | N/A — subscription | 3m33s | `kpai://open?id=7a512&dir=/home/andy/.cline/worktrees/7a512/osramp-demo&host=fortuna&model=claude-3-7-sonnet` |
| EAPR-P1-GOV | $0.00 | in 2.9M; out 25.9k; reason 10.7k; cache 4.6M | 12m17s | `cpai://open?id=ses_f2c60c119ffecP4p0iOV7ViLud&dir=/home/andy/.cline/worktrees/7ce29/osramp-demo&host=fortuna&model=gpt-5.6-sol` |

## Prior gate evidence retained, not re-claimed

The current branch already contains durable evidence from the immediately
preceding rerun:

- `bats-summary-2026-09-24.txt`: 375 expected, 375 executed, 375 passed,
  zero failed, zero skipped.
- `mutation-summary-2026-09-24.tsv`: rows 1–10 red-then-green; row 11
  green-then-green because the current test hardcodes the merged script.
- `impossibility-summary-2026-09-24.md`: forged marker becomes `claimed` and
  `corroborated=false`, but the absent card does not produce the required SKIP.
- `rerun-2026-09-24.md`: no retained live row exists for the required
  historical zero-output-card demonstration.

Those records explain why a previous rerun failed. This independent preflight
does not present them as newly executed evidence and does not repair their
owners' defects.

## Prompt-to-artifact audit

| Requirement | Current evidence | Result |
| :---------- | :--------------- | :----- |
| Dedicated worktree identity | path, branch, clean start | PASS |
| Four prerequisite markers | canonical proposal read through bridge earlier | PASS |
| P1-4 present on integration | ancestry rc `1` | FAIL — hard-stop |
| P2 held pending signature | P2-1 already in progress | FAIL |
| Fifteen BATS suites | prior durable 375/375 record | NOT RERUN |
| Eleven red-then-green mutations | prior row 11 green-then-green | FAIL |
| Forged marker explicit SKIP | prior card omitted from listing | FAIL |
| Retained zero-output proof | required rows unavailable | FAIL |
| SLEA doctor healthy | rc `1`, UNHEALTHY | FAIL |
| SLET doctor healthy | rc `1`, UNHEALTHY | FAIL |
| SLES doctor healthy | rc `1`, ZERO-OUTPUT plus UNHEALTHY | FAIL |
| SLED doctor healthy | rc `1`, ZERO-OUTPUT plus UNHEALTHY | FAIL |
| ZZZZ positive control nonzero | rc `0` | FAIL |
| Cost table updated | exact command rc `0` | PASS |
| P1-4 plus P1-3 merged | prohibited after hard-stop | NOT RUN |
| Offline acceptance baseline | no integration candidate | NOT RUN |
| Integration tag created | certification failed | NOT RUN |
| Canonical errata updated | Obsidian bridge exact-string verification | PASS |
| Remote push performed | prohibited | NOT RUN |
| Human signature created | principal-only action | NOT RUN |

## Containment

No tooling implementation, product code, integration merge, tag, remote ref,
pull request, board state, sibling worktree, protected base ref, or human review
line was changed. The canonical proposal's existing rerun errata was updated
through `obsidian-modify`; its marker remains:

`<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->`

Human final review required before any P2 card starts. The governor stops here.
