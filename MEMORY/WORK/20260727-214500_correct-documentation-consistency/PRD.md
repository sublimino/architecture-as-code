---
task: Correct confirmed documentation consistency findings now
slug: 20260727-214500_correct-documentation-consistency
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-27T21:45:00+01:00
updated: 2026-07-27T21:50:00+01:00
---

## Context

Correct five documentation inconsistencies confirmed by the repository audit: one supply-chain overclaim and four stale descriptions of implemented Signal Loom work or local lifecycle behavior.

## Criteria

- [x] ISC-1: Evidence README avoids blanket digest-binding claim.
- [x] ISC-2: Applications README describes vendored source accurately.
- [x] ISC-3: Contracts README describes committed bootstrap artifact accurately.
- [x] ISC-4: Infrastructure README describes existing workload manifests accurately.
- [x] ISC-5: Root README describes make up scope accurately.
- [x] ISC-6: Documentation retains scoped supply-chain limitations accurately.
- [x] ISC-7: Changed Markdown renders as valid plain documentation.
- [x] ISC-8: Documentation diff contains only confirmed consistency corrections.

## Decisions

- Preserve the detailed, scoped evidence limitations rather than overstating release readiness.

## Verification

- `git diff --check` passed.
- Focused searches confirm every audited stale sentence was removed.
- Manual diff review confirms five targeted prose corrections only.
- CodeReview capability was invoked, but roborev is not installed; focused manual diff review supplied the available verification.
