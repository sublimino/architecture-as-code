# AMXO-P1-3 failure evidence and unpublished errata

No schema validation run is claimed. See [prerequisite proof](amxo-p1-3-proof.md)
for exact commands, dependency evidence, and the unfulfilled-deliverable audit.

The following block is **not published to the proposal**. The Commit field
identifies the durable baseline at the time of recording; the failure-evidence
commit SHA is reported separately at closeout. The Governor should use that
failure-evidence SHA when publishing the block after resolving the documented
proposal-location discrepancy.

#### Errata — AMXO-P1-3 Freeze versioned architecture wire contracts and service ownership
**Created:** 2026-09-13 11:24:41+01:00
**Last Updated:** 2026-09-13 11:24:41+01:00
**Status:** Failed
**Commit:** ebd90f096bfc43bda100463f284941ffaa8caa19 (baseline; implementation not started)
**Blocker:** The authorized integration-derived checkout does not contain prerequisite P1-1 commit 363398237c202bba7abc6bfb493d3fc955acb79b or P1-2 commit aca5f51efc54095ba108f796f2a517fe5f8bb52d, contrary to the card's already-merged dependency contract.
**Attempted:** Verified worktree isolation, prescribed integration ancestry, both dependency object types and ancestry, read the supplied proposal, and ran the read-only board progress and AMXO doctor. Did not merge, rebuild prerequisites, or substitute another base. Checked Obsidian bridge health and read the same-titled note before any proposed write.
**Evidence:** Both git cat-file probes returned commit with exit 0; both git merge-base --is-ancestor dependency-SHA HEAD probes returned exit 1. HEAD and integration were ebd90f096bfc43bda100463f284941ffaa8caa19. AMXO doctor was healthy but does not establish dependency ancestry. docs/signalloom/amxo-p1-3-proof.md records the complete gate results. The Obsidian note lacks the required Appendix and P1-3 Result row, so this block remains unpublished rather than being inserted into a substitute section.
**Recommended action:** remediate — Governor reconciles prerequisite commits into integration, runtime supplies the corrected integration-derived checkout, and the principal or Governor resolves the canonical proposal Appendix location before retrying P1-3.
<!-- kanban-check: status=fail proceed=no blocking_drift=no -->

Required Result cell after canonical proposal resolution:

`fail — P1-1/P1-2 prerequisite commits absent from authorized integration baseline (see Errata — AMXO-P1-3)`
