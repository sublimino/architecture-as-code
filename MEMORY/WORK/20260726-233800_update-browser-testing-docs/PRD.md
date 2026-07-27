---
task: Update browser testing documentation and human review guide
slug: 20260726-233800_update-browser-testing-docs
effort: extended
phase: complete
progress: 16/16
mode: interactive
started: 2026-07-26T23:34:50+01:00
updated: 2026-07-26T23:46:00+01:00
---

## Context
Andrew asked to update relevant browser-testing documentation consistently and provide a document suitable for human review. The decision is between `TESTING.md` as general engineering documentation and `HUMAN_VALIDATION.md` as an explicit review checklist. The preferred outcome is a canonical testing guide plus a focused human-validation handoff, without duplicating contradictory commands.

### Risks
- Root README currently contains stale claims that all eight browser tests passed.
- `test/acceptance/README.md` is boilerplate with an invalid run command.
- Technical instructions and human review steps can drift if duplicated.
- Current failures reflect missing Archivista and customer-portal services.

## Criteria
- [x] ISC-1: Existing browser-testing documentation locations are identified
- [x] ISC-2: Existing test commands are compared for consistency
- [x] ISC-3: Canonical browser test command is documented
- [x] ISC-4: Acceptance test prerequisites are documented
- [x] ISC-5: Port-forward mappings are documented
- [x] ISC-6: Dependency installation is documented
- [x] ISC-7: Browser artifact installation is documented
- [x] ISC-8: Failure artifact locations are documented
- [x] ISC-9: Trace inspection command is documented
- [x] ISC-10: Current passing test groups are documented
- [x] ISC-11: Current failing test groups are documented
- [x] ISC-12: Missing cluster services are explicitly documented
- [x] ISC-13: Human validation checklist file is created
- [x] ISC-14: Human checklist includes observable acceptance steps
- [x] ISC-15: Human checklist includes evidence capture fields
- [x] ISC-16: Documentation changes pass consistency review

## Decisions
- Create `TESTING.md` as the canonical technical testing guide.
- Create `HUMAN_VALIDATION.md` as the human-review checklist.
- Link both from the root README and acceptance README.
- Record the latest observed result as a dated baseline, not a permanent health claim.

## Verification
- ISC-1: Reviewed root README and acceptance README documentation.
- ISC-2: Replaced the invalid `bun run` example with the canonical root command.
- ISC-3: `TESTING.md` documents `make acceptance-test` as canonical.
- ISC-4: `TESTING.md` lists cluster, Bun, Chrome, and workload prerequisites.
- ISC-5: `TESTING.md` records all four managed port-forwards.
- ISC-6: Dependency installation uses `bun install --frozen-lockfile`.
- ISC-7: FFmpeg installation uses `bunx playwright install ffmpeg`.
- ISC-8: Report and per-test artifact paths are documented.
- ISC-9: Trace inspection command is documented in both guides.
- ISC-10: Four passing tests are recorded by test group.
- ISC-11: Four failing tests are recorded by test group.
- ISC-12: Missing Archivista and Olly services are explicitly named.
- ISC-13: `HUMAN_VALIDATION.md` provides the review handoff.
- ISC-14: Human checklist contains four service-area review sections.
- ISC-15: Human checklist contains reviewer, evidence, and conclusion fields.
- ISC-16: Documentation links and commands were checked after editing.
- Verification command passed: `bash -n scripts/acceptance-test.sh`.
- Verification command passed: `make -n acceptance-test`.
- Relative Markdown links resolved; external URLs were excluded from local checks.
- Pre-existing unrelated worktree changes were left untouched.
