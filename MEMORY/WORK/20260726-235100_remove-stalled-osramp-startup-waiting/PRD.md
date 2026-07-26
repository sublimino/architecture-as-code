---
task: Remove stalled osramp startup namespace waiting behavior
slug: 20260726-235100_remove-stalled-osramp-startup-waiting
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-26T23:51:27+01:00
updated: 2026-07-26T23:55:00+01:00
---

## Context

Remove the post-reconciliation `make workload-key` invocation from `scripts/osramp-up.sh`. It waits up to five minutes for `frontend` after the script has already performed a bounded namespace check. Preserve ResourceSet restoration, reconciliation, and the independent Make target. Do not remove unrelated lifecycle behavior.

### Risks

- The signing key may be absent after startup; this change intentionally removes the automatic recreation step requested by the observed stalled output.

## Criteria

- [x] ISC-1: OSRAMP startup omits workload-key target invocation.
- [x] ISC-2: OSRAMP startup omits workload-key status announcement.
- [x] ISC-3: OSRAMP startup omits workload-key warning fallback.
- [x] ISC-4: ResourceSet input restoration remains in osramp-up script.
- [x] ISC-5: ResourceSet reconciliation annotation remains in osramp-up script.
- [x] ISC-6: Existing namespace appearance timeout remains bounded.
- [x] ISC-7: Makefile workload-key target remains available independently.
- [x] ISC-A-1: No unrelated OSRAMP lifecycle files are changed.

## Decisions

- Remove the caller, not the reusable `workload-key` Make target, because the reported stall originates from the caller and the target may remain useful independently.

## Verification

- ISC-1 through ISC-3: `git diff -- scripts/osramp-up.sh` shows only removal of the automatic `workload-key` block.
- ISC-4 through ISC-6: source inspection confirms ResourceSet input restore, reconciliation annotation, and existing 60-second namespace loop remain.
- ISC-7: `Makefile` retains the standalone `workload-key` target.
- ISC-A-1: source diff changes only `scripts/osramp-up.sh`.
- Syntax and dry-run: `bash -n scripts/osramp-up.sh`, `make -n demo-osramp-up`, and `git diff --check` passed.
- CodeReview capability invoked. `roborev` is unavailable in this environment, so automated review produced no findings report.
