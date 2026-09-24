# EAPR-P1-GOV Step 0 Refusal Evidence

Created: 2026-09-23 20:44:10-05:00
Last Updated: 2026-09-23 20:44:10-05:00

## Verdict

Phase 1 is not certified. The governor stopped before merging because a declared
prerequisite could not be verified under the card's explicit STOP conditions.
Phase 2 remains blocked pending human resolution. Predecessor governors: none.

## Repository boundary

- Worktree: `/home/andy/src/.worktrees/osramp-demo/eapr-v0.1.0/governor`
- Branch: `integration/eapr-v0.1.0`
- Initial integration tip: `844afa5acd2bef019641bb915bc8a63aa9c6e0d4`
- Protected base tip: `c429beea958ace9ee12752271c99542e5e6e4af7`
- Initial tracked status: clean

## Step 0 prerequisite evidence

The canonical proposal contains pass markers for EAPR-P1-1 through EAPR-P1-4.
The following osramp-demo refs were resolved locally:

| Card | Ref result |
| :--- | :--------- |
| EAPR-P1-1 | `36302b49fe304ddf6c6093ec8445d036e1dbfbda` |
| EAPR-P1-2 | missing (`git show-ref` rc `1`) |
| EAPR-P1-3 | `1d15a906bcb4632d148f2f56468f3caefa336454` |
| EAPR-P1-4 | `4621df93ed63e085abb90478a544e1904bad1ad4` |

The proposal records P1-2 as eleven commits landed directly on
`~/.andy_sync` master and records no osramp-demo delivery branch. Live Git
inspection of `/home/andy/.andy_sync` returned `fatal: not a git repository`
despite a positive `stat` proving the directory exists. This is a sandbox
visibility denial, not evidence that the repository is absent.

The explicit card condition says that any missing P1 implementation branch, an
unresolved commit, or a commit not on its branch requires `status=fail`,
`proceed=no`, and no merge. Consequently the governor did not merge P1-3 or
P1-4, did not advance the sync master ref, did not create the integration tag,
and did not run certification suites whose authoritative merged skill could not
be constructed.

## Independent review

A cross-vendor Gemini reviewer independently recommended fail-closed. It found
the missing osramp-demo P1-2 branch technically plausible for cross-repository
delivery but procedurally blocking under the literal contract. It specifically
rejected creating a cosmetic branch to conceal the ambiguity.

## Board containment

The pre-integration progress snapshot reported EAPR-P1-GOV in progress and every
P2 card in backlog. No P2 card was started. No raw board file, task record,
dependency record, sibling worktree, remote ref, or protected base ref was
modified.

## Required remediation

Provide authoritative repository-scoped provenance for EAPR-P1-2: full commit
SHAs, object resolution, ancestry from the intended `~/.andy_sync` master, and
an explicit ruling that direct-to-master delivery satisfies the branch gate.
Then rerun EAPR-P1-GOV from Step 0 in an environment permitted to inspect and
test `/home/andy/.andy_sync`.

Human final review required before any P2 card starts.

<!-- kanban-check: status=fail proceed=no blocking_drift=yes -->
