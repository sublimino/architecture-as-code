---
task: Check documentation correctness and consistency comprehensively
slug: 20260727-205500_audit-documentation-consistency
effort: advanced
phase: plan
progress: 0/24
mode: interactive
started: 2026-07-27T20:55:00+01:00
updated: 2026-07-27T20:59:00+01:00
---

## Context

Audit repository documentation for correctness and consistency against current source, runtime outcomes, and related documents. Report actionable discrepancies without modifying documentation.

### Risks

- Historical evidence can be factually accurate but misleading if presented as current runtime status.
- Some documentation commands intentionally require local cluster prerequisites and cannot be executed safely during a read-only audit.

## Criteria

- [ ] ISC-1: Documentation inventory is counted by repository area.
- [ ] ISC-2: Root README commands are checked against Make targets.
- [ ] ISC-3: Signal Loom documentation is checked against current manifests.
- [ ] ISC-4: Signal Loom documentation is checked against current test targets.
- [ ] ISC-5: Zot documentation is checked against current cache behavior.
- [ ] ISC-6: Gateway documentation is checked against current routes.
- [ ] ISC-7: OIDC documentation is checked against current configuration.
- [ ] ISC-8: NetworkPolicy documentation is checked against current policies.
- [ ] ISC-9: Runtime claims are distinguished from static evidence.
- [ ] ISC-10: Historical errata are distinguished from current source truth.
- [ ] ISC-11: Cross-document contradictions are identified with locations.
- [ ] ISC-12: Broken local file references are identified.
- [ ] ISC-13: Broken Make target references are identified.
- [ ] ISC-14: Obsolete branch references are identified.
- [ ] ISC-15: Obsolete phase status claims are identified.
- [ ] ISC-16: Security claims are checked against implemented controls.
- [ ] ISC-17: Deployment commands are checked for executable syntax.
- [ ] ISC-18: Documentation scope exclusions are recorded accurately.
- [ ] ISC-19: Findings are ranked by operational impact.
- [ ] ISC-20: Findings include exact source locations.
- [ ] ISC-21: No documentation is modified during the audit.
- [ ] ISC-22: Independent reviewers assess separate documentation domains.
- [ ] ISC-23: A remediation sequence is proposed for confirmed findings.
- [ ] ISC-24: Audit limits are explicitly reported to Andrew.

## Decisions

- Audit only; no documentation rewrites without Andrew's approval.

## Verification
