---
task: Locate missing demo Kubernetes AFM make command
slug: 20260731-143500_locate-demo-kubernetes-afm-make-command
effort: standard
phase: complete
progress: 8/8
mode: interactive
started: 2026-07-31T14:35:00+01:00
updated: 2026-07-31T14:36:50+01:00
---

## Context

Andrew needs the `make demo-k8s-afm-up` command for this repository. It may be present in the worktree, reachable history, unreachable Git objects, or a nearby accidental filesystem location. This is read-only forensic discovery: do not alter repository content or invent a command without evidence.

### Risks

- Git garbage collection may already have pruned unreachable objects.
- The remembered target name may differ slightly from the stored target.
- Candidate filesystem locations can contain unrelated copies.

## Criteria

- [x] ISC-1: Current tracked files are searched for exact command text.
- [x] ISC-2: Current untracked files are searched for exact command text.
- [x] ISC-3: Reachable Git history is searched for exact command text.
- [x] ISC-4: Dangling Git commits are enumerated using Git fsck.
- [x] ISC-5: Dangling commit trees are searched for command text.
- [x] ISC-6: Git reflogs are searched for relevant historical references.
- [x] ISC-7: Nearby candidate filesystem locations are searched for command text.
- [x] ISC-8: Report identifies evidence-backed command location or absence.

## Decisions

- Treat `demo-k8s-afm-up` as the authoritative search token.
- Keep investigation read-only to preserve potential forensic evidence.

## Verification

- ISC-1: Root exact-token search returned no tracked-worktree match.
- ISC-2: Untracked-file search found the target only in ignored nested worktrees.
- ISC-3: `git log -S` found introduction commit `86b956ab381e8a551978ba761064bd743d091a90`.
- ISC-4: `git fsck --full --no-reflogs --unreachable` enumerated unreachable objects.
- ISC-5: Each unreachable commit tree was searched; no target match found.
- ISC-6: `git reflog --all` exact-token search returned no match.
- ISC-7: Bounded sibling-directory search returned no match.
- ISC-8: Verified target at nested Makefile lines 302-304, ignored by global `worktrees/` rule.
- Capability check: `explore` agent invoked in BUILD and returned independent forensic results.
